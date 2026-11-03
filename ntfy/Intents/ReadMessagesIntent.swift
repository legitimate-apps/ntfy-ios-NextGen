import AppIntents
import CoreData

@available(iOS 16.0, *)
struct StoredMessage: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Message"
    static var defaultQuery = StoredMessageQuery()
    let id: String
    @Property(title: "Message") var message: String
    @Property(title: "Title") var title: String
    @Property(title: "Priority") var priority: Int
    @Property(title: "Tags") var tags: [String]
    @Property(title: "Click URL") var clickURL: URL?
    @Property(title: "Time") var time: Date
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title.isEmpty ? message : title)") }

    init(notification: Notification) {
        id = notification.objectID.uriRepresentation().absoluteString
        message = notification.encryptionState == .locked ? String(localized: "Encrypted message")
            : Message.localizedBody(notification.message, contentType: notification.contentType)
        title = notification.title ?? ""
        priority = Int(notification.priority)
        tags = parseAllTags(notification.tags)
        clickURL = notification.click.flatMap(URL.init(string:))
        time = Date(timeIntervalSince1970: TimeInterval(notification.time))
    }
}

@available(iOS 16.0, *)
struct StoredMessageQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [StoredMessage] {
        try await Self.resolve(identifiers, store: .shared)
    }
    @MainActor
    static func resolve(_ identifiers: [String], store: Store) throws -> [StoredMessage] {
        let context = SubscribedTopicQuery.readContext(store: store)
        let ids = identifiers.compactMap { URL(string: $0) }.filter {
            $0.scheme == "x-coredata" && $0.host != nil && $0.pathComponents.count == 3
                && $0.pathComponents[1] == "Notification"
                && $0.lastPathComponent.range(of: "^p[0-9]+$", options: .regularExpression) != nil
        }.compactMap {
            context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: $0)
        }
        let request = Notification.fetchRequest()
        request.predicate = NSPredicate(format: "SELF IN %@ AND subscription != nil", ids)
        let rows = try context.fetch(request).map(StoredMessage.init)
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byID[$0] }
    }
}

@available(iOS 16.0, *)
struct ReadMessagesIntent: AppIntent {
    static var title: LocalizedStringResource = "Read messages"
    static var description = IntentDescription("Read locally stored messages, newest first. No messages are downloaded or marked as read. Choose Message to parse a JSON body in Shortcuts.")
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }
    @Parameter(title: "Topic", description: "A topic you subscribe to in NTFY me.") var topic: SubscribedTopic
    @Parameter(title: "Limit", default: 1, inclusiveRange: (1, 100)) var limit: Int
    @Parameter(title: "Since", description: "Only messages newer than this date.") var since: Date?
    static var parameterSummary: some ParameterSummary {
        Summary("Read messages from \(\.$topic)") { \.$limit; \.$since }
    }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[StoredMessage]> {
        .result(value: try read(store: .shared))
    }
    @MainActor
    func read(store: Store) throws -> [StoredMessage] {
        guard (1...100).contains(limit) else {
            throw TopicPublisher.Failure(message: String(localized: "Choose a message limit from 1 to 100."))
        }
        let context = SubscribedTopicQuery.readContext(store: store)
        guard let subscription = try context.fetch(Subscription.fetchRequest()).first(where: {
            $0.objectID.uriRepresentation().absoluteString == topic.id
        }) else {
            throw TopicPublisher.Failure(message: String(localized: "This topic is no longer subscribed. Choose another topic or subscribe again in NTFY me."))
        }
        let request = Notification.fetchRequest()
        var predicates = [NSPredicate(format: "subscription == %@", subscription)]
        if let since { predicates.append(NSPredicate(format: "time > %@", NSNumber(value: since.timeIntervalSince1970))) }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [NSSortDescriptor(key: "time", ascending: false), NSSortDescriptor(key: "id", ascending: false)]
        request.fetchLimit = limit
        return try context.fetch(request).map(StoredMessage.init)
    }
}
