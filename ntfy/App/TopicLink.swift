import Foundation

/// Matches ntfy v2.31.1 server.go topicRegex and config.go DefaultDisallowedTopics.
/// Hosts ignore case; topics (including reserved names) retain their case.
struct TopicLink: Equatable {
    static let baseURL = "https://ntfy-me.com"
    static let reservedNames: Set<String> = [
        "docs", "static", "file", "app", "metrics", "account", "settings", "signup", "login", "v1"
    ]
    let topic: String

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.host?.lowercased() == "ntfy-me.com",
              parts.port == nil || parts.port == 443, parts.user == nil, parts.password == nil else { return nil }
        var path = parts.path
        guard path.hasPrefix("/") else { return nil }
        path.removeFirst()
        if path.hasSuffix("/") { path.removeLast() }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_".utf8)
        guard (1...64).contains(path.utf8.count), path.utf8.allSatisfy({ allowed.contains($0) }),
              !Self.reservedNames.contains(path) else { return nil }
        topic = path
    }
}

/// Receipt chooses a screen only. Subscription creation still requires the Subscribe button.
enum TopicLinkRoute: Equatable {
    case add(TopicLink)
    case open(String)

    static func resolve(_ url: URL, subscriptionURLs: [String]) -> TopicLinkRoute? {
        guard let link = TopicLink(url: url) else { return nil }
        if let existing = subscriptionURLs.first(where: { URL(string: $0).flatMap(TopicLink.init(url:)) == link }) {
            return .open(existing)
        }
        return .add(link)
    }
}
