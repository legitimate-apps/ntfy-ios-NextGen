import Foundation

/// Matches ntfy v2.31.1 server.go topicRegex and config.go DefaultDisallowedTopics.
/// Hosts ignore case; topics (including reserved names) retain their case.
struct TopicLink: Equatable {
    static let baseURL = "https://ntfy-me.com"
    static let reservedNames: Set<String> = [
        "docs", "static", "file", "app", "metrics", "account", "settings", "signup", "login", "v1"
    ]
    /// The server the topic lives on: scheme, lowercased host, a non-default port and any path prefix.
    let server: String
    let topic: String

    /// Universal Links: only https://ntfy-me.com/<topic>, the one host whose association file names this app.
    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.host?.lowercased() == "ntfy-me.com",
              parts.port == nil || parts.port == 443, parts.user == nil, parts.password == nil else { return nil }
        self.init(scheme: "https", parts: parts, prefixAllowed: false)
    }

    /// Text decoded from a QR code, for any server: an http(s) topic URL, optionally behind a port or a
    /// path prefix, the `ntfy://host/topic[?secure=false]` deep link ntfy's Android app opens, or the
    /// same address without a scheme. Nothing is subscribed here; the Add sheet still asks.
    init?(scanned text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let parts = URLComponents(string: text), parts.user == nil, parts.password == nil,
              let scheme = parts.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            self.init(scheme: scheme, parts: parts, prefixAllowed: true)
        case "ntfy":
            let secure = parts.queryItems?.first { $0.name == "secure" }?.value?.lowercased() != "false"
            self.init(scheme: secure ? "https" : "http", parts: parts, prefixAllowed: false)
        default:
            return nil
        }
    }

    private init?(scheme: String, parts: URLComponents, prefixAllowed: Bool) {
        guard var host = parts.host?.lowercased(), !host.isEmpty, parts.percentEncodedPath.hasPrefix("/") else { return nil }
        if host.contains(":"), !host.hasPrefix("[") { host = "[" + host + "]" }
        var path = parts.percentEncodedPath
        path.removeFirst()
        if path.hasSuffix("/") { path.removeLast() }
        // Split before decoding, so an encoded slash (%2F) stays inside one segment and fails the topic rules.
        let encoded = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let segments = encoded.map { $0.removingPercentEncoding ?? "" }
        guard let topic = segments.last, prefixAllowed || segments.count == 1 else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_".utf8)
        // A reserved name anywhere in the path is a server page (https://ntfy.sh/docs/publish), not a topic.
        guard (1...64).contains(topic.utf8.count), topic.utf8.allSatisfy({ allowed.contains($0) }),
              !segments.contains(where: { $0.isEmpty || Self.reservedNames.contains($0) }) else { return nil }
        // Our own server supports HTTPS. A scanned legacy HTTP link must resolve to the
        // existing HTTPS subscription rather than creating a second, insecure address.
        let normalizedScheme = host == "ntfy-me.com" ? "https" : scheme
        var server = normalizedScheme + "://" + host
        if let port = parts.port, port != (normalizedScheme == "https" ? 443 : 80),
           !(host == "ntfy-me.com" && scheme == "http" && port == 80) { server += ":\(port)" }
        server += encoded.dropLast().map { "/" + $0 }.joined()
        self.server = server
        self.topic = topic
    }
}

/// Receipt chooses a screen only. Subscription creation still requires the Subscribe button.
enum TopicLinkRoute: Equatable {
    case add(TopicLink)
    case open(String)

    static func resolve(_ url: URL, subscriptionURLs: [String]) -> TopicLinkRoute? {
        TopicLink(url: url).map { resolve($0, subscriptionURLs: subscriptionURLs) }
    }

    /// A scanned code that isn't a topic address has no routing decision.
    static func resolve(scanned text: String, subscriptionURLs: [String]) -> TopicLinkRoute? {
        TopicLink(scanned: text).map { resolve($0, subscriptionURLs: subscriptionURLs) }
    }

    static func resolve(_ link: TopicLink, subscriptionURLs: [String]) -> TopicLinkRoute {
        if let existing = subscriptionURLs.first(where: { TopicLink(scanned: $0) == link }) {
            return .open(existing)
        }
        return .add(link)
    }
}
