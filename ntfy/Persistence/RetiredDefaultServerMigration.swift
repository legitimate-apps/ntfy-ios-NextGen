import Foundation
import CoreData

/// Moves subscriptions off the built-in server that 1.12 and 1.13 shipped with.
///
/// Those builds named a private server as `Config.appBaseUrl`. It denies access to anyone without an
/// account, so a topic added there by anyone else gets HTTP 403 on every poll and never receives a
/// message. 1.14 changed the built-in server to ntfy-me.com, but a subscription keeps the base URL it
/// was created with (`Store.saveSubscription`), so those topics stayed broken after the update.
///
/// On first launch this moves every such subscription to ntfy-me.com, and the "default server"
/// preference with it, unless this device has any credentials for that server. A login means the
/// server is used on purpose and works for this person, so nothing is touched.
///
/// - The login check is deliberately broad: a saved user, password or HTTP headers under any spelling
///   of either of that server's host names (any scheme, port, path or letter case) counts, and so does
///   any store or Keychain read that fails. When in doubt, nothing moves and it retries next launch.
/// - A moved row keeps its identity (same object, same topic), so its notifications, pin and display
///   name come with it. If ntfy-me.com already has the same topic, the old row's notifications are
///   folded into that one and the old row is removed, so the list never shows the topic twice. A
///   survivor spelled differently (e.g. with `:443`) is rewritten to the canonical URL so its FCM
///   name and push lookups match; an encrypted one is never rewritten (its key is salted with the
///   topic URL), so the old row goes to the canonical URL beside it instead.
/// - End-to-end encrypted subscriptions on the retired server stay where they are, for the same reason.
///   The feature postdates the builds that created these rows, so none is encrypted in practice.
/// - FCM names depend on the server. The old names are queued in `defaults` before the store save
///   (`FcmSubscriptionReconciler.enqueueObsoleteTopicNames`), so a launch killed between the save and
///   the teardown still tears them down later.
/// - The moved topics are recorded for a one-time notice (`pendingNoticeTopics`), because whatever
///   publishes to them must now post to ntfy-me.com.
/// - It runs once. Completion is recorded only after the store save succeeds.
enum RetiredDefaultServerMigration {
    private static let tag = "RetiredServerMigration"

    static let replacementBaseUrl = "https://ntfy-me.com"

    /// Every host name the private server has had, the one 1.12 and 1.13 used first. Set in the build
    /// configuration (`RETIRED_SERVER_HOSTS`, space-separated) rather than here, because it names a
    /// private server. Only the login check uses the later ones. Empty in a build that sets none,
    /// which turns the migration off.
    static var retiredHostList: [String] {
        if let override = retiredHostsForTesting { return override }
        let raw = Bundle.main.infoDictionary?["RetiredServerHosts"] as? String ?? ""
        return raw.split(whereSeparator: { $0 == " " || $0 == "," }).map { $0.lowercased() }
    }
    static var retiredHosts: Set<String> { Set(retiredHostList) }
    /// The address 1.12 and 1.13 shipped as the built-in server; nil when no retired host is set.
    static var retiredBaseUrl: String? { retiredHostList.first.map { "https://\($0)" } }

    /// Test seam: the retired hosts to use instead of the build configuration's.
    static var retiredHostsForTesting: [String]?
    static let defaultsKeyCompleted = "retiredDefaultServerMigrationCompleted"
    static let defaultsKeyNoticeTopics = "retiredDefaultServerMigrationNoticeTopics"

    /// Test seam: returns an error to make the fetch of the named entity fail.
    static var fetchFaultForTesting: ((String) -> Error?)?

    struct Outcome: Equatable {
        /// Topics whose subscription now points at the replacement server.
        var moved: [String] = []
        /// Topics folded into an existing subscription on the replacement server.
        var merged: [String] = []
        /// Encrypted topics left on the retired server.
        var skippedEncrypted: [String] = []
        var defaultServerMoved = false
        /// True when a saved login for the retired server meant nothing was touched.
        var keptForSavedLogin = false
    }

    private enum LoginCheck { case none, found, unreadable }

    /// Runs the migration unless it already completed. Returns nil when it had already run, or when it
    /// could not finish this time and will retry on the next launch.
    @discardableResult
    static func runIfNeeded(
        store: Store,
        defaults: UserDefaults,
        reconciler: FcmSubscriptionReconciler?
    ) -> Outcome? {
        guard !defaults.bool(forKey: defaultsKeyCompleted) else { return nil }
        // A build without a retired server has nothing to move. Not recorded as completed, so a build
        // that later sets one still runs it.
        guard retiredBaseUrl != nil else { return nil }

        var outcome = Outcome()
        var login = LoginCheck.unreadable
        var saved = false
        var obsoleteNames: [String] = []
        var defaultPreference: String?
        store.context.performAndWait {
            let subscriptions: [Subscription]
            let users: [User]
            do {
                subscriptions = try fetch(Subscription.fetchRequest(), store: store)
                users = try fetch(User.fetchRequest(), store: store)
                let request = Preference.fetchRequest()
                request.predicate = NSPredicate(format: "key = %@", Store.prefKeyDefaultBaseUrl)
                defaultPreference = try fetch(request, store: store).first?.value
            } catch let error {
                Log.e(tag, "Cannot read the store; will retry next launch", error)
                return
            }

            let spellings = subscriptions.compactMap(\.baseUrl) + users.compactMap(\.baseUrl)
                + [defaultPreference].compactMap { $0 }
            login = savedLogin(store: store, users: users, spellings: spellings)
            guard login == .none else { return }

            // Fold only into a row FCM and push lookups will find: the canonical spelling, or an
            // unencrypted variant, which is rewritten to the canonical one below.
            var onReplacement: [String: Subscription] = [:]
            for subscription in subscriptions {
                guard let baseUrl = subscription.baseUrl, let topic = subscription.topic,
                      isServer(baseUrl, replacementBaseUrl) else { continue }
                let canonical = baseUrl == replacementBaseUrl
                guard canonical || !subscription.encrypted else { continue }
                if canonical || onReplacement[topic] == nil { onReplacement[topic] = subscription }
            }
            for subscription in subscriptions {
                guard let baseUrl = subscription.baseUrl, let topic = subscription.topic,
                      isRetiredServer(baseUrl) else { continue }
                if subscription.encrypted {
                    outcome.skippedEncrypted.append(topic)
                    continue
                }
                obsoleteNames += [topic, topicHash(baseUrl: baseUrl, topic: topic)]
                if let existing = onReplacement[topic] {
                    let notifications = (subscription.notifications as? Set<Notification>) ?? []
                    notifications.forEach { $0.subscription = existing }
                    if subscription.pinned { existing.pinned = true }
                    if existing.customDisplayName == nil { existing.customDisplayName = subscription.customDisplayName }
                    if let survivorUrl = existing.baseUrl, survivorUrl != replacementBaseUrl {
                        obsoleteNames.append(topicHash(baseUrl: survivorUrl, topic: topic))
                        existing.baseUrl = replacementBaseUrl
                        existing.fcmSubscribed = false
                    }
                    store.context.delete(subscription)
                    outcome.merged.append(topic)
                } else {
                    subscription.baseUrl = replacementBaseUrl
                    // The last message id belongs to the old server; ntfy-me.com has never seen it.
                    subscription.lastNotificationId = nil
                    // Its FCM name changed with the server, so it needs a fresh bind.
                    subscription.fcmSubscribed = false
                    onReplacement[topic] = subscription
                    outcome.moved.append(topic)
                }
            }
            guard store.context.hasChanges else { saved = true; return }
            // Queue the old names before the save: if the process dies after it, the next launch still
            // knows what to tear down. A queued name some row still needs is never torn down.
            let queueBefore = FcmSubscriptionReconciler.pendingObsoleteTopicNames(defaults: defaults)
            FcmSubscriptionReconciler.enqueueObsoleteTopicNames(obsoleteNames, defaults: defaults)
            do {
                try store.context.save()
                saved = true
            } catch let error {
                Log.e(tag, "Cannot move subscriptions off the retired server; will retry next launch", error)
                FcmSubscriptionReconciler.setPendingObsoleteTopicNames(queueBefore, defaults: defaults)
                store.rollbackAndRefresh()
            }
        }
        switch login {
        case .unreadable:
            Log.w(tag, "Cannot tell whether credentials are saved for the retired server; will retry next launch")
            return nil
        case .found:
            outcome.keptForSavedLogin = true
            Log.i(tag, "A login is saved for the retired built-in server; leaving its subscriptions alone")
            defaults.set(true, forKey: defaultsKeyCompleted)
            return outcome
        case .none:
            break
        }
        guard saved else { return nil }

        if let preference = defaultPreference, isRetiredServer(preference) {
            store.saveDefaultBaseUrl(baseUrl: replacementBaseUrl)
            guard !isRetiredServer(store.getDefaultBaseUrl()) else {
                Log.e(tag, "Cannot update the default server preference; will retry next launch")
                return nil
            }
            outcome.defaultServerMoved = true
        }

        let noticeTopics = Array(Set(outcome.moved + outcome.merged)).sorted()
        if !noticeTopics.isEmpty {
            defaults.set(noticeTopics, forKey: defaultsKeyNoticeTopics)
        }
        defaults.set(true, forKey: defaultsKeyCompleted)
        Log.i(tag, "Retired built-in server migration done: moved \(outcome.moved.count) topic(s) "
                 + "\(outcome.moved), merged \(outcome.merged.count) \(outcome.merged), left "
                 + "\(outcome.skippedEncrypted.count) encrypted \(outcome.skippedEncrypted), "
                 + "default server moved: \(outcome.defaultServerMoved)")
        if !obsoleteNames.isEmpty {
            reconciler?.reconcile(reason: "subscriptions moved server")
        }
        return outcome
    }

    // MARK: Notice

    /// Topics moved by the migration that the user has not yet been told about.
    static func pendingNoticeTopics(defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: defaultsKeyNoticeTopics) ?? []
    }

    static func dismissNotice(defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKeyNoticeTopics)
    }

    static func noticeMessage(topics: [String]) -> String {
        let limit = 8
        var urls = topics.prefix(limit).map { "\(replacementBaseUrl)/\($0)" }
        if topics.count > limit { urls.append("and \(topics.count - limit) more") }
        return "The server this app used to default to is private, so these topics never received "
            + "messages there. They now live on ntfy-me.com:\n\n" + urls.joined(separator: "\n")
            + "\n\nAnything that sends to them, such as scripts or services, must now post to "
            + "\(replacementBaseUrl)/<topic>."
    }

    // MARK: Matching

    /// True when `baseUrl` is the retired server, ignoring surrounding whitespace, trailing slashes,
    /// letter case of scheme and host, and an explicit default port.
    static func isRetiredServer(_ baseUrl: String) -> Bool {
        guard let retiredBaseUrl = retiredBaseUrl else { return false }
        return isServer(baseUrl, retiredBaseUrl)
    }

    /// True when `baseUrl` names either host the private server has had, with any scheme, port or
    /// path. Used only to decide whether a credential is "for that server", where a false match only
    /// means nothing is moved.
    static func isRetiredHost(_ baseUrl: String) -> Bool {
        let trimmed = normalizeBaseUrl(baseUrl)
        let parsed = URLComponents(string: trimmed)?.host != nil
            ? URLComponents(string: trimmed) : URLComponents(string: "https://" + trimmed)
        guard var host = parsed?.host?.lowercased() else { return false }
        while host.hasSuffix(".") { host.removeLast() }
        return retiredHosts.contains(host)
    }

    private static func isServer(_ baseUrl: String, _ reference: String) -> Bool {
        guard let lhs = URLComponents(string: normalizeBaseUrl(baseUrl)),
              let rhs = URLComponents(string: reference) else { return false }
        func port(_ c: URLComponents) -> Int? { c.port ?? (c.scheme?.lowercased() == "https" ? 443 : nil) }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && port(lhs) == port(rhs)
            && lhs.path.isEmpty
            && lhs.query == nil
    }

    // MARK: Credentials

    /// Whether this device holds credentials for the retired server: a saved user, a Keychain password
    /// or custom HTTP headers (e.g. an access-proxy token) under any stored spelling of it or the
    /// canonical ones. Credentials are keyed by the spelling they were saved under, so each one is
    /// checked. Any read that fails makes the answer unreadable, never "none".
    private static func savedLogin(store: Store, users: [User], spellings: [String]) -> LoginCheck {
        if users.contains(where: { $0.baseUrl.map(isRetiredHost) == true }) { return .found }
        var candidates = Set(retiredHosts.map { "https://\($0)" })
        for spelling in spellings where isRetiredHost(spelling) {
            candidates.insert(spelling)
            candidates.insert(normalizeBaseUrl(spelling))
        }
        var unreadable = false
        for candidate in candidates.sorted() {
            switch store.credentialStore.readPassword(baseUrl: candidate) {
            case .found: return .found
            case .notFound: break
            case .failed: unreadable = true
            }
            switch store.credentialStore.readHTTPHeaders(baseUrl: candidate) {
            case .success(let headers): if !headers.isEmpty { return .found }
            case .failure: unreadable = true
            }
        }
        return unreadable ? .unreadable : .none
    }

    private static func fetch<T: NSFetchRequestResult>(_ request: NSFetchRequest<T>, store: Store) throws -> [T] {
        if let entity = request.entityName, let error = fetchFaultForTesting?(entity) { throw error }
        return try store.context.fetch(request)
    }
}
