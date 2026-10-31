import Foundation
import UniformTypeIdentifiers

/// Loads each representation once. File representations are copied while the provider URL is valid,
/// without decoding images or materializing attachment data in the extension process.
enum ShareItemLoader {
    struct Content {
        var message = ""
        var fileURL: URL?
    }
    enum Failure: Error {
        case unsupported, multipleAttachments, unreadable
        var userMessage: String {
            switch self {
            case .unsupported: return String(localized: "Share a link, text, one photo or one file.")
            case .multipleAttachments: return String(localized: "Share only one photo or file at a time.")
            case .unreadable: return String(localized: "The shared item could not be opened. Share it again from the original app.")
            }
        }
    }

    static func load(_ providers: [NSItemProvider]) async throws -> Content {
        guard !providers.isEmpty else { throw Failure.unsupported }
        var content = Content()
        do {
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    guard content.fileURL == nil else { throw Failure.multipleAttachments }
                    let url = try await url(provider, type: UTType.fileURL.identifier)
                    guard url.isFileURL else { throw Failure.unreadable }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    content.fileURL = try ComposeModel.stage(url, limit: Int64.max)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    let url = try await url(provider, type: UTType.url.identifier)
                    guard PublishOptions.webURL(url.absoluteString) else { throw Failure.unsupported }
                    append(url.absoluteString, to: &content.message)
                } else if let type = provider.registeredTypeIdentifiers.first(where: {
                    UTType($0)?.conforms(to: .image) == true
                }) {
                    guard content.fileURL == nil else { throw Failure.multipleAttachments }
                    content.fileURL = try await file(provider, type: type)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    let value = try await item(provider, type: UTType.plainText.identifier)
                    let text = (value as? String) ?? (value as? NSAttributedString)?.string
                        ?? (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
                    guard let text else { throw Failure.unreadable }
                    append(text, to: &content.message)
                } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true }) {
                    guard content.fileURL == nil else { throw Failure.multipleAttachments }
                    content.fileURL = try await file(provider, type: type)
                } else { throw Failure.unsupported }
            }
            return content
        } catch {
            if let file = content.fileURL { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            throw error
        }
    }
    private static func append(_ text: String, to message: inout String) {
        if !message.isEmpty { message += "\n" }
        message += text
    }
    private static func url(_ provider: NSItemProvider, type: String) async throws -> URL {
        if provider.canLoadObject(ofClass: NSURL.self) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadObject(ofClass: NSURL.self) { value, error in
                    if let url = value as? URL { continuation.resume(returning: url) }
                    else { continuation.resume(throwing: error ?? Failure.unreadable) }
                }
            }
        }
        let value = try await item(provider, type: type)
        if let url = value as? URL { return url }
        if let text = value as? String, let url = URL(string: text) { return url }
        if let data = value as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { return url }
        throw Failure.unreadable
    }
    private static func item(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
                if let value { continuation.resume(returning: value) }
                else { continuation.resume(throwing: error ?? Failure.unreadable) }
            }
        }
    }
    private static func file(_ provider: NSItemProvider, type: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url else { continuation.resume(throwing: error ?? Failure.unreadable); return }
                do { continuation.resume(returning: try ComposeModel.stage(url, limit: Int64.max)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Stable across Core Data reloads and unambiguous for the same topic on different servers.
enum ShareTopicSelection {
    static let preferenceKey = "lastShareTopic121"
    static func choose(_ topics: [Subscription], lastURL: String?) -> Subscription? {
        topics.first { $0.urlString() == lastURL } ?? topics.sorted {
            let left = $0.shortDisplayName(), right = $1.shortDisplayName()
            return left == right ? $0.urlString() < $1.urlString() : left.localizedStandardCompare(right) == .orderedAscending
        }.first
    }
}
