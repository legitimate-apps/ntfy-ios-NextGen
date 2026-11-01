import Foundation
import UIKit

/// Legacy MDM app configuration works on iOS 15 without an additional capability.
/// All store access and reconciliation is serialized on the main queue.
final class ManagedConfiguration: NSObject {
    static let configurationKey = "com.apple.configuration.managed"
    static let feedbackKey = "com.apple.feedback.managed"
    static let shared = ManagedConfiguration(manager: SubscriptionManager(store: .shared))
    private static let ownershipKey = "managedConfigurationSubscriptionIDs"
    private static let namesKey = "managedConfigurationDisplayNames"
    private static let defaultKey = "managedConfigurationDefault"
    private let manager: SubscriptionManager
    private let defaults: UserDefaults
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var lastRead: NSDictionary?

    init(manager: SubscriptionManager, defaults: UserDefaults = .standard) {
        self.manager = manager
        self.defaults = defaults
        super.init()
    }

    func start() {
        precondition(Thread.isMainThread)
        guard !started else { return }
        started = true
        // Unlike didChangeNotification, KVO includes changes from another process (MDM).
        defaults.addObserver(self, forKeyPath: Self.configurationKey, options: [], context: nil)
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() })
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            guard let self, self.snapshot() != self.lastRead else { return }
            self.refresh()
        })
        refresh()
    }

    private func snapshot() -> NSDictionary {
        ["configuration": defaults.object(forKey: Self.configurationKey) ?? NSNull()] as NSDictionary
    }

    deinit {
        if started { defaults.removeObserver(self, forKeyPath: Self.configurationKey) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == Self.configurationKey else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    @objc func refresh() {
        precondition(Thread.isMainThread)
        lastRead = snapshot()
        let raw = defaults.object(forKey: Self.configurationKey)
        guard raw == nil || raw is [String: Any] else {
            feedback(applied: 0, errors: ["configuration: expected dictionary"])
            return
        }
        let configuration = raw as? [String: Any] ?? [:]
        var errors: [String] = []
        // Do not echo unknown keys or values: an admin might accidentally include a secret.
        if !Set(configuration.keys).isSubset(of: ["defaultServer", "topics"]) {
            errors.append("configuration: unsupported keys ignored; credentials are not supported")
        }
        var applied = 0
        let store = manager.store
        var previousDefault = defaults.dictionary(forKey: Self.defaultKey) as? [String: String]
        if let value = configuration["defaultServer"] {
            if let server = Self.server(value) {
                if previousDefault == nil { previousDefault = ["previous": store.getDefaultBaseUrl()] }
                if store.getDefaultBaseUrl() != server { store.saveDefaultBaseUrl(baseUrl: server) }
                if store.getDefaultBaseUrl() == server {
                    previousDefault?["applied"] = server
                    if defaults.dictionary(forKey: Self.defaultKey) as? [String: String] != previousDefault {
                        defaults.set(previousDefault, forKey: Self.defaultKey)
                    }
                    applied += 1
                } else {
                    errors.append("defaultServer: could not be saved; retry on next refresh")
                }
            } else { errors.append("defaultServer: expected HTTP(S) server URL without credentials, query or fragment") }
        } else if let previousDefault {
            if store.getDefaultBaseUrl() == previousDefault["applied"] {
                store.saveDefaultBaseUrl(baseUrl: previousDefault["previous"])
            }
            defaults.removeObject(forKey: Self.defaultKey)
        }

        let rawTopics = configuration["topics"]
        guard rawTopics == nil || rawTopics is [Any] else {
            errors.append("topics: expected array")
            feedback(applied: applied, errors: errors)
            return // A malformed collection must not release ownership of existing topics.
        }
        let owned = defaults.dictionary(forKey: Self.ownershipKey) as? [String: String] ?? [:]
        let appliedNames = defaults.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
        var nextAppliedNames: [String: String] = [:]
        var nextOwned: [String: String] = [:]
        var seen: Set<String> = []
        for (index, value) in (rawTopics as? [Any] ?? []).enumerated() {
            guard let entry = value as? [String: Any], let server = Self.server(entry["server"]),
                  let topic = entry["topic"] as? String, isValidTopicName(topic),
                  entry["displayName"] == nil || entry["displayName"] is String,
                  ((entry["displayName"] as? String)?.count ?? 0) <= 256,
                  Set(entry.keys).isSubset(of: ["server", "topic", "displayName"]) else {
                errors.append("topics[\(index)]: invalid server, topic, displayName or unsupported keys")
                continue
            }
            let key = topicUrl(baseUrl: server, topic: topic)
            guard seen.insert(key).inserted else {
                errors.append("topics[\(index)]: duplicate")
                continue
            }
            var subscription = store.getSubscription(baseUrl: server, topic: topic)
            let created = subscription == nil
            if created {
                manager.subscribe(baseUrl: server, topic: topic)
                subscription = store.getSubscription(baseUrl: server, topic: topic)
            }
            guard let subscription, !subscription.isInserted, !subscription.objectID.isTemporaryID else {
                errors.append("topics[\(index)]: subscription could not be saved; retry on next refresh")
                continue
            }
            let id = subscription.objectID.uriRepresentation().absoluteString
            // Never adopt or rename a topic that the user added, even with the same URL.
            if created || owned[key] == id {
                nextOwned[key] = id
                let name = (entry["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = name?.isEmpty == true ? nil : name
                let previousName = created ? nil : appliedNames[id]
                // A refresh is not a new naming request. Removing an admin name clears only
                // that value, preserving a different name the user supplied afterwards.
                if displayName != previousName &&
                    (displayName != nil || subscription.customDisplayName == previousName) {
                    store.updateSubscription(subscription: subscription, displayName: displayName)
                }
                nextAppliedNames[id] = displayName
            }
            applied += 1
        }
        // Removed topics keep their history and become personal subscriptions. This also avoids
        // destructive cleanup after a temporarily missing or malformed profile.
        if owned != nextOwned { defaults.set(nextOwned, forKey: Self.ownershipKey) }
        if appliedNames != nextAppliedNames { defaults.set(nextAppliedNames, forKey: Self.namesKey) }
        feedback(applied: applied, errors: errors)
    }

    private func feedback(applied: Int, errors: [String]) {
        let result: [String: Any] = ["applied": applied, "errors": errors]
        if !(defaults.dictionary(forKey: Self.feedbackKey).map { NSDictionary(dictionary: $0).isEqual(to: result) } ?? false) {
            defaults.set(result, forKey: Self.feedbackKey)
        }
    }

    /// A base URL may include a reverse proxy path. Reject embedded secrets and ambiguous URLs.
    static func server(_ value: Any?) -> String? {
        guard let value = value as? String, value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              let url = URLComponents(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil || (1...65535).contains(url.port!), url.url != nil else { return nil }
        var canonical = url
        canonical.scheme = scheme
        canonical.host = host.lowercased()
        if canonical.port == (scheme == "https" ? 443 : 80) { canonical.port = nil }
        return canonical.string.map(normalizeBaseUrl)
    }
}
