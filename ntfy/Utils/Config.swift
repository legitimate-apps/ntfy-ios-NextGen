import Foundation

enum Config {
    static var appBaseUrl: String {
        string(for: "AppBaseURL")
    }
    
    /// Who runs the built-in server, for copy that names it. Shipped builds pin `AppBaseURL` to
    /// ntfy-me.com (scripts/verify-app-base-url.sh gates the archive), which this app's publisher runs.
    static var appServerDescription: String {
        "\(shortUrl(url: normalizeBaseUrl(appBaseUrl))), a free public server run by the "
            + "publisher of this app (not affiliated with ntfy.sh or the ntfy project)"
    }

    // MARK: - Build identity
    //
    // Set in Configuration/*.xcconfig and carried in both the app's and the extension's Info.plist,
    // so the source names no signing identity. Keychain items and the shared container are keyed by
    // these, so a shipped build must keep the values it shipped with.

    /// The app's bundle id; the prefix of every Keychain service name.
    static var bundleIdBase: String {
        string(for: "AppBundleIdBase")
    }

    /// App Group shared by the app and the notification extension.
    static var appGroupId: String {
        string(for: "AppGroupId")
    }

    /// Keychain access group shared by the app and the extension, without the team prefix.
    static var keychainGroup: String {
        string(for: "AppKeychainGroup")
    }

    /// The `upstream-base-url` line a self-hosted server needs so its messages reach this app instantly.
    static var upstreamConfigLine: String {
        "upstream-base-url: \(normalizeBaseUrl(appBaseUrl))"
    }

    /// ntfy.sh pushes to the official app's Firebase project, not this app's.
    static func ntfyShDeliveryHint(baseUrl: String) -> String? {
        guard URL(string: normalizeBaseUrl(baseUrl))?.host?.lowercased() == "ntfy.sh" else { return nil }
        return "Topics on ntfy.sh have no instant banners in this app. Messages appear when you open "
            + "the app or refresh. For banners, move your topic to \(shortUrl(url: normalizeBaseUrl(appBaseUrl))). "
            + "See \(migrateUrl)."
    }

    static func subscriptionServerFooter(baseUrl: String, useAnother: Bool) -> String {
        if let hint = ntfyShDeliveryHint(baseUrl: baseUrl) { return hint }
        if useAnother {
            return selfHostedDeliveryHint
        }
        if baseUrl == normalizeBaseUrl(appBaseUrl) {
            return "New topics use \(appServerDescription). Any ntfy server works: turn on "
                + "\"Use another server\" or change the default in Settings. "
                + "Your scripts must send to \(shortUrl(url: normalizeBaseUrl(appBaseUrl))); the same topic name on ntfy.sh is a different topic."
        }
        return "New topics use your default server, \(shortUrl(url: baseUrl))."
    }

    static func defaultServerFooter(baseUrl: String) -> String {
        let deliveryHint = ntfyShDeliveryHint(baseUrl: baseUrl)
            ?? selfHostedDeliveryHint
        return "When subscribing to new topics, this server will be used as a default. Leave it empty "
            + "to use \(appServerDescription). \(deliveryHint)"
    }

    static var selfHostedDeliveryHint: String {
        "For instant delivery from your own server, add \"\(upstreamConfigLine)\" to its config. "
            + "Without it, messages may arrive with significant delay. A server has one upstream; using "
            + "\(shortUrl(url: normalizeBaseUrl(appBaseUrl))) stops instant delivery to the official ntfy iOS app on that server. "
            + "See \(selfHostingUrl)."
    }

    static var build: String {
        string(for: "CFBundleVersion")
    }
    
    static var version: String {
        string(for: "CFBundleShortVersionString")
    }
    
    static var osVersion: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return String(os.majorVersion) + "." + String(os.minorVersion) + "." + String(os.patchVersion)
    }
    
    // MARK: - Outward links
    //
    // Single source of truth for every link the app opens. These used to be
    // string literals inline in AboutView, which is how a shipped build ended
    // up sending "Rate the app" to UPSTREAM's App Store listing and "Report a
    // bug" to upstream's issue tracker. Keeping them here means a fork-wide
    // rename touches one file, and a wrong id is visible next to the right one.

    /// This app's App Store id, from `APP_STORE_ID`; nil in a build that sets none.
    ///
    /// Upstream ntfy is `1625396347`. That is a DIFFERENT app on a different
    /// team — never point our review or listing links at it.
    static var appStoreId: String? {
        let id = (Bundle.main.infoDictionary?["AppStoreId"] as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return id.isEmpty ? nil : id
    }

    /// Deep link to the App Store review composer; nil without an App Store id.
    ///
    /// `?action=write-review` opens the review sheet directly. Without it the
    /// user lands on the listing and has to find "Write a Review" themselves,
    /// which is most of the reason a "Rate the app" button gets abandoned.
    static var reviewUrl: String? {
        appStoreId.map { "https://apps.apple.com/app/id\($0)?action=write-review" }
    }

    /// Moving a topic from the official app or keeping it on ntfy.sh.
    static let migrateUrl = "https://ntfy-me.com/docs/migrate"

    static let selfHostingUrl = "https://ntfy-me.com/docs/self-hosting"

    /// Where OUR users report OUR bugs. Reports about this fork must not land
    /// on upstream's tracker; they are a different project with a different
    /// maintainer who did not ship this code.
    ///
    /// Shipped builds before 1.16 link the support page on GitHub Pages, which
    /// now forwards here.
    static let supportUrl = "https://ntfy-me.com/docs/support"

    /// The quick start for this app's default server. It is the primary help link: its examples
    /// publish to ntfy-me.com, where new topics live. ntfy.sh's own pages publish to ntfy.sh, so a
    /// newcomer who followed them sent their first message to a server the app was not listening to.
    static let helpUrl = "https://ntfy-me.com/"

    /// ntfy's own documentation — genuinely upstream's, and correct to link as the full reference
    /// for the protocol. Not the first place to send a newcomer; see `helpUrl`.
    static let docsUrl = "https://ntfy.sh/docs"

    static private func string(for key: String) -> String {
        Bundle.main.infoDictionary?[key] as! String
    }
}
