import Foundation

/// Extensions to make the notification easier to display
extension Notification {
    func shortDateTime() -> String {
        return Notification.shortDateTime(for: Date(timeIntervalSince1970: TimeInterval(self.time)))
    }

    /// When a notification arrived, at the precision the user can actually act on (ntfy#1205).
    ///
    /// The time is now always shown. Previously anything not from today lost it entirely —
    /// yesterday rendered as the bare word "yesterday" and older messages as a bare date — so
    /// there was no way to tell whether an alert landed at 09:00 or 23:00, which is exactly what
    /// people were asking for. Only *today* omits the date, because the date is redundant there
    /// and the list is already in chronological order.
    ///
    /// "Yesterday" comes from `doesRelativeDateFormatting`, so it is localized (and correctly
    /// absent in locales that have no such word) rather than a hardcoded English string.
    ///
    /// `now`, `calendar` and `locale` are injectable so this is testable without depending on the
    /// machine's clock, timezone or region.
    static func shortDateTime(for date: Date,
                              now: Date = Date(),
                              calendar: Calendar = .current,
                              locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .short

        let isToday = calendar.isDate(date, inSameDayAs: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
        let isYesterday = yesterday.map { calendar.isDate(date, inSameDayAs: $0) } ?? false

        if isToday {
            formatter.dateStyle = .none
        } else if isYesterday {
            formatter.dateStyle = .medium
            formatter.doesRelativeDateFormatting = true
        } else {
            formatter.dateStyle = .short
        }

        return formatter.string(from: date)
    }
    
    func formatMessage(bundle: Bundle = .main) -> String {
        // A stored locked placeholder is app copy, not server content. Resolve it again after
        // a language change without touching any readable message from the sender.
        if encryptionState == .locked {
            return bundle.localizedString(forKey: "Encrypted message", value: nil, table: nil)
        }
        let message = Message.localizedBody(message, contentType: contentType, bundle: bundle)
        if let title = title, title != "" {
            return message
        }
        let emojiTags = emojiTags()
        if !emojiTags.isEmpty {
            return emojiTags.joined(separator: "") + " " + message
        }
        return message
    }
    
    func formatTitle() -> String? {
        if let title = title, title != "" {
            let emojiTags = emojiTags()
            if !emojiTags.isEmpty {
                return emojiTags.joined(separator: "") + " " + title
            }
            return title
        }
        return nil
    }
    
    var encryptionState: NotificationEncryption {
        NotificationEncryption(rawValue: encryption) ?? .none
    }

    func emojiTags() -> [String] {
        return parseEmojiTags(tags)
    }
    
    func nonEmojiTags() -> [String] {
        return parseNonEmojiTags(tags)
    }
    
    func actionsList() -> [Action] {
        return Actions.shared.parse(actions) ?? []
    }

    /// The per-message icon URL from the ntfy `Icon` header (#1107), if any.
    func iconUrl() -> URL? {
        guard let icon = icon, !icon.isEmpty else { return nil }
        return URL(string: icon)
    }

    func messageAttachment() -> MessageAttachment? {
        guard let attachmentUrl = attachmentUrl, !attachmentUrl.isEmpty else {
            return nil
        }
        return MessageAttachment(
            name: attachmentName ?? "",
            type: attachmentType,
            size: attachmentSize == 0 ? nil : attachmentSize,
            expires: attachmentExpires == 0 ? nil : attachmentExpires,
            url: attachmentUrl
        )
    }

    func attachmentRemoteUrl() -> URL? {
        guard let attachment = messageAttachment() else {
            return nil
        }
        return URL(string: attachment.url)
    }

    func attachmentStoredLocalFileUrl() -> URL? {
        guard let attachmentLocalPath, !attachmentLocalPath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: attachmentLocalPath)
    }

    func attachmentLocalFileUrl() -> URL? {
        guard let url = attachmentStoredLocalFileUrl() else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    func attachmentStoredProgressState() -> AttachmentProgressState {
        AttachmentProgressState(
            storedValue: attachmentProgress,
            hasAttachment: messageAttachment() != nil,
            hasLocalFile: attachmentStoredLocalFileUrl() != nil
        )
    }

    func attachmentProgressState(overrideState: AttachmentProgressState? = nil) -> AttachmentProgressState {
        overrideState ?? attachmentStoredProgressState()
    }

    func isAttachmentDownloading(overrideState: AttachmentProgressState? = nil) -> Bool {
        attachmentProgressState(overrideState: overrideState).isDownloading
    }

    func attachmentIsExpired(referenceDate: Date = Date()) -> Bool {
        guard let expires = messageAttachment()?.expires else {
            return false
        }
        return expires < Int64(referenceDate.timeIntervalSince1970)
    }

    func attachmentStatusDescription(overrideState: AttachmentProgressState? = nil) -> String {
        guard let attachment = messageAttachment() else {
            return ""
        }
        var parts: [String] = []
        if let size = attachment.size, size > 0 {
            parts.append(formatBytes(size))
        }

        let progress = attachmentProgressState(overrideState: overrideState)
        let hasStoredLocalFile = attachmentStoredLocalFileUrl() != nil
        let deleted = !hasStoredLocalFile && (progress == .done || progress == .deleted)
        if progress == .none {
            if attachmentIsExpired() {
                parts.append(String(localized: "Not downloaded, expired"))
            } else if let expiry = attachmentExpiryShortDateString() {
                parts.append(String(localized: "Not downloaded, expires \(expiry)"))
            } else {
                parts.append(String(localized: "Not downloaded"))
            }
        } else if case .progress(let percent) = progress {
            parts.append(String(localized: "Downloading \(Int(percent))%"))
        } else if progress == .failed {
            if attachmentIsExpired() {
                parts.append(String(localized: "Download failed, expired"))
            } else if let expiry = attachmentExpiryShortDateString() {
                parts.append(String(localized: "Download failed, expires \(expiry)"))
            } else {
                parts.append(String(localized: "Download failed"))
            }
        } else if progress == .canceled {
            if attachmentIsExpired() {
                parts.append(String(localized: "Download canceled, expired"))
            } else if let expiry = attachmentExpiryShortDateString() {
                parts.append(String(localized: "Download canceled, expires \(expiry)"))
            } else {
                parts.append(String(localized: "Download canceled"))
            }
        } else if progress == .skipped {
            if attachmentIsExpired() {
                parts.append(String(localized: "Not downloaded, expired"))
            } else if let expiry = attachmentExpiryShortDateString() {
                parts.append(String(localized: "Not auto-downloaded, expires \(expiry)"))
            } else {
                parts.append(String(localized: "Not auto-downloaded"))
            }
        } else if deleted {
            if attachmentIsExpired() {
                parts.append(String(localized: "Deleted, expired"))
            } else if let expiry = attachmentExpiryShortDateString() {
                parts.append(String(localized: "Deleted, expires \(expiry)"))
            } else {
                parts.append(String(localized: "Deleted"))
            }
        }
        return parts.joined(separator: " · ")
    }

    func notificationAttachmentSummary(overrideState: AttachmentProgressState? = nil) -> String? {
        guard let attachment = messageAttachment() else {
            return nil
        }
        var parts = [attachment.displayName()]
        if let size = attachment.size, size > 0 {
            parts.append(formatBytes(size))
        }

        let progress = attachmentProgressState(overrideState: overrideState)
        if progress == .done {
            parts.append(String(localized: "downloaded"))
        } else if progress.isDownloading {
            parts.append(String(localized: "downloading"))
        } else if progress == .failed {
            parts.append(String(localized: "download failed"))
        } else if progress == .canceled {
            parts.append(String(localized: "download canceled"))
        } else if progress == .skipped {
            parts.append(String(localized: "not auto-downloaded"))
        } else if attachmentIsExpired() {
            parts.append(String(localized: "expired"))
        }

        return String(localized: "Attachment: \(parts.joined(separator: ", "))")
    }

    private func attachmentExpiryShortDateString() -> String? {
        guard let expires = messageAttachment()?.expires else {
            return nil
        }
        let expiresDate = Date(timeIntervalSince1970: TimeInterval(expires))
        guard expiresDate > Date() else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: expiresDate)
    }

    @MainActor
    func resetAttachmentDownload() {
        attachmentProgress = AttachmentProgressState.none.persistedValue
        try? managedObjectContext?.save()
    }

    @MainActor
    func failAttachmentDownload() {
        attachmentProgress = AttachmentProgressState.failed.persistedValue
        try? managedObjectContext?.save()
    }

    @MainActor
    func cancelAttachmentDownload() {
        attachmentProgress = AttachmentProgressState.canceled.persistedValue
        try? managedObjectContext?.save()
    }

    @MainActor
    func skipAttachmentAutoDownload() {
        attachmentProgress = AttachmentProgressState.skipped.persistedValue
        try? managedObjectContext?.save()
    }

    @MainActor
    func completeAttachmentDownload(localPath: String, resolvedType: String?, resolvedSize: Int64) {
        attachmentLocalPath = localPath
        attachmentProgress = AttachmentProgressState.done.persistedValue
        if resolvedSize > 0 {
            attachmentSize = resolvedSize
        }
        if let resolvedType, !resolvedType.isEmpty {
            attachmentType = resolvedType
        }
        try? managedObjectContext?.save()
    }

    @MainActor
    func markAttachmentDeleted() {
        attachmentLocalPath = nil
        attachmentProgress = AttachmentProgressState.deleted.persistedValue
        try? managedObjectContext?.save()
    }
}

struct MessageAttachment: Codable {
    var name: String
    var type: String?
    var size: Int64?
    var expires: Int64?
    var url: String

    func isImageAttachment() -> Bool {
        if let type = type, type.lowercased().hasPrefix("image/") {
            return true
        }
        guard let parsedUrl = URL(string: url) else {
            return false
        }
        let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"]
        return imageExtensions.contains(parsedUrl.pathExtension.lowercased())
    }

    func isExpired(referenceDate: Date = Date()) -> Bool {
        guard let expires else {
            return false
        }
        return expires < Int64(referenceDate.timeIntervalSince1970)
    }

    func displayName(bundle: Bundle = .main) -> String {
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        if let parsedUrl = URL(string: url) {
            let filename = parsedUrl.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !filename.isEmpty, filename != "/" {
                return filename
            }
        }
        return bundle.localizedString(forKey: "attachment", value: nil, table: nil)
    }

    func systemImageName() -> String {
        guard let type = type?.lowercased() else {
            return "doc"
        }
        if type.hasPrefix("image/") {
            return "photo"
        } else if type.hasPrefix("video/") {
            return "video"
        } else if type.hasPrefix("audio/") {
            return "waveform"
        } else if type == "application/pdf" {
            return "doc.richtext"
        } else if type.hasPrefix("text/") {
            return "doc.text"
        } else if type.hasPrefix("application/zip") || type.hasSuffix("compressed") {
            return "archivebox"
        } else {
            return "doc"
        }
    }
}

/// This is the "on the wire" message as it is received from the ntfy server
struct Message: Decodable {
    var id: String
    var time: Int64
    var event: String
    var topic: String
    var message: String?
    var title: String?
    var priority: Int16?
    var tags: [String]?
    var actions: [Action]?
    var click: String?
    var pollId: String?
    var attachment: MessageAttachment?
    var contentType: String?
    var icon: String?
    var sequenceID: String?
    /// Local presentation decision; never trusted from the wire.
    var isUpdate = false

    var sequence: String { sequenceID.flatMap { $0.isEmpty ? nil : $0 } ?? id }
    var isControl: Bool { event == "message_clear" || event == "message_delete" }
    /// Not on the wire: set by `TopicEncryption.ingest` so banners can mark how the message arrived.
    var encryption: NotificationEncryption = .none

    enum CodingKeys: String, CodingKey {
        case id, time, event, topic, message, title, priority, tags, actions, click, attachment
        case pollId = "poll_id"
        case encoding
        case contentType = "content_type"
        case icon
        case sequenceID = "sequence_id"
    }

    init(
        id: String,
        time: Int64,
        event: String,
        topic: String,
        message: String? = nil,
        title: String? = nil,
        priority: Int16? = nil,
        tags: [String]? = nil,
        actions: [Action]? = nil,
        click: String? = nil,
        pollId: String? = nil,
        attachment: MessageAttachment? = nil,
        contentType: String? = nil,
        icon: String? = nil,
        sequenceID: String? = nil,
        encoding: String? = nil
    ) {
        self.id = id
        self.time = time
        self.event = event
        self.topic = topic
        let normalized = Self.normalize(message, encoding: encoding)
        self.message = normalized.body
        self.title = title
        self.priority = priority
        self.tags = tags
        self.actions = actions
        self.click = click
        self.pollId = pollId
        self.attachment = attachment
        self.contentType = normalized.isDiagnostic ? Self.diagnosticContentType : contentType
        self.icon = icon
        self.sequenceID = sequenceID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        time = try container.decode(Int64.self, forKey: .time)
        event = try container.decode(String.self, forKey: .event)
        topic = try container.decode(String.self, forKey: .topic)
        let normalized = Self.normalize(try container.decodeIfPresent(String.self, forKey: .message),
                                        encoding: try container.decodeIfPresent(String.self, forKey: .encoding))
        message = normalized.body
        title = try container.decodeIfPresent(String.self, forKey: .title)
        priority = try container.decodeIfPresent(Int16.self, forKey: .priority)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        actions = try container.decodeIfPresent([Action].self, forKey: .actions)
        click = try container.decodeIfPresent(String.self, forKey: .click)
        pollId = try container.decodeIfPresent(String.self, forKey: .pollId)
        attachment = try container.decodeIfPresent(MessageAttachment.self, forKey: .attachment)
        let declaredContentType = try container.decodeIfPresent(String.self, forKey: .contentType)
        contentType = normalized.isDiagnostic ? Self.diagnosticContentType : declaredContentType
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        sequenceID = try container.decodeIfPresent(String.self, forKey: .sequenceID)
    }
    
    // Stored in the existing contentType field, so diagnostics need no schema migration and a
    // sender's literal text matching an English diagnostic is never guessed to be app copy.
    static let diagnosticContentType = "application/x-ntfy-decode-error"
    private static let diagnostics = [
        "This message uses an unsupported encoding.",
        "This message could not be decoded (invalid base64).",
        "This message contains binary data and cannot be displayed as text."
    ]

    static func localizedBody(_ body: String?, contentType: String?, bundle: Bundle = .main) -> String {
        let body = body ?? ""
        guard contentType == diagnosticContentType, diagnostics.contains(body) else { return body }
        return bundle.localizedString(forKey: body, value: body, table: nil)
    }

    /// Transport normalization retains language-neutral source text for storage and userInfo.
    /// The type marker distinguishes diagnostics from readable server content after a relaunch.
    static func normalizedBody(_ body: String?, encoding: String?) -> String? {
        normalize(body, encoding: encoding).body
    }

    static func normalizedDisplayBody(_ body: String?, encoding: String?) -> String {
        let normalized = normalize(body, encoding: encoding)
        return localizedBody(normalized.body, contentType: normalized.isDiagnostic ? diagnosticContentType : nil)
    }

    private static func normalize(_ body: String?, encoding: String?) -> (body: String?, isDiagnostic: Bool) {
        guard let body, let encoding, !encoding.isEmpty else { return (body, false) }
        guard encoding == "base64" else { return (diagnostics[0], true) }
        let encoded = body.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = Data(base64Encoded: encoded) else { return (diagnostics[1], true) }
        guard let text = String(data: data, encoding: .utf8) else { return (diagnostics[2], true) }
        return (text, false)
    }

    func toUserInfo() -> [AnyHashable: Any] {
        // This should mimic the way that the ntfy server encodes a message.
        // See server_firebase.go for more details.
        
        var userInfo: [AnyHashable: Any] = [
            "id": id,
            "time": String(time),
            "event": event,
            "topic": topic,
            "message": message ?? "",
            "title": title ?? "",
            "priority": String(priority ?? 3),
            "tags": tags?.joined(separator: ",") ?? "",
            "actions": Actions.shared.encode(actions),
            "click": click ?? "",
            "poll_id": pollId ?? "",
            "content_type": contentType ?? "",
            "icon": icon ?? "",
            "sequence_id": sequenceID ?? ""
        ]
        if let attachment {
            userInfo["attachment_name"] = attachment.name
            userInfo["attachment_type"] = attachment.type ?? ""
            userInfo["attachment_size"] = String(attachment.size ?? 0)
            userInfo["attachment_expires"] = String(attachment.expires ?? 0)
            userInfo["attachment_url"] = attachment.url
        }
        return userInfo
    }
    
    static func from(userInfo: [AnyHashable: Any]) -> Message? {
        guard let id = userInfo["id"] as? String,
              let time = userInfo["time"] as? String,
              let event = userInfo["event"] as? String,
              let topic = userInfo["topic"] as? String,
              let timeInt = Int64(time) else {
            Log.d(Store.tag, "Unknown or irrelevant message", userInfo)
            return nil
        }
        let message = userInfo["message"] as? String
        let title = userInfo["title"] as? String
        let priority = Int16(userInfo["priority"] as? String ?? "3") ?? 3
        let tags = (userInfo["tags"] as? String ?? "").components(separatedBy: ",").filter { !$0.isEmpty }
        let actions = userInfo["actions"] as? String
        let click = userInfo["click"] as? String
        let pollId = userInfo["poll_id"] as? String
        let contentType = (userInfo["content_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let icon = (userInfo["icon"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let attachmentUrl = userInfo["attachment_url"] as? String
        let attachment: MessageAttachment?
        if let attachmentUrl = attachmentUrl, !attachmentUrl.isEmpty {
            attachment = MessageAttachment(
                name: userInfo["attachment_name"] as? String ?? "",
                type: userInfo["attachment_type"] as? String,
                size: Int64(userInfo["attachment_size"] as? String ?? "0").flatMap { $0 == 0 ? nil : $0 },
                expires: Int64(userInfo["attachment_expires"] as? String ?? "0").flatMap { $0 == 0 ? nil : $0 },
                url: attachmentUrl
            )
        } else {
            attachment = nil
        }
        return Message(
            id: id,
            time: timeInt,
            event: event,
            topic: topic,
            message: message,
            title: title,
            priority: priority,
            tags: tags,
            actions: Actions.shared.parse(actions),
            click: click,
            pollId: pollId,
            attachment: attachment,
            contentType: contentType,
            icon: icon,
            sequenceID: userInfo["sequence_id"] as? String,
            encoding: userInfo["encoding"] as? String
        )
    }
}

struct Action: Encodable, Decodable, Identifiable {
    var id: String
    var action: String
    var label: String
    var url: String?
    var method: String?
    var headers: [String: String]?
    var body: String?
    var clear: Bool?
    // ntfy copy actions carry the text to copy under the "value" key.
    var value: String? = nil
}
