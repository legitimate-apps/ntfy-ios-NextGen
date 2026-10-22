import CryptoKit
import Foundation
import Combine

/// A tap-scoped diagnostic. The relay receives a hash only, through a session with no cookies,
/// saved credentials or redirects. Publishing stays with the topic server's ordinary API path.
final class RelayCheck: ObservableObject {
    enum State: Equatable {
        case idle, discovering, consent, checking, unsupported, cancelled
        case received(Int64)
        case notObserved
        case failed(String)

        var isBusy: Bool { self == .discovering || self == .checking }
        var message: String? {
            switch self {
            case .idle: return nil
            case .discovering: return String(localized: "Checking whether the relay supports this test…")
            case .consent: return String(localized: "The relay supports a wake-up check. Sending the test needs your approval.")
            case .checking: return String(localized: "Waiting for a newer forwarded wake-up…")
            case .unsupported: return String(localized: "This relay does not offer an automatic check. On your server, check upstream-base-url: https://ntfy-me.com, its canonical base-url, and outbound HTTPS. No automatic result is available.")
            case .cancelled: return String(localized: "Check cancelled. A test message already sent may still arrive.")
            case .received(let milliseconds):
                let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
                let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .medium)
                return String(localized: "ntfy-me.com received a wake-up for this topic at \(time), and FCM accepted it. This does not prove your phone received it or that this test caused the wake-up.")
            case .notObserved: return String(localized: "No newer forwarded wake-up was observed during this check (about 10 seconds). Check upstream-base-url: https://ntfy-me.com, the canonical base-url, outbound HTTPS, and the relay's status. Network or FCM trouble, delays, or evicted history can give the same result.")
            case .failed(let reason): return reason
            }
        }
    }

    struct Snapshot: Decodable, Equatable {
        let relayed: Bool
        let relayedAt: Int64?
        let windowSeconds: Int
        enum CodingKeys: String, CodingKey {
            case relayed, relayedAt = "relayed_at", windowSeconds = "window_seconds"
        }
        var isValid: Bool { windowSeconds == 120 && (relayed ? (relayedAt ?? 0) > 0 : relayedAt == nil) }
    }

    typealias Read = (URLRequest, @escaping (Data?, HTTPURLResponse?, Error?) -> Void) -> Void
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    @Published private(set) var state = State.idle
    private let discover: (@escaping (Bool) -> Void) -> Void
    private let read: Read
    private let schedule: Schedule
    private let relayBaseUrl: String
    private let cooldown: ServerCooldown?
    private var generation = UUID()
    private var nextAllowed: TimeInterval = 0
    private var baselineRead = true
    private var baseline: Int64?
    private var hash = ""
    private var topicBaseUrl = ""
    private var session: URLSession?

    init(relayBaseUrl: String = Config.appBaseUrl,
         cooldown: ServerCooldown? = .shared,
         discover: ((@escaping (Bool) -> Void) -> Void)? = nil,
         read: Read? = nil,
         schedule: @escaping Schedule = { delay, action in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action) }) {
        self.relayBaseUrl = relayBaseUrl
        self.cooldown = cooldown
        self.discover = discover ?? { completion in
            ServerCapabilitiesCache.shared.discover(baseUrl: relayBaseUrl, user: nil) { completion($0.relayCheck) }
        }
        self.schedule = schedule
        if let read { self.read = read } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 10
            let session = URLSession(configuration: config, delegate: RelayNoRedirectDelegate(), delegateQueue: .main)
            self.session = session
            self.read = { request, completion in
                session.dataTask(with: request) { data, response, error in
                    DispatchQueue.main.async { completion(data, response as? HTTPURLResponse, error) }
                }.resume()
            }
        }
    }

    deinit { session?.invalidateAndCancel() }

    static func topicHash(baseUrl: String, topic: String) -> String {
        // Deliberately do not normalize the configured spelling, including a trailing slash.
        SHA256.hash(data: Data((baseUrl + "/" + topic).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isSecureBase(_ base: String) -> Bool {
        guard let url = URL(string: base) else { return false }
        return url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }

    func prepare(baseUrl: String, topic: String) {
        guard !state.isBusy, ProcessInfo.processInfo.systemUptime >= nextAllowed else { return }
        if let cooldown, !cooldown.claim(server: relayBaseUrl, manual: true, kind: .relay, consumingProbe: false) {
            state = .failed(String(localized: "The relay is pausing requests after a rate limit. Wait for the requested delay or the relevant server or request change before trying again."))
            return
        }
        generation = UUID()
        baseline = nil
        baselineRead = true
        guard Self.isSecureBase(baseUrl), Self.isSecureBase(relayBaseUrl), !topic.isEmpty else {
            state = .failed(String(localized: "An automatic relay check requires HTTPS for both your topic server and the relay. No test message was sent."))
            return
        }
        topicBaseUrl = baseUrl
        hash = Self.topicHash(baseUrl: baseUrl, topic: topic)
        state = .discovering
        let id = generation
        discover { [weak self] supported in
            DispatchQueue.main.async {
                guard let self, self.generation == id else { return }
                self.state = supported ? .consent : .unsupported
            }
        }
    }

    /// Called only from the visible consent action. The publisher must use the ordinary encrypted
    /// publish path for encrypted topics and fail closed when the key is unavailable.
    func approve(publish: @escaping (@escaping (String?) -> Void) -> Void) {
        guard state == .consent else { return }
        state = .checking
        let id = generation
        lookup(id: id) { [weak self] snapshot in
            guard let self else { return }
            self.baseline = snapshot.relayedAt
            self.publishWhenDistinct(id: id, publish: publish)
        }
    }

    func cancel() {
        generation = UUID()
        session?.getAllTasks { $0.forEach { $0.cancel() } }
        state = .cancelled
    }

    private func publishWhenDistinct(id: UUID, publish: @escaping (@escaping (String?) -> Void) -> Void) {
        guard generation == id else { return }
        // The baseline response follows the server's accepted wake. Let a monotonic timer
        // cross a millisecond before publishing; comparing server and device clocks is unsafe.
        schedule(0.002) { [weak self] in
            guard let self, self.generation == id else { return }
            self.publish(id: id, using: publish)
        }
    }

    private func publish(id: UUID, using publish: @escaping (@escaping (String?) -> Void) -> Void) {
        let attempt = cooldown?.claimAttempt(server: topicBaseUrl, manual: true, kind: .publish)
        guard cooldown == nil || attempt != nil else {
            state = .failed(String(localized: "Your topic server is pausing publishes after a rate limit. No test message was sent. Try again after its wait or state change."))
            return
        }
        publish { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.generation == id else { return }
                if let error { self.state = .failed(String(localized: "The test message could not be confirmed: \(error) No relay result is available.")) }
                else {
                    if let attempt { self.cooldown?.succeeded(server: self.topicBaseUrl, attempt: attempt) }
                    self.poll(id: id, index: 0)
                }
            }
        }
    }

    private func poll(id: UUID, index: Int) {
        let delays: [TimeInterval] = [1, 2, 3, 4]
        guard index < delays.count else { state = .notObserved; return }
        schedule(delays[index]) { [weak self] in
            guard let self, self.generation == id else { return }
            self.lookup(id: id) { [weak self] snapshot in
                guard let self else { return }
                if let timestamp = snapshot.relayedAt, timestamp > (self.baseline ?? 0) { self.state = .received(timestamp) }
                else { self.poll(id: id, index: index + 1) }
            }
        }
    }

    private func lookup(id: UUID, completion: @escaping (Snapshot) -> Void) {
        guard generation == id,
              let url = URL(string: relayBaseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/ntfyme/relay-check") else { return }
        let attempt = cooldown?.claimAttempt(server: relayBaseUrl, manual: baselineRead, kind: .relay)
        guard cooldown == nil || attempt != nil else {
            state = .failed(String(localized: "The relay is pausing requests after a rate limit. Wait for the requested delay or the relevant server or request change before trying again."))
            return
        }
        baselineRead = false
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ApiService.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONEncoder().encode(["hash": hash])
        read(request) { [weak self] data, response, error in
            guard let self, self.generation == id else { return }
            guard error == nil, let response else {
                self.state = .failed(String(localized: "The relay could not be reached. This check cannot tell whether wake-ups are forwarding. Try again when the connection is available."))
                return
            }
            if response.statusCode == 404 || response.statusCode == 405 {
                ServerCapabilitiesCache.shared.invalidate(baseUrl: self.relayBaseUrl)
                self.state = .unsupported
                return
            }
            if response.statusCode == 429 {
                self.cooldown?.limit(server: self.relayBaseUrl,
                    retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
                    condition: response.value(forHTTPHeaderField: "Retry-After-Condition"), kind: .relay)
                let condition = response.value(forHTTPHeaderField: "Retry-After-Condition")
                let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let guidance: String
                if condition == "state-change" { guidance = String(localized: "Wait for the relevant server state to change before trying again.") }
                else if condition == "request-change" { guidance = String(localized: "The server requires a different request before it can accept this check.") }
                else if let seconds, seconds.isFinite, seconds > 0 { guidance = String(format: NSLocalizedString("Wait at least %lld seconds before trying again.", comment: "Retry interval in seconds"), locale: DeliveryHealthCopy.retryIntervalLocale(), Int(ceil(min(seconds, Double(Int.max / 2))))) }
                else { guidance = String(localized: "Wait at least 60 seconds before trying again.") }
                if condition != "state-change", condition != "request-change" {
                    let delay = seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 60
                    self.nextAllowed = ProcessInfo.processInfo.systemUptime + delay
                }
                self.state = .failed(String(localized: "The relay rate limited this check. \(guidance) No automatic retry will be sent."))
                return
            }
            guard response.statusCode == 200, let data,
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.isValid else {
                self.state = .failed(String(localized: "The relay did not return a valid check result (HTTP \(response.statusCode)). This does not establish whether forwarding works."))
                return
            }
            if let attempt { self.cooldown?.succeeded(server: self.relayBaseUrl, attempt: attempt) }
            completion(snapshot)
        }
    }
}

private final class RelayNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
