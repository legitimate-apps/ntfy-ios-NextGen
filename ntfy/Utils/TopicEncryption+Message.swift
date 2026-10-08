import Foundation

/// How a stored notification relates to end-to-end encryption. Persisted as `Notification.encryption`.
enum NotificationEncryption: Int16 {
    /// An ordinary message.
    case none = 0
    /// Arrived encrypted and was decrypted with the topic's password.
    case decrypted = 1
    /// Arrived encrypted and could not be read yet (no password, or the wrong one). The JWE is kept in
    /// `Notification.ciphertext` so setting the right password later can still open it.
    case locked = 2
    /// Arrived as plaintext on a topic that has a password. Topics are public, so anyone who knows the
    /// name can publish; marking these keeps them from passing as the encrypted sender's messages.
    /// Shown, not dropped: upstream's draft also shows unencrypted messages on encrypted topics.
    case unencrypted = 3
}

/// Whether a topic is encrypted and, if so, whether its key can be read right now.
enum TopicKeyState: Equatable {
    case notEncrypted
    case key(Data)
    /// Flagged as encrypted, but the key can't be read now. Callers must fail closed.
    case unavailable

    var key: Data? {
        if case .key(let key) = self { return key }
        return nil
    }
}

/// What the encryption settings screen shows for a topic.
enum TopicPasswordState: Equatable {
    case off
    case on(String)
    /// On, but the password can't be read on this device right now.
    case unreadable
}

/// A message as it should be stored and shown, after any decryption.
struct IngestedMessage {
    let message: Message
    let encryption: NotificationEncryption
    /// The JWE, kept only while the message is still locked.
    let ciphertext: String?
    /// The JWE's IV (base64), set once the message authenticated. Senders pick a random IV per
    /// message, so a second message with the same IV is a captured ciphertext re-posted (a replay).
    var iv: String? = nil
}

/// What the push path did with a message.
enum PushedMessageResult {
    /// Stored (or already stored); this is the message as the row shows it.
    case stored(Message)
    /// An authenticated ciphertext this topic has already received under another id: not stored.
    case replay

    var message: Message? {
        if case .stored(let message) = self { return message }
        return nil
    }
}

extension TopicEncryption {
    static let lockedPlaceholder = "Encrypted message"
    static let unencryptedMarker = "⚠︎ Not encrypted"

    /// Passwords are trimmed on entry: a space picked up when pasting would otherwise produce a
    /// different key from the sender's, and nothing would ever decrypt.
    static func normalizedPassword(_ password: String) -> String {
        password.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Turns a message from the server into what the app stores and shows.
    ///
    /// `key` is the topic's key, or nil when the topic has no password (or it can't be read). On a topic without a password,
    /// anything that is not upstream-format JWE passes through untouched, exactly as before.
    ///
    /// Trust rule: the server (or anyone who knows the topic name) can't read or forge the encrypted
    /// payload, but it controls every outer field. So:
    /// - decrypted: every presentation field comes from the authenticated payload only; the outer
    ///   message contributes just its envelope (id, time, event, topic, poll id);
    /// - locked: a plain placeholder with no outer title, tags, priority, links, actions, icon or
    ///   attachment, so nothing about it looks trustworthy;
    /// - plaintext on a topic with a password: kept as sent but marked `.unencrypted`.
    /// `topicEncrypted` defaults to "a key was given"; pass true with a nil key for a topic that has a
    /// password whose key can't be read right now.
    static func ingest(_ message: Message, key: Data?, topicEncrypted: Bool? = nil) -> IngestedMessage {
        guard message.event == "message" else {
            return IngestedMessage(message: message, encryption: .none, ciphertext: nil)
        }
        guard let body = message.message, parse(body) != nil else {
            guard topicEncrypted ?? (key != nil) else {
                return IngestedMessage(message: message, encryption: .none, ciphertext: nil)
            }
            var marked = message
            marked.encryption = .unencrypted
            return IngestedMessage(message: marked, encryption: .unencrypted, ciphertext: nil)
        }
        guard let key, let payload = try? decryptPayload(body, key: key) else {
            var locked = envelope(of: message)
            locked.message = lockedPlaceholder
            locked.encryption = .locked
            return IngestedMessage(message: locked, encryption: .locked, ciphertext: body.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var decrypted = merge(payload, into: message)
        decrypted.encryption = .decrypted
        return IngestedMessage(message: decrypted, encryption: .decrypted, ciphertext: nil,
                               iv: parse(body)?.iv.base64EncodedString())
    }

    /// Only the server's routing envelope: what dedupe, ordering and polling need, nothing it could use
    /// to dress up a message. Outer attachments are dropped rather than shown: the draft doesn't
    /// encrypt them, so one next to an encrypted message is server-asserted and unauthenticated.
    private static func envelope(of outer: Message) -> Message {
        Message(id: outer.id, time: outer.time, event: outer.event, topic: outer.topic, pollId: outer.pollId)
    }

    static func merge(_ payload: EncryptedPayload, into outer: Message) -> Message {
        var message = envelope(of: outer)
        message.message = payload.message
        message.title = payload.title
        message.tags = payload.tags
        message.priority = payload.priority.map { Int16(clamping: $0) }
        message.click = payload.click
        message.icon = payload.icon
        message.contentType = payload.markdown == true ? "text/markdown" : nil
        if let actions = payload.actions {
            // The server mints action ids, but it never saw these. Derive them from the message id so
            // the app and the extension (separate processes that may both ingest the same message)
            // agree on them — a tapped banner action is resolved by id.
            message.actions = actions.enumerated().compactMap { index, action in
                guard ["view", "http"].contains(action.action) else { return nil }
                return Action(
                    id: "\(outer.id)-e2e\(index)",
                    action: action.action,
                    label: action.label,
                    url: action.url,
                    method: action.method,
                    headers: action.headers,
                    body: action.body,
                    clear: action.clear
                )
            }
        }
        return message
    }

    /// The JSON payload the app itself publishes to an encrypted topic.
    static func payload(message: String, title: String, priority: Int, tags: [String]) -> EncryptedPayload {
        EncryptedPayload(
            message: message,
            title: title.isEmpty ? nil : title,
            tags: tags.isEmpty ? nil : tags,
            priority: priority
        )
    }
}
