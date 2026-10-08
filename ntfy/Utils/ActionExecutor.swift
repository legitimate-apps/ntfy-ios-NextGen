import Foundation
import UIKit
import UserNotifications

/// Outcome of an `http` action's network request, split out as a pure value so the
/// status-code classification can be unit-tested without touching the network.
enum HTTPActionResult: Equatable {
    case success
    case failure(String) // human-readable reason (transport error or non-2xx status)
}

struct ActionExecutor {
    private static let tag = "ActionExecutor"

    /// Executes a user-tapped action. When the action carries ntfy's `clear`
    /// flag and the id of the delivered notification is known, that notification
    /// is removed from Notification Center so the tap gives visible feedback
    /// (ntfy #1728 — e.g. a remote "Approve" button that otherwise leaves the
    /// banner on screen with no change). Adapted from binwiederhier/ntfy-ios#38
    /// (@abreparentesis) for this fork's ActionExecutor.
    static func execute(
        _ action: Action,
        notificationId: String? = nil,
        baseUrl: String? = nil,
        credentialStore: CredentialStoring = KeychainCredentialStore.shared
    ) {
        Log.d(tag, "Executing user action", action)
        switch action.action {
        case "view":
            if let url = URL(string: action.url ?? "") {
                open(url: url)
            } else {
                Log.w(tag, "Unable to parse action URL", action)
            }
        case "http":
            http(action, baseUrl: baseUrl, credentialStore: credentialStore)
        default:
            Log.w(tag, "Action \(action.action) not supported", action)
        }

        if let ids = identifiersToClear(for: action, notificationId: notificationId) {
            Log.d(tag, "Clearing delivered notification(s) for action.clear", ids)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    /// Pure decision — which delivered-notification identifiers a tap on `action`
    /// should dismiss, or `nil` when nothing should be cleared. The `clear` flag is
    /// honored only when a non-empty notification id is actually known (otherwise
    /// there is nothing to remove). Split out from the side effect above so it is
    /// unit-testable without touching Notification Center (see ntfyTests).
    static func identifiersToClear(for action: Action, notificationId: String?) -> [String]? {
        guard action.clear == true,
              let notificationId, !notificationId.isEmpty else {
            return nil
        }
        return [notificationId]
    }
    
    private static func http(_ action: Action, baseUrl: String?, credentialStore: CredentialStoring) {
        guard let request = makeHTTPRequest(action, baseUrl: baseUrl, credentialStore: credentialStore) else {
            Log.w(tag, "Unable to execute HTTP action, no or invalid URL", action)
            return
        }
        let method = action.method ?? "POST" // POST is the default!!

        Log.d(tag, "Performing HTTP \(method) \(request.url?.absoluteString ?? "?")")

        let session: URLSession
        if let baseUrl {
            let redirectDelegate = ServerCredentialRedirectDelegate(baseUrl: baseUrl, credentialStore: credentialStore)
            session = URLSession(configuration: .default, delegate: redirectDelegate, delegateQueue: nil)
        } else {
            session = .shared
        }
        session.dataTask(with: request) { (data, response, error) in
            switch httpActionResult(response: response, error: error) {
            case .success:
                Log.d(self.tag, "HTTP \(method) action succeeded", response)
                notifyActionResult(action, success: true, detail: nil)
            case .failure(let reason):
                Log.e(self.tag, "HTTP \(method) action failed: \(reason)")
                notifyActionResult(action, success: false, detail: reason)
            }
        }.resume()
        // A per-action delegate session is retained until invalidated; let the task finish, then free it.
        if session !== URLSession.shared {
            session.finishTasksAndInvalidate()
        }
    }

    static func makeHTTPRequest(
        _ action: Action,
        baseUrl: String?,
        credentialStore: CredentialStoring = KeychainCredentialStore.shared
    ) -> URLRequest? {
        guard let actionUrl = action.url, let url = URL(string: actionUrl) else { return nil }
        let method = action.method ?? "POST"
        var request = URLRequest(url: url)
        request.httpMethod = method
        action.headers?.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if !["GET", "HEAD"].contains(method) {
            request.httpBody = (action.body ?? "").data(using: .utf8)
        }
        if let baseUrl {
            ServerCredentials.apply(to: &request, baseUrl: baseUrl, credentialStore: credentialStore)
        }
        return request
    }

    /// Classifies an `http` action response. A transport `error`, or an HTTP status
    /// outside 2xx, is a failure — the previous code logged non-2xx (e.g. a 401 on an
    /// "Approve" action) as success, so the user got no signal the action didn't take.
    static func httpActionResult(response: URLResponse?, error: Error?) -> HTTPActionResult {
        if let error = error {
            return .failure(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            // Non-HTTP (or missing) response with no transport error: nothing to
            // assess, treat the completed request as a success.
            return .success
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failure("HTTP \(http.statusCode)")
        }
        return .success
    }

    /// Stable identifier for the action-result notification. Re-using one identifier means a
    /// new result *replaces* the previous one instead of stacking: iOS treats a re-added
    /// request id as an update. With a fresh UUID per tap, every action the user ever pressed
    /// would leave a permanent extra row in Notification Center for them to clear by hand.
    private static let resultNotificationId = "ntfyActionResult"

    /// Posts a local notification so the user sees whether an action succeeded — the
    /// only feedback channel that works from a banner tap, where there is no in-app UI.
    private static func notifyActionResult(_ action: Action, success: Bool, detail: String?) {
        let content = UNMutableNotificationContent()
        content.title = success ? "✅ \(action.label)" : "⚠️ \(action.label) failed"
        if !success, let detail = detail {
            content.body = detail
        }
        // A result is an acknowledgement, not news: keep it out of the way of real messages.
        content.interruptionLevel = success ? .passive : .active
        content.relevanceScore = 0
        let request = UNNotificationRequest(identifier: resultNotificationId, content: content, trigger: nil /* now */)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Log.e(tag, "Unable to post action-result notification", error)
            }
        }
    }

    private static func open(url: URL) {
        Log.d(tag, "Opening URL \(url)")
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
