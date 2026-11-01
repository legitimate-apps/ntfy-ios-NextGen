import Foundation
import Combine

/// The topic remains fixed while composing. No new subscription or credential is created.
@MainActor
final class ComposeModel: ObservableObject {
    @Published var message = ""
    @Published var title = ""
    @Published var tags = ""
    @Published var priority = 3
    @Published var clickURL = ""
    @Published var attachmentURL = ""
    @Published var delay = ""
    @Published var markdown = false
    @Published var fileURL: URL?
    @Published var fileName = ""
    @Published var attachmentLimit: Int64?
    @Published var loadingLimits = false
    @Published var busy = false
    @Published var error = ""
    private var lastAttempt = ""
    private var closed = false
    private var limitGeneration = UUID()

    var options: PublishOptions {
        PublishOptions(clickURL: clickURL.trimmingCharacters(in: .whitespacesAndNewlines),
            attachmentURL: attachmentURL.trimmingCharacters(in: .whitespacesAndNewlines),
            filename: fileName, delay: delay.trimmingCharacters(in: .whitespacesAndNewlines),
            markdown: markdown, fileURL: fileURL, attachmentLimit: attachmentLimit)
    }
    var canSend: Bool { !busy && (!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || options.hasAttachment) }
    var dirty: Bool { !message.isEmpty || !title.isEmpty || !tags.isEmpty || !clickURL.isEmpty || options.hasAttachment || !delay.isEmpty || markdown || priority != 3 }

    func loadLimits(baseURL: String, user: ServerCredential?) {
        guard let url = URL(string: normalizeBaseUrl(baseURL) + "/v1/account") else { return }
        let generation = UUID()
        limitGeneration = generation
        attachmentLimit = nil
        loadingLimits = true
        let api = ApiService.shared
        let request = api.newRequest(url: url, baseUrl: baseURL, user: user)
        api.runOneShot(request, timeout: 10, baseUrl: baseURL) { data, response, networkError in
            DispatchQueue.main.async {
                guard self.limitGeneration == generation, !self.closed else { return }
                self.loadingLimits = false
                guard networkError == nil, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let data, let limit = PublishOptions.attachmentLimit(from: data) else {
                    self.attachmentLimit = nil
                    return
                }
                self.attachmentLimit = limit
            }
        }
    }

    /// Copy provider-owned files before their security scope or load callback expires.
    nonisolated static func stage(_ source: URL, limit: Int64) throws -> URL {
        let size = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, let count = size.fileSize, count > 0, Int64(count) <= limit else {
            throw ApiService.PublishError.attachmentTooLarge
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("compose-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        do { try FileManager.default.copyItem(at: source, to: destination) }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
        return destination
    }

    func selectFile(_ result: Result<URL, Error>) {
        switch result {
        case .failure: error = String(localized: "The file could not be opened. Choose it again.")
        case .success(let source):
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            guard let limit = attachmentLimit else { return }
            do { acceptFile(try Self.stage(source, limit: limit)) }
            catch { self.error = (error as? ApiService.PublishError)?.userMessage ?? String(localized: "The file could not be opened. Choose it again.") }
        }
    }

    func acceptFile(_ url: URL) {
        guard !closed else {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            return
        }
        removeFile()
        fileURL = url
        fileName = url.lastPathComponent
        attachmentURL = ""
        error = ""
    }
    func close() {
        closed = true
        removeFile()
    }
    func removeFile() {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        fileURL = nil
        fileName = ""
    }

    func send(subscription: Subscription, store: Store, completion: @escaping () -> Void) {
        guard canSend else { return }
        let baseURL = subscription.baseUrl ?? ""
        let fingerprint = "\(subscription.urlString())|\(message)|\(title)|\(tags)|\(priority)|\(clickURL)|\(attachmentURL)|\(delay)|\(markdown)|\(fileURL?.absoluteString ?? "")"
        if !lastAttempt.isEmpty && fingerprint != lastAttempt {
            ServerCooldown.shared.requestChanged(server: baseURL, kind: .publish)
        }
        lastAttempt = fingerprint
        busy = true
        error = ""
        TopicPublisher.send(subscription: subscription, store: store, message: message, title: title,
            priority: priority, tags: tags, options: options) { result in
                self.busy = false
                switch result {
                case .success:
                    self.removeFile()
                    completion()
                case .failure(let failure):
                    self.error = failure.message
                }
            }
    }
}
