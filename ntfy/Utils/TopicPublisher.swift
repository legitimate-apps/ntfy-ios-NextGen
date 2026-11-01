import Foundation

/// Compose and automation share credentials, encryption and publish error handling.
@MainActor
enum TopicPublisher {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func send(subscription: Subscription, store: Store, message: String, title: String,
                     priority: Int = 3, tags: String = "", options: PublishOptions = PublishOptions(),
                     api: ApiService = .shared, cooldown: ServerCooldown = .shared,
                     completion: @escaping (Result<Void, Failure>) -> Void) {
        let keyState = store.topicKeyState(for: subscription)
        guard keyState != .unavailable else {
            completion(.failure(Failure(message: String(localized: "The encryption password is unavailable. Unlock your phone or set the topic password again. Nothing was sent."))))
            return
        }
        let baseURL = subscription.baseUrl ?? ""
        let credential = store.getBasicUser(baseUrl: baseURL)
        guard store.getUser(baseUrl: baseURL) == nil || credential != nil,
              case .success = store.credentialStore.readHTTPHeaders(baseUrl: baseURL) else {
            completion(.failure(Failure(message: String(localized: "The server sign-in is unavailable. Unlock your phone or sign in again in Settings. Nothing was sent."))))
            return
        }
        api.publish(subscription: subscription, user: credential, message: message, title: title,
            priority: priority, tags: parseAllTags(tags), options: options, encryptionKey: keyState.key,
            cooldown: cooldown, completionHandler: {
                DispatchQueue.main.async { completion(.success(())) }
            }, failureHandler: { failure in
                DispatchQueue.main.async {
                    let message: String
                    if failure == .http(429), cooldown.hasNonTimeRefusal(server: baseURL, kind: .publish) {
                        message = ApiService.PublishError.publishNeedsChange.userMessage
                    } else if failure == .http(429) {
                        let seconds = Int(ceil(max(1, cooldown.deadline(for: baseURL, kind: .publish).timeIntervalSinceNow)))
                        message = ApiService.PublishError.publishWait(seconds).userMessage
                    } else {
                        message = failure.userMessage
                    }
                    completion(.failure(Failure(message: message)))
                }
            })
    }
}
