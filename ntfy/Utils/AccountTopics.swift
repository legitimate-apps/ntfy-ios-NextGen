import Foundation
import SwiftUI

/// GET /v1/account: server/types.go and user/types.go in the ntfy server.
/// Accounts may save subscriptions on other servers; importing here stays on the selected server.
struct AccountTopic: Decodable, Identifiable, Equatable {
    let baseURL: String
    let topic: String
    let displayName: String?
    var id: String { topicUrl(baseUrl: baseURL, topic: topic) }
    var title: String {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? topic : name
    }

    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url", topic, displayName = "display_name"
    }
}

private struct AccountTopicsResponse: Decodable {
    let username: String
    let role: String?
    let subscriptions: [AccountTopic?]?
}

extension ApiService {
    /// Optional discovery: old servers, anonymous responses and network failures all yield no offer.
    /// Use the normal request/redirect path, including custom headers and password/token auth.
    func accountTopics(baseURL: String, user: ServerCredential?, session: URLSession? = nil,
                       completion: @escaping ([AccountTopic]) -> Void) {
        guard let user, let url = URL(string: normalizeBaseUrl(baseURL) + "/v1/account") else {
            completion([])
            return
        }
        runOneShot(newRequest(url: url, baseUrl: baseURL, user: user), timeout: 10, baseUrl: baseURL, session: session) { data, response, error in
            guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let account = try? JSONDecoder().decode(AccountTopicsResponse.self, from: data),
                  !account.username.isEmpty, account.username != "*", account.role != "anonymous" else {
                completion([])
                return
            }
            var seen = Set<String>()
            completion((account.subscriptions ?? []).compactMap { $0 }.filter {
                normalizeBaseUrl($0.baseURL) == normalizeBaseUrl(baseURL)
                    && isValidTopicName($0.topic) && seen.insert($0.id).inserted
            })
        }
    }
}

@MainActor
final class AccountTopicsModel: ObservableObject {
    @Published private(set) var topics: [AccountTopic] = []
    @Published var selected = Set<String>()
    @Published private(set) var loading = false
    @Published private(set) var busy = false
    @Published private(set) var failed = false
    @Published private(set) var importedURLs: [String] = []
    var importedURL: String? { importedURLs.first }
    let baseURL: String
    private let store: Store
    private let loadTopics: () async -> [AccountTopic]
    private let authorize: (String) async -> Bool
    private let subscribe: (AccountTopic) -> Void

    init(baseURL: String, user: ServerCredential, store: Store,
         loadTopics: (() async -> [AccountTopic])? = nil,
         authorize: ((String) async -> Bool)? = nil,
         subscribe: ((AccountTopic) -> Void)? = nil) {
        self.baseURL = normalizeBaseUrl(baseURL)
        self.store = store
        self.loadTopics = loadTopics ?? {
            await withCheckedContinuation { continuation in
                ApiService.shared.accountTopics(baseURL: baseURL, user: user) { continuation.resume(returning: $0) }
            }
        }
        self.authorize = authorize ?? { topic in
            await withCheckedContinuation { continuation in
                ApiService.shared.checkAuth(baseUrl: baseURL, topic: topic, user: user) { result in
                    if case .Success = result { continuation.resume(returning: true) }
                    else { continuation.resume(returning: false) }
                }
            }
        }
        self.subscribe = subscribe ?? { item in
            SubscriptionManager(store: store).subscribe(baseUrl: baseURL, topic: item.topic)
        }
    }

    func load() async {
        guard !loading, !busy else { return }
        loading = true
        failed = false
        let fetched = await loadTopics()
        defer { loading = false }
        guard !Task.isCancelled else { return }
        // Defend again at the import boundary, even for injected loaders.
        var seen = Set<String>()
        topics = fetched.filter {
            normalizeBaseUrl($0.baseURL) == baseURL && isValidTopicName($0.topic)
                && store.getSubscription(baseUrl: baseURL, topic: $0.topic) == nil
                && seen.insert($0.id).inserted
        }
        selected.formIntersection(Set(topics.map(\.id)))
    }

    /// Only selected, still-missing topics reach the existing subscribe path. Check again after
    /// auth, since another sheet or managed configuration may subscribe while the request runs.
    /// Failures remain selected for retry; successful imports are removed and never renamed twice.
    func importSelected() async -> String? {
        guard !loading, !busy else { return nil }
        busy = true
        failed = false
        defer { busy = false }
        for item in topics where selected.contains(item.id) {
            guard !Task.isCancelled else { break }
            if store.getSubscription(baseUrl: baseURL, topic: item.topic) != nil {
                selected.remove(item.id)
                continue
            }
            guard await authorize(item.topic), !Task.isCancelled else { failed = true; continue }
            guard store.getSubscription(baseUrl: baseURL, topic: item.topic) == nil else {
                selected.remove(item.id)
                continue
            }
            subscribe(item)
            guard let subscription = store.getSubscription(baseUrl: baseURL, topic: item.topic) else {
                failed = true
                continue
            }
            store.updateSubscription(subscription: subscription, displayName: item.displayName)
            selected.remove(item.id)
            importedURLs.append(item.id)
        }
        topics.removeAll { store.getSubscription(baseUrl: baseURL, topic: $0.topic) != nil }
        return failed || Task.isCancelled ? nil : importedURL
    }
}

struct AccountTopicsView: View {
    @StateObject private var model: AccountTopicsModel
    @State private var importTask: Task<Void, Never>?
    @State private var finished = false
    let onImported: ([String]) -> Void

    init(baseURL: String, user: ServerCredential, store: Store, onImported: @escaping ([String]) -> Void) {
        _model = StateObject(wrappedValue: AccountTopicsModel(baseURL: baseURL, user: user, store: store))
        self.onImported = onImported
    }

    init(model: AccountTopicsModel, onImported: @escaping ([String]) -> Void) {
        _model = StateObject(wrappedValue: model)
        self.onImported = onImported
    }

    var body: some View {
        Form {
            Section(footer: Text(footerText)) {
                Text(shortUrl(url: model.baseURL)).font(.subheadline).foregroundColor(.secondary)
                if model.loading && model.topics.isEmpty {
                    ProgressView().accessibilityLabel(String(localized: "In progress"))
                } else if model.topics.isEmpty {
                    Text(String(localized: "No new saved topics are available for this server account."))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(model.topics) { item in
                        Toggle(isOn: Binding(get: { model.selected.contains(item.id) }, set: { selected in
                            if selected { model.selected.insert(item.id) } else { model.selected.remove(item.id) }
                        })) {
                            VStack(alignment: .leading) {
                                Text(item.title)
                                if !(item.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(item.topic).font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .disabled(model.busy || model.loading)
            if model.failed {
                Text(String(localized: "Some topics couldn't be added. Check your server login and connection, then try again. Topics already added are kept."))
                    .foregroundColor(.secondary)
            }
            Button(String(localized: "Refresh")) { Task { await model.load() } }
                .disabled(model.loading || model.busy)
        }
        .navigationTitle(String(localized: "Topics saved in account"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    importTask = Task { if await model.importSelected() != nil { finish() } }
                } label: {
                    if model.busy { ProgressView() } else { Text(String(localized: "Subscribe")) }
                }
                .accessibilityLabel(String(localized: "Subscribe"))
                .disabled(model.loading || model.busy || model.selected.isEmpty)
            }
        }
        .task { await model.load() }
        // Leaving the picker stops the batch after the current auth request. Already added
        // topics remain subscribed, and no new topic is added after cancellation.
        .onDisappear {
            importTask?.cancel()
            // Back after a partial import still offers notification permission for topics added.
            if !model.importedURLs.isEmpty { finish() }
        }
    }

    private var footerText: String {
        if model.topics.isEmpty && !model.loading {
            return String(localized: "Topics saved in this account in the ntfy web app appear here. Topics already subscribed and topics on other servers are not listed.")
        }
        return String(localized: "Choose topics to subscribe to on this device. Topics already subscribed and topics on other servers are not listed.")
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onImported(model.importedURLs)
    }
}
