import CoreData
import Foundation

class ApiService {
    static let shared = ApiService()
    static let userAgent = "ntfy/\(Config.version) (build \(Config.build); iOS \(Config.osVersion))"
    
    private let tag = "ApiService"
    private let credentialStore: CredentialStoring

    init(credentialStore: CredentialStoring = KeychainCredentialStore.shared) {
        self.credentialStore = credentialStore
    }
    
    /// Polls from `request.since` using only the snapshot's values, never the managed `Subscription`,
    /// so it is safe to call and complete on any queue.
    func poll(_ request: PollRequest, timeout: TimeInterval = 30, completionHandler: @escaping ([Message]?, Error?) -> Void) {
        let urlString = "\(request.topicUrl)/json?poll=1&since=\(request.since ?? "all")"
        Log.d(tag, "Polling from \(urlString) with user \(request.user?.username ?? "anonymous")")
        fetchJsonData(urlString: urlString, baseUrl: request.baseUrl, user: request.user, timeout: timeout, completionHandler: completionHandler)
    }
    
    func poll(subscription: Subscription, messageId: String, user: ServerCredential?, completionHandler: @escaping (Message?, Error?) -> Void) {
        poll(baseUrl: subscription.baseUrl ?? "?", topic: subscription.topic ?? "?", messageId: messageId, user: user, completionHandler: completionHandler)
    }

    func poll(baseUrl: String, topic: String, messageId: String, user: ServerCredential?, timeout: TimeInterval = 30, completionHandler: @escaping (Message?, Error?) -> Void) {
        guard let url = URL(string: "\(topicUrl(baseUrl: baseUrl, topic: topic))/json?poll=1&id=\(messageId)") else {
            completionHandler(nil, URLError(.badURL))
            return
        }
        Log.d(tag, "Polling single message from \(url) with user \(user?.username ?? "anonymous")")
        
        let request = newRequest(url: url, baseUrl: baseUrl, user: user)
        runOneShot(request, timeout: timeout, baseUrl: baseUrl) { (data, response, error) in
            if let error = error {
                completionHandler(nil, error)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                let http = response as? HTTPURLResponse
                completionHandler(nil, PollHTTPError(status: http?.statusCode ?? 0,
                    retryAfter: http?.value(forHTTPHeaderField: "Retry-After"),
                    retryCondition: http?.value(forHTTPHeaderField: "Retry-After-Condition")))
                return
            }
            guard let data = data else {
                completionHandler(nil, URLError(.badServerResponse))
                return
            }
            do {
                let message = try JSONDecoder().decode(Message.self, from: data)
                completionHandler(message, nil)
            } catch {
                completionHandler(nil, error)
            }
        }
    }

    /// Clear endpoints exist on sequence-aware servers; older servers reject this path. There is
    /// no fallback publish, retry, or user-facing error (read-only subscriptions remain useful).
    func clearRequest(_ clear: ClearRequest) -> URLRequest? {
        guard clear.sequence.range(of: "^[-_A-Za-z0-9]{1,64}$", options: .regularExpression) != nil,
              let url = URL(string: "\(topicUrl(baseUrl: clear.baseUrl, topic: clear.topic))/\(clear.sequence)/clear") else { return nil }
        var request = newRequest(url: url, baseUrl: clear.baseUrl, user: clear.user)
        request.httpMethod = "PUT"
        return request
    }

    func clear(_ clear: ClearRequest, session: URLSession? = nil, completion: (() -> Void)? = nil) {
        action(clear, session: session) { _ in completion?() }
    }

    /// Only a successful response from the real server permits an upstream wake. A 429 carries
    /// the server's Retry-After so the pacer can stop sending until then.
    func action(_ clear: ClearRequest, session: URLSession? = nil, completion: @escaping (ClearOutcome) -> Void) {
        guard let request = clearRequest(clear) else { completion(.failed); return }
        runOneShot(request, timeout: 8, baseUrl: clear.baseUrl, session: session) { _, response, error in
            let http = response as? HTTPURLResponse
            let status = error == nil ? http?.statusCode ?? 0 : 0
            if !(200..<300).contains(status) {
                Log.w(self.tag, "Sequence action failed; keeping local state (HTTP \(status))")
            }
            if status == 429 {
                if let directive = RetryDirective.parse(condition: http?.value(forHTTPHeaderField: "Retry-After-Condition"),
                    retryAfter: http?.value(forHTTPHeaderField: "Retry-After")) {
                    completion(.conditionLimited(directive)); return
                }
                completion(.rateLimited(retryAfter: PollTiming.retryDelay(http?.value(forHTTPHeaderField: "Retry-After"), now: Date()) ?? 60))
            } else {
                completion((200..<300).contains(status) ? .sent : .failed)
            }
        }
    }

    /// Stock ntfy clear events use silent APNs even with the poll-only Firebase auther patch.
    /// The fixed sequence is a protocol marker, never an originating message identity. No body,
    /// real-server authorization or custom headers cross this boundary.
    func wakeRequest(topic: String) -> URLRequest? {
        guard topic.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let url = URL(string: "\(topicUrl(baseUrl: Config.appBaseUrl, topic: topic))/ntfy-sync/clear") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("ntfy", forHTTPHeaderField: "User-Agent")
        return request
    }

    func wake(topic: String, session: URLSession? = nil, completion: @escaping () -> Void) {
        guard let request = wakeRequest(topic: topic) else { completion(); return }
        runOneShot(request, timeout: 8, baseUrl: Config.appBaseUrl, session: session) { _, response, error in
            if error != nil || !(200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) {
                Log.w(self.tag, "Silent wake failed; other devices will reconcile on their next poll")
            }
            completion()
        }
    }

    func publish(
        subscription: Subscription,
        user: ServerCredential?,
        message: String,
        title: String,
        priority: Int = 3,
        tags: [String] = [],
        encryptionKey: Data? = nil,
        session: URLSession? = nil,
        cooldown: ServerCooldown = .shared,
        completionHandler: (() -> Void)? = nil,
        failureHandler: ((PublishError) -> Void)? = nil
    ) {
        let request: URLRequest
        switch buildPublishRequest(
            subscription: subscription,
            user: user,
            message: message,
            title: title,
            priority: priority,
            tags: tags,
            encryptionKey: encryptionKey
        ) {
        case .success(let built): request = built
        case .failure(let error):
            failureHandler?(error)
            return
        }
        let baseUrl = subscription.baseUrl ?? ""
        Log.d(tag, "Publishing to \(request.url?.absoluteString ?? "?")\(encryptionKey == nil ? "" : " (end-to-end encrypted)")")
        runOneShot(request, timeout: 10, baseUrl: baseUrl, session: session) { (data, response, error) in
            guard error == nil else {
                Log.e(self.tag, "Error publishing message", error!)
                failureHandler?(.network(error!.localizedDescription))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode
                if let http = response as? HTTPURLResponse, http.statusCode == 429,
                   RetryDirective.parse(condition: http.value(forHTTPHeaderField: "Retry-After-Condition"),
                                        retryAfter: http.value(forHTTPHeaderField: "Retry-After")) != nil {
                    cooldown.limit(server: baseUrl, retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                        condition: http.value(forHTTPHeaderField: "Retry-After-Condition"), kind: .publish)
                }
                Log.e(self.tag, "Publishing message failed with HTTP status \(status.map { String($0) } ?? "<missing>")")
                failureHandler?(.http(status))
                return
            }
            Log.d(self.tag, "Publishing message succeeded", response)
            completionHandler?()
        }
    }
    
    /// Builds the publish request. With an `encryptionKey` (the topic has a password) everything the
    /// user wrote — message, title, priority, tags — goes inside the encrypted body and none of it in
    /// headers, so the server only learns that something was sent.
    func publishRequest(
        subscription: Subscription,
        user: ServerCredential?,
        message: String,
        title: String,
        priority: Int = 3,
        tags: [String] = [],
        encryptionKey: Data? = nil
    ) -> URLRequest? {
        try? buildPublishRequest(subscription: subscription, user: user, message: message, title: title,
                                 priority: priority, tags: tags, encryptionKey: encryptionKey).get()
    }

    func buildPublishRequest(
        subscription: Subscription,
        user: ServerCredential?,
        message: String,
        title: String,
        priority: Int = 3,
        tags: [String] = [],
        encryptionKey: Data? = nil
    ) -> Result<URLRequest, PublishError> {
        guard let url = URL(string: subscription.urlString()) else { return .failure(.invalidTopicUrl) }
        var request = newRequest(url: url, baseUrl: subscription.baseUrl ?? "?", user: user)
        request.httpMethod = "POST"
        if let encryptionKey {
            let payload = TopicEncryption.payload(message: message, title: title, priority: priority, tags: tags)
            let body: String
            do {
                body = try TopicEncryption.encrypt(payload, key: encryptionKey)
            } catch TopicEncryption.Failure.tooLarge(let bytes) {
                Log.e(tag, "Encrypted message is \(bytes) bytes; not sending it unencrypted")
                return .failure(.tooLargeToEncrypt(bytes: bytes))
            } catch {
                Log.e(tag, "Cannot encrypt the message; not sending it unencrypted")
                return .failure(.encryptionFailed)
            }
            request.setValue(TopicEncryption.encodingHeaderValue, forHTTPHeaderField: TopicEncryption.encodingHeaderName)
            request.httpBody = Data(body.utf8)
            return .success(request)
        }
        request.setValue(title, forHTTPHeaderField: "Title")
        request.setValue(String(priority), forHTTPHeaderField: "Priority")
        request.setValue(tags.joined(separator: ","), forHTTPHeaderField: "Tags")
        request.httpBody = message.data(using: String.Encoding.utf8)
        return .success(request)
    }

    enum PublishError: Error, Equatable {
        case invalidTopicUrl
        case tooLargeToEncrypt(bytes: Int)
        case encryptionFailed
        case network(String)
        case http(Int?)

        var userMessage: String {
            switch self {
            case .invalidTopicUrl: return "The topic URL is not valid."
            case .tooLargeToEncrypt(let bytes): return "The encrypted message would be \(bytes) bytes; the limit is \(TopicEncryption.maxMessageBytes). Shorten it. Nothing was sent."
            case .encryptionFailed: return "The message could not be encrypted, so it was not sent."
            case .network(let description): return "Could not reach the server: \(description)"
            case .http(let status): return "The server refused the message (HTTP \(status.map(String.init) ?? "?"))."
            }
        }
    }

    func checkAuth(baseUrl: String, topic: String, user: ServerCredential?, session: URLSession? = nil, completionHandler: @escaping(AuthResult) -> Void) {
        // Every exit from this method must call completionHandler: "Add subscription" clears its
        // loading spinner only from the handler, so dropping it hangs the sheet with no error.
        // A base URL can reach here unparseable — isAddViewValid() only checks `^https?://.+`,
        // which accepts e.g. an internal space ("https://my server.com") that URL(string:) rejects.
        guard let url = URL(string: topicAuthUrl(baseUrl: baseUrl, topic: topic)) else {
            Log.e(tag, "Cannot build auth URL for baseUrl=\(baseUrl), topic=\(topic)")
            completionHandler(.Error("Invalid server URL"))
            return
        }
        let request = newRequest(url: url, baseUrl: baseUrl, user: user)
        Log.d(tag, "Checking auth for \(url) with user \(user?.username ?? "anonymous")")
        runOneShot(request, timeout: 10, baseUrl: baseUrl, session: session) { (data, response, error) in
            if let error = error {
                Log.e(self.tag, "Error checking auth: \(error)")
                completionHandler(.Error(error.localizedDescription))
            } else if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    completionHandler(.Unauthorized)
                } else {
                    completionHandler(.Error("Unexpected response from server: \(httpResponse.statusCode)"))
                }
            } else if let data = data {
                do {
                    let result = try JSONDecoder().decode(AuthCheckResponse.self, from: data)
                    Log.d(self.tag, "Auth result: \(result)")
                    if result.success == true {
                        completionHandler(.Success)
                    } else {
                        completionHandler(.Error("Unexpected response from server"))
                    }
                } catch {
                    Log.e(self.tag, "Error handling auth response: \(error)")
                    completionHandler(.Error("Unexpected response from server. Is this a ntfy server?"))
                }
            } else {
                // Not reached today (URLSession hands back empty Data, not nil, for a bodyless
                // response), but the chain above had no terminal branch — so any future shape
                // that satisfies none of them would silently hang the sheet. Fail loudly instead.
                Log.e(self.tag, "Auth check produced no error, no HTTP status and no data")
                completionHandler(.Error("Unexpected response from server"))
            }
        }
    }

    private func fetchJsonData<T: Decodable>(urlString: String, baseUrl: String, user: ServerCredential?, timeout: TimeInterval = 30, completionHandler: @escaping ([T]?, Error?) -> ()) {
        guard let url = URL(string: urlString) else {
            completionHandler(nil, URLError(.badURL))
            return
        }
        let request = newRequest(url: url, baseUrl: baseUrl, user: user)
        runOneShot(request, timeout: timeout, baseUrl: baseUrl) { (data, response, error) in
            if let error {
                Log.e(self.tag, "Error fetching data", error)
                completionHandler(nil, error)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                let http = response as? HTTPURLResponse
                completionHandler(nil, PollHTTPError(status: http?.statusCode ?? 0,
                    retryAfter: http?.value(forHTTPHeaderField: "Retry-After"),
                    retryCondition: http?.value(forHTTPHeaderField: "Retry-After-Condition")))
                return
            }
            guard let data = data else {
                completionHandler(nil, URLError(.badServerResponse))
                return
            }
            do {
                let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                var notifications: [T] = []
                for jsonLine in lines {
                    guard let jsonData = jsonLine.data(using: .utf8) else {
                        throw URLError(.cannotDecodeContentData)
                    }
                    notifications.append(try JSONDecoder().decode(T.self, from: jsonData))
                }
                completionHandler(notifications, nil)
            } catch {
                Log.e(self.tag, "Error fetching data", error)
                completionHandler(nil, error)
            }
        }
    }
    
    func newRequest(url: URL, baseUrl: String, user: ServerCredential?) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(ApiService.userAgent, forHTTPHeaderField: "User-Agent")
        // Apply these last: an explicit custom Authorization or User-Agent is an intentional
        // override, while all other requests retain the app's defaults above.
        ServerCredentials.apply(
            to: &request,
            baseUrl: baseUrl,
            authorizationHeader: user?.toHeader(),
            credentialStore: credentialStore
        )
        return request
    }
    
    /// Runs one request. A session this creates is invalidated as soon as its task is queued
    /// (`finishTasksAndInvalidate` lets the task finish first), because a URLSession with a delegate
    /// is retained by the system, delegate included, until invalidated. These never were, so every
    /// poll, publish and auth check leaked a session; the open-topic poll made that one every
    /// ten seconds. A caller-supplied session is the caller's to manage and is left alone.
    @discardableResult
    func runOneShot(
        _ request: URLRequest,
        timeout: TimeInterval,
        baseUrl: String,
        session: URLSession? = nil,
        completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void
    ) -> URLSession {
        let owned = session == nil
        let session = session ?? newSession(timeout: timeout, baseUrl: baseUrl)
        session.dataTask(with: request, completionHandler: completionHandler).resume()
        if owned {
            session.finishTasksAndInvalidate()
        }
        return session
    }

    private func newSession(timeout: TimeInterval, baseUrl: String) -> URLSession {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = timeout
        sessionConfig.timeoutIntervalForResource = timeout
        let redirectDelegate = ServerCredentialRedirectDelegate(baseUrl: baseUrl, credentialStore: credentialStore)
        return URLSession(configuration: sessionConfig, delegate: redirectDelegate, delegateQueue: nil)
    }
}

/// Everything a poll request needs, copied off the managed `Subscription` on its context's queue.
struct PollRequest {
    let subscriptionID: NSManagedObjectID
    let baseUrl: String
    let topicUrl: String
    /// The cursor the request asks from (`since=`), nil for the first poll.
    let since: String?
    let user: ServerCredential?
}

/// A server has exactly one login, shared by API and attachment requests.
enum ServerCredential: Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    case basic(username: String, password: String)
    case accessToken(String)

    init(username: String, password: String) {
        self = .basic(username: username, password: password)
    }

    /// Only a label is exposed for token accounts. The secret never becomes a username.
    var username: String {
        if case .basic(let username, _) = self { return username }
        return "Access token"
    }

    var password: String {
        if case .basic(_, let password) = self { return password }
        return ""
    }

    var isAccessToken: Bool {
        if case .accessToken = self { return true }
        return false
    }

    func toHeader() -> String {
        switch self {
        case .basic(let username, let password):
            return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        case .accessToken(let token):
            return "Bearer " + token
        }
    }

    var description: String { isAccessToken ? "Access token (<redacted>)" : "Username and password (<redacted>)" }
    var debugDescription: String { description }
}

// Existing polling and extension callers accept the same value type during this transition.
typealias BasicUser = ServerCredential

enum AuthResult {
    case Success
    case Unauthorized
    case Error(String)
}

struct AuthCheckResponse: Codable {
    let success: Bool?
    let code: Int?
    let http: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case success, code, http, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.success = try container.decodeIfPresent(Bool.self, forKey: .success)
        self.code = try container.decodeIfPresent(Int.self, forKey: .code)
        self.http = try container.decodeIfPresent(Int.self, forKey: .http)
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

enum ClearOutcome: Equatable {
    case sent, failed, rateLimited(retryAfter: TimeInterval), conditionLimited(RetryDirective)
}

/// Read-state clears share the server's per-IP request bucket (ntfy-me.com: 120 burst, one token
/// per 3 s) and its daily message quota with polls and publishes. Opening a topic with hundreds of
/// unread messages used to fire one PUT per message at once; most came back 429 and locked the
/// user's own polls out for minutes. Clears go out one at a time, spaced, and a 429 drops what is
/// queued for that server and pauses it for its Retry-After; other servers keep going.
/// Clears are best effort: local state never waits.
final class ClearPacer {
    /// Newest distinct sequences cleared per read action; older ones are rarely still on screen elsewhere.
    static let perAction = 10
    static let maxPending = 30
    static let spacing: TimeInterval = 1
    typealias Publish = (ClearRequest, @escaping (ClearOutcome) -> Void) -> Void
    var schedule: (TimeInterval, @escaping () -> Void) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) }
    var now: () -> Date = Date.init
    private struct Item {
        let request: ClearRequest; let publish: Publish; let first: Bool; let done: (Bool) -> Void
        var server: String { normalizeBaseUrl(request.baseUrl) }
    }
    private let lock = NSLock()
    private var pending: [Item] = []
    private var busy = false
    private var lastStart = Date.distantPast
    private let injectedCooldown: ServerCooldown?
    private lazy var cooldown = injectedCooldown ?? ServerCooldown(defaults: nil, now: { [weak self] in self?.now() ?? Date() })

    init(cooldown: ServerCooldown? = nil) { injectedCooldown = cooldown }

    /// `first` puts these ahead of the backlog: a notification response holds iOS's completion
    /// handler until its clear is sent, so it can't wait behind a topic's worth of clears.
    func send(_ requests: [ClearRequest], via publish: @escaping Publish, first: Bool = false,
              done: @escaping (ClearRequest, Bool) -> Void) {
        lock.lock()
        for request in requests { cooldown.requestChanged(server: request.baseUrl, kind: .clear) }
        let items = requests.map { request in Item(request: request, publish: publish, first: first) { done(request, $0) } }
        if first { pending.insert(contentsOf: items, at: 0) } else { pending += items }
        var overflow: [Item] = []
        var index = 0
        while pending.count > Self.maxPending, index < pending.count {
            if pending[index].first { index += 1 } else { overflow.append(pending.remove(at: index)) }
        }
        lock.unlock()
        overflow.forEach { $0.done(false) }
        pump()
    }

    private func pump() {
        lock.lock()
        let now = now()
        let paused = pending.filter { !cooldown.claim(server: $0.server, manual: cooldown.hasNonTimeRefusal(server: $0.server, kind: .clear), kind: .clear, consumingProbe: false) }
        pending.removeAll { !cooldown.claim(server: $0.server, manual: cooldown.hasNonTimeRefusal(server: $0.server, kind: .clear), kind: .clear, consumingProbe: false) }
        guard !busy, !pending.isEmpty else { lock.unlock(); paused.forEach { $0.done(false) }; return }
        busy = true
        let wait = lastStart.addingTimeInterval(Self.spacing).timeIntervalSince(now)
        if wait > 0 {
            lock.unlock()
            paused.forEach { $0.done(false) }
            schedule(wait) { [self] in lock.lock(); busy = false; lock.unlock(); pump() }
            return
        }
        let item = pending.removeFirst()
        guard let attempt = cooldown.claimAttempt(server: item.server,
            manual: cooldown.hasNonTimeRefusal(server: item.server, kind: .clear), kind: .clear) else {
            busy = false
            lock.unlock()
            paused.forEach { $0.done(false) }
            item.done(false)
            pump()
            return
        }
        lastStart = now
        lock.unlock()
        paused.forEach { $0.done(false) }
        item.publish(item.request) { [self] outcome in
            lock.lock()
            busy = false
            var dropped: [Item] = []
            if outcome == .sent { cooldown.succeeded(server: item.server, attempt: attempt) }
            if case .rateLimited(let retryAfter) = outcome {
                let header = retryAfter.isFinite && retryAfter >= 0 ? String(Int(min(retryAfter, 3600))) : nil
                cooldown.limit(server: item.server, retryAfter: header, kind: .clear)
                dropped = pending.filter { $0.server == item.server }
                pending.removeAll { $0.server == item.server }
            }
            if case .conditionLimited(let directive) = outcome {
                switch directive {
                case .time(let delay): cooldown.limit(server: item.server, retryAfter: String(format: "%.0f", ceil(delay)), condition: "time", kind: .clear)
                case .stateChange: cooldown.limit(server: item.server, retryAfter: nil, condition: "state-change", kind: .clear)
                case .requestChange: cooldown.limit(server: item.server, retryAfter: nil, condition: "request-change", kind: .clear)
                }
                dropped = pending.filter { $0.server == item.server }
                pending.removeAll { $0.server == item.server }
            }
            lock.unlock()
            item.done(outcome == .sent)
            dropped.forEach { $0.done(false) }
            pump()
        }
    }
}

/// Snapshot captured on the store queue. Safe to use after the row is changed or deleted.
struct ClearRequest {
    let baseUrl: String
    let topic: String
    let sequence: String
    let user: ServerCredential?
    let messageId: String?
    init(baseUrl: String, topic: String, sequence: String, user: ServerCredential?, messageId: String? = nil) {
        self.baseUrl = baseUrl; self.topic = topic; self.sequence = sequence; self.user = user; self.messageId = messageId
    }
}
