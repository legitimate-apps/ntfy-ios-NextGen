import AppIntents
import CoreData

@available(iOS 16.0, *)
struct SubscribedTopic: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Topic"
    static var defaultQuery = SubscribedTopicQuery()

    let id: String
    let name: String
    let server: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: server.map { "\($0)" })
    }

    init(subscription: Subscription) {
        id = subscription.objectID.uriRepresentation().absoluteString
        name = subscription.shortDisplayName()
        server = normalizeBaseUrl(subscription.baseUrl ?? "") == normalizeBaseUrl(Config.appBaseUrl)
            ? nil : subscription.serverHost()
    }
}

/// This target runs in the app process. A fresh read context avoids stale picker rows.
@available(iOS 16.0, *)
struct SubscribedTopicQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SubscribedTopic] {
        try await Self.topics(identifiers: identifiers)
    }
    func suggestedEntities() async throws -> [SubscribedTopic] {
        try await Self.topics()
    }
    func entities(matching string: String) async throws -> [SubscribedTopic] {
        try await Self.topics().filter {
            $0.name.localizedCaseInsensitiveContains(string) || ($0.server?.localizedCaseInsensitiveContains(string) ?? false)
        }
    }

    @MainActor
    static func readContext(store: Store) -> NSManagedObjectContext {
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = store.container.persistentStoreCoordinator
        context.stalenessInterval = 0
        context.undoManager = nil
        return context
    }

    @MainActor
    static func topics(identifiers: [String]? = nil, store: Store = .shared) throws -> [SubscribedTopic] {
        let context = readContext(store: store)
        let topics: [SubscribedTopic]
        do {
            topics = try context.fetch(Subscription.fetchRequest()).map(SubscribedTopic.init)
        } catch {
            throw TopicPublisher.Failure(message: String(localized: "Topics could not be read. Unlock your phone and open NTFY me, then try again."))
        }
        if let identifiers {
            let byID = Dictionary(topics.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return identifiers.compactMap { byID[$0] }
        }
        return topics.sorted { ($0.name, $0.server ?? "", $0.id) < ($1.name, $1.server ?? "", $1.id) }
    }
}

@available(iOS 16.0, *)
struct SendMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Send message"
    static var description = IntentDescription("Send a message to a subscribed topic using its saved sign-in and encryption settings.")
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Topic", description: "A topic you subscribe to in NTFY me.")
    var topic: SubscribedTopic
    @Parameter(title: "Message", description: "The text to send.")
    var message: String
    @Parameter(title: "Title")
    var messageTitle: String?
    @Parameter(title: "Priority", inclusiveRange: (1, 5))
    var priority: Int?
    @Parameter(title: "Tags", description: "Comma-separated tags or emoji names.")
    var tags: String?
    @Parameter(title: "Click URL")
    var clickURL: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$message) to \(\.$topic)") {
            \.$messageTitle
            \.$priority
            \.$tags
            \.$clickURL
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await send(store: .shared)
        return .result(dialog: "Message sent.")
    }

    /// The same entry point is exercised against real loopback HTTP in tests.
    @MainActor
    func send(store: Store, api: ApiService = .shared, cooldown: ServerCooldown = .shared) async throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TopicPublisher.Failure(message: String(localized: "Enter a message to send. Nothing was sent."))
        }
        guard (1...5).contains(priority ?? 3) else {
            throw TopicPublisher.Failure(message: String(localized: "Choose a priority from 1 to 5. Nothing was sent."))
        }
        let context = SubscribedTopicQuery.readContext(store: store)
        let subscription: Subscription
        do {
            guard let found = try context.fetch(Subscription.fetchRequest()).first(where: {
                $0.objectID.uriRepresentation().absoluteString == topic.id
            }) else {
                throw TopicPublisher.Failure(message: String(localized: "This topic is no longer subscribed. Choose another topic or subscribe again in NTFY me. Nothing was sent."))
            }
            subscription = found
        } catch let failure as TopicPublisher.Failure {
            throw failure
        } catch {
            throw TopicPublisher.Failure(message: String(localized: "Topics could not be read. Unlock your phone and open NTFY me, then try again."))
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            TopicPublisher.send(subscription: subscription, store: store, message: message,
                title: messageTitle ?? "", priority: priority ?? 3, tags: tags ?? "",
                options: PublishOptions(clickURL: (clickURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)),
                api: api, cooldown: cooldown) { continuation.resume(with: $0.mapError { $0 as Error }) }
        }
    }
}

@available(iOS 16.0, *)
struct MessageAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SendMessageIntent(), phrases: ["Send a message with \(.applicationName)"],
                    shortTitle: "Send message", systemImageName: "paperplane")
    }
}
