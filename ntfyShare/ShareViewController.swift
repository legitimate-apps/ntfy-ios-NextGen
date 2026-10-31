import SwiftUI
import UIKit

final class ShareViewController: UIViewController {
    private var model: ShareModel?
    override func viewDidLoad() {
        super.viewDidLoad()
        isModalInPresentation = true
        let model = ShareModel(store: Store.shared)
        self.model = model
        let host = UIHostingController(rootView: ShareView(model: model, finish: { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }))
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        model.load(providers)
    }
}

@MainActor
final class ShareModel: ObservableObject {
    let store: Store
    let compose = ComposeModel()
    let topics: [Subscription]
    @Published var selectedURL = ""
    @Published var loading = true
    @Published var inputError = ""
    private var closed = false
    private let defaults = UserDefaults(suiteName: Store.appGroup)!
    init(store: Store) {
        self.store = store
        topics = (store.getSubscriptions() ?? []).sorted { $0.urlString() < $1.urlString() }
        selectedURL = ShareTopicSelection.choose(topics, lastURL: defaults.string(forKey: ShareTopicSelection.preferenceKey))?.urlString() ?? ""
    }
    var selected: Subscription? { topics.first { $0.urlString() == selectedURL } }
    var encrypted: Bool { selected.map { store.topicKeyState(for: $0) != .notEncrypted } ?? false }
    var canSend: Bool {
        !loading && inputError.isEmpty && selected != nil && compose.canSend
            && (compose.fileURL == nil || (!encrypted && compose.attachmentLimit != nil))
    }
    func selectTopic() {
        compose.error = ""
        compose.attachmentLimit = nil
        guard let topic = selected, !encrypted else { return }
        compose.loadLimits(baseURL: topic.baseUrl ?? "", user: store.getBasicUser(baseUrl: topic.baseUrl ?? ""))
    }
    func load(_ providers: [NSItemProvider]) {
        selectTopic()
        Task {
            do {
                let content = try await ShareItemLoader.load(providers)
                if let file = content.fileURL { compose.acceptFile(file) }
                guard !closed else { return }
                compose.message = content.message
                loading = false
            } catch {
                guard !closed else { return }
                loading = false
                inputError = (error as? ShareItemLoader.Failure)?.userMessage ?? String(localized: "The shared item could not be opened. Share it again from the original app.")
            }
        }
    }
    func close() { closed = true; compose.close() }
    func send(finish: @escaping () -> Void) {
        guard canSend, let topic = selected else { return }
        compose.send(subscription: topic, store: store) {
            self.defaults.set(topic.urlString(), forKey: ShareTopicSelection.preferenceKey)
            self.close()
            finish()
        }
    }
}

private struct ShareView: View {
    @Environment(\.sizeCategory) private var sizeCategory
    @ObservedObject var model: ShareModel
    @ObservedObject private var compose: ComposeModel
    let finish: () -> Void
    @State private var discard = false
    init(model: ShareModel, finish: @escaping () -> Void) {
        self.model = model; self.compose = model.compose; self.finish = finish
    }
    var body: some View {
        NavigationView {
            Form {
                if model.topics.isEmpty {
                    Section { Text(String(localized: "Open NTFY me and subscribe to a topic first. Then share this item again.")) }
                } else {
                    Section {
                        Picker(String(localized: "Topic"), selection: $model.selectedURL) {
                            ForEach(model.topics, id: \.objectID) { topic in
                                VStack(alignment: .leading) {
                                    Text(topic.shortDisplayName())
                                    Text(topic.urlString()).font(.caption).foregroundColor(.secondary)
                                }.tag(topic.urlString())
                            }
                        }.accessibilityIdentifier("share-topic")
                        if let topic = model.selected {
                            if sizeCategory.isAccessibilityCategory {
                                Text(topic.shortDisplayName()).fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("share-selected-topic")
                            }
                            Text(topic.urlString()).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Section(header: Text(String(localized: "Message"))) {
                        TextEditor(text: $compose.message).frame(minHeight: 100)
                            .accessibilityLabel(String(localized: "Message")).accessibilityIdentifier("share-message")
                        TextField(String(localized: "Title (optional)"), text: $compose.title)
                            .accessibilityIdentifier("share-title")
                    }
                    if compose.fileURL != nil {
                        Section(header: Text(String(localized: "Attachment"))) {
                            Text(compose.fileName)
                            if model.encrypted {
                                Text(String(localized: "Attachments are unavailable for encrypted topics. Remove the attachment to send text or a link."))
                            } else if let limit = compose.attachmentLimit {
                                Text(String(localized: "Available upload size: \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))"))
                                    .font(.caption).foregroundColor(.secondary)
                            } else {
                                Text(String(localized: "Upload limits are unavailable. Try checking again before sending the attachment."))
                                Button(String(localized: "Check upload limits"), action: model.selectTopic).disabled(compose.loadingLimits)
                            }
                            Button(String(localized: "Remove attachment"), role: .destructive, action: compose.removeFile)
                        }
                    }
                }
                if model.loading { ProgressView(String(localized: "Loading shared item…")) }
                if !model.inputError.isEmpty { Text(model.inputError).foregroundColor(.red).accessibilityIdentifier("share-input-error") }
                if !compose.error.isEmpty { Text(compose.error).foregroundColor(.red).accessibilityIdentifier("share-error") }
                if compose.busy { ProgressView(String(localized: "Sending…")) }
            }
            .disabled(compose.busy)
            .navigationTitle(String(localized: "Share to NTFY me"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        if compose.dirty { discard = true } else { close() }
                    }.disabled(compose.busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Send")) { model.send(finish: finish) }
                        .disabled(!model.canSend).accessibilityIdentifier("share-send")
                }
            }
            .alert(String(localized: "Discard message?"), isPresented: $discard) {
                Button(String(localized: "Discard"), role: .destructive, action: close)
                Button(String(localized: "Keep editing"), role: .cancel) {}
            }
            .onChange(of: model.selectedURL) { _ in model.selectTopic() }
        }.navigationViewStyle(StackNavigationViewStyle())
    }
    private func close() { model.close(); finish() }
}
