import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

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

    var options: PublishOptions {
        PublishOptions(clickURL: clickURL.trimmingCharacters(in: .whitespacesAndNewlines),
            attachmentURL: attachmentURL.trimmingCharacters(in: .whitespacesAndNewlines),
            filename: fileName, delay: delay.trimmingCharacters(in: .whitespacesAndNewlines),
            markdown: markdown, fileURL: fileURL, attachmentLimit: attachmentLimit)
    }
    var canSend: Bool { !busy && (!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || options.hasAttachment) }
    var dirty: Bool { !message.isEmpty || !title.isEmpty || !tags.isEmpty || !clickURL.isEmpty || options.hasAttachment || !delay.isEmpty || markdown || priority != 3 }

    func loadLimits(baseURL: String, user: ServerCredential?) {
        guard !loadingLimits, let url = URL(string: normalizeBaseUrl(baseURL) + "/v1/account") else { return }
        loadingLimits = true
        let api = ApiService.shared
        let request = api.newRequest(url: url, baseUrl: baseURL, user: user)
        api.runOneShot(request, timeout: 10, baseUrl: baseURL) { data, response, networkError in
            DispatchQueue.main.async {
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
        let keyState = store.topicKeyState(for: subscription)
        guard keyState != .unavailable else {
            error = String(localized: "The encryption password is unavailable. Unlock your phone or set the topic password again. Nothing was sent.")
            return
        }
        let baseURL = subscription.baseUrl ?? ""
        let fingerprint = "\(message)|\(title)|\(tags)|\(priority)|\(clickURL)|\(attachmentURL)|\(delay)|\(markdown)|\(fileURL?.absoluteString ?? "")"
        if !lastAttempt.isEmpty && fingerprint != lastAttempt {
            ServerCooldown.shared.requestChanged(server: baseURL, kind: .publish)
        }
        lastAttempt = fingerprint
        busy = true
        error = ""
        ApiService.shared.publish(subscription: subscription, user: store.getBasicUser(baseUrl: baseURL),
            message: message, title: title, priority: priority,
            tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            options: options, encryptionKey: keyState.key,
            completionHandler: {
                DispatchQueue.main.async {
                    self.busy = false
                    self.removeFile()
                    SubscriptionManager(store: store).pollWithOutcome(subscription, manual: true) { _ in }
                    completion()
                }
            }, failureHandler: { failure in
                DispatchQueue.main.async {
                    self.busy = false
                    self.error = failure.userMessage
                    if failure == .http(429), ServerCooldown.shared.hasNonTimeRefusal(server: baseURL, kind: .publish) {
                        self.error = ApiService.PublishError.publishNeedsChange.userMessage
                    } else if failure == .http(429) {
                        let seconds = Int(ceil(max(1, ServerCooldown.shared.deadline(for: baseURL, kind: .publish).timeIntervalSinceNow)))
                        self.error += " " + String(localized: "Try again in \(seconds) seconds.")
                    }
                }
            })
    }
}

@MainActor
struct ComposeSheetView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.presentationMode) private var presentationMode
    @ObservedObject var subscription: Subscription
    @StateObject var model = ComposeModel()
    @State private var showFiles = false
    @State private var showPhotos = false
    @State private var confirmDiscard = false

    init(subscription: Subscription, model: ComposeModel? = nil) {
        self.subscription = subscription
        _model = StateObject(wrappedValue: model ?? ComposeModel())
    }

    private var encrypted: Bool { store.topicKeyState(for: subscription) != .notEncrypted }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text(subscription.shortDisplayName()).font(.headline)
                    Text(subscription.urlString()).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                }
                Section(header: Text(String(localized: "Message"))) {
                    TextEditor(text: $model.message)
                        .frame(minHeight: 120)
                        .accessibilityLabel(String(localized: "Message"))
                        .accessibilityIdentifier("compose-message")
                    TextField(String(localized: "Title (optional)"), text: $model.title)
                        .accessibilityIdentifier("compose-title")
                    Toggle(String(localized: "Markdown"), isOn: $model.markdown)
                }
                Section(header: Text(String(localized: "Options"))) {
                    TextField(String(localized: "Tags, separated by commas"), text: $model.tags)
                        .autocapitalization(.none).disableAutocorrection(true)
                    Picker(String(localized: "Priority"), selection: $model.priority) {
                        Text(String(localized: "Minimum")).tag(1)
                        Text(String(localized: "Low")).tag(2)
                        Text(String(localized: "Default")).tag(3)
                        Text(String(localized: "High")).tag(4)
                        Text(String(localized: "Maximum")).tag(5)
                    }
                    urlField(String(localized: "Click URL (optional)"), text: $model.clickURL).accessibilityIdentifier("compose-click")
                    TextField(String(localized: "Delay, for example 30m or 3h"), text: $model.delay)
                        .autocapitalization(.none).disableAutocorrection(true)
                    Text(String(localized: "Delayed messages appear when the server delivers them.")).font(.caption).foregroundColor(.secondary)
                }
                Section(header: Text(String(localized: "Attachment"))) {
                    if encrypted {
                        Text(String(localized: "Attachments are unavailable for encrypted topics. Your message, title, tags and click URL stay encrypted."))
                            .font(.callout).foregroundColor(.secondary)
                    } else {
                        if model.fileURL != nil {
                            Text(model.fileName).lineLimit(nil)
                            Button(String(localized: "Remove attachment"), role: .destructive) { model.removeFile() }
                        } else {
                            urlField(String(localized: "Attachment URL (optional)"), text: $model.attachmentURL)
                        }
                        if let limit = model.attachmentLimit {
                            Text(String(localized: "Available upload size: \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))"))
                                .font(.caption).foregroundColor(.secondary)
                            Button(String(localized: "Choose photo")) { showPhotos = true }
                                .disabled(limit <= 0 || !model.attachmentURL.isEmpty)
                                .accessibilityIdentifier("compose-photo")
                            Button(String(localized: "Choose file")) { showFiles = true }
                                .disabled(limit <= 0 || !model.attachmentURL.isEmpty)
                        } else {
                            Text(String(localized: "Upload limits are unavailable. You can still attach a URL."))
                                .font(.caption).foregroundColor(.secondary)
                            Button(String(localized: "Check upload limits")) { loadLimits() }.disabled(model.loadingLimits)
                        }
                    }
                }
                if !model.error.isEmpty {
                    Section {
                        Label(model.error, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.red).accessibilityIdentifier("compose-error")
                    }
                }
                if model.busy {
                    Section { ProgressView(String(localized: "Sending…")) }
                }
            }
            .disabled(model.busy)
            .navigationTitle(String(localized: "New message"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        if model.dirty { confirmDiscard = true } else { close() }
                    }.disabled(model.busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Send")) {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        model.send(subscription: subscription, store: store, completion: close)
                    }
                        .disabled(!model.canSend).accessibilityIdentifier("compose-send")
                }
            }
            .alert(String(localized: "Discard message?"), isPresented: $confirmDiscard) {
                Button(String(localized: "Discard"), role: .destructive, action: close)
                Button(String(localized: "Keep editing"), role: .cancel) {}
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .interactiveDismissDisabled(model.busy || model.dirty)
        .onAppear(perform: loadLimits)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item]) { model.selectFile($0) }
        .sheet(isPresented: $showPhotos) {
            ComposePhotoPicker(limit: model.attachmentLimit ?? 0, cancel: { showPhotos = false }) { result in
                showPhotos = false
                switch result {
                case .success(let url): model.acceptFile(url)
                case .failure(let failure): model.error = failure.userMessage
                }
            }
        }
    }

    private func urlField(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text).keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
            .accessibilityLabel(label)
    }
    private func loadLimits() {
        guard !encrypted else { return }
        let baseURL = subscription.baseUrl ?? ""
        model.loadLimits(baseURL: baseURL, user: store.getBasicUser(baseUrl: baseURL))
    }
    private func close() {
        model.close()
        presentationMode.wrappedValue.dismiss()
    }
}

/// The system photo picker grants just the selected item; no library entitlement is needed.
private struct ComposePhotoPicker: UIViewControllerRepresentable {
    let limit: Int64
    let cancel: () -> Void
    let completion: (Result<URL, ApiService.PublishError>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ComposePhotoPicker
        init(_ parent: ComposePhotoPicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else { parent.cancel(); return }
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                let result: Result<URL, ApiService.PublishError>
                if let url {
                    do { result = .success(try ComposeModel.stage(url, limit: self.parent.limit)) }
                    catch { result = .failure((error as? ApiService.PublishError) ?? .attachmentUnreadable) }
                } else { result = .failure(.attachmentUnreadable) }
                DispatchQueue.main.async { self.parent.completion(result) }
            }
        }
    }
}
