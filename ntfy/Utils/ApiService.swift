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
    func poll(_ request: PollRequest, completionHandler: @escaping ([Message]?, Error?) -> Void) {
        let urlString = "\(request.topicUrl)/json?poll=1&since=\(request.since ?? "all")"
        Log.d(tag, "Polling from \(urlString) with user \(request.user?.username ?? "anonymous")")
        fetchJsonData(urlString: urlString, baseUrl: request.baseUrl, user: request.user, completionHandler: completionHandler)
    }
    
    func poll(subscription: Subscription, messageId: String, user: BasicUser?, completionHandler: @escaping (Message?, Error?) -> Void) {
        poll(baseUrl: subscription.baseUrl ?? "?", topic: subscription.topic ?? "?", messageId: messageId, user: user, completionHandler: completionHandler)
    }

    func poll(baseUrl: String, topic: String, messageId: String, user: BasicUser?, timeout: TimeInterval = 30, completionHandler: @escaping (Message?, Error?) -> Void) {
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
                completionHandler(nil, URLError(.badServerResponse))
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

    func publish(
        subscription: Subscription,
        user: BasicUser?,
        message: String,
        title: String,
        priority: Int = 3,
        tags: [String] = [],
        encryptionKey: Data? = nil,
        session: URLSession? = nil,
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
        Log.d(tag, "Publishing to \(request.url?.absoluteString ?? "?")\(encryptionKey == nil ? "" : " (end-to-end encrypted)")")
        runOneShot(request, timeout: 10, baseUrl: subscription.baseUrl ?? "?", session: session) { (data, response, error) in
            guard error == nil else {
                Log.e(self.tag, "Error publishing message", error!)
                failureHandler?(.network(error!.localizedDescription))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode
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
        user: BasicUser?,
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
        user: BasicUser?,
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

    func checkAuth(baseUrl: String, topic: String, user: BasicUser?, session: URLSession? = nil, completionHandler: @escaping(AuthResult) -> Void) {
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

    private func fetchJsonData<T: Decodable>(urlString: String, baseUrl: String, user: BasicUser?, completionHandler: @escaping ([T]?, Error?) -> ()) {
        guard let url = URL(string: urlString) else {
            completionHandler(nil, URLError(.badURL))
            return
        }
        let request = newRequest(url: url, baseUrl: baseUrl, user: user)
        runOneShot(request, timeout: 30, baseUrl: baseUrl) { (data, response, error) in
            if let error {
                Log.e(self.tag, "Error fetching data", error)
                completionHandler(nil, error)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                completionHandler(nil, URLError(.badServerResponse))
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
    
    func newRequest(url: URL, baseUrl: String, user: BasicUser?) -> URLRequest {
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
    let user: BasicUser?
}

struct BasicUser {
    let username: String
    let password: String
    
    func toHeader() -> String {
        return "Basic " + String(format: "%@:%@", username, password).data(using: String.Encoding.utf8)!.base64EncodedString()
    }
}

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
