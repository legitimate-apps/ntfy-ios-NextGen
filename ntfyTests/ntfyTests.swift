import XCTest
import UserNotifications
import CoreData
import UIKit
import Security
@testable import ntfy

private final class InMemoryCredentialStore: CredentialStoring {
    private var passwords: [String: String] = [:]
    private var headers: [String: [String: String]] = [:]
    private var deleteRequests: [String] = []
    private var headerReadsFail = false
    private var passwordReadsFail = false
    private let lock = NSLock()

    @discardableResult
    func setPassword(_ password: String?, baseUrl: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let password, !password.isEmpty else {
            passwords.removeValue(forKey: baseUrl)
            return true
        }
        passwords[baseUrl] = password
        return true
    }

    func password(baseUrl: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return passwords[baseUrl]
    }

    func readPassword(baseUrl: String) -> TopicSecretRead<String> {
        lock.lock()
        defer { lock.unlock() }
        if passwordReadsFail { return .failed(errSecInteractionNotAllowed) }
        return passwords[baseUrl].map { .found($0) } ?? .notFound
    }

    func setPasswordReadsFail(_ fail: Bool) {
        lock.lock()
        defer { lock.unlock() }
        passwordReadsFail = fail
    }

    @discardableResult
    func deletePassword(baseUrl: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        deleteRequests.append(baseUrl)
        passwords.removeValue(forKey: baseUrl)
        return true
    }

    @discardableResult
    func setHTTPHeaders(_ newHeaders: [String: String], baseUrl: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        headers[normalizeBaseUrl(baseUrl)] = newHeaders
        return true
    }

    func readHTTPHeaders(baseUrl: String) -> HTTPHeadersReadResult {
        lock.lock()
        defer { lock.unlock() }
        if headerReadsFail { return .failure }
        return .success(headers[normalizeBaseUrl(baseUrl)] ?? [:])
    }

    @discardableResult
    func deleteHTTPHeaders(baseUrl: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        headers.removeValue(forKey: normalizeBaseUrl(baseUrl))
        return true
    }

    func setHeaderReadsFail(_ fail: Bool) {
        lock.lock()
        defer { lock.unlock() }
        headerReadsFail = fail
    }

    func requestedDeletion(of baseUrl: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return deleteRequests.contains(baseUrl)
    }
}

private final class InMemoryTopicSecretStore: TopicSecretStoring {
    private var passwords: [String: String] = [:]
    private var keys: [String: Data] = [:]
    private(set) var readCount = 0
    /// Simulates a stored secret that can't be read (errSecInteractionNotAllowed before first unlock).
    var failReads: OSStatus?
    var failWrites = false
    var failDeletes = false
    private let lock = NSLock()

    func topicPassword(topicUrl: String) -> TopicSecretRead<String> {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        if let failReads { return .failed(failReads) }
        return passwords[topicUrl].map { .found($0) } ?? .notFound
    }

    func topicKey(topicUrl: String) -> TopicSecretRead<Data> {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        if let failReads { return .failed(failReads) }
        return keys[topicUrl].map { .found($0) } ?? .notFound
    }

    @discardableResult
    func setTopicSecret(password: String, key: Data, topicUrl: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if failWrites { return false }
        passwords[topicUrl] = password
        keys[topicUrl] = key
        return true
    }

    @discardableResult
    func deleteTopicSecret(topicUrl: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if failDeletes { return false }
        passwords.removeValue(forKey: topicUrl)
        keys.removeValue(forKey: topicUrl)
        return true
    }

    func dropKey(topicUrl: String) {
        lock.lock(); defer { lock.unlock() }
        keys.removeValue(forKey: topicUrl)
    }
}

/// Seed unit-test suite for ntfy iOS NextGen.
///
/// This target exists so `test_sim` is a real verification step (it was a no-op
/// before — the project shipped with no test target). These assertions exercise
/// pure, deterministic app logic through `@testable import ntfy`; future fixes
/// add their regression tests here.
final class ntfyTests: XCTestCase {
    private var credentialStore: InMemoryCredentialStore!
    private var topicSecrets: InMemoryTopicSecretStore!

    override func setUp() {
        super.setUp()
        Store.shared.clearPublisher = { _, done in done(true) }
        Store.shared.wakePublisher = { _, done in done() }
        Store.shared.notificationRemover = { _ in }
        credentialStore = InMemoryCredentialStore()
        Store.shared.credentialStore = credentialStore
        topicSecrets = InMemoryTopicSecretStore()
        Store.shared.topicSecrets = topicSecrets
        // The retired server comes from the build configuration, which a public checkout leaves
        // empty; the migration tests run against these stand-ins instead.
        RetiredDefaultServerMigration.retiredHostsForTesting = ["ntfy.retired.example", "push.retired.example"]
    }

    // MARK: BasicUser.toHeader() — deterministic Basic-auth header

    func testBasicUserHeaderIsExpectedBase64() {
        let user = BasicUser(username: "phil", password: "mypass")
        // base64("phil:mypass") == "cGhpbDpteXBhc3M="
        XCTAssertEqual(user.toHeader(), "Basic cGhpbDpteXBhc3M=")
    }

    // MARK: per-server custom HTTP headers

    private let headersBaseUrl = "https://headers.example.com"

    private func storeTestHeaders(baseUrl: String? = nil) {
        XCTAssertTrue(credentialStore.setHTTPHeaders(
            ["CF-Access-Client-Id": "client-id", "CF-Access-Client-Secret": "client-secret"],
            baseUrl: baseUrl ?? headersBaseUrl
        ))
    }

    func testCustomHeadersRoundTripAndNormalizeBaseUrl() {
        storeTestHeaders(baseUrl: "  https://headers.example.com///  ")
        let readResult = credentialStore.readHTTPHeaders(baseUrl: headersBaseUrl)
        XCTAssertEqual(readResult, .success([
            "CF-Access-Client-Id": "client-id",
            "CF-Access-Client-Secret": "client-secret",
        ]))
        XCTAssertEqual(ServerHeadersView.loadedHeaders(from: readResult), [
            "CF-Access-Client-Id": "client-id",
            "CF-Access-Client-Secret": "client-secret",
        ])
        XCTAssertEqual(credentialStore.httpHeaders(baseUrl: headersBaseUrl), [
            "CF-Access-Client-Id": "client-id",
            "CF-Access-Client-Secret": "client-secret",
        ])
        XCTAssertTrue(credentialStore.deleteHTTPHeaders(baseUrl: headersBaseUrl + "/"))
        XCTAssertEqual(credentialStore.httpHeaders(baseUrl: headersBaseUrl), [:])
    }

    func testFailedHeaderReadCannotBeFollowedByAnEmptySaveThatReplacesStoredHeaders() {
        let expected = ["CF-Access-Client-Id": "id", "CF-Access-Client-Secret": "secret"]
        XCTAssertTrue(credentialStore.setHTTPHeaders(expected, baseUrl: headersBaseUrl))
        credentialStore.setHeaderReadsFail(true)

        let readResult = credentialStore.readHTTPHeaders(baseUrl: headersBaseUrl)
        XCTAssertEqual(readResult, .failure)
        XCTAssertNil(
            ServerHeadersView.loadedHeaders(from: readResult),
            "the view must preserve its current form when storage cannot be read"
        )
        let savePlan = ServerHeadersView.savePlan(for: [], hasUnresolvedReadFailure: true)
        XCTAssertEqual(
            savePlan,
            .blockedByReadFailure,
            "Save must remain blocked for the server whose stored headers could not be loaded"
        )
        if case .persist(let replacement) = savePlan {
            XCTAssertTrue(credentialStore.setHTTPHeaders(replacement, baseUrl: headersBaseUrl))
        }
        XCTAssertEqual(
            credentialStore.httpHeaders(baseUrl: headersBaseUrl),
            [:],
            "network request builders must continue to fail closed on the same read failure"
        )

        credentialStore.setHeaderReadsFail(false)
        XCTAssertEqual(
            credentialStore.readHTTPHeaders(baseUrl: headersBaseUrl),
            .success(expected),
            "the failed load and blocked Save must leave the stored headers unchanged"
        )
    }

    func testSuccessfulEmptyHeaderReadIsDistinctAndSaveStillRequiresAnExplicitDelete() {
        XCTAssertEqual(credentialStore.readHTTPHeaders(baseUrl: headersBaseUrl), .success([:]))
        XCTAssertEqual(ServerHeadersView.loadedHeaders(from: .success([:])), [:])
        XCTAssertEqual(
            ServerHeadersView.savePlan(for: [], hasUnresolvedReadFailure: false),
            .nothingToSave
        )
        XCTAssertEqual(
            ServerHeadersView.savePlan(for: [(name: "", value: "")], hasUnresolvedReadFailure: false),
            .nothingToSave
        )
        XCTAssertEqual(
            ServerHeadersView.savePlan(for: [(name: "   ", value: "")], hasUnresolvedReadFailure: false),
            .nothingToSave,
            "a whitespace-only name with no value is an empty row, not an implicit delete request"
        )
    }

    func testHeaderSavePlanPersistsFilledRows() {
        XCTAssertEqual(
            ServerHeadersView.savePlan(
                for: [(name: "  CF-Access-Client-Id  ", value: "abc123")],
                hasUnresolvedReadFailure: false
            ),
            .persist(["CF-Access-Client-Id": "abc123"])
        )
    }

    func testHeaderSavePlanTrimsNamesAndIgnoresBlankRowsAlongsideRealOnes() {
        XCTAssertEqual(
            ServerHeadersView.savePlan(
                for: [
                    (name: "  CF-Access-Client-Id  ", value: "abc123"),
                    (name: "", value: ""),
                ],
                hasUnresolvedReadFailure: false
            ),
            .persist(["CF-Access-Client-Id": "abc123"]),
            "a blank UI row must not affect the trimmed header that is persisted"
        )
    }

    func testHeaderSavePlanRejectsDuplicateNamesIgnoringCapitalization() {
        XCTAssertEqual(
            ServerHeadersView.savePlan(
                for: [
                    (name: "CF-Access-Client-Id", value: "a"),
                    (name: "cf-access-client-id", value: "b"),
                ],
                hasUnresolvedReadFailure: false
            ),
            .duplicateName
        )
    }

    func testHeaderSavePlanDefersEmptyNameToCredentialValidation() {
        XCTAssertEqual(
            ServerHeadersView.savePlan(
                for: [(name: "", value: "secret")],
                hasUnresolvedReadFailure: false
            ),
            .persist(["": "secret"])
        )
        XCTAssertNotNil(
            ServerCredentials.validationError(headers: ["": "secret"]),
            "an empty header name must be rejected before credential storage"
        )
    }

    func testApiServiceInjectsHeadersOnlyForConfiguredOrigin() {
        storeTestHeaders()
        let service = ApiService(credentialStore: credentialStore)

        let matching = service.newRequest(
            url: URL(string: headersBaseUrl + "/topic/json")!,
            baseUrl: headersBaseUrl,
            user: nil
        )
        XCTAssertEqual(matching.value(forHTTPHeaderField: "CF-Access-Client-Id"), "client-id")
        XCTAssertEqual(matching.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "client-secret")

        let otherOrigin = service.newRequest(
            url: URL(string: "https://other.example.com/topic/json")!,
            baseUrl: headersBaseUrl,
            user: nil
        )
        XCTAssertNil(otherOrigin.value(forHTTPHeaderField: "CF-Access-Client-Id"),
                     "server A's secret must never be attached to a server B request")
    }

    func testCrossOriginRedirectRemovesAuthorizationAndCustomServerHeaders() {
        var redirect = URLRequest(url: URL(string: "https://other.example.com/landing")!)
        redirect.setValue("Basic victim-credentials", forHTTPHeaderField: "Authorization")
        redirect.setValue("client-secret", forHTTPHeaderField: "CF-Access-Client-Secret")
        redirect.setValue("keep", forHTTPHeaderField: "X-Unrelated")

        let sanitized = ServerCredentials.removingCredentialsFromCrossOriginRedirect(
            redirect,
            baseUrl: headersBaseUrl,
            customHeaderNames: ["CF-Access-Client-Secret"]
        )
        XCTAssertNil(sanitized.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(sanitized.value(forHTTPHeaderField: "CF-Access-Client-Secret"))
        XCTAssertEqual(sanitized.value(forHTTPHeaderField: "X-Unrelated"), "keep")

        var sameOrigin = redirect
        sameOrigin.url = URL(string: headersBaseUrl + "/redirected")!
        let retained = ServerCredentials.removingCredentialsFromCrossOriginRedirect(
            sameOrigin,
            baseUrl: headersBaseUrl + "/",
            customHeaderNames: ["CF-Access-Client-Secret"]
        )
        XCTAssertEqual(retained.value(forHTTPHeaderField: "Authorization"), "Basic victim-credentials")
        XCTAssertEqual(retained.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "client-secret")
    }

    func testExplicitCustomHeadersOverrideDefaultAuthorizationAndUserAgent() {
        XCTAssertTrue(credentialStore.setHTTPHeaders(
            ["authorization": "Bearer proxy-token", "user-agent": "custom-agent"],
            baseUrl: headersBaseUrl
        ))
        let request = ApiService(credentialStore: credentialStore).newRequest(
            url: URL(string: headersBaseUrl + "/topic")!,
            baseUrl: headersBaseUrl,
            user: BasicUser(username: "phil", password: "mypass")
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer proxy-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "custom-agent")
    }

    func testUnrelatedCustomHeaderPreservesDefaultAuthorizationAndUserAgent() {
        XCTAssertTrue(credentialStore.setHTTPHeaders(["X-Proxy-Token": "proxy"], baseUrl: headersBaseUrl))
        let user = BasicUser(username: "phil", password: "mypass")
        let request = ApiService(credentialStore: credentialStore).newRequest(
            url: URL(string: headersBaseUrl + "/topic")!,
            baseUrl: headersBaseUrl,
            user: user
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), user.toHeader())
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), ApiService.userAgent)
    }

    func testCustomHeaderValidationRejectsInjectionAndCaseInsensitiveDuplicates() {
        XCTAssertNotNil(ServerCredentials.validationError(headers: ["X-Bad Name": "value"]))
        XCTAssertNotNil(ServerCredentials.validationError(headers: ["X-Test": "one", "x-test": "two"]))
        XCTAssertNotNil(ServerCredentials.validationError(headers: ["X-Test": "one\r\nInjected: yes"]))
        XCTAssertNil(ServerCredentials.validationError(headers: ["X-Proxy_Token": "valid value"]))
    }

    func testManualAttachmentRequestInjectsServerHeaders() {
        storeTestHeaders()
        let authorization = BasicUser(username: "victim", password: "server-password").toHeader()
        let request = AttachmentFileStore.makeRequest(
            remoteUrl: URL(string: headersBaseUrl + "/file/image.png")!,
            baseUrl: headersBaseUrl,
            authorizationHeader: authorization,
            credentialStore: credentialStore
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), authorization)
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "client-secret")
    }

    func testManualAttachmentRequestOmitsAllCredentialsForAttackerOrigin() {
        storeTestHeaders()
        let request = AttachmentFileStore.makeRequest(
            remoteUrl: URL(string: "https://evil.example/p.png")!,
            baseUrl: headersBaseUrl,
            authorizationHeader: BasicUser(username: "victim", password: "server-password").toHeader(),
            credentialStore: credentialStore
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"))
    }

    func testSameOriginHTTPActionInjectsHeadersButThirdPartyActionDoesNot() throws {
        storeTestHeaders()
        let sameOrigin = Action(
            id: "1", action: "http", label: "Approve",
            url: headersBaseUrl + "/approve", method: "POST",
            headers: nil, body: nil, clear: nil
        )
        let thirdParty = Action(
            id: "2", action: "http", label: "Approve elsewhere",
            url: "https://actions.example.net/approve", method: "POST",
            headers: nil, body: nil, clear: nil
        )

        let protectedRequest = try XCTUnwrap(ActionExecutor.makeHTTPRequest(
            sameOrigin, baseUrl: headersBaseUrl, credentialStore: credentialStore
        ))
        XCTAssertEqual(protectedRequest.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "client-secret")

        let externalRequest = try XCTUnwrap(ActionExecutor.makeHTTPRequest(
            thirdParty, baseUrl: headersBaseUrl, credentialStore: credentialStore
        ))
        XCTAssertNil(externalRequest.value(forHTTPHeaderField: "CF-Access-Client-Secret"))
    }

    // MARK: Actions.parse — guards + supported-action filtering

    func testActionsParseReturnsNilForNilAndEmpty() {
        XCTAssertNil(Actions.shared.parse(nil))
        XCTAssertNil(Actions.shared.parse(""))
    }

    func testActionsParseFiltersUnsupportedActions() {
        let json = """
        [{"id":"1","action":"view","label":"Open","url":"https://ntfy.sh"},\
        {"id":"2","action":"bogus","label":"Nope"}]
        """
        let parsed = Actions.shared.parse(json)
        // "view" is supported, "bogus" is filtered out.
        XCTAssertEqual(parsed?.count, 1)
        XCTAssertEqual(parsed?.first?.action, "view")
    }

    // MARK: Actions.encode — nil round-trips to empty string

    func testActionsEncodeNilIsEmptyString() {
        XCTAssertEqual(Actions.shared.encode(nil), "")
    }

    // MARK: ActionExecutor.identifiersToClear — honor ntfy's `clear` flag (ntfy #1728, ntfy-ios#38)

    private func makeAction(clear: Bool?) -> Action {
        Action(id: "1", action: "http", label: "Approve",
               url: "https://example.com/approve", method: nil,
               headers: nil, body: nil, clear: clear)
    }

    func testClearTrueWithIdReturnsThatId() {
        // clear==true + a known delivered-notification id → dismiss exactly that one.
        XCTAssertEqual(
            ActionExecutor.identifiersToClear(for: makeAction(clear: true), notificationId: "abc-123"),
            ["abc-123"]
        )
    }

    func testClearTrueWithoutIdClearsNothing() {
        // clear==true but no id is known → nothing to remove (must not crash / clear all).
        XCTAssertNil(ActionExecutor.identifiersToClear(for: makeAction(clear: true), notificationId: nil))
    }

    func testClearTrueWithEmptyIdClearsNothing() {
        // An empty identifier is not a real notification → do not clear.
        XCTAssertNil(ActionExecutor.identifiersToClear(for: makeAction(clear: true), notificationId: ""))
    }

    func testClearFalseClearsNothing() {
        XCTAssertNil(ActionExecutor.identifiersToClear(for: makeAction(clear: false), notificationId: "abc-123"))
    }

    func testClearAbsentClearsNothing() {
        // The overwhelmingly common case: no `clear` field on the action → banner stays.
        XCTAssertNil(ActionExecutor.identifiersToClear(for: makeAction(clear: nil), notificationId: "abc-123"))
    }

    // MARK: UNMutableNotificationContent.modify — never leak the "New message" placeholder (#1080)

    func testModifyReplacesPlaceholderWithRealBody() {
        let content = UNMutableNotificationContent()
        content.body = "New message"  // the incoming server placeholder
        let msg = Message(id: "x", time: 1, event: "message", topic: "t", message: "real body", title: "T")
        content.modify(message: msg, baseUrl: "https://ntfy.sh")
        XCTAssertEqual(content.body, "real body")
    }

    func testModifyNeverLeaksPlaceholderForBodylessMessage() {
        // A title-only (or attachment-only) message has message.message == nil. Before the fix the
        // body kept the incoming "New message" placeholder; now it must be cleared. (#1080 regression)
        let content = UNMutableNotificationContent()
        content.body = "New message"
        let msg = Message(id: "x", time: 1, event: "message", topic: "t", message: nil, title: "Only Title")
        content.modify(message: msg, baseUrl: "https://ntfy.sh")
        XCTAssertNotEqual(content.body, "New message",
                          "a processed message must never show the raw push placeholder")
    }

    // MARK: Message.icon — per-message icon field (#1107), poll + push paths

    func testMessageDecodesIconFromJson() throws {
        let json = #"{"id":"x","time":1,"event":"message","topic":"t","message":"hi","icon":"https://ntfy.sh/i.png"}"#.data(using: .utf8)!
        let m = try JSONDecoder().decode(Message.self, from: json)
        XCTAssertEqual(m.icon, "https://ntfy.sh/i.png")
    }

    func testMessageIconRoundTripsThroughUserInfo() {
        // push/NSE path: toUserInfo -> from(userInfo:) must preserve the icon
        let m = Message(id: "x", time: 1, event: "message", topic: "t", message: "hi",
                        icon: "https://ntfy.sh/i.png")
        XCTAssertEqual(Message.from(userInfo: m.toUserInfo())?.icon, "https://ntfy.sh/i.png")
    }

    func testMessageIconAbsentNormalizesToNil() throws {
        let json = #"{"id":"x","time":1,"event":"message","topic":"t","message":"hi"}"#.data(using: .utf8)!
        let m = try JSONDecoder().decode(Message.self, from: json)
        XCTAssertNil(m.icon)
        // empty "" in userInfo must come back as nil, not empty string
        XCTAssertNil(Message.from(userInfo: m.toUserInfo())?.icon)
    }

    // MARK: renderMessageBody — markdown (#1072) vs plain-text linkification

    func testRenderMarkdownStripsSyntax() {
        // text/markdown → "**bold**" parses to "bold" (asterisks consumed = markdown applied)
        let out = renderMessageBody("**bold** text", contentType: "text/markdown")
        let plain = String(out.characters)
        XCTAssertEqual(plain, "bold text")
        XCTAssertFalse(plain.contains("**"))
    }

    func testRenderMarkdownParsesLink() {
        let out = renderMessageBody("see [ntfy](https://ntfy.sh) here", contentType: "text/markdown")
        XCTAssertFalse(String(out.characters).contains("]("), "link markdown syntax should be consumed")
        XCTAssertTrue(out.runs.contains { $0.link != nil }, "a real link run should exist")
    }

    func testRenderPlainLeavesMarkdownLiteral() {
        // no content type → markdown syntax stays literal (plain-text path)
        let out = renderMessageBody("**bold**", contentType: nil)
        XCTAssertEqual(String(out.characters), "**bold**")
    }

    func testRenderPlainLinkifiesUrls() {
        let out = renderMessageBody("visit https://ntfy.sh now", contentType: nil)
        XCTAssertTrue(out.runs.contains { $0.link != nil }, "plain-text URLs should be linkified")
    }

    func testRenderMarkdownLinkifiesBareUrls() {
        // A bare URL inside a markdown message must be tappable too — Foundation's
        // markdown parser only links [text](url)/<url>, not bare "https://…", so the
        // plain-text path linkified it while the markdown path left it dead (#1743 parity).
        let out = renderMessageBody("visit https://ntfy.sh now", contentType: "text/markdown")
        XCTAssertTrue(out.runs.contains { $0.link != nil }, "bare URLs in markdown should be linkified")
    }

    func testRenderMarkdownBareUrlLinkCoexistsWithBold() {
        // Adding bare-URL linkification must not clobber markdown's own styling runs.
        let out = renderMessageBody("**bold** see https://ntfy.sh", contentType: "text/markdown")
        XCTAssertFalse(String(out.characters).contains("**"), "markdown bold syntax should still be consumed")
        XCTAssertTrue(out.runs.contains { $0.link != nil }, "the bare URL should still become a link")
    }

    func testRenderMarkdownAuthoredLinkPreserved() {
        // An explicit markdown link must keep its target (label != URL), not be overwritten
        // by the bare-URL detector pass.
        let out = renderMessageBody("see [ntfy](https://ntfy.sh) here", contentType: "text/markdown")
        XCTAssertFalse(String(out.characters).contains("]("), "link markdown syntax should be consumed")
        XCTAssertTrue(out.runs.contains { $0.link != nil }, "the authored link run should survive")
    }

    // MARK: Selectable message text + native link menu

    private func linkTargets(in attributed: AttributedString) -> [URL] {
        attributed.runs.compactMap(\.link)
    }

    func testSelectableMessageTextDetectsMultipleLinks() {
        let out = renderMessageBody(
            "first https://one.example/path then https://two.example/other",
            contentType: nil
        )
        XCTAssertEqual(
            linkTargets(in: out),
            [URL(string: "https://one.example/path")!, URL(string: "https://two.example/other")!]
        )
    }

    func testSelectableMessageTextLeavesMalformedPartialURLUnlinked() {
        let out = renderMessageBody("good https://ntfy.sh then broken https://", contentType: nil)
        XCTAssertEqual(linkTargets(in: out), [URL(string: "https://ntfy.sh")!])
    }

    func testSelectableMessageTextKeepsVeryLongURLAsOneLink() {
        let url = "https://example.com/" + String(repeating: "long-segment-", count: 40) + "finish"
        let out = renderMessageBody("before \(url) after", contentType: nil)
        XCTAssertEqual(linkTargets(in: out), [URL(string: url)!])
    }

    func testSelectableMessageTextExcludesAdjacentPunctuationFromLink() {
        let out = renderMessageBody("See (https://ntfy.sh/docs), then continue.", contentType: nil)
        XCTAssertEqual(linkTargets(in: out), [URL(string: "https://ntfy.sh/docs")!])
    }

    func testSelectableMessageTitleLinkifiesURLs() {
        let out = renderMessageTitle("Status at https://status.example.com/incident")
        XCTAssertEqual(linkTargets(in: out), [URL(string: "https://status.example.com/incident")!])
    }

    func testUIKitConversionKeepsMarkdownAuthoredLinkTarget() {
        let swift = renderMessageBody(
            "read [the guide](https://ntfy.sh/docs) now",
            contentType: "text/markdown"
        )
        let output = makeMessageNSAttributedString(swift, style: .body)
        let labelRange = (output.string as NSString).range(of: "the guide")
        XCTAssertEqual(
            output.attribute(.link, at: labelRange.location, effectiveRange: nil) as? URL,
            URL(string: "https://ntfy.sh/docs")!
        )
    }

    func testUIKitConversionKeepsBareURLInMarkdownBody() {
        let swift = renderMessageBody("**bold** https://ntfy.sh/docs", contentType: "text/markdown")
        let output = makeMessageNSAttributedString(swift, style: .body)
        let linkRange = (output.string as NSString).range(of: "https://ntfy.sh/docs")
        XCTAssertEqual(
            output.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL,
            URL(string: "https://ntfy.sh/docs")!
        )
    }

    func testUIKitConversionUsesLabelColorForNonLinkText() {
        let output = makeMessageNSAttributedString(
            renderMessageBody("plain text and https://ntfy.sh", contentType: nil),
            style: .body
        )
        let plainRange = (output.string as NSString).range(of: "plain text")
        XCTAssertEqual(
            output.attribute(.foregroundColor, at: plainRange.location, effectiveRange: nil) as? UIColor,
            UIColor.label,
            "non-link text must remain readable in dark mode"
        )
    }

    func testUIKitConversionResolvesMarkdownEmphasisIntoBoldFontTrait() {
        let output = makeMessageNSAttributedString(
            renderMessageBody("before **bold words** after", contentType: "text/markdown"),
            style: .body
        )
        let boldRange = (output.string as NSString).range(of: "bold words")
        let font = output.attribute(.font, at: boldRange.location, effectiveRange: nil) as? UIFont
        XCTAssertNotNil(font)
        XCTAssertTrue(
            font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true,
            "Markdown strong emphasis must survive the NSAttributedString bridge"
        )
    }

    func testSelectableTextViewConfigurationEnablesNativeReadOnlyInteractionAndSelfSizing() {
        let textView = UITextView()
        configureMessageTextView(textView, isInteractionEnabled: true)

        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.isEditable)
        XCTAssertFalse(textView.isScrollEnabled)
        XCTAssertTrue(textView.adjustsFontForContentSizeCategory)
        XCTAssertTrue(textView.isUserInteractionEnabled)
        XCTAssertEqual(textView.backgroundColor, UIColor.clear)
        XCTAssertEqual(textView.textContainerInset, .zero)
        XCTAssertEqual(textView.textContainer.lineFragmentPadding, 0)
    }

    func testSelectableTextViewDisablesInteractionDuringListEditMode() {
        let textView = UITextView()
        configureMessageTextView(textView, isInteractionEnabled: false)
        XCTAssertFalse(
            textView.isUserInteractionEnabled,
            "the text view must yield row taps to List(selection:) while edit mode is active"
        )
    }

    func testMessageContentDoesNotInstallAncestorTapRecognizer() {
        let normalPolicy = messageRowTapPolicy(isEditing: false)
        let editingPolicy = messageRowTapPolicy(isEditing: true)

        XCTAssertFalse(
            normalPolicy.installsAncestorContentTap,
            "a SwiftUI ancestor tap would fire handleRowTap independently after a link opens"
        )
        XCTAssertFalse(
            editingPolicy.installsAncestorContentTap,
            "edit mode must leave row selection to List(selection:)"
        )
        XCTAssertTrue(
            normalPolicy.installsRegionTaps,
            "non-text parts of the row must preserve the existing row action"
        )
        XCTAssertFalse(
            editingPolicy.installsRegionTaps,
            "component taps must not compete with List(selection:) in edit mode"
        )
    }

    func testSelectableTextViewUsesStaticTextAccessibilitySemantics() {
        let textView = UITextView()
        configureMessageTextView(textView, isInteractionEnabled: true)

        XCTAssertTrue(
            textView.accessibilityTraits.contains(.staticText),
            "VoiceOver should announce a read-only message body as static text, not an editable field"
        )
        XCTAssertTrue(textView.isSelectable, "static accessibility semantics must not disable selection")
        XCTAssertFalse(textView.isEditable, "message text must remain read-only")
    }

    @available(iOS 17.0, *)
    func testLinkMenuPreservesSystemCopyLinkActionAndItsPasteboardEffect() {
        UIPasteboard.general.items = []
        addTeardownBlock { UIPasteboard.general.items = [] }
        let url = URL(string: "https://ntfy.sh/docs")!
        let open = UIAction(title: "Open") { _ in }
        let copy = UICommand(
            title: "Copy Link",
            action: #selector(copyLinkTestCommand(_:)),
            propertyList: url.absoluteString as NSString
        )
        let share = UIAction(title: "Share") { _ in }
        let defaultMenu = UIMenu(children: [open, copy, share])

        let retainedMenu = preservedDefaultLinkMenu(defaultMenu)
        XCTAssertTrue(retainedMenu === defaultMenu, "the platform-supplied menu must remain unchanged")
        let retainedTitles = retainedMenu.children.map { element in
            (element as? UIAction)?.title ?? (element as? UICommand)?.title ?? ""
        }
        XCTAssertEqual(retainedTitles, ["Open", "Copy Link", "Share"])

        guard let retainedCopy = retainedMenu.children.first(where: {
            ($0 as? UICommand)?.title == "Copy Link"
        }) as? UICommand else {
            XCTFail("the system Copy Link action must not be replaced or dropped")
            return
        }
        XCTAssertTrue(
            UIApplication.shared.sendAction(
                retainedCopy.action,
                to: self,
                from: retainedCopy,
                for: nil
            )
        )
        XCTAssertEqual(UIPasteboard.general.url, url, "Copy Link must write the URL to the general pasteboard")
    }

    @objc
    private func copyLinkTestCommand(_ sender: UICommand) {
        guard let value = sender.propertyList as? String else {
            return
        }
        UIPasteboard.general.url = URL(string: value)
    }

    // MARK: Helpers — URL/tag utilities (rebase-regression coverage)

    func testNormalizeBaseUrlStripsTrailingSlashesAndWhitespace() {
        XCTAssertEqual(normalizeBaseUrl("https://ntfy.sh/"), "https://ntfy.sh")
        XCTAssertEqual(normalizeBaseUrl("https://ntfy.sh///"), "https://ntfy.sh")
        XCTAssertEqual(normalizeBaseUrl("  https://ntfy.sh/  "), "https://ntfy.sh")
        XCTAssertEqual(normalizeBaseUrl("https://ntfy.sh"), "https://ntfy.sh")
    }

    func testTopicUrlAndShortUrl() {
        XCTAssertEqual(topicUrl(baseUrl: "https://ntfy.sh/", topic: "mytopic"), "https://ntfy.sh/mytopic")
        XCTAssertEqual(shortUrl(url: "https://ntfy.sh/mytopic"), "ntfy.sh/mytopic")
        XCTAssertEqual(topicShortUrl(baseUrl: "https://ntfy.sh/", topic: "mytopic"), "ntfy.sh/mytopic")
    }

    func testParseAllTagsTrimsAndDropsEmpties() {
        // spaces after commas must not leak into tag names (they break emoji lookup + display)
        XCTAssertEqual(parseAllTags("tag1, tag2 ,  ,tag3"), ["tag1", "tag2", "tag3"])
        XCTAssertEqual(parseAllTags(""), [])
        XCTAssertEqual(parseAllTags(nil), [])
    }

    func testFirebaseTopicHashesForNonDefaultServer() {
        // A clearly non-default self-hosted server must map to a 64-char SHA-256 hex hash,
        // never the raw topic (which would leak across servers on the shared FCM sender).
        let t = firebaseTopic(baseUrl: "https://ntfy.example-selfhosted-12345.tld", topic: "secret")
        XCTAssertEqual(t.count, 64)
        XCTAssertTrue(t.allSatisfy { $0.isHexDigit })
        XCTAssertNotEqual(t, "secret")
        // deterministic
        XCTAssertEqual(t, firebaseTopic(baseUrl: "https://ntfy.example-selfhosted-12345.tld", topic: "secret"))
    }

    // MARK: Notification.format{Message,Title} — title/message/emoji placement rules
    // (deterministic assertions only — no dependency on the emoji dataset)

    private func makeNotification(message: String?, title: String?, tags: String? = nil) -> ntfy.Notification {
        let n = ntfy.Notification(context: Store.shared.context)  // in-memory under XCTest; ntfy. disambiguates from Foundation.Notification
        n.message = message
        n.title = title
        n.tags = tags
        return n
    }

    func testFormatMessagePlainWhenNoTitleNoTags() {
        XCTAssertEqual(makeNotification(message: "hello", title: nil, tags: nil).formatMessage(), "hello")
    }

    func testFormatMessageIsUnchangedWhenTitlePresent() {
        // With a title, emoji tags decorate the TITLE, so the message body is untouched.
        XCTAssertEqual(makeNotification(message: "hello", title: "Header", tags: "warning").formatMessage(), "hello")
    }

    func testFormatMessageNilMessageIsEmptyString() {
        XCTAssertEqual(makeNotification(message: nil, title: nil, tags: nil).formatMessage(), "")
    }

    func testFormatTitleNilWhenNoTitle() {
        XCTAssertNil(makeNotification(message: "hello", title: nil, tags: "warning").formatTitle())
        XCTAssertNil(makeNotification(message: "hello", title: "", tags: nil).formatTitle())
    }

    func testFormatTitleReturnsTitleWhenNoTags() {
        XCTAssertEqual(makeNotification(message: "hello", title: "Header", tags: nil).formatTitle(), "Header")
    }

    // MARK: ActionExecutor.httpActionResult — non-2xx is a failure, not a silent success
    // Regression: the old completion handler only checked the transport `error` and logged
    // "succeeded" for any response, so an "Approve" action returning 401/403/500 looked fine.

    private func httpResponse(_ status: Int) -> HTTPURLResponse {
        return HTTPURLResponse(url: URL(string: "https://ntfy.sh/secret-broker-approve")!,
                               statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testHttpActionResultSuccessFor2xx() {
        XCTAssertEqual(ActionExecutor.httpActionResult(response: httpResponse(200), error: nil), .success)
        XCTAssertEqual(ActionExecutor.httpActionResult(response: httpResponse(201), error: nil), .success)
        XCTAssertEqual(ActionExecutor.httpActionResult(response: httpResponse(204), error: nil), .success)
        XCTAssertEqual(ActionExecutor.httpActionResult(response: httpResponse(299), error: nil), .success)
    }

    func testHttpActionResultFailureForNon2xx() {
        XCTAssertEqual(ActionExecutor.httpActionResult(response: httpResponse(401), error: nil), .failure("HTTP 401"))
        XCTAssertEqual(ActionExecutor.httpActionResult(response: httpResponse(403), error: nil), .failure("HTTP 403"))
        XCTAssertEqual(ActionExecutor.httpActionResult(response: httpResponse(500), error: nil), .failure("HTTP 500"))
        // 300 is the first non-2xx code above the success band.
        XCTAssertEqual(ActionExecutor.httpActionResult(response: httpResponse(300), error: nil), .failure("HTTP 300"))
    }

    func testHttpActionResultFailureOnTransportError() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: nil)
        if case .failure = ActionExecutor.httpActionResult(response: nil, error: err) {
            // expected
        } else {
            XCTFail("transport error should classify as failure")
        }
    }

    func testHttpActionResultSuccessWhenNoHttpResponseAndNoError() {
        // Non-HTTP response with no transport error: nothing to assess → treat as success.
        XCTAssertEqual(ActionExecutor.httpActionResult(response: nil, error: nil), .success)
    }

    // MARK: Clear everywhere — wire events and store regressions

    private func sequenceEvent(_ id: String, _ event: String = "message", sequence: String = "job", time: Int64 = 100, body: String = "first") throws -> Message {
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "time": time, "event": event, "topic": "sequence-tests", "sequence_id": sequence, "message": body])
        return try JSONDecoder().decode(Message.self, from: data)
    }

    private func sequenceSubscription() -> Subscription {
        let sub = Store.shared.saveSubscription(baseUrl: "https://sequence.invalid", topic: "sequence-tests")
        addTeardownBlock { Store.shared.delete(subscription: sub) }
        return sub
    }

    private func sequenceRows(_ sub: Subscription) -> [ntfy.Notification] {
        let request = ntfy.Notification.fetchRequest()
        request.predicate = NSPredicate(format: "subscription == %@", sub)
        return (try? Store.shared.context.fetch(request)) ?? []
    }

    func testSequenceWireRoundTripIncludesControls() throws {
        for event in ["message", "message_clear", "message_delete"] {
            let parsed = try sequenceEvent("event-" + event, event)
            XCTAssertEqual(parsed.toUserInfo()["sequence_id"] as? String, "job")
            XCTAssertEqual(Message.from(userInfo: parsed.toUserInfo())?.toUserInfo()["sequence_id"] as? String, "job")
        }
    }

    func testSequenceClearMarksReadWithoutAddingRow() throws {
        let sub = sequenceSubscription()
        Store.shared.save(notificationsFromMessages: [try sequenceEvent("original")], withSubscription: sub)
        let result = Store.shared.save(notificationsFromMessages: [try sequenceEvent("clear", "message_clear", time: 101)], withSubscription: sub)
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(sequenceRows(sub).count, 1)
        XCTAssertTrue(try XCTUnwrap(sequenceRows(sub).first).read)
        XCTAssertEqual(sub.lastNotificationId, "clear")
    }

    func testSequenceDeleteRemovesStoreRow() throws {
        let sub = sequenceSubscription()
        Store.shared.save(notificationsFromMessages: [try sequenceEvent("original")], withSubscription: sub)
        let result = Store.shared.save(notificationsFromMessages: [try sequenceEvent("delete", "message_delete", time: 101)], withSubscription: sub)
        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(sequenceRows(sub).isEmpty)
        XCTAssertEqual(sub.lastNotificationId, "delete")
    }

    func testSequenceUpdateReplacesObjectInPlace() throws {
        let sub = sequenceSubscription()
        Store.shared.save(notificationsFromMessages: [try sequenceEvent("original")], withSubscription: sub)
        let original = try XCTUnwrap(sequenceRows(sub).first)
        let objectID = original.objectID
        Store.shared.save(notificationsFromMessages: [try sequenceEvent("updated", time: 101, body: "replacement")], withSubscription: sub)
        XCTAssertEqual(sequenceRows(sub).count, 1)
        XCTAssertEqual(sequenceRows(sub).first?.objectID, objectID)
        XCTAssertEqual(sequenceRows(sub).first?.message, "replacement")
        XCTAssertEqual(sequenceRows(sub).first?.id, "updated")
    }

    func testSequencePollBatchDoesNotAlertClearedOrDeletedMessages() throws {
        let sub = sequenceSubscription()
        let result = Store.shared.save(notificationsFromMessages: [try sequenceEvent("a"), try sequenceEvent("b", "message_clear", time: 101), try sequenceEvent("c", "message_delete", time: 102)], withSubscription: sub)
        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(sequenceRows(sub).isEmpty)
    }

    func testSequenceControlsAreScopedToSubscriptionAndIgnoreKeepalive() throws {
        let sub = sequenceSubscription()
        let other = Store.shared.saveSubscription(baseUrl: "https://other-sequence.invalid", topic: "sequence-tests")
        addTeardownBlock { Store.shared.delete(subscription: other) }
        Store.shared.save(notificationsFromMessages: [try sequenceEvent("original")], withSubscription: sub)
        Store.shared.save(notificationsFromMessages: [try sequenceEvent("other")], withSubscription: other)
        Store.shared.save(notificationsFromMessages: [try sequenceEvent("clear", "message_clear", time: 101), try sequenceEvent("keep", "keepalive", time: 102)], withSubscription: sub)
        XCTAssertEqual(sequenceRows(sub).count, 1)
        XCTAssertTrue(sequenceRows(sub).first?.read == true)
        XCTAssertFalse(try XCTUnwrap(sequenceRows(other).first).read)
    }

    func testSequenceReceivedClearNeverRepublishesEvenWhenTopicIsReadAgain() throws {
        let sub = sequenceSubscription()
        var clears: [ClearRequest] = []
        Store.shared.clearPublisher = { request, done in clears.append(request); done(true) }
        Store.shared.save(notificationsFromMessages: [try sequenceEvent("original")], withSubscription: sub)
        _ = Store.shared.ingest(pushedMessage: try sequenceEvent("clear", "message_clear", time: 101), baseUrl: sub.baseUrl!, topic: sub.topic!)
        Store.shared.setRead(true, forSubscription: sub)
        XCTAssertTrue(clears.isEmpty)
        XCTAssertTrue(try XCTUnwrap(sequenceRows(sub).first).read)
    }

    func testSequenceLocalReadPublishesOnceWithSubscriptionCredentials() throws {
        let sub = sequenceSubscription()
        Store.shared.saveUser(baseUrl: sub.baseUrl!, username: "reader", password: "password")
        let user = try XCTUnwrap(Store.shared.getUser(baseUrl: sub.baseUrl!))
        addTeardownBlock { Store.shared.delete(user: user) }
        Store.shared.save(notificationsFromMessages: [try sequenceEvent("original")], withSubscription: sub)
        var clears: [ClearRequest] = []
        Store.shared.clearPublisher = { request, done in clears.append(request); done(true) }
        Store.shared.setRead(true, forSubscription: sub)
        Store.shared.setRead(true, forSubscription: sub)
        XCTAssertEqual(clears.count, 1)
        XCTAssertEqual(clears.first?.sequence, "job")
        XCTAssertEqual(clears.first?.topic, "sequence-tests")
        XCTAssertEqual(clears.first?.baseUrl, sub.baseUrl)
        XCTAssertEqual(clears.first?.user?.username, "reader")
        XCTAssertEqual(clears.first?.user?.password, "password")
    }

    func testSequenceDismissCompletionWaitsForBestEffortSend() throws {
        let sub = sequenceSubscription()
        let original = try sequenceEvent("original")
        Store.shared.save(notificationsFromMessages: [original], withSubscription: sub)
        var finished: ((Bool) -> Void)?
        Store.shared.clearPublisher = { _, done in finished = done }
        let completed = expectation(description: "dismiss completion after request")
        Store.shared.read(message: original, baseUrl: sub.baseUrl!) { completed.fulfill() }
        XCTAssertTrue(try XCTUnwrap(sequenceRows(sub).first).read)
        XCTAssertNotNil(finished)
        finished?(true)
        wait(for: [completed], timeout: 2)
    }

    func testSequenceMarkUnreadDoesNotPublishAndBannerReadFindsUpdatedRow() throws {
        let sub = sequenceSubscription()
        let old = try sequenceEvent("old")
        Store.shared.save(notificationsFromMessages: [old, try sequenceEvent("new", time: 101)], withSubscription: sub)
        var sequences: [String] = []
        Store.shared.clearPublisher = { request, done in sequences.append(request.sequence); done(true) }
        Store.shared.setRead(false, forNotification: try XCTUnwrap(sequenceRows(sub).first))
        XCTAssertTrue(sequences.isEmpty)
        Store.shared.read(message: old, baseUrl: sub.baseUrl!)
        XCTAssertEqual(sequences, ["job"])
        XCTAssertTrue(try XCTUnwrap(sequenceRows(sub).first).read)
    }

    func testSequenceUsesOrdinaryMessageIDAndIgnoresUnrelatedEvents() throws {
        let sub = sequenceSubscription()
        let original = Message(id: "legacy-id", time: 100, event: "message", topic: sub.topic!, message: "old server")
        Store.shared.save(notificationsFromMessages: [original], withSubscription: sub)
        var ids: [String] = []
        Store.shared.clearPublisher = { request, done in ids.append(request.sequence); done(true) }
        Store.shared.setRead(true, forNotification: try XCTUnwrap(sequenceRows(sub).first))
        XCTAssertEqual(ids, ["legacy-id"])
        let clear = try sequenceEvent("clear", "message_clear", sequence: "legacy-id", time: 101)
        Store.shared.save(notificationsFromMessages: [clear], withSubscription: sub)
        XCTAssertEqual(sequenceRows(sub).count, 1)
    }

    func testSequenceDeletedVersionCannotReturnFromOverlappingPollAndCanRevive() throws {
        let sub = sequenceSubscription()
        let original = try sequenceEvent("original")
        let delete = try sequenceEvent("delete", "message_delete", time: 101)
        Store.shared.save(notificationsFromMessages: [original, delete], withSubscription: sub)
        Store.shared.save(notificationsFromMessages: [original], withSubscription: sub)
        XCTAssertTrue(sequenceRows(sub).isEmpty)
        XCTAssertEqual(sub.lastNotificationId, "delete")
        Store.shared.save(notificationsFromMessages: [try sequenceEvent("revived", time: 102)], withSubscription: sub)
        XCTAssertEqual(sequenceRows(sub).first?.id, "revived")
        XCTAssertFalse(try XCTUnwrap(sequenceRows(sub).first).read)
    }

    func testSequenceClearBeforeMessageRejectsStalePushAndOrderedPollCanReviveSameSecond() throws {
        let sub = sequenceSubscription()
        let clear = try sequenceEvent("clear", "message_clear")
        Store.shared.save(notificationsFromMessages: [clear], withSubscription: sub)
        Store.shared.save(notificationsFromMessages: [try sequenceEvent("old", time: 99)], withSubscription: sub)
        Store.shared.save(notificationsFromMessages: [try sequenceEvent("ambiguous")], withSubscription: sub)
        XCTAssertTrue(sequenceRows(sub).isEmpty)
        let request = try XCTUnwrap(Store.shared.pollRequest(for: sub))
        let result = Store.shared.save(notificationsFromMessages: [clear, try sequenceEvent("revived")], polledWith: request)
        XCTAssertEqual(result?.map(\.id), ["revived"])
        XCTAssertEqual(sub.lastNotificationId, "revived")
    }

    func testSequenceUpdateDoesNotBuzzAndPreservesReadStateAndAttachmentCleanup() throws {
        let sub = sequenceSubscription()
        Store.shared.save(notificationsFromMessages: [try sequenceEvent("original")], withSubscription: sub)
        let row = try XCTUnwrap(sequenceRows(sub).first)
        Store.shared.setRead(true, forNotification: row)
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try Data("attachment".utf8).write(to: file)
        row.attachmentLocalPath = file.path
        try Store.shared.context.save()
        let result = Store.shared.save(notificationsFromMessages: [try sequenceEvent("updated", time: 101)], withSubscription: sub)
        XCTAssertTrue(row.read)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let update = try XCTUnwrap(result.first)
        XCTAssertTrue(update.isUpdate)
        let content = UNMutableNotificationContent()
        content.modify(message: update, baseUrl: sub.baseUrl!)
        XCTAssertNil(content.sound)
        XCTAssertEqual(content.interruptionLevel, .passive)
        Store.shared.save(notificationsFromMessages: [try sequenceEvent("original")], withSubscription: sub)
        XCTAssertEqual(row.id, "updated")
    }

    func testSequenceRemovalMatchesAPNSIdentifierAndScopesServerTopicTimeAndVersion() throws {
        let original = try sequenceEvent("original")
        func request(_ identifier: String, message: Message, server: String = "https://sequence.invalid") -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.userInfo = message.toUserInfo()
            content.userInfo["base_url"] = server
            return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        }
        var otherTopic = original
        otherTopic.topic = "another-topic"
        let removal = SequenceRemoval(baseUrl: "https://sequence.invalid/", topic: "sequence-tests", sequence: "job", throughTime: 101, keepingID: "replacement")
        let requests = [request("apns-uuid", message: original), request("other-server", message: original, server: "https://other.invalid"), request("other-topic", message: otherTopic), request("keep", message: try sequenceEvent("replacement", time: 101)), request("future", message: try sequenceEvent("future", time: 102))]
        XCTAssertEqual(removal.identifiers(in: requests), ["apns-uuid"])
        let implicit = Message(id: "implicit", time: 100, event: "message", topic: "sequence-tests")
        XCTAssertEqual(SequenceRemoval(baseUrl: "https://sequence.invalid", topic: "sequence-tests", sequence: "implicit").identifiers(in: [request("implicit-apns", message: implicit)]), ["implicit-apns"])
    }

    func testSequenceClearRequestUsesPUTAndServerHeadersRejectsInvalidSequence() throws {
        let api = ApiService(credentialStore: credentialStore)
        XCTAssertTrue(credentialStore.setHTTPHeaders(["X-Test-Auth": "value"], baseUrl: "https://sequence.invalid"))
        let request = try XCTUnwrap(api.clearRequest(ClearRequest(baseUrl: "https://sequence.invalid/", topic: "sequence-tests", sequence: "job-123", user: BasicUser(username: "user", password: "pass"))))
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://sequence.invalid/sequence-tests/job-123/clear")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), BasicUser(username: "user", password: "pass").toHeader())
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Test-Auth"), "value")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(api.clearRequest(ClearRequest(baseUrl: "https://sequence.invalid", topic: "sequence-tests", sequence: "../evil", user: nil)))
    }

    func testSequenceClearForbiddenOldServerAndNetworkFailuresCompleteQuietly() {
        for status in [403, 404, 200] {
            let done = expectation(description: "clear status \(status)")
            ApiService.shared.clear(ClearRequest(baseUrl: "https://sequence.invalid", topic: "sequence-tests", sequence: "job", user: nil), session: StubURLProtocol.session(status: status, body: Data())) { done.fulfill() }
            wait(for: [done], timeout: 2)
        }
        let done = expectation(description: "offline clear")
        ApiService.shared.clear(ClearRequest(baseUrl: "https://sequence.invalid", topic: "sequence-tests", sequence: "job", user: nil), session: StubURLProtocol.session(failWith: URLError(.notConnectedToInternet))) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testSequenceEveryNotificationRegistersDismissCategory() {
        let content = UNMutableNotificationContent()
        let done = expectation(description: "category")
        DispatchQueue.global(qos: .userInitiated).async {
            content.modify(message: Message(id: "dismiss", time: 100, event: "message", topic: "sequence-tests"), baseUrl: "https://sequence.invalid")
            XCTAssertEqual(content.categoryIdentifier, UNMutableNotificationContent.categoryPrefix + "dismiss")
            UNUserNotificationCenter.current().getNotificationCategories { categories in
                XCTAssertTrue(categories.first { $0.identifier == content.categoryIdentifier }?.options.contains(.customDismissAction) == true)
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 2)
    }

    func testSequenceDelayedSameSecondUpdateAndControlRequestAuthoritativeOrder() throws {
        let sub = sequenceSubscription()
        let a = try sequenceEvent("a")
        let clear = try sequenceEvent("clear", "message_clear")
        let b = try sequenceEvent("b", body: "latest")
        _ = Store.shared.ingest(pushedMessage: b, baseUrl: sub.baseUrl!, topic: sub.topic!)
        for stale in [a, clear] {
            guard case .reconcile(let poll) = Store.shared.ingest(pushedMessage: stale, baseUrl: sub.baseUrl!, topic: sub.topic!) else {
                return XCTFail("ambiguous push must request ordered poll")
            }
            XCTAssertNil(poll.since)
            XCTAssertEqual(sequenceRows(sub).first?.id, "b")
            Store.shared.save(notificationsFromMessages: [a, clear, b], polledWith: poll)
            XCTAssertEqual(sequenceRows(sub).first?.id, "b")
            XCTAssertFalse(try XCTUnwrap(sequenceRows(sub).first).read)
            XCTAssertFalse(sub.sequenceReconcile)
        }
    }

    func testSequenceDelayedSameSecondPollDoesNotOverwriteLatestOrMoveCursor() throws {
        let sub = sequenceSubscription()
        let staleRequest = try XCTUnwrap(Store.shared.pollRequest(for: sub))
        Store.shared.save(notificationsFromMessages: [try sequenceEvent("b", body: "latest")], withSubscription: sub)
        Store.shared.save(notificationsFromMessages: [try sequenceEvent("a")], polledWith: staleRequest)
        XCTAssertEqual(sequenceRows(sub).first?.id, "b")
        XCTAssertEqual(sub.lastNotificationId, "b")
        XCTAssertTrue(sub.sequenceReconcile)
    }

    func testSequenceForegroundStoredCustomSequenceStillGetsFirstPushSound() throws {
        let sub = sequenceSubscription()
        let first = try sequenceEvent("first")
        Store.shared.save(notificationsFromMessages: [first], withSubscription: sub)
        sub.sequenceReconcile = true // another sequence's failed reconciliation cannot swallow this first push
        try Store.shared.context.save()
        guard case .stored(let delivered) = Store.shared.ingest(pushedMessage: first, baseUrl: sub.baseUrl!, topic: sub.topic!) else { return XCTFail("first push must present") }
        XCTAssertFalse(delivered.isUpdate)
        XCTAssertTrue(try XCTUnwrap(sequenceRows(sub).first).presented)
        guard case .stored(let repeated) = Store.shared.ingest(pushedMessage: first, baseUrl: sub.baseUrl!, topic: sub.topic!) else { return XCTFail("repeat may replace silently") }
        XCTAssertTrue(repeated.isUpdate)
    }

    func testSequenceControlRemovalSideEffectsOccurWithoutPublishing() throws {
        let sub = sequenceSubscription()
        Store.shared.save(notificationsFromMessages: [try sequenceEvent("original")], withSubscription: sub)
        var removals: [SequenceRemoval] = []
        Store.shared.notificationRemover = { removals.append($0) }
        Store.shared.clearPublisher = { _, _ in XCTFail("received controls cannot publish") }
        Store.shared.save(notificationsFromMessages: [try sequenceEvent("clear", "message_clear", time: 101), try sequenceEvent("delete", "message_delete", time: 102)], withSubscription: sub)
        XCTAssertEqual(removals.map(\.sequence), ["job", "job"])
        XCTAssertEqual(removals.map(\.throughTime), [101, 102])
    }

    func testSequenceStateUniquenessAcrossIndependentContexts() throws {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: Store.shared.context.persistentStoreCoordinator!.managedObjectModel)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sequence-race-\(UUID().uuidString).sqlite")
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        defer { try? coordinator.remove(store); try? FileManager.default.removeItem(at: url) }
        let contexts = (0..<2).map { _ -> NSManagedObjectContext in
            let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            context.mergePolicy = NSMergePolicy.mergeByPropertyStoreTrump
            return context
        }
        // Both transactions observe no state, just as separate app/NSE contexts can.
        for (i, context) in contexts.enumerated() {
            let state = NSEntityDescription.insertNewObject(forEntityName: "SequenceState", into: context)
            state.setValue("https://sequence.invalid/sequence-tests/job", forKey: "key")
            state.setValue("job", forKey: "sequenceID")
            state.setValue("event-\(i)", forKey: "eventID")
            state.setValue("message_clear", forKey: "event")
        }
        for context in contexts { try context.save() }
        let reader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        reader.persistentStoreCoordinator = coordinator
        XCTAssertEqual(try reader.count(for: NSFetchRequest<NSManagedObject>(entityName: "SequenceState")), 1)
    }

    func testSequenceModel5MigrationPreservesReadAndDefaultIdentity() throws {
        let oldURL = try XCTUnwrap(try compiledModelVersionURLs().first { $0.lastPathComponent == "Model 5.mom" })
        let oldModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: oldURL))
        // Generic objects avoid registering another generated entity description in this process.
        oldModel.entities.forEach { $0.managedObjectClassName = "NSManagedObject" }
        let current = Store.shared.context.persistentStoreCoordinator!.managedObjectModel
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sequence-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
        let oldStore = try oldCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let writer = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        writer.persistentStoreCoordinator = oldCoordinator
        let sub = NSEntityDescription.insertNewObject(forEntityName: "Subscription", into: writer)
        sub.setValue("https://sequence.invalid", forKey: "baseUrl")
        sub.setValue("sequence-tests", forKey: "topic")
        let row = NSEntityDescription.insertNewObject(forEntityName: "Notification", into: writer)
        row.setValue("old", forKey: "id")
        row.setValue("survives", forKey: "message")
        row.setValue(false, forKey: "read")
        row.setValue(sub, forKey: "subscription")
        try writer.save()
        try oldCoordinator.remove(oldStore)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: current)
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: [NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true])
        defer { try? coordinator.remove(store) }
        let reader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        reader.persistentStoreCoordinator = coordinator
        let rows = try reader.fetch(NSFetchRequest<NSManagedObject>(entityName: "Notification"))
        XCTAssertEqual(rows.first?.value(forKey: "message") as? String, "survives")
        XCTAssertEqual(rows.first?.value(forKey: "read") as? Bool, false)
        XCTAssertNil(rows.first?.value(forKey: "sequenceID"))
        XCTAssertEqual(rows.first?.value(forKey: "presented") as? Bool, false)
        XCTAssertEqual(try reader.count(for: NSFetchRequest<NSManagedObject>(entityName: "SequenceState")), 0)
    }

    func testSequenceUnrelatedMessageStillPresentsWhileReconciliationIsPending() throws {
        let sub = sequenceSubscription()
        Store.shared.save(notificationsFromMessages: [try sequenceEvent("original")], withSubscription: sub)
        _ = Store.shared.ingest(pushedMessage: try sequenceEvent("ambiguous", "message_clear"), baseUrl: sub.baseUrl!, topic: sub.topic!)
        XCTAssertTrue(sub.sequenceReconcile)
        guard case .stored(let message) = Store.shared.ingest(pushedMessage: try sequenceEvent("unrelated", sequence: "another"), baseUrl: sub.baseUrl!, topic: sub.topic!) else { return XCTFail("unrelated message must present") }
        XCTAssertEqual(message.id, "unrelated")
        XCTAssertFalse(message.isUpdate)
    }

    func testSequenceConcurrentDifferentVersionsCannotInsertTwoRows() throws {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: Store.shared.context.persistentStoreCoordinator!.managedObjectModel)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sequence-rows-\(UUID().uuidString).sqlite")
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        defer { try? coordinator.remove(store); try? FileManager.default.removeItem(at: url) }
        let contexts = (0..<2).map { _ -> NSManagedObjectContext in
            let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            context.mergePolicy = NSMergePolicy.mergeByPropertyStoreTrump
            return context
        }
        for (i, context) in contexts.enumerated() {
            let row = NSEntityDescription.insertNewObject(forEntityName: "Notification", into: context)
            row.setValue("event-\(i)", forKey: "id")
            row.setValue("version-\(i)", forKey: "message")
            row.setValue("https://sequence.invalid/sequence-tests/job", forKey: "sequenceKey")
        }
        for context in contexts { try context.save() }
        let reader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        reader.persistentStoreCoordinator = coordinator
        XCTAssertEqual(try reader.count(for: NSFetchRequest<NSManagedObject>(entityName: "Notification")), 1)
    }

    // MARK: Silent self-hosted clear/delete wake — independent regression gate

    private let instantHash = "20428e863f19a4a3570462569f64a29c74c0eeddfbc043faa37f3c81d53707fc"

    private func instantSubscription(baseUrl: String = "https://selfhost.invalid", topic: String = "instant") -> Subscription {
        let sub = Store.shared.saveSubscription(baseUrl: baseUrl, topic: topic)
        addTeardownBlock { Store.shared.delete(subscription: sub) }
        return sub
    }

    private func instantMessage(_ id: String, sequence: String, event: String = "message", topic: String = "instant", time: Int64 = 100) -> Message {
        Message(id: id, time: time, event: event, topic: topic, message: "trusted source content", sequenceID: sequence)
    }

    private func instantRows(_ sub: Subscription) -> [ntfy.Notification] {
        let request = ntfy.Notification.fetchRequest()
        request.predicate = NSPredicate(format: "subscription == %@", sub)
        return (try? Store.shared.context.fetch(request)) ?? []
    }

    private func instantWake(topic: String? = nil, event: String = "message_clear") -> [AnyHashable: Any] {
        ["id": "untrusted-id", "time": "9999999999", "event": event,
         "topic": topic ?? instantHash, "sequence_id": "job", "base_url": "https://attacker.invalid",
         "message": "never apply this payload"]
    }

    func testInstantWakeHashMatchesServerForwardPollRequestFixture() {
        // server/server.go forwardPollRequest: SHA256(bytes(baseURL + "/" + topic)), lowercase hex.
        XCTAssertEqual(topicHash(baseUrl: "https://selfhost.invalid", topic: "instant"), instantHash)
        XCTAssertEqual(firebaseTopic(baseUrl: "https://selfhost.invalid", topic: "instant"), instantHash)
        XCTAssertEqual(firebaseTopic(baseUrl: Config.appBaseUrl, topic: "instant"), "instant")
    }

    func testInstantReadBatchWaitsForActionsThenCoalescesOneWake() throws {
        let sub = instantSubscription()
        Store.shared.save(notificationsFromMessages: [instantMessage("a", sequence: "one"), instantMessage("b", sequence: "two"), instantMessage("c", sequence: "three")], withSubscription: sub)
        var sends: [ClearRequest] = []
        var callbacks: [(Bool) -> Void] = []
        var wakes: [String] = []
        Store.shared.clearPublisher = { sends.append($0); callbacks.append($1) }
        let woke = expectation(description: "one batch wake")
        Store.shared.wakePublisher = { topic, done in wakes.append(topic); done(); woke.fulfill() }
        Store.shared.setRead(true, forSubscription: sub)
        XCTAssertEqual(sends.count, 3)
        XCTAssertTrue(instantRows(sub).allSatisfy(\.read))
        XCTAssertTrue(wakes.isEmpty)
        callbacks[0](true)
        callbacks[1](false)
        XCTAssertTrue(wakes.isEmpty, "do not wake before source action batch finishes")
        callbacks[2](true)
        wait(for: [woke], timeout: 2)
        XCTAssertEqual(wakes, [instantHash])
        XCTAssertEqual(Set(sends.map(\.sequence)), ["one", "two", "three"])
    }

    func testInstantFailedReadBatchKeepsLocalReadWithoutWake() {
        let sub = instantSubscription()
        Store.shared.save(notificationsFromMessages: [instantMessage("a", sequence: "one"), instantMessage("b", sequence: "two")], withSubscription: sub)
        Store.shared.clearPublisher = { _, done in done(false) }
        let unexpected = expectation(description: "failed source actions cannot wake")
        unexpected.isInverted = true
        Store.shared.wakePublisher = { _, done in done(); unexpected.fulfill() }
        Store.shared.setRead(true, forSubscription: sub)
        wait(for: [unexpected], timeout: 0.05)
        XCTAssertTrue(instantRows(sub).allSatisfy(\.read))
    }

    func testInstantMixedTopicDeleteSelectionStaysLocalWithoutPublishingOrWake() {
        let selfhost = instantSubscription(topic: "local-selfhost")
        let direct = instantSubscription(baseUrl: Config.appBaseUrl, topic: "local-default")
        Store.shared.save(notificationsFromMessages: [instantMessage("local-self-a", sequence: "one", topic: "local-selfhost"), instantMessage("local-self-b", sequence: "two", topic: "local-selfhost")], withSubscription: selfhost)
        Store.shared.save(notificationsFromMessages: [instantMessage("local-direct-a", sequence: "one", topic: "local-default")], withSubscription: direct)
        var published: [ClearRequest] = []
        Store.shared.clearPublisher = { request, done in published.append(request); done(true) }
        let unexpected = expectation(description: "local mixed selection cannot wake another device")
        unexpected.isInverted = true
        Store.shared.wakePublisher = { _, done in done(); unexpected.fulfill() }
        Store.shared.delete(notifications: Set(instantRows(selfhost) + instantRows(direct)))
        wait(for: [unexpected], timeout: 0.05)
        XCTAssertTrue(instantRows(selfhost).isEmpty)
        XCTAssertTrue(instantRows(direct).isEmpty)
        XCTAssertTrue(published.isEmpty, "local selection deletion must neither clear nor delete server sequences")
    }

    func testInstantDefaultServerReadAndDeleteNeverPublishWake() throws {
        let sub = instantSubscription(baseUrl: Config.appBaseUrl)
        Store.shared.save(notificationsFromMessages: [instantMessage("default", sequence: "job")], withSubscription: sub)
        var clears = 0
        Store.shared.clearPublisher = { _, done in clears += 1; done(true) }
        let unexpected = expectation(description: "default server already sends direct controls")
        unexpected.isInverted = true
        Store.shared.wakePublisher = { _, done in done(); unexpected.fulfill() }
        Store.shared.setRead(true, forSubscription: sub)
        Store.shared.delete(notification: try XCTUnwrap(instantRows(sub).first))
        wait(for: [unexpected], timeout: 0.05)
        XCTAssertEqual(clears, 1, "deletion must not publish another clear")
        XCTAssertTrue(instantRows(sub).isEmpty)
    }

    func testInstantSingleSelectionAndAllDeletesStayLocalOnBothServerTypes() throws {
        var published: [ClearRequest] = []
        var removals: [SequenceRemoval] = []
        var expectedScopes: [String] = []
        Store.shared.notificationRemover = { removals.append($0) }
        Store.shared.clearPublisher = { request, done in published.append(request); done(true) }
        let unexpected = expectation(description: "all local delete APIs cannot wake")
        unexpected.isInverted = true
        var wakeCount = 0
        Store.shared.wakePublisher = { _, done in
            wakeCount += 1
            done()
            if wakeCount == 1 { unexpected.fulfill() }
        }
        for (server, baseUrl) in ["selfhost": "https://selfhost.invalid", "default": Config.appBaseUrl] {
            for count in 1...3 {
                let topic = "local-delete-\(server)-\(count)"
                let sub = instantSubscription(baseUrl: baseUrl, topic: topic)
                Store.shared.save(notificationsFromMessages: (0..<count).map { instantMessage("local-delete-\(server)-\(count)-\($0)", sequence: "job-\($0)", topic: topic) }, withSubscription: sub)
                let rows = instantRows(sub)
                expectedScopes += rows.map { topicUrl(baseUrl: baseUrl, topic: topic) + "/" + ($0.sequenceID ?? $0.id ?? "") }
                if count == 1 { Store.shared.delete(notification: try XCTUnwrap(rows.first)) }
                else if count == 2 { Store.shared.delete(notifications: Set(rows)) }
                else { Store.shared.delete(allNotificationsFor: sub) }
                XCTAssertTrue(instantRows(sub).isEmpty, "API \(count) must delete local \(server) rows")
            }
        }
        wait(for: [unexpected], timeout: 0.05)
        XCTAssertEqual(wakeCount, 0, "none of the local deletion APIs may wake another device")
        XCTAssertTrue(published.isEmpty, "message, selection and history deletion are all local-only")
        XCTAssertEqual(removals.count, 12, "retain same-device delivered removal for every locally deleted row")
        XCTAssertEqual(Set(removals.map { topicUrl(baseUrl: $0.baseUrl, topic: $0.topic) + "/" + $0.sequence }), Set(expectedScopes), "local removal must target only the deleted server/topic/sequences")
    }

    func testInstantLocalDeleteDoesNotAttemptEvenADeniedSourceWrite() throws {
        let sub = instantSubscription()
        Store.shared.save(notificationsFromMessages: [instantMessage("local-denied", sequence: "job")], withSubscription: sub)
        var attempts = 0
        Store.shared.clearPublisher = { _, done in attempts += 1; done(false) }
        let unexpected = expectation(description: "local delete never attempts wake")
        unexpected.isInverted = true
        Store.shared.wakePublisher = { _, done in done(); unexpected.fulfill() }
        Store.shared.delete(notification: try XCTUnwrap(instantRows(sub).first))
        wait(for: [unexpected], timeout: 0.05)
        XCTAssertTrue(instantRows(sub).isEmpty)
        XCTAssertEqual(attempts, 0, "read-only credentials must not even be consulted for local deletion")
    }

    func testInstantWakeRequestContainsOnlyHashFixedSequenceAndNoSourceCredentials() throws {
        let api = ApiService(credentialStore: credentialStore)
        XCTAssertTrue(credentialStore.setHTTPHeaders(["Authorization": "Bearer originating-secret", "CF-Access-Client-Secret": "origin-access", "X-Origin": "private"], baseUrl: "https://selfhost.invalid"))
        let request = try XCTUnwrap(api.wakeRequest(topic: instantHash))
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "\(normalizeBaseUrl(Config.appBaseUrl))/\(instantHash)/ntfy-sync/clear")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Origin"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Poll-ID"))
        XCTAssertNil(api.wakeRequest(topic: "../private"))
    }

    func testInstantClearActionUsesSourceCredentialsAndReportsHTTPFailure() {
        let api = ApiService(credentialStore: credentialStore)
        XCTAssertTrue(credentialStore.setHTTPHeaders(["CF-Access-Client-Secret": "origin-access"], baseUrl: "https://selfhost.invalid"))
        let clear = ClearRequest(baseUrl: "https://selfhost.invalid", topic: "instant", sequence: "job", user: BasicUser(username: "writer", password: "source-password"))
        RecordingURLProtocol.reset()
        let recorded = expectation(description: "source clear attempted")
        api.action(clear, session: recordingSession()) { success in XCTAssertFalse(success); recorded.fulfill() }
        wait(for: [recorded], timeout: 2)
        XCTAssertEqual(RecordingURLProtocol.requests.first?.httpMethod, "PUT")
        XCTAssertEqual(RecordingURLProtocol.requests.first?.url?.absoluteString, "https://selfhost.invalid/instant/job/clear")
        XCTAssertEqual(RecordingURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), clear.user?.toHeader())
        XCTAssertEqual(RecordingURLProtocol.requests.first?.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "origin-access")
        for status in [200, 403, 404, 500] {
            let done = expectation(description: "action status \(status)")
            api.action(clear, session: StubURLProtocol.session(status: status)) { success in XCTAssertEqual(success, status == 200); done.fulfill() }
            wait(for: [done], timeout: 2)
        }
    }

    func testInstantWakeNetworkFailureCompletesWithoutRetry() {
        RecordingURLProtocol.reset()
        let done = expectation(description: "wake failure completes")
        ApiService.shared.wake(topic: instantHash, session: recordingSession()) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(RecordingURLProtocol.requests.count, 1)
    }

    func testInstantSilentWakePollsOwnServerAndNeverAppliesPayload() {
        let sub = instantSubscription()
        Store.shared.save(notificationsFromMessages: [instantMessage("original", sequence: "job")], withSubscription: sub)
        var requests: [PollRequest] = []
        var manager = SubscriptionManager(store: Store.shared)
        manager.fetch = { request, done in requests.append(request); done([], nil) }
        let done = expectation(description: "trusted empty poll succeeds")
        XCTAssertTrue(manager.handleSilentWake(userInfo: instantWake()) { success in XCTAssertTrue(success); done.fulfill() })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.baseUrl, "https://selfhost.invalid")
        XCTAssertEqual(requests.first?.topicUrl, "https://selfhost.invalid/instant")
        XCTAssertFalse(instantRows(sub).first?.read ?? true, "forged wake clear cannot mark the real sequence read")
        XCTAssertEqual(instantRows(sub).first?.message, "trusted source content")
    }

    func testInstantSilentWakeAcceptsEventAndKnownHashWithoutMessageEnvelope() {
        _ = instantSubscription()
        var manager = SubscriptionManager(store: Store.shared)
        var fetched = 0
        manager.fetch = { _, done in fetched += 1; done([], nil) }
        let done = expectation(description: "metadata-only wake")
        XCTAssertTrue(manager.handleSilentWake(userInfo: ["event": "message_clear", "topic": instantHash]) { success in XCTAssertTrue(success); done.fulfill() })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(fetched, 1, "id, sequence and time are untrusted wake data, not required message input")
    }

    func testInstantSilentWakeAppliesTrustedClearDeleteUpdateWithoutSendLoop() throws {
        let sub = instantSubscription()
        Store.shared.saveUser(baseUrl: sub.baseUrl!, username: "reader", password: "source-password")
        let user = try XCTUnwrap(Store.shared.getUser(baseUrl: sub.baseUrl!))
        addTeardownBlock { Store.shared.delete(user: user) }
        Store.shared.save(notificationsFromMessages: [instantMessage("a", sequence: "read"), instantMessage("b", sequence: "delete"), instantMessage("c", sequence: "update")], withSubscription: sub)
        var removals: [SequenceRemoval] = []
        Store.shared.notificationRemover = { removals.append($0) }
        Store.shared.clearPublisher = { _, _ in XCTFail("received state cannot send clear") }
        Store.shared.wakePublisher = { _, _ in XCTFail("received state cannot send wake") }
        var manager = SubscriptionManager(store: Store.shared)
        manager.fetch = { request, done in
            XCTAssertEqual(request.user?.username, "reader")
            XCTAssertEqual(request.user?.password, "source-password")
            done([self.instantMessage("clear", sequence: "read", event: "message_clear", time: 101), self.instantMessage("delete", sequence: "delete", event: "message_delete", time: 102), self.instantMessage("updated", sequence: "update", time: 103)], nil)
        }
        let done = expectation(description: "trusted controls applied")
        XCTAssertTrue(manager.handleSilentWake(userInfo: instantWake(event: "message_delete")) { success in XCTAssertTrue(success); done.fulfill() })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(instantRows(sub).count, 2)
        XCTAssertTrue(try XCTUnwrap(instantRows(sub).first { $0.id == "a" }).read)
        XCTAssertEqual(instantRows(sub).first { $0.sequenceID == "update" }?.id, "updated")
        XCTAssertEqual(Set(removals.map(\.sequence)), ["read", "delete", "update"])
        XCTAssertEqual(sub.lastNotificationId, "updated")
    }

    func testInstantSilentWakeRejectsUnmatchedAndNonControlTopics() {
        _ = instantSubscription()
        _ = instantSubscription(baseUrl: Config.appBaseUrl, topic: "default")
        var manager = SubscriptionManager(store: Store.shared)
        manager.fetch = { _, _ in XCTFail("unmatched wake cannot fetch") }
        for payload in [instantWake(topic: "not-a-known-hash"), instantWake(topic: "default"), instantWake(event: "message"), instantWake(event: "poll_request")] {
            XCTAssertFalse(manager.handleSilentWake(userInfo: payload) { _ in XCTFail("unconsumed wake completion belongs to caller") })
        }
    }

    func testInstantSilentWakeFailureAndUnsubscribeCompleteFalseWithoutPayloadEffect() throws {
        for unsubscribe in [false, true] {
            let sub = instantSubscription()
            Store.shared.save(notificationsFromMessages: [instantMessage("original", sequence: "job")], withSubscription: sub)
            var manager = SubscriptionManager(store: Store.shared)
            manager.fetch = { _, done in
                if unsubscribe { Store.shared.delete(subscription: sub); done([], nil) }
                else { done(nil, URLError(.notConnectedToInternet)) }
            }
            let done = expectation(description: "wake failure completes \(unsubscribe)")
            XCTAssertTrue(manager.handleSilentWake(userInfo: instantWake()) { success in XCTAssertFalse(success); done.fulfill() })
            wait(for: [done], timeout: 2)
            if !unsubscribe { XCTAssertFalse(try XCTUnwrap(instantRows(sub).first).read); Store.shared.delete(subscription: sub) }
        }
    }

    func testInstantSilentWakePersistenceFailureReportsFalseAndRollsBackClear() throws {
        let sub = instantSubscription()
        Store.shared.save(notificationsFromMessages: [instantMessage("invalid-save-original", sequence: "job")], withSubscription: sub)
        // Real validation failure, not an injected success flag: required id/message are absent.
        let invalid = ntfy.Notification(context: Store.shared.context)
        XCTAssertNil(invalid.id)
        var manager = SubscriptionManager(store: Store.shared)
        manager.fetch = { _, done in done([self.instantMessage("invalid-save-clear", sequence: "job", event: "message_clear", time: 101)], nil) }
        let done = expectation(description: "failed persistence is not successful wake application")
        XCTAssertTrue(manager.handleSilentWake(userInfo: instantWake()) { success in XCTAssertFalse(success); done.fulfill() })
        wait(for: [done], timeout: 2)
        XCTAssertFalse(try XCTUnwrap(instantRows(sub).first { $0.id == "invalid-save-original" }).read)
        XCTAssertEqual(sub.lastNotificationId, "invalid-save-original")
    }

    func testInstantSilentWakeOverlapPerformsOneOrderedPollBeforeCompletion() throws {
        let sub = instantSubscription()
        let a = instantMessage("overlap-a", sequence: "job")
        let b = instantMessage("overlap-b", sequence: "job")
        let clear = instantMessage("overlap-clear", sequence: "job", event: "message_clear")
        Store.shared.save(notificationsFromMessages: [a], withSubscription: sub)
        var requests: [PollRequest] = []
        var manager = SubscriptionManager(store: Store.shared)
        manager.fetch = { request, done in
            requests.append(request)
            if requests.count == 1 {
                XCTAssertEqual(request.since, a.id)
                // Another trusted poll stores B while the wake's since=A request is in flight.
                Store.shared.save(notificationsFromMessages: [b], polledWith: request)
                done([clear], nil)
            } else {
                XCTAssertEqual(requests.count, 2, "at most one reconciliation within background budget")
                XCTAssertNil(request.since)
                done([a, b, clear], nil)
            }
        }
        Store.shared.clearPublisher = { _, _ in XCTFail("wake reconciliation cannot send clear") }
        Store.shared.wakePublisher = { _, _ in XCTFail("wake reconciliation cannot re-wake") }
        let done = expectation(description: "same-second control applied before wake completion")
        XCTAssertTrue(manager.handleSilentWake(userInfo: instantWake()) { success in
            XCTAssertTrue(success)
            XCTAssertTrue(self.instantRows(sub).first?.read ?? false)
            done.fulfill()
        })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(sub.lastNotificationId, clear.id)
        XCTAssertFalse(sub.sequenceReconcile)
    }

    // MARK: UNMutableNotificationContent.actionCategoryIdentifier — per-action-set banner category
    // Regression: the old code registered ONE global "ntfyActions" category and rewrote it for
    // every notification, so notifications delivered close together with different buttons
    // clobbered each other's banner actions. The fix keys the category off the action set, so
    // different sets get different (stable, cross-process) ids and can't overwrite each other.

    private func action(_ id: String, _ label: String) -> Action {
        return Action(id: id, action: "http", label: label, url: "https://ntfy.sh/x",
                      method: "POST", headers: nil, body: nil, clear: nil)
    }

    func testActionCategoryEmptyForNoActions() {
        XCTAssertEqual(UNMutableNotificationContent.actionCategoryIdentifier(for: []), "")
    }

    func testActionCategoryStableAndPrefixed() {
        let set = [action("0", "Approve"), action("1", "Reject")]
        let id = UNMutableNotificationContent.actionCategoryIdentifier(for: set)
        // Deterministic: recomputing the same set yields the same id (so two notifications
        // with identical buttons safely reuse one category), and it's namespaced.
        XCTAssertEqual(id, UNMutableNotificationContent.actionCategoryIdentifier(for: set))
        XCTAssertTrue(id.hasPrefix("ntfyActions."))
    }

    func testActionCategoryDistinctForDifferentSets() {
        // The core anti-clobber property: the old code returned the SAME "ntfyActions" for
        // both of these; the fix must return DIFFERENT ids.
        let approve = UNMutableNotificationContent.actionCategoryIdentifier(for: [action("0", "Approve")])
        let openUrl = UNMutableNotificationContent.actionCategoryIdentifier(for: [action("0", "Open")])
        XCTAssertNotEqual(approve, openUrl)
    }

    func testActionCategoryRespectsFieldBoundaries() {
        // Field/record delimiters must keep ["a","bc"] distinct from ["ab","c"] and from a
        // two-action set, so no accidental collisions across genuinely different button sets.
        let a = UNMutableNotificationContent.actionCategoryIdentifier(for: [action("a", "bc")])
        let b = UNMutableNotificationContent.actionCategoryIdentifier(for: [action("ab", "c")])
        let twoActions = UNMutableNotificationContent.actionCategoryIdentifier(for: [action("a", "b"), action("c", "d")])
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, twoActions)
    }

    func testActionCategoryIsOrderSensitive() {
        // iOS renders the buttons in order, so [Approve, Reject] is a different banner than
        // [Reject, Approve] and must get its own category.
        let ab = UNMutableNotificationContent.actionCategoryIdentifier(for: [action("0", "Approve"), action("1", "Reject")])
        let ba = UNMutableNotificationContent.actionCategoryIdentifier(for: [action("1", "Reject"), action("0", "Approve")])
        XCTAssertNotEqual(ab, ba)
    }

    func testActionCategoryCapsAtFourActions() {
        // iOS renders at most 4 actions, and the category id is derived from the same 4, so a
        // difference only in a 5th (never-rendered) action does not create a new category.
        let base = [action("0", "A"), action("1", "B"), action("2", "C"), action("3", "D")]
        let plusFifth = base + [action("4", "E")]
        XCTAssertEqual(
            UNMutableNotificationContent.actionCategoryIdentifier(for: base),
            UNMutableNotificationContent.actionCategoryIdentifier(for: plusFifth)
        )
    }

    // MARK: UNMutableNotificationContent.modify — priority → interruption level / relevance (critical alerts, ntfy #1235)
    //
    // These pin the flagship critical-alerts mapping (the 47-reaction #1235, implemented on main but
    // previously with zero unit coverage). The priority switch in NotificationContent.modify() *is* the
    // feature: p5 only elevates to `.critical` when the user opted in (getCriticalAlertsEnabled) AND iOS
    // granted the critical-alert entitlement (getCriticalAlertsAuthorized) — otherwise it must fall back
    // to `.timeSensitive`. A silent regression there (e.g. dropping the entitlement gate, or reordering
    // the relevanceScore ranking) is exactly the class of break a unit test catches before a device
    // round-trip. All inputs are deterministic under XCTest: Store.shared is in-memory (Store.swift:26)
    // and both critical-alerts flags are test-settable (Core Data preference + app-group UserDefaults).

    override func tearDown() {
        // Critical-alerts state is process-global (Store.shared + shared UserDefaults); reset so the
        // p5 tests can't leak enabled/authorized into each other regardless of execution order.
        Store.shared.saveCriticalAlertsEnabled(false)
        Store.saveCriticalAlertsAuthorized(false)
        Store.shared.credentialStore = KeychainCredentialStore.shared
        credentialStore = nil
        super.tearDown()
    }

    private func modifiedContent(priority: Int16?, title: String? = "T", baseUrl: String = "https://ntfy.sh",
                                 displayName: String? = nil, tags: [String]? = nil) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let msg = Message(id: "x", time: 1, event: "message", topic: "mytopic",
                          message: "body", title: title, priority: priority, tags: tags)
        content.modify(message: msg, baseUrl: baseUrl, displayName: displayName)
        return content
    }

    func testModifyPriority1IsPassiveAndLowestRelevance() {
        let c = modifiedContent(priority: 1)
        XCTAssertEqual(c.interruptionLevel, .passive)
        XCTAssertEqual(c.relevanceScore, 0, accuracy: 0.0001)
    }

    func testModifyPriority2IsPassiveAndLowRelevance() {
        let c = modifiedContent(priority: 2)
        XCTAssertEqual(c.interruptionLevel, .passive)
        XCTAssertEqual(c.relevanceScore, 0.25, accuracy: 0.0001)
    }

    func testModifyPriority4IsTimeSensitive() {
        let c = modifiedContent(priority: 4)
        XCTAssertEqual(c.interruptionLevel, .timeSensitive)
        XCTAssertEqual(c.relevanceScore, 0.75, accuracy: 0.0001)
    }

    func testModifyDefaultPriorityIsActive() {
        // Priority 3 (server default) and an absent priority both fall through to the `default` branch.
        for p: Int16? in [3, nil] {
            let c = modifiedContent(priority: p)
            XCTAssertEqual(c.interruptionLevel, .active, "priority \(String(describing: p)) should be .active")
            XCTAssertEqual(c.relevanceScore, 0.5, accuracy: 0.0001)
        }
    }

    func testModifyPriority5IsCriticalOnlyWhenEnabledAndAuthorized() {
        Store.shared.saveCriticalAlertsEnabled(true)
        Store.saveCriticalAlertsAuthorized(true)
        let c = modifiedContent(priority: 5)
        XCTAssertEqual(c.interruptionLevel, .critical, "p5 with opt-in + entitlement must be .critical")
        XCTAssertEqual(c.relevanceScore, 1, accuracy: 0.0001)
    }

    func testModifyPriority5FallsBackToTimeSensitiveWhenNotAuthorized() {
        // Opted in, but iOS has NOT granted the critical-alert entitlement → must never use .critical.
        Store.shared.saveCriticalAlertsEnabled(true)
        Store.saveCriticalAlertsAuthorized(false)
        let c = modifiedContent(priority: 5)
        XCTAssertEqual(c.interruptionLevel, .timeSensitive)
        XCTAssertEqual(c.relevanceScore, 1, accuracy: 0.0001)
    }

    func testModifyPriority5FallsBackToTimeSensitiveWhenNotEnabled() {
        // Entitlement granted, but the user hasn't opted in → must never use .critical.
        Store.shared.saveCriticalAlertsEnabled(false)
        Store.saveCriticalAlertsAuthorized(true)
        let c = modifiedContent(priority: 5)
        XCTAssertEqual(c.interruptionLevel, .timeSensitive)
        XCTAssertEqual(c.relevanceScore, 1, accuracy: 0.0001)
    }

    // MARK: UNMutableNotificationContent.modify — title falls back to the short topic URL

    func testModifyUsesTopicShortUrlWhenTitleMissing() {
        XCTAssertEqual(modifiedContent(priority: 3, title: "").title, "ntfy.sh/mytopic",
                       "an empty server title must fall back to the short topic URL")
        XCTAssertEqual(modifiedContent(priority: 3, title: nil).title, "ntfy.sh/mytopic",
                       "a missing server title must fall back to the short topic URL")
    }

    func testModifyKeepsServerTitleWhenPresent() {
        XCTAssertEqual(modifiedContent(priority: 3, title: "Header").title, "Header")
    }

    // MARK: UNMutableNotificationContent.modify — a renamed subscription must title its notifications
    //
    // A custom display name is a third display surface alongside the subscription list and the
    // notification list header. Titleless messages are the common case, so a renamed subscription
    // whose pushes still say "ntfy.sh/mytopic" looks broken exactly where the user looks most.
    // The Android client does honor it (Util.kt formatTitle -> displayName); iOS was the outlier.

    func testModifyUsesCustomDisplayNameWhenTitleMissing() {
        XCTAssertEqual(modifiedContent(priority: 3, title: "", displayName: "Home Server").title, "Home Server",
                       "an empty server title must fall back to the subscription's custom display name")
        XCTAssertEqual(modifiedContent(priority: 3, title: nil, displayName: "Home Server").title, "Home Server",
                       "a missing server title must fall back to the subscription's custom display name")
    }

    func testModifyPrefersServerTitleOverDisplayName() {
        // The server title is the more specific signal and still wins — renaming a subscription
        // must not start overwriting per-message titles.
        XCTAssertEqual(modifiedContent(priority: 3, title: "Header", displayName: "Home Server").title, "Header")
    }

    func testModifyFallsBackToShortUrlWithoutDisplayName() {
        // Control: passes before and after the fix. Pins that the change only affects the
        // renamed case and leaves an unnamed subscription's title exactly as it was.
        XCTAssertEqual(modifiedContent(priority: 3, title: "", displayName: nil).title, "ntfy.sh/mytopic")
        XCTAssertEqual(modifiedContent(priority: 3, title: nil, displayName: nil).title, "ntfy.sh/mytopic")
    }

    func testModifyIgnoresEmptyDisplayName() {
        // Defensive: Subscription.displayName() never returns empty, but a blank name must never
        // produce a blank notification title.
        XCTAssertEqual(modifiedContent(priority: 3, title: "", displayName: "").title, "ntfy.sh/mytopic")
        XCTAssertEqual(modifiedContent(priority: 3, title: "", displayName: "   ").title, "ntfy.sh/mytopic")
    }

    func testStoreLookupSuppliesCustomDisplayNameForNotificationTitle() {
        // Observes the exact expression both modify() call sites use (AppDelegate.showNotification and
        // the NSE's handleMessage), so the renamed-subscription -> notification-title chain is covered
        // end-to-end rather than only from modify()'s parameter inward.
        // NB: don't use Store.saveSubscription here — it does a DispatchQueue.main.sync and would
        // deadlock on XCTest's main thread. Building on the context directly is enough; Core Data
        // fetches include pending changes.
        let context = Store.shared.context
        let subscription = Subscription(context: context)
        subscription.baseUrl = "https://ntfy.sh"
        subscription.topic = "renamedtopic"
        subscription.customDisplayName = "Home Server"
        defer { context.delete(subscription) }

        let displayName = Store.shared.getSubscription(baseUrl: "https://ntfy.sh", topic: "renamedtopic")?.displayName()
        XCTAssertEqual(displayName, "Home Server", "a renamed subscription must resolve to its custom name")

        let content = UNMutableNotificationContent()
        let msg = Message(id: "y", time: 1, event: "message", topic: "renamedtopic", message: "body", title: nil)
        content.modify(message: msg, baseUrl: "https://ntfy.sh", displayName: displayName)
        XCTAssertEqual(content.title, "Home Server",
                       "a titleless message on a renamed subscription must be titled with the custom name")
    }

    func testStoreLookupFallsBackToShortUrlForUnnamedSubscription() {
        // Control: an un-renamed subscription keeps the existing short-URL title.
        let context = Store.shared.context
        let subscription = Subscription(context: context)
        subscription.baseUrl = "https://ntfy.sh"
        subscription.topic = "plaintopic"
        defer { context.delete(subscription) }

        let displayName = Store.shared.getSubscription(baseUrl: "https://ntfy.sh", topic: "plaintopic")?.displayName()
        XCTAssertEqual(displayName, "ntfy.sh/plaintopic")

        let content = UNMutableNotificationContent()
        let msg = Message(id: "z", time: 1, event: "message", topic: "plaintopic", message: "body", title: nil)
        content.modify(message: msg, baseUrl: "https://ntfy.sh", displayName: displayName)
        XCTAssertEqual(content.title, "ntfy.sh/plaintopic")
    }

    // MARK: shortDisplayName / shortUrlString — the subscription list's three-line row
    //
    // The list used to render displayName() as its headline, which falls back to "host/topic". With a
    // long self-hosted hostname the topic truncated off the end, so several topics on one server were
    // visually identical ("ntfy.<long-host>/build…" for both build-log and build-alerts). The row
    // now shows name / address / count on separate lines, and the name line must never carry the host.

    func testRowNameIsTheBareTopicWhenNotRenamed() {
        let context = Store.shared.context
        let subscription = Subscription(context: context)
        subscription.baseUrl = "https://ntfy.retired.example"
        subscription.topic = "basket-alerts"
        defer { context.delete(subscription) }

        XCTAssertEqual(subscription.shortDisplayName(), "basket-alerts",
                       "the row's name line must be the topic alone, so it can't be truncated away by the host")
        XCTAssertFalse(subscription.shortDisplayName().contains("/"),
                       "the name line must never contain the server address")
    }

    func testRowNameUsesTheCustomNameWhenRenamed() {
        let context = Store.shared.context
        let subscription = Subscription(context: context)
        subscription.baseUrl = "https://ntfy.sh"
        subscription.topic = "basket-alerts"
        subscription.customDisplayName = "Basket alerts"
        defer { context.delete(subscription) }

        XCTAssertEqual(subscription.shortDisplayName(), "Basket alerts")
    }

    func testRowNameFallsBackToTopicForAWhitespaceOnlyCustomName() {
        // Store trims on write, but a store written by an older build (or a future writer that
        // forgets) must not render a blank headline.
        let context = Store.shared.context
        let subscription = Subscription(context: context)
        subscription.baseUrl = "https://ntfy.sh"
        subscription.topic = "basket-alerts"
        subscription.customDisplayName = "   "
        defer { context.delete(subscription) }

        XCTAssertEqual(subscription.shortDisplayName(), "basket-alerts",
                       "a whitespace-only name must not produce an empty row headline")
    }

    func testRowAddressLineCarriesServerAndTopic() {
        let context = Store.shared.context
        let subscription = Subscription(context: context)
        subscription.baseUrl = "https://ntfy.retired.example/"
        subscription.topic = "basket-alerts"
        defer { context.delete(subscription) }

        XCTAssertEqual(subscription.shortUrlString(), "ntfy.retired.example/basket-alerts",
                       "the address line is the full topic URL, scheme stripped and no trailing slash")
        XCTAssertEqual(subscription.serverHost(), "ntfy.retired.example",
                       "VoiceOver announces only the server, since the name line already said the topic")
    }

    func testNotificationTitleFallbackIsUnaffectedByTheRowNameChange() {
        // CONTROL: displayName() titles notifications and deliberately keeps host/topic. This pins
        // that adding shortDisplayName() for the list did not quietly restyle every push title.
        let context = Store.shared.context
        let subscription = Subscription(context: context)
        subscription.baseUrl = "https://ntfy.sh"
        subscription.topic = "titletopic"
        defer { context.delete(subscription) }

        XCTAssertEqual(subscription.displayName(), "ntfy.sh/titletopic",
                       "notification titles must still carry the server")
        XCTAssertNotEqual(subscription.displayName(), subscription.shortDisplayName(),
                          "the two accessors are intentionally different for an unnamed subscription")
    }

    func testModifyRoutesEmojisToBodyWhenTitleMissingEvenWithDisplayName() {
        // Emoji routing must not change: with no server title the emojis prefix the BODY, and the
        // display name titles the notification cleanly (matches Android formatTitle/formatMessage).
        let c = modifiedContent(priority: 3, title: "", displayName: "Home Server", tags: ["+1"])
        XCTAssertEqual(c.title, "Home Server", "emojis must not be prefixed onto the display name")
        XCTAssertEqual(c.body, "👍 body")
    }

    // MARK: attachImageIfNeeded — Settings → "Download attachments" must gate the push/NSE path too
    //
    // Settings offers Never / Always / a size cap, and the in-app attachment path honors it in three
    // places (NotificationAttachmentController.swift:39, NotificationAttachmentSectionView.swift:296,343).
    // attachImageIfNeeded — the path BOTH the app (AppDelegate.swift:177) and the notification service
    // extension (ntfyNSE/NotificationService.swift:67) use — consulted the policy nowhere, so every image
    // arriving by push was fetched over the network and persisted regardless of the setting. These tests
    // assert on whether a request is even ATTEMPTED, which is the actual promise ("Never" = no traffic);
    // asserting only on the resulting body would pass either way, since a failed download also falls back
    // to the text summary.
    //
    // The `session` seam exists so this is provable offline: RecordingURLProtocol records each request and
    // fails it immediately, so no test here touches the network. The Always/under-cap cases are controls —
    // they must show a request ATTEMPTED, which is what makes the "no request" assertions meaningful.

    /// Records every request the download session starts, then fails it — so a test can prove a
    /// download was or wasn't attempted without any network access.
    private final class RecordingURLProtocol: URLProtocol {
        private static let lock = NSLock()
        private static var recorded: [URLRequest] = []

        static var requestedUrls: [URL] {
            lock.lock(); defer { lock.unlock() }
            return recorded.compactMap(\.url)
        }

        static var requests: [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }

        static func reset() {
            lock.lock(); defer { lock.unlock() }
            recorded = []
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            RecordingURLProtocol.lock.lock()
            RecordingURLProtocol.recorded.append(request)
            RecordingURLProtocol.lock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }

        override func stopLoading() {}
    }

    private func recordingSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// The auto-download preference is process-global (Core Data via Store.shared), so restore the
    /// default after each test rather than leaking a policy into whatever runs next.
    private func setAutoDownloadPolicy(_ maxSize: Int64) {
        Store.shared.saveAttachmentAutoDownloadMaxSize(maxSize)
        addTeardownBlock {
            Store.shared.saveAttachmentAutoDownloadMaxSize(Store.autoDownloadDefault)
        }
    }

    private func imageAttachmentMessage(size: Int64?, expires: Int64? = nil,
                                        type: String? = "image/png",
                                        url: String = "https://ntfy.sh/file/shot.png") -> Message {
        let attachment = MessageAttachment(name: "shot.png", type: type, size: size, expires: expires, url: url)
        return Message(id: "att1", time: 1, event: "message", topic: "mytopic",
                       message: "body", title: "T", attachment: attachment)
    }

    @discardableResult
    private func runAttachImage(_ message: Message) -> UNMutableNotificationContent {
        RecordingURLProtocol.reset()
        let content = UNMutableNotificationContent()
        let done = expectation(description: "attachImageIfNeeded calls its completion handler")
        content.attachImageIfNeeded(message: message, baseUrl: "https://ntfy.sh", user: nil, session: recordingSession()) {
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return content
    }

    func testAttachImageSkipsDownloadWhenPolicyIsNever() {
        setAutoDownloadPolicy(Store.autoDownloadNever)
        runAttachImage(imageAttachmentMessage(size: 1024))
        XCTAssertEqual(RecordingURLProtocol.requestedUrls, [],
                       "\"Never\" must mean no attachment traffic at all on the push path")
    }

    func testAttachImageSkipsDownloadWhenAttachmentExceedsMaxSize() {
        setAutoDownloadPolicy(Store.autoDownload100KB)
        runAttachImage(imageAttachmentMessage(size: 5 * 1024 * 1024))
        XCTAssertEqual(RecordingURLProtocol.requestedUrls, [],
                       "a 5 MB attachment must not be fetched under a 100 KB cap")
    }

    func testAttachImageSkipsDownloadForExpiredAttachment() {
        setAutoDownloadPolicy(Store.autoDownloadAlways)
        // Expired server-side: the bytes are gone, so the fetch can only waste a request and fail.
        let expired = imageAttachmentMessage(size: 1024, expires: 1)
        runAttachImage(expired)
        XCTAssertEqual(RecordingURLProtocol.requestedUrls, [],
                       "an expired attachment must not be fetched even under \"Always\"")
    }

    func testAttachImageDownloadsWhenPolicyIsAlways() {
        // CONTROL: proves the recorder sees a real attempt, so the "no request" assertions above mean something.
        setAutoDownloadPolicy(Store.autoDownloadAlways)
        runAttachImage(imageAttachmentMessage(size: 5 * 1024 * 1024))
        XCTAssertEqual(RecordingURLProtocol.requestedUrls.map(\.absoluteString),
                       ["https://ntfy.sh/file/shot.png"],
                       "\"Always\" must still fetch, regardless of size")
    }

    func testAutomaticAttachmentRequestInjectsServerHeaders() {
        setAutoDownloadPolicy(Store.autoDownloadAlways)
        storeTestHeaders()
        let authorization = BasicUser(username: "victim", password: "server-password")
        RecordingURLProtocol.reset()
        let content = UNMutableNotificationContent()
        let done = expectation(description: "automatic attachment request completes")
        content.attachImageIfNeeded(
            message: imageAttachmentMessage(size: 1024, url: headersBaseUrl + "/file/shot.png"),
            baseUrl: headersBaseUrl,
            user: authorization,
            credentialStore: credentialStore,
            session: recordingSession()
        ) {
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(RecordingURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"),
                       authorization.toHeader())
        XCTAssertEqual(RecordingURLProtocol.requests.first?.value(forHTTPHeaderField: "CF-Access-Client-Secret"),
                       "client-secret")
    }

    func testAutomaticAttachmentRequestOmitsAllCredentialsForExactAttackerPayload() throws {
        setAutoDownloadPolicy(Store.autoDownload100KB)
        storeTestHeaders()
        let payload = #"{"id":"attack1","time":1,"event":"message","topic":"public-topic","message":"look","attachment":{"name":"p.png","type":"image/png","url":"https://evil.example/p.png"}}"#
        let message = try JSONDecoder().decode(Message.self, from: Data(payload.utf8))
        XCTAssertNil(message.attachment?.size, "the attacker omitted size, so current policy attempts the download")

        RecordingURLProtocol.reset()
        let content = UNMutableNotificationContent()
        let done = expectation(description: "attacker-controlled automatic attachment request completes")
        content.attachImageIfNeeded(
            message: message,
            baseUrl: headersBaseUrl,
            user: BasicUser(username: "victim", password: "server-password"),
            credentialStore: credentialStore,
            session: recordingSession()
        ) {
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        let request = try XCTUnwrap(RecordingURLProtocol.requests.first,
                                    "the unknown-size payload should still attempt a download in this focused fix")
        XCTAssertEqual(request.url?.absoluteString, "https://evil.example/p.png")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"))
    }

    func testAttachImageDownloadsWhenAttachmentIsUnderMaxSize() {
        // CONTROL: the cap must gate on size, not disable downloading outright.
        setAutoDownloadPolicy(Store.autoDownload100KB)
        runAttachImage(imageAttachmentMessage(size: 50 * 1024))
        XCTAssertEqual(RecordingURLProtocol.requestedUrls.map(\.absoluteString),
                       ["https://ntfy.sh/file/shot.png"],
                       "a 50 KB attachment is under the 100 KB cap and must still be fetched")
    }

    func testAttachImageDownloadsWhenAttachmentSizeIsUnknown() {
        // CONTROL + documented parity gap: with no server-declared size, Store.shouldAutoDownloadAttachment
        // returns true, matching the in-app path. The in-app path then aborts mid-flight via
        // DownloadDelegate(maxSize:); this path has no such abort. Pinning it here so the gap is a
        // deliberate, visible decision rather than an accident.
        setAutoDownloadPolicy(Store.autoDownload100KB)
        runAttachImage(imageAttachmentMessage(size: nil))
        XCTAssertEqual(RecordingURLProtocol.requestedUrls.map(\.absoluteString),
                       ["https://ntfy.sh/file/shot.png"])
    }

    func testAttachImageNeverDownloadsNonImageAttachment() {
        // CONTROL: pre-existing guard, must survive the policy gate.
        setAutoDownloadPolicy(Store.autoDownloadAlways)
        runAttachImage(imageAttachmentMessage(size: 1024, type: "application/pdf",
                                              url: "https://ntfy.sh/file/doc.pdf"))
        XCTAssertEqual(RecordingURLProtocol.requestedUrls, [])
    }

    func testAttachImageStillSummarizesSkippedAttachmentInBody() {
        // Skipping the download must not silently drop the attachment from the notification: the user
        // still gets the name/size line, which is the same fallback a failed download produces.
        setAutoDownloadPolicy(Store.autoDownloadNever)
        let content = runAttachImage(imageAttachmentMessage(size: 1024))
        XCTAssertTrue(content.body.contains("Attachment: shot.png"),
                      "expected an attachment summary in the body, got: \(content.body)")
        XCTAssertEqual(content.attachments.count, 0)
    }

    // MARK: ApiService.checkAuth — must ALWAYS call its completion handler (ntfy #999)
    //
    // "Add subscription" sets `loading = true` and only ever clears it from inside this
    // completion handler (SubscriptionAddView.swift:153/171/174 and :180/194/197). So any
    // path through checkAuth that returns WITHOUT calling the handler leaves the Subscribe
    // button as a permanent spinner: no error, no dismissal, sheet unusable until force-quit.
    //
    // The reachable path is an unparseable URL. isAddViewValid() only requires the base URL
    // to match `^https?://.+`, and normalizeBaseUrl() trims only the OUTER whitespace — so an
    // INTERNAL space ("https://my server.com", a realistic paste/typo for a self-hosted
    // server) passes validation, then makes URL(string:) return nil inside checkAuth.
    //
    // These tests assert the handler FIRES (and fires exactly once). Asserting on the result
    // value alone would be a fake test: a never-invoked handler trivially never produces a
    // wrong value. The invalid-URL cases need no network at all — checkAuth returns before it
    // builds a session — and the rest use the `session` seam so nothing here touches the wire.

    /// Base URLs that pass `isAddViewValid()`'s `^https?://.+` but that `URL(string:)` rejects.
    private static let unparseableButValidatedBaseUrls = [
        "https://my server.com",   // internal space — the realistic typo/paste
        "https://bad|host.com",    // pipe is not a legal URL character
    ]

    private func checkAuthResult(baseUrl: String, topic: String = "mytopic",
                                 session: URLSession? = nil) -> AuthResult? {
        let done = expectation(description: "checkAuth calls its completion handler")
        var result: AuthResult?
        var callCount = 0
        ApiService.shared.checkAuth(baseUrl: baseUrl, topic: topic, user: nil, session: session) { r in
            callCount += 1
            result = r
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(callCount, 1, "completion handler must fire exactly once")
        return result
    }

    func testCheckAuthCallsHandlerForUnparseableUrl() {
        // RED before the fix: `guard let url = ... else { return }` drops the handler on the
        // floor, so the expectation times out and the Subscribe spinner would hang forever.
        for baseUrl in Self.unparseableButValidatedBaseUrls {
            guard let result = checkAuthResult(baseUrl: baseUrl) else {
                XCTFail("no result for \(baseUrl)")
                continue
            }
            guard case .Error = result else {
                return XCTFail("expected .Error for unparseable \(baseUrl), got \(result)")
            }
        }
    }

    func testUnparseableBaseUrlsGenuinelyPassAppValidation() {
        // Pins the premise of the bug: these really are reachable from the Add-subscription
        // sheet. If validation ever tightens, this fails and tells the next reader why.
        for baseUrl in Self.unparseableButValidatedBaseUrls {
            XCTAssertNotNil(baseUrl.range(of: "^https?://.+", options: .regularExpression),
                            "\(baseUrl) should pass isAddViewValid()'s regex")
            XCTAssertEqual(normalizeBaseUrl(baseUrl), baseUrl,
                           "normalizeBaseUrl must not rescue \(baseUrl)")
            XCTAssertNil(URL(string: topicAuthUrl(baseUrl: baseUrl, topic: "mytopic")),
                         "\(baseUrl) should be unparseable, otherwise this bug isn't reachable")
        }
    }

    func testCheckAuthCallsHandlerForBodylessSuccessResponse() {
        // Defence in depth for the missing terminal `else`: a 200 with no decodable body must
        // still resolve the handler rather than silently falling off the end of the chain.
        let result = checkAuthResult(baseUrl: "https://ntfy.sh",
                                     session: StubURLProtocol.session(status: 200, body: Data()))
        guard case .Error = result else {
            return XCTFail("expected .Error for a bodyless 200, got \(String(describing: result))")
        }
    }

    // Controls — these pass BOTH before and after the fix. They pin the exact axis under test
    // (handler-always-fires) and prove the change didn't alter normal auth outcomes.

    func testCheckAuthUnauthorizedControl() {
        let result = checkAuthResult(baseUrl: "https://ntfy.sh",
                                     session: StubURLProtocol.session(status: 401, body: Data()))
        guard case .Unauthorized = result else {
            return XCTFail("expected .Unauthorized for 401, got \(String(describing: result))")
        }
    }

    func testCheckAuthSuccessControl() {
        let body = #"{"success":true}"#.data(using: .utf8)!
        let result = checkAuthResult(baseUrl: "https://ntfy.sh",
                                     session: StubURLProtocol.session(status: 200, body: body))
        guard case .Success = result else {
            return XCTFail("expected .Success, got \(String(describing: result))")
        }
    }

    func testCheckAuthTransportErrorControl() {
        let result = checkAuthResult(baseUrl: "https://ntfy.sh",
                                     session: StubURLProtocol.session(failWith: URLError(.notConnectedToInternet)))
        guard case .Error = result else {
            return XCTFail("expected .Error for a transport failure, got \(String(describing: result))")
        }
    }

    /// Serves a canned HTTP response (or a canned failure) so auth outcomes are provable offline.
    private final class StubURLProtocol: URLProtocol {
        private static let lock = NSLock()
        private static var status = 200
        private static var body = Data()
        private static var failure: Error?

        static func session(status: Int = 200, body: Data = Data(), failWith error: Error? = nil) -> URLSession {
            lock.lock()
            self.status = status
            self.body = body
            self.failure = error
            lock.unlock()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [StubURLProtocol.self]
            return URLSession(configuration: config)
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            StubURLProtocol.lock.lock()
            let status = StubURLProtocol.status
            let body = StubURLProtocol.body
            let failure = StubURLProtocol.failure
            StubURLProtocol.lock.unlock()

            if let failure = failure {
                client?.urlProtocol(self, didFailWithError: failure)
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty {
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    // MARK: Store writes must be safe from ANY thread — Add-subscription runs them off-main
    //
    // `Store.context` is `container.viewContext`, i.e. an NSMainQueueConcurrencyType context, so every
    // fetch/insert/save against it must happen on the main queue. `SubscriptionAddView` violated that:
    // its `checkAuth` completion runs on a URLSession delegate queue and it then hopped further onto
    // `DispatchQueue.global(qos: .userInitiated)` before calling `store.saveUser` and
    // `subscriptionManager.subscribe` (-> `store.saveSubscription`). Core Data misuse like that is
    // silent-until-it-isn't (corruption / `__Multithreading_Violation_AllThatIsLeftToUsIsHonor__`),
    // so these tests pin the *contract* rather than one crash: a Store write must complete and persist
    // whichever queue calls it, main included.
    //
    // TWO of the four tests below are red before the fix, for two DIFFERENT reasons — the old
    // `saveSubscription` did the `Subscription(context:)` insert on the caller's thread and wrapped only
    // `try? context.save()` in `DispatchQueue.main.sync`:
    //   * called from MAIN, `main.sync`-from-main deadlocks   -> testSaveSubscriptionIsSafeToCallFromTheMainThread
    //   * called from a BACKGROUND queue, the row silently does not persist (the insert landed on the
    //     wrong queue and `try?` swallowed the failure) -> testSaveSubscriptionFromABackgroundQueuePersists
    // The second one is the user-visible half: the background queue is exactly what production used, so
    // "I added a topic and it didn't stick" was reachable. It was originally written expecting to be a
    // control and it failed — recorded here rather than quietly relabelled.
    //
    // The two saveUser tests ARE genuine controls: they pass on both sides. saveUser had no `main.sync`
    // and its insert+save were already on one thread, so it was an unsound-but-not-yet-failing threading
    // violation. They pin that this change is about queue affinity without regressing persistence.
    //
    // NB on the red signal: a `main.sync`-from-main deadlock HANGS rather than fails, so the red run was
    // taken with `-default-test-execution-time-allowance 30`; the hang surfaced as "Restarting after
    // unexpected exit, crash, or test timeout". Keep that flag in mind if this test stops returning.

    private func deleteAfterTest(_ object: NSManagedObject) {
        addTeardownBlock {
            Store.shared.context.performAndWait {
                Store.shared.context.delete(object)
                try? Store.shared.context.save()
            }
        }
    }

    func testSaveSubscriptionIsSafeToCallFromTheMainThread() {
        // RED before the fix: DispatchQueue.main.sync from the main thread never returns.
        XCTAssertTrue(Thread.isMainThread, "premise: XCTest runs test methods on the main thread")

        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: "mainqueuetopic")
        deleteAfterTest(subscription)

        XCTAssertEqual(
            Store.shared.getSubscription(baseUrl: "https://ntfy.sh", topic: "mainqueuetopic")?.topic,
            "mainqueuetopic",
            "saveSubscription must return and persist when called on the context's own queue"
        )
    }

    // QoS NOTE (2026-08-30). Every test in this group dispatches at `.userInitiated`, NOT
    // `.background`, and that is deliberate — do not "restore" it.
    //
    // What these tests pin is that Store's methods are safe when called OFF THE MAIN QUEUE. The QoS
    // class was never the property under test. `.background` is the one QoS macOS throttles hardest,
    // and on a loaded CI runner the dispatched block simply never receives a thread: three
    // /usr/bin/sample captures of a live hang showed ZERO background-qos threads in the process,
    // ZERO ntfy frames and ZERO CoreData frames, with the main thread parked in XCTWaiter. The work
    // had not started, so nothing was deadlocked — it was starved.
    //
    // That produced a bimodal failure that looks exactly like a deadlock: these pass in
    // 0.007-0.473s or consume their entire 5s/10s timeout, with nothing in between. It cost two
    // wrong diagnoses (a Core Data model leak, then "the runner is slow") before the stacks settled
    // it. The real NSE never uses `.background` either, so `.userInitiated` is also the more
    // faithful simulation of the push path these tests exist to model.
    func testSaveSubscriptionFromABackgroundQueuePersists() {
        // CONTROL: passes on both sides. Pins that the fix did not break the queue-hopping path that
        // production actually used, i.e. the change is about reentrancy, not about persistence.
        let done = expectation(description: "saveSubscription returns off-main")
        var saved: Subscription?
        DispatchQueue.global(qos: .userInitiated).async {
            let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: "bgqueuetopic")
            DispatchQueue.main.async {
                saved = subscription
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)

        guard let saved else { return XCTFail("saveSubscription never returned from a background queue") }
        deleteAfterTest(saved)
        XCTAssertEqual(
            Store.shared.getSubscription(baseUrl: "https://ntfy.sh", topic: "bgqueuetopic")?.topic,
            "bgqueuetopic",
            "saveSubscription must still persist when called off the main queue"
        )
    }

    func testPreferenceReadsResolveSafelyFromABackgroundQueue() {
        // RED before the fix: getCriticalAlertsEnabled / getAttachmentAutoDownloadMaxSize /
        // getDefaultBaseUrl fetched the main-queue viewContext on the *caller's* queue and then read
        // a property off the returned managed object. That is exactly what the push path does —
        // NotificationContent.modify asks for the critical-alerts flag on the NSE's delivery queue,
        // and attachImageIfNeeded asks for the auto-download policy on a URLSession completion queue
        // during the `~poll` wakeup. The Test action runs with -com.apple.CoreData.ConcurrencyDebug 1,
        // so an off-queue access traps the runner rather than failing politely.
        Store.shared.saveCriticalAlertsEnabled(true)
        // Explicit: the attachment tests share this store and leave their own policy behind.
        Store.shared.saveAttachmentAutoDownloadMaxSize(Store.autoDownload500KB)

        let done = expectation(description: "preferences resolve off the context queue")
        var enabled: Bool?
        var maxSize: Int64?
        var defaultBaseUrl: String?
        DispatchQueue.global(qos: .userInitiated).async {
            enabled = Store.shared.getCriticalAlertsEnabled()
            maxSize = Store.shared.getAttachmentAutoDownloadMaxSize()
            defaultBaseUrl = Store.shared.getDefaultBaseUrl()
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        XCTAssertEqual(enabled, true, "the push path must see the stored critical-alerts preference")
        XCTAssertEqual(maxSize, Store.autoDownload500KB)
        XCTAssertFalse(defaultBaseUrl?.isEmpty ?? true)
    }

    func testSaveUserFromABackgroundQueuePersists() {
        // CONTROL: passes on both sides. saveUser had no main.sync, so it never hung — it simply did
        // fetch/insert/save on whatever thread called it. This is the SubscriptionAddView:187 path.
        let done = expectation(description: "saveUser returns off-main")
        DispatchQueue.global(qos: .userInitiated).async {
            Store.shared.saveUser(baseUrl: "https://ntfy.example.com", username: "bguser", password: "pw")
            DispatchQueue.main.async { done.fulfill() }
        }
        wait(for: [done], timeout: 5)

        guard let user = Store.shared.getUser(baseUrl: "https://ntfy.example.com") else {
            return XCTFail("saveUser did not persist from a background queue")
        }
        deleteAfterTest(user)
        XCTAssertEqual(user.username, "bguser")
    }

    func testSaveUserFromTheMainThreadPersists() {
        // CONTROL: passes on both sides. This is the SettingsView:46 path, which was already on main.
        Store.shared.saveUser(baseUrl: "https://ntfy.main.example.com", username: "mainuser", password: "pw")

        guard let user = Store.shared.getUser(baseUrl: "https://ntfy.main.example.com") else {
            return XCTFail("saveUser did not persist from the main thread")
        }
        deleteAfterTest(user)
        XCTAssertEqual(user.username, "mainuser")
    }

    // MARK: Store READS must be safe from the push path's background queue — display-name / user resolution
    //
    // The read-side sibling of the block above. The NSE's handleMessage and AppDelegate.showNotification
    // both resolve a subscription's display name (and the Basic-auth user) before building the notification,
    // and both run OFF the main queue — handleMessage on the extension's queue, showNotification inside a
    // URLSession poll completion (ApiService.newSession sets no delegate queue). PR #20 wrote the display
    // name as getSubscription(...)?.displayName(): that fetches a viewContext-owned managed object off the
    // context's queue AND reads its properties there. getBasicUser already hopped; the display-name read
    // did not. subscriptionDisplayName(baseUrl:topic:) does the fetch and the displayName() extraction
    // inside context.performAndWait and returns a String, so it is safe from any queue.
    //
    // RED before the fix: with -com.apple.CoreData.ConcurrencyDebug 1 (this scheme's Test action) the
    // off-queue fetch traps (__Multithreading_Violation_AllThatIsLeftToUsIsHonor__), surfacing as
    // "Restarting after unexpected exit, crash, or test timeout" (same red signal as the write tests above).
    // The getBasicUser test is a genuine CONTROL: it already hopped, so it is green on both sides — it pins
    // the axis as queue affinity (not value) and covers the accessor showNotification switches to in place
    // of getUser(...)?.toBasicUser().

    func testSubscriptionDisplayNameResolvesSafelyFromABackgroundQueue() {
        let context = Store.shared.context
        let subscription = Subscription(context: context)
        subscription.baseUrl = "https://ntfy.sh"
        subscription.topic = "offmaintopic"
        subscription.customDisplayName = "Home Server"
        deleteAfterTest(subscription)

        let done = expectation(description: "subscriptionDisplayName returns off the context queue")
        var resolved: String?
        DispatchQueue.global(qos: .userInitiated).async {
            resolved = Store.shared.subscriptionDisplayName(baseUrl: "https://ntfy.sh", topic: "offmaintopic")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(resolved, "Home Server",
                       "a renamed subscription must resolve to its custom name from the push path's background queue")
    }

    func testGetBasicUserResolvesSafelyFromABackgroundQueue() {
        // CONTROL: getBasicUser already wraps its fetch + toBasicUser() in performAndWait and returns a
        // value, so it is green on both sides. Covers the accessor AppDelegate.showNotification switches to.
        Store.shared.saveUser(baseUrl: "https://ntfy.offmain.example.com", username: "offmainuser", password: "pw")
        if let user = Store.shared.getUser(baseUrl: "https://ntfy.offmain.example.com") {
            deleteAfterTest(user)
        }

        let done = expectation(description: "getBasicUser returns off the context queue")
        var resolved: BasicUser?
        DispatchQueue.global(qos: .userInitiated).async {
            resolved = Store.shared.getBasicUser(baseUrl: "https://ntfy.offmain.example.com")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(resolved?.username, "offmainuser",
                       "getBasicUser must resolve the Basic-auth user from a background queue without tripping the concurrency guard")
    }

    // MARK: A poll must report only NEWLY-STORED messages — repeat alerts (ntfy #1111 "ghost messages")
    //
    // `Store.saveNotifications` already computes the answer: it fetches the existing rows for the
    // incoming ids and inserts only `messages.filter { !existingIDs.contains($0.id) }`. But
    // `save(notificationsFromMessages:)` returned Void, so `SubscriptionManager.poll` handed its
    // completion handler the RAW server response, and `AppDelegate.showNotificationsSequentially`
    // (the background `~poll` wakeup, AppDelegate:140) posted one local notification per element of
    // that raw list. The store knew which messages were new; the notification layer never asked.
    //
    // The overlap is reachable in production because `since` is read per-request: `ApiService.poll`
    // builds `?poll=1&since=\(subscription.lastNotificationId ?? "all")` at request time, and four
    // call sites can have a poll in flight simultaneously (AppDelegate:134 background wakeup,
    // NotificationListView:40 onAppear, :256 after publish, SubscriptionListView:88). Two overlapping
    // polls therefore compute the SAME `since`, receive the SAME messages, and the second inserts
    // nothing — yet still re-notifies for every message. Because the banner is added with
    // `UNNotificationRequest(identifier: message.id, ...)`, iOS REPLACES the delivered notification
    // rather than stacking it, so the symptom is a repeated alert (banner + sound) for a message the
    // user already saw, not a duplicated row. `didReceiveNewData` (AppDelegate:136) was wrong for the
    // same reason: an all-duplicate poll reported `.newData` and kept spending the refresh budget.
    //
    // RED technique (per the ledger): the return value was added FIRST returning `messages`
    // unfiltered — reproducing today's behavior exactly — so the two tests below fail BEHAVIORALLY
    // rather than failing to compile. The two controls pass on both sides and pin the axis: this
    // change is about what the poll REPORTS, not about what it stores.

    private func deleteNotificationsAfterTest(ids: [String]) {
        addTeardownBlock {
            Store.shared.context.performAndWait {
                let request = Notification.fetchRequest()
                request.predicate = NSPredicate(format: "id IN %@", ids)
                for object in (try? Store.shared.context.fetch(request)) ?? [] {
                    Store.shared.context.delete(object)
                }
                try? Store.shared.context.save()
            }
        }
    }

    private func pollMessage(_ id: String, topic: String) -> Message {
        Message(id: id, time: 1, event: "message", topic: topic, message: "body-\(id)", title: nil)
    }

    func testASecondPollOfTheSameMessagesReportsNothingNew() {
        // RED before the fix: returned both messages again, so the background wakeup re-alerted both.
        let topic = "polldedupe-repeat"
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: topic)
        deleteAfterTest(subscription)
        let messages = [pollMessage("dedupe-a1", topic: topic), pollMessage("dedupe-a2", topic: topic)]
        deleteNotificationsAfterTest(ids: messages.map(\.id))

        let first = Store.shared.save(notificationsFromMessages: messages, withSubscription: subscription)
        XCTAssertEqual(first.map(\.id), ["dedupe-a1", "dedupe-a2"], "premise: a first poll reports both messages")

        let second = Store.shared.save(notificationsFromMessages: messages, withSubscription: subscription)
        XCTAssertEqual(second.map(\.id), [], "a re-poll of already-stored messages must report nothing to notify about")
    }

    func testAnOverlappingPollReportsOnlyTheUnseenMessages() {
        // RED before the fix: reported the already-seen message alongside the genuinely new one.
        let topic = "polldedupe-overlap"
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: topic)
        deleteAfterTest(subscription)
        let seen = pollMessage("dedupe-b1", topic: topic)
        let fresh = pollMessage("dedupe-b2", topic: topic)
        deleteNotificationsAfterTest(ids: [seen.id, fresh.id])

        _ = Store.shared.save(notificationsFromMessages: [seen], withSubscription: subscription)
        let overlapping = Store.shared.save(notificationsFromMessages: [seen, fresh], withSubscription: subscription)

        XCTAssertEqual(
            overlapping.map(\.id), ["dedupe-b2"],
            "a poll whose window overlaps stored messages must report only the ones it actually stored"
        )
    }

    func testAFirstPollReportsEveryMessage() {
        // CONTROL: passes on both sides. Pins that the filter does not over-reject — a genuine first
        // poll must still notify for everything, which is the whole point of the background wakeup.
        let topic = "polldedupe-first"
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: topic)
        deleteAfterTest(subscription)
        let messages = [pollMessage("dedupe-c1", topic: topic), pollMessage("dedupe-c2", topic: topic)]
        deleteNotificationsAfterTest(ids: messages.map(\.id))

        let reported = Store.shared.save(notificationsFromMessages: messages, withSubscription: subscription)
        XCTAssertEqual(reported.map(\.id), ["dedupe-c1", "dedupe-c2"])
    }

    func testADeduplicatedPollStillAdvancesLastNotificationId() {
        // CONTROL: passes on both sides. `saveNotifications`' early-return branch advances
        // `lastNotificationId` even when it inserts nothing, so the next poll's `since` moves forward.
        // Reporting fewer messages must not regress that — otherwise the same window is re-fetched
        // forever and the repeat-alert bug comes back by a different route.
        let topic = "polldedupe-since"
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: topic)
        deleteAfterTest(subscription)
        let messages = [pollMessage("dedupe-d1", topic: topic), pollMessage("dedupe-d2", topic: topic)]
        deleteNotificationsAfterTest(ids: messages.map(\.id))

        _ = Store.shared.save(notificationsFromMessages: messages, withSubscription: subscription)
        _ = Store.shared.save(notificationsFromMessages: messages, withSubscription: subscription)

        XCTAssertEqual(
            subscription.lastNotificationId, "dedupe-d2",
            "an all-duplicate poll must still advance the since-cursor to the last message it saw"
        )
    }

    // MARK: The poll cursor never moves backward (PR #83 review, finding 4)
    // Polls can finish out of order. A late response from an older `since` ends on an older message;
    // adopting its last id as the cursor re-fetches a window the app already has.

    func testALateOlderPollResponseDoesNotMoveTheCursorBack() {
        // RED before the fix: the all-duplicate branch set the cursor to "cursor-a1".
        let topic = "pollcursor-late"
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: topic)
        deleteAfterTest(subscription)
        let older = Message(id: "cursor-a1", time: 100, event: "message", topic: topic, message: "old", title: nil)
        let newer = Message(id: "cursor-a2", time: 200, event: "message", topic: topic, message: "new", title: nil)
        deleteNotificationsAfterTest(ids: [older.id, newer.id])

        _ = Store.shared.save(notificationsFromMessages: [older, newer], withSubscription: subscription)
        XCTAssertEqual(subscription.lastNotificationId, "cursor-a2", "premise")
        _ = Store.shared.save(notificationsFromMessages: [older], withSubscription: subscription)

        XCTAssertEqual(subscription.lastNotificationId, "cursor-a2",
                       "a late response ending on an older message must not move the cursor back")
    }

    func testANewlyStoredButOlderMessageDoesNotMoveTheCursorBack() {
        // RED before the fix: the insert branch set the cursor to the batch's last (older) message.
        let topic = "pollcursor-insert"
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: topic)
        deleteAfterTest(subscription)
        let newer = Message(id: "cursor-b2", time: 200, event: "message", topic: topic, message: "new", title: nil)
        let older = Message(id: "cursor-b1", time: 100, event: "message", topic: topic, message: "old", title: nil)
        deleteNotificationsAfterTest(ids: [older.id, newer.id])

        _ = Store.shared.save(notificationsFromMessages: [newer], withSubscription: subscription)
        let stored = Store.shared.save(notificationsFromMessages: [older], withSubscription: subscription)

        XCTAssertEqual(stored.map(\.id), ["cursor-b1"], "premise: the older message is still stored")
        XCTAssertEqual(subscription.lastNotificationId, "cursor-b2")
    }

    func testTheCursorStillMovesForward() {
        // CONTROL: passes on both sides.
        let topic = "pollcursor-forward"
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: topic)
        deleteAfterTest(subscription)
        let first = Message(id: "cursor-c1", time: 100, event: "message", topic: topic, message: "1", title: nil)
        let second = Message(id: "cursor-c2", time: 200, event: "message", topic: topic, message: "2", title: nil)
        deleteNotificationsAfterTest(ids: [first.id, second.id])

        _ = Store.shared.save(notificationsFromMessages: [first], withSubscription: subscription)
        _ = Store.shared.save(notificationsFromMessages: [second], withSubscription: subscription)
        XCTAssertEqual(subscription.lastNotificationId, "cursor-c2")
    }

    // MARK: Same-second cursor ordering, and responses for deleted topics (PR #83 review round 2)

    func testALateSameSecondResponseDoesNotMoveTheCursorBack() {
        // RED with the round-1 rule (`current.time > candidate.time`): B and C share a second, so a late
        // response ending on B replaced C.
        let topic = "pollcursor-samesecond"
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: topic)
        deleteAfterTest(subscription)
        let b = Message(id: "cursor-d1", time: 300, event: "message", topic: topic, message: "B", title: nil)
        let c = Message(id: "cursor-d2", time: 300, event: "message", topic: topic, message: "C", title: nil)
        deleteNotificationsAfterTest(ids: [b.id, c.id])

        _ = Store.shared.save(notificationsFromMessages: [c], withSubscription: subscription) // the push of C
        XCTAssertEqual(subscription.lastNotificationId, "cursor-d2", "premise")
        _ = Store.shared.save(notificationsFromMessages: [b], withSubscription: subscription) // the late poll

        XCTAssertEqual(subscription.lastNotificationId, "cursor-d2",
                       "a same-second message can't be ordered by time, so it must not replace the cursor")
    }

    func testAPollFromTheCurrentCursorStillAdvancesWithinTheSameSecond() {
        // A poll that asked `since=` the current cursor only returns newer messages, so its last one is
        // the new cursor even in the same second. RED if that exception is removed: the cursor would
        // stay put and every poll would re-fetch the same message.
        let topic = "pollcursor-samesecond-forward"
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: topic)
        deleteAfterTest(subscription)
        let c = Message(id: "cursor-e1", time: 400, event: "message", topic: topic, message: "C", title: nil)
        let d = Message(id: "cursor-e2", time: 400, event: "message", topic: topic, message: "D", title: nil)
        deleteNotificationsAfterTest(ids: [c.id, d.id])

        _ = Store.shared.save(notificationsFromMessages: [c], withSubscription: subscription)
        guard let request = Store.shared.pollRequest(for: subscription) else { return XCTFail("no request") }
        XCTAssertEqual(request.since, "cursor-e1", "premise: the request asks from the current cursor")
        let stored = Store.shared.save(notificationsFromMessages: [d], polledWith: request)

        XCTAssertEqual(stored?.map(\.id), ["cursor-e2"])
        XCTAssertEqual(subscription.lastNotificationId, "cursor-e2")
    }

    func testAPollFromTheCurrentCursorCannotMoveItToAnOlderMessage() {
        // Round 3, finding 2. RED at 6bef17d: a matching `since` bypassed the time comparison, and
        // ntfy answers an unknown `since` id with its cached history, which can end on an older message.
        let topic = "pollcursor-since-older"
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: topic)
        deleteAfterTest(subscription)
        let c = Message(id: "cursor-f2", time: 700, event: "message", topic: topic, message: "C", title: nil)
        let b = Message(id: "cursor-f1", time: 650, event: "message", topic: topic, message: "B", title: nil)
        deleteNotificationsAfterTest(ids: [b.id, c.id])

        _ = Store.shared.save(notificationsFromMessages: [c], withSubscription: subscription)
        guard let request = Store.shared.pollRequest(for: subscription) else { return XCTFail("no request") }
        XCTAssertEqual(request.since, "cursor-f2", "premise: the poll asked from the current cursor")
        _ = Store.shared.save(notificationsFromMessages: [b], polledWith: request)

        XCTAssertEqual(subscription.lastNotificationId, "cursor-f2", "a strictly older message never becomes the cursor")
    }

    func testAPollResponseForAnUnsubscribedTopicIsDropped() {
        // Round 2 finding 1: the topic is unsubscribed while its poll is out. Before, the queued
        // follow-up force-unwrapped the deleted subscription's base URL; now the response is saved
        // against the object ID, which no longer resolves, so nothing is stored and nothing crashes.
        let topic = "poll-unsubscribed-meanwhile"
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: topic)
        guard let request = Store.shared.pollRequest(for: subscription) else { return XCTFail("no request") }
        XCTAssertTrue(Store.shared.delete(subscription: subscription), "premise")
        let late = Message(id: "poll-orphan-1", time: 500, event: "message", topic: topic, message: "late", title: nil)
        deleteNotificationsAfterTest(ids: [late.id])

        XCTAssertNil(Store.shared.save(notificationsFromMessages: [late], polledWith: request))
        XCTAssertNil(Store.shared.pollRequest(for: subscription), "a deleted subscription can't start a poll")
        var rows = -1
        Store.shared.context.performAndWait {
            let fetch = Notification.fetchRequest()
            fetch.predicate = NSPredicate(format: "id == %@", late.id)
            rows = (try? Store.shared.context.count(for: fetch)) ?? -1
        }
        XCTAssertEqual(rows, 0, "the late response must not be stored")
    }

    // MARK: A deleted notification must leave the published list at once — swipe-delete crash (ntfy #1058)
    //
    // `NotificationListView:183` renders `ForEach(notificationsModel.notifications, id: \.self)` and each
    // `NotificationRowView` binds its row to `@ObservedObject var notification: Notification`. Swiping a row
    // calls `Store.delete(notification:)`, which deletes AND saves inside `context.performAndWait`, so the
    // managed object is invalid the moment that call returns. But `NotificationsObservable`
    // republished through `DispatchQueue.main.async`, so for one full runloop turn `notifications` still
    // held the dead object while Core Data's save had already told SwiftUI that the row's `@ObservedObject`
    // changed. The row body is then re-evaluated against an object whose row is gone — `shortDateTime()`,
    // `priority`, `formatTitle()` and `renderedMessageAttributedString()` all fault — and the process dies
    // with no alert, which is exactly how ntfy #1058 puts it: "App simply disappears with no error message".
    //
    // This also explains the two qualifiers in that report. It needs MORE THAN ONE message because a
    // surviving sibling row is what keeps the list rendering through the deletion, and "clear all" is safe
    // because `delete(allNotificationsFor:)` removes every row at once, leaving no row pointed at a dead
    // object. The fix therefore belongs in the observable, not in the view: the published array must never
    // outlive the rows it points at.
    //
    // The first two tests fail BEHAVIORALLY before the fix (a stale array, not a compile error). The two
    // after them are CONTROLS that pass on BOTH sides and pin the axis — this change is about what the view
    // layer OBSERVES, not about whether the delete persists.

    private func makeNotificationsObservableFixture(
        topic: String,
        ids: [String]
    ) -> (subscription: Subscription, observable: NotificationsObservable, published: [ntfy.Notification]) {
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: topic)
        deleteAfterTest(subscription)
        deleteNotificationsAfterTest(ids: ids)
        let messages = ids.map { pollMessage($0, topic: topic) }
        _ = Store.shared.save(notificationsFromMessages: messages, withSubscription: subscription)

        let observable = NotificationsObservable(subscriptionID: subscription.objectID)
        return (subscription, observable, observable.notifications)
    }

    func testDeletingOneNotificationRemovesItFromThePublishedListImmediately() {
        // RED before the fix: the async republish leaves the deleted row in the array for a whole runloop
        // turn, and that turn is exactly when SwiftUI re-renders the row bound to the dead object.
        let fixture = makeNotificationsObservableFixture(topic: "swipedelete-immediate",
                                                        ids: ["swipe-a1", "swipe-a2"])
        XCTAssertEqual(fixture.published.count, 2, "premise: the observable starts with both notifications")
        guard let victim = fixture.published.first(where: { $0.id == "swipe-a1" }) else {
            return XCTFail("premise: fixture did not contain swipe-a1")
        }

        Store.shared.delete(notification: victim)

        XCTAssertEqual(
            fixture.observable.notifications.count, 1,
            "a deleted notification must be gone from the published list as soon as delete() returns"
        )
        XCTAssertFalse(
            fixture.observable.notifications.contains { $0.id == "swipe-a1" },
            "the published list must not still contain the deleted notification"
        )
    }

    func testThePublishedListNeverExposesAnInvalidatedNotification() {
        // RED before the fix. This is the assertion that maps straight onto the crash: a managed object
        // whose managedObjectContext is nil has had its row deleted, so reading ANY property of it from a
        // SwiftUI body faults. It must never be reachable from the array the view renders.
        let fixture = makeNotificationsObservableFixture(topic: "swipedelete-invalidated",
                                                        ids: ["swipe-b1", "swipe-b2", "swipe-b3"])
        XCTAssertEqual(fixture.published.count, 3, "premise: the observable starts with all three")
        guard let victim = fixture.published.first(where: { $0.id == "swipe-b2" }) else {
            return XCTFail("premise: fixture did not contain swipe-b2")
        }

        Store.shared.delete(notification: victim)

        XCTAssertNil(
            victim.managedObjectContext,
            "premise: deleting through the store invalidates the managed object right away"
        )
        XCTAssertFalse(
            fixture.observable.notifications.contains { $0.managedObjectContext == nil },
            "the published list must never hand the view layer an invalidated managed object"
        )
    }

    func testDeletingOneNotificationStillLeavesTheOthersStored() {
        // CONTROL: green on BOTH sides. The delete itself was always correct — `Store.delete(notification:)`
        // has run inside `context.performAndWait` since PR #23. This pins that the fix is about what the
        // view layer observes, not about persistence.
        let ids = ["swipe-c1", "swipe-c2"]
        let fixture = makeNotificationsObservableFixture(topic: "swipedelete-persistence", ids: ids)
        guard let victim = fixture.published.first(where: { $0.id == "swipe-c1" }) else {
            return XCTFail("premise: fixture did not contain swipe-c1")
        }

        Store.shared.delete(notification: victim)

        let request = Notification.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", ids)
        let remaining = (try? Store.shared.context.fetch(request)) ?? []
        XCTAssertEqual(
            remaining.compactMap(\.id), ["swipe-c2"],
            "the delete must persist: exactly the untouched notification remains in the store"
        )
    }

    func testTheObservablePublishesEveryNotificationForItsSubscription() {
        // CONTROL: green on BOTH sides. `init` -> `performFetch` is untouched by this fix; if this goes red,
        // the change broke the observable's normal population path rather than just its refresh path.
        let fixture = makeNotificationsObservableFixture(topic: "swipedelete-initialfetch",
                                                        ids: ["swipe-d1", "swipe-d2"])
        XCTAssertEqual(
            Set(fixture.observable.notifications.compactMap(\.id)), ["swipe-d1", "swipe-d2"],
            "the observable must publish every stored notification for its subscription"
        )
    }

    // MARK: Shipping safety batch — credentials, push/NSE bounds, logging, persistence, publishing

    func testBlankPasswordWhileEditingMeansKeepExistingCredential() {
        XCTAssertNil(
            passwordForUserEdit(enteredPassword: "", storedPassword: "", isNewUser: false),
            "a blank edit must be represented as no password update; the Core Data column is "
                + "deliberately blank after Keychain migration"
        )
    }

    func testSavingUserWithNoPasswordUpdatePreservesInjectedCredential() throws {
        let baseURL = "https://preserve-edit-\(UUID().uuidString).example"
        Store.shared.saveUser(baseUrl: baseURL, username: "original-user", password: "existing-secret")
        XCTAssertEqual(credentialStore.password(baseUrl: baseURL), "existing-secret", "premise")

        Store.shared.saveUser(baseUrl: baseURL, username: "edited-user", password: nil)
        let user = try XCTUnwrap(Store.shared.getUser(baseUrl: baseURL))
        defer {
            Store.shared.context.performAndWait {
                Store.shared.context.delete(user)
                try? Store.shared.context.save()
            }
        }

        XCTAssertEqual(user.username, "edited-user", "the unrelated edit must still persist")
        XCTAssertEqual(
            credentialStore.password(baseUrl: baseURL), "existing-secret",
            "nil means keep the existing password, not delete it"
        )
    }

    func testNSEAttachmentLimitCombinesPreferenceWithHardCeiling() {
        XCTAssertEqual(
            notificationServiceAttachmentDownloadLimit(configuredMaxSize: 100 * 1024),
            100 * 1024,
            "a stricter user preference must remain in force"
        )
        XCTAssertEqual(
            notificationServiceAttachmentDownloadLimit(configuredMaxSize: 50 * 1024 * 1024),
            NotificationServiceTiming.attachmentSizeCeiling,
            "a permissive preference must not exceed the publisher-triggered NSE ceiling"
        )
        XCTAssertEqual(
            notificationServiceAttachmentDownloadLimit(configuredMaxSize: nil),
            NotificationServiceTiming.attachmentSizeCeiling,
            "Always must mean the NSE ceiling, never an unbounded background transfer"
        )
    }

    func testBoundedDownloaderRejectsOversizeBodyWithoutContentLength() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        _ = StubURLProtocol.session(status: 200, body: Data(repeating: 0x61, count: 2048))
        let attachment = MessageAttachment(
            name: "unknown.png", type: "image/png", size: nil, expires: nil,
            url: "https://ntfy.sh/file/unknown.png"
        )

        do {
            _ = try await AttachmentFileStore.download(
                notificationID: "bounded-unknown",
                remoteUrl: try XCTUnwrap(URL(string: attachment.url)),
                attachment: attachment,
                baseUrl: "https://ntfy.sh",
                authorizationHeader: nil,
                maxSize: 1024,
                configuration: config
            )
            XCTFail("an unknown-length 2 KB body must not complete under a 1 KB cap")
        } catch AttachmentDownloadError.tooLarge {
            // Expected: the delegate aborts while bytes arrive, even without a declared size.
        } catch {
            XCTFail("expected tooLarge, got \(error)")
        }
    }

    func testNSEWorstCaseFitsProcessingBudgetWithMargin() {
        XCTAssertLessThanOrEqual(
            NotificationServiceTiming.worstCaseDuration,
            NotificationServiceTiming.processingBudget,
            "poll + category registration + attachment download must fit the NSE budget"
        )
    }

    func testNotificationDeliveryGateInvokesHandlerExactlyOnce() {
        var callCount = 0
        let gate = NotificationDeliveryGate { _ in callCount += 1 }
        let first = UNMutableNotificationContent()
        let late = UNMutableNotificationContent()

        XCTAssertTrue(gate.deliver(first), "the first delivery must win")
        XCTAssertFalse(gate.deliver(late), "a poll callback after expiry must be ignored")
        XCTAssertEqual(callCount, 1, "Apple's content handler must be invoked exactly once per request")
    }

    func testLogRedactionRemovesMessageBodiesURLsAndBearerActions() {
        let payload: [AnyHashable: Any] = [
            "topic": "alerts",
            "message": "482991 is your login code",
            "click": "https://private.example/reset?token=secret-token",
            "actions": #"[{"headers":{"Authorization":"Bearer top-secret"}}]"#,
        ]
        let rendered = Log.redactedDescription(payload)

        XCTAssertFalse(rendered.contains("482991"), "message bodies must never enter logs")
        XCTAssertFalse(rendered.contains("secret-token"), "click URL secrets must never enter logs")
        XCTAssertFalse(rendered.contains("top-secret"), "action bearer tokens must never enter logs")
        XCTAssertTrue(rendered.contains("alerts"), "non-sensitive routing context should remain useful")
    }

    func testMissingAppGroupContainerFallsBackInsteadOfCrashing() {
        let fallback = URL(fileURLWithPath: "/tmp/ntfy-test-application-support", isDirectory: true)
        XCTAssertEqual(
            Store.persistentStoreURL(
                inMemory: false,
                appGroupContainerURL: nil,
                fallbackApplicationSupportURL: fallback
            ),
            fallback.appendingPathComponent("ntfy.sqlite"),
            "a missing entitlement must degrade to process-local persistence instead of force-unwrapping"
        )
    }

    func testDeletingUserRequestsDeletionFromInjectedCredentialStore() throws {
        let baseURL = "https://delete-user-\(UUID().uuidString).example"
        Store.shared.saveUser(baseUrl: baseURL, username: "delete-me", password: "orphan-secret")
        let user = try XCTUnwrap(Store.shared.getUser(baseUrl: baseURL))
        XCTAssertEqual(credentialStore.password(baseUrl: baseURL), "orphan-secret", "premise")

        Store.shared.delete(user: user)

        XCTAssertNil(user.managedObjectContext, "the user row must be durably deleted")
        XCTAssertTrue(
            credentialStore.requestedDeletion(of: baseURL),
            "Store.delete(user:) must explicitly ask credential storage to remove this server"
        )
        XCTAssertNil(
            credentialStore.password(baseUrl: baseURL),
            "the injected credential fake must observe the requested deletion"
        )
    }

    func testPublishDoesNotReportSuccessForForbiddenResponse() {
        let subscription = Subscription(context: Store.shared.context)
        subscription.baseUrl = "https://ntfy.sh"
        subscription.topic = "read-only"
        defer { Store.shared.context.delete(subscription) }
        let incorrectlySucceeded = expectation(description: "403 must not report publish success")
        incorrectlySucceeded.isInverted = true

        ApiService.shared.publish(
            subscription: subscription,
            user: nil,
            message: "hello",
            title: "title",
            session: StubURLProtocol.session(status: 403, body: Data())
        ) {
            incorrectlySucceeded.fulfill()
        }

        wait(for: [incorrectlySucceeded], timeout: 0.3)
    }

    func testLogVariadicMetadataRendersOneLinePerValue() {
        XCTAssertEqual(
            Log.formattedMetadata(["alpha", 42]),
            ["alpha", "42"],
            "variadic values must not be wrapped into one bracketed array"
        )
    }

    // MARK: EmojiManager — every gemoji alias must resolve, not just the first
    //
    // The bundled emojis.json is gemoji, where an emoji may carry several aliases
    // ("+1" and "thumbsup" are both 👍). EmojiManager indexed only aliases.first,
    // so 43 aliases that ntfy's web client accepts silently failed here: the tag
    // resolved to no emoji and then leaked into the row as a literal text tag.

    func testGetEmojiByAliasResolvesFirstAlias() {
        XCTAssertEqual(EmojiManager.shared.getEmojiByAlias(alias: "+1")?.getUnicode(), "👍")
        XCTAssertEqual(EmojiManager.shared.getEmojiByAlias(alias: "hankey")?.getUnicode(), "💩")
    }

    func testGetEmojiByAliasResolvesNonFirstAliases() {
        // Each of these is aliases[1..] of its entry — nil before the fix.
        XCTAssertEqual(EmojiManager.shared.getEmojiByAlias(alias: "thumbsup")?.getUnicode(), "👍")
        XCTAssertEqual(EmojiManager.shared.getEmojiByAlias(alias: "thumbsdown")?.getUnicode(), "👎")
        XCTAssertEqual(EmojiManager.shared.getEmojiByAlias(alias: "poop")?.getUnicode(), "💩")
        XCTAssertEqual(EmojiManager.shared.getEmojiByAlias(alias: "uk")?.getUnicode(), "🇬🇧")
        XCTAssertEqual(EmojiManager.shared.getEmojiByAlias(alias: "telephone")?.getUnicode(), "☎️")
    }

    func testGetEmojiByAliasIsNilForUnknownAndEmpty() {
        XCTAssertNil(EmojiManager.shared.getEmojiByAlias(alias: ""))
        XCTAssertNil(EmojiManager.shared.getEmojiByAlias(alias: "definitely-not-an-emoji-alias"))
    }

    func testEveryAliasInTheDatasetResolvesToItsOwnEmoji() {
        // The contract, dataset-wide: alias -> the emoji that declares it. Indexing every
        // alias is only safe because gemoji has no alias claimed by two entries; this pins
        // both halves (full coverage AND no entry shadowing another).
        let url = Bundle.main.url(forResource: "emojis", withExtension: "json")
        XCTAssertNotNil(url, "emojis.json must be bundled into the test host")
        let entries = try! JSONDecoder().decode([Emoji].self, from: Data(contentsOf: url!))
        XCTAssertGreaterThan(entries.count, 1800, "sanity: the gemoji dataset should be fully loaded")

        var aliasCount = 0
        for entry in entries {
            for alias in entry.aliases {
                aliasCount += 1
                XCTAssertEqual(EmojiManager.shared.getEmojiByAlias(alias: alias)?.getUnicode(),
                               entry.getUnicode(),
                               "alias '\(alias)' must resolve to \(entry.getUnicode())")
            }
        }
        // 1855 aliases across 1812 entries — the 43-alias gap is the bug this pins.
        XCTAssertGreaterThan(aliasCount, entries.count,
                             "sanity: the dataset must contain multi-alias entries for this to be meaningful")
    }

    // MARK: tag parsing over the real dataset — the user-visible half of the alias bug

    func testParseEmojiTagsResolvesNonFirstAlias() {
        XCTAssertEqual(parseEmojiTags("thumbsup"), ["👍"])
        XCTAssertEqual(parseEmojiTags("+1,thumbsdown"), ["👍", "👎"])
    }

    func testParseNonEmojiTagsDoesNotLeakKnownAliasAsLiteralTag() {
        // The symptom users see: an unresolved alias falls through to the literal tag list,
        // so the row renders "thumbsup" as text instead of 👍.
        XCTAssertEqual(parseNonEmojiTags("thumbsup"), [])
        XCTAssertEqual(parseNonEmojiTags("thumbsup,backup"), ["backup"])
    }

    // MARK: - FCM subscription reconciliation (ntfy#1305)
    //
    // The push path cannot be exercised on the simulator (no APNs, no FCM), so
    // these pin the *decision* logic behind the FcmTopicSubscriber seam: who we
    // try to subscribe, when we refuse to try, and what survives a failure.

    /// Records calls and lets a test force a per-topic failure.
    private final class FakeFcmSubscriber: FcmTopicSubscriber {
        var hasApnsToken = true
        private(set) var subscribed: [String] = []
        private(set) var unsubscribed: [String] = []
        var failures: [String: Error] = [:]

        struct Boom: Error {}

        /// Hold completions open so a test can interleave events with a round that is
        /// genuinely still in flight — the only way to reproduce a token rotation landing
        /// mid-round, which is where the confirmations of a superseded round used to win.
        var deferCompletions = false
        private var pending: [(topic: String, completion: (Error?) -> Void)] = []

        func subscribe(toTopic topic: String, completion: @escaping (Error?) -> Void) {
            subscribed.append(topic)
            if deferCompletions {
                pending.append((topic, completion))
            } else {
                completion(failures[topic])
            }
        }

        /// Fire every held completion, as Firebase eventually would.
        func flushPendingCompletions() {
            let held = pending
            pending = []
            held.forEach { $0.completion(failures[$0.topic]) }
        }

        func unsubscribe(fromTopic topic: String, completion: @escaping (Error?) -> Void) {
            unsubscribed.append(topic)
            // Honours `failures`, so a test can reproduce unsubscribing while offline.
            completion(failures[topic])
        }
    }

    /// `reconcile` finishes on the main queue, so a test must let it drain
    /// before asserting or starting another round.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    /// Reuse `Store.shared`, which is already backed by an in-memory store under
    /// XCTest (see `Store.shared`). Standing up a second `NSPersistentContainer`
    /// per test loads the model again and makes Core Data log
    /// "Failed to find a unique match for an NSEntityDescription", so we take the
    /// one container and wipe the rows instead.
    ///
    /// `bindingsAppBaseUrl` is what the defaults record as the app base URL the existing bindings were
    /// named under. It defaults to the current one, i.e. a steady-state install; pass nil to model an
    /// install upgrading from a build that never recorded it.
    private func makeReconciler(
        _ subscriber: FakeFcmSubscriber,
        bindingsAppBaseUrl: String? = Config.appBaseUrl
    ) -> (FcmSubscriptionReconciler, Store, UserDefaults) {
        let store = Store.shared
        store.getSubscriptions()?.forEach { store.delete(subscription: $0) }
        let defaults = UserDefaults(suiteName: "ntfyTests-\(UUID().uuidString)")!
        defaults.set(bindingsAppBaseUrl, forKey: FcmSubscriptionReconciler.defaultsKeyBindingsAppBaseUrl)
        let reconciler = FcmSubscriptionReconciler(store: store, subscriber: subscriber, defaults: defaults)
        return (reconciler, store, defaults)
    }

    // Without the APNs token, FCM rejects every topic bind. The old code fired
    // anyway and swallowed the errors — that is the desync this refuses to create.
    func testReconcileDoesNothingUntilApnsTokenIsAssociated() {
        let fake = FakeFcmSubscriber()
        fake.hasApnsToken = false
        let (reconciler, store, _) = makeReconciler(fake)
        _ = store.saveSubscription(baseUrl: Config.appBaseUrl, topic: "alerts")

        reconciler.reconcile(reason: "test")
        drainMainQueue()

        XCTAssertEqual(fake.subscribed, [], "must not attempt a bind before APNs association")
        XCTAssertEqual(store.getSubscriptionsPendingFcmSubscribe().count, 1, "the subscription stays queued")
    }

    func testReconcileSubscribesPendingTopicsAndThePollTopic() {
        let fake = FakeFcmSubscriber()
        let (reconciler, store, _) = makeReconciler(fake)
        _ = store.saveSubscription(baseUrl: Config.appBaseUrl, topic: "alerts")

        reconciler.reconcile(reason: "test")
        drainMainQueue()

        XCTAssertTrue(fake.subscribed.contains(FcmSubscriptionReconciler.pollTopic))
        XCTAssertTrue(fake.subscribed.contains("alerts"))
        XCTAssertTrue(store.getSubscriptionsPendingFcmSubscribe().isEmpty,
                      "a confirmed bind must clear the retry queue")
    }

    // Reconciling repeatedly is the whole safety model (it runs on every
    // foreground), so it has to be free when there is nothing to do.
    func testReconcileIsIdempotentOnceConfirmed() {
        let fake = FakeFcmSubscriber()
        let (reconciler, store, _) = makeReconciler(fake)
        _ = store.saveSubscription(baseUrl: Config.appBaseUrl, topic: "alerts")

        reconciler.reconcile(reason: "first")
        drainMainQueue()
        let afterFirst = fake.subscribed.count

        reconciler.reconcile(reason: "second")
        drainMainQueue()

        XCTAssertEqual(fake.subscribed.count, afterFirst, "no duplicate binds for already-confirmed topics")
    }

    // The regression that defines #1305: a failed bind must stay queued.
    func testFailedSubscribeStaysQueuedAndRetriesOnNextReconcile() {
        let fake = FakeFcmSubscriber()
        fake.failures["alerts"] = FakeFcmSubscriber.Boom()
        let (reconciler, store, _) = makeReconciler(fake)
        _ = store.saveSubscription(baseUrl: Config.appBaseUrl, topic: "alerts")

        reconciler.reconcile(reason: "first")
        drainMainQueue()
        XCTAssertEqual(store.getSubscriptionsPendingFcmSubscribe().count, 1,
                       "a failed bind must NOT be marked subscribed")

        fake.failures.removeAll() // transient failure clears
        reconciler.reconcile(reason: "retry")
        drainMainQueue()

        XCTAssertEqual(fake.subscribed.filter { $0 == "alerts" }.count, 2, "the topic is retried")
        XCTAssertTrue(store.getSubscriptionsPendingFcmSubscribe().isEmpty, "and then confirmed")
    }

    // Token rotation is why users report "it just stopped working after a couple
    // months": FCM binds topics to a token, so a new one voids them all.
    func testRotatedRegistrationTokenRequeuesEveryTopic() {
        let fake = FakeFcmSubscriber()
        let (reconciler, store, _) = makeReconciler(fake)
        _ = store.saveSubscription(baseUrl: Config.appBaseUrl, topic: "alerts")

        XCTAssertTrue(reconciler.noteRegistrationToken("token-one"))
        reconciler.reconcile(reason: "first token")
        drainMainQueue()
        XCTAssertTrue(store.getSubscriptionsPendingFcmSubscribe().isEmpty)

        XCTAssertTrue(reconciler.noteRegistrationToken("token-two"), "a new token invalidates state")
        drainMainQueue()

        // noteRegistrationToken now drives the rebuild itself instead of leaving the topics queued
        // for a caller to notice. Leaving that to convention was how a rotation could invalidate
        // everything and then have no round scheduled to act on it.
        XCTAssertEqual(fake.subscribed.filter { $0 == "alerts" }.count, 2,
                       "every topic must be rebound against the new token")
        XCTAssertEqual(fake.subscribed.filter { $0 == FcmSubscriptionReconciler.pollTopic }.count, 2,
                       "the poll topic is bound to the token too, so it also rebinds")
        XCTAssertTrue(store.getSubscriptionsPendingFcmSubscribe().isEmpty,
                      "and the rebind must end up confirmed, not merely queued")
    }

    // MARK: FCM topic names follow the app base URL (1.14 moved it to ntfy-me.com)
    //
    // `firebaseTopic` names a subscription by its raw topic on the built-in server and by a hash
    // everywhere else, so changing the built-in server renames existing bindings. Rows bound under
    // the old names still read `fcmSubscribed == true`, so without a rebind nothing would ever bind
    // the new names: silent push death on upgrade for every existing subscription.

    private let homeServer = "https://home.example.com"

    /// Rows that FCM confirmed under whatever names the previous build used.
    private func saveConfirmedSubscription(_ store: Store, baseUrl: String, topic: String) {
        let subscription = store.saveSubscription(baseUrl: baseUrl, topic: topic)
        store.setFcmSubscribed(subscription, true)
    }

    func testUpgradeWithNoRecordedBaseUrlTearsDownOldNamesAndBindsNewOnes() {
        let fake = FakeFcmSubscriber()
        let (reconciler, store, defaults) = makeReconciler(fake, bindingsAppBaseUrl: nil)
        saveConfirmedSubscription(store, baseUrl: Config.appBaseUrl, topic: "news")
        saveConfirmedSubscription(store, baseUrl: homeServer, topic: "alerts")
        XCTAssertTrue(store.getSubscriptionsPendingFcmSubscribe().isEmpty, "sanity: everything reads bound")

        reconciler.reconcile(reason: "launch after upgrade")
        drainMainQueue()

        let newsHash = topicHash(baseUrl: Config.appBaseUrl, topic: "news")
        let alertsHash = topicHash(baseUrl: homeServer, topic: "alerts")
        XCTAssertEqual(Set(fake.unsubscribed), [newsHash, "alerts"],
                       "each subscription's superseded name is torn down")
        XCTAssertTrue(fake.subscribed.contains("news"), "built-in server subscriptions bind the raw topic")
        XCTAssertTrue(fake.subscribed.contains(alertsHash), "other servers bind the hash")
        XCTAssertTrue(store.getSubscriptionsPendingFcmSubscribe().isEmpty, "and both end up confirmed")
        XCTAssertEqual(defaults.string(forKey: FcmSubscriptionReconciler.defaultsKeyBindingsAppBaseUrl),
                       normalizeBaseUrl(Config.appBaseUrl), "the new base URL is recorded")

        // Once recorded, later rounds must not rename again.
        let unsubscribedBefore = fake.unsubscribed.count
        let subscribedBefore = fake.subscribed.count
        reconciler.reconcile(reason: "next foreground")
        drainMainQueue()
        XCTAssertEqual(fake.unsubscribed.count, unsubscribedBefore)
        XCTAssertEqual(fake.subscribed.count, subscribedBefore)
    }

    func testRecordedPreviousBaseUrlAlsoTriggersRebind() {
        let fake = FakeFcmSubscriber()
        let (reconciler, store, _) = makeReconciler(fake, bindingsAppBaseUrl: "https://ntfy.sh/")
        saveConfirmedSubscription(store, baseUrl: homeServer, topic: "alerts")

        reconciler.reconcile(reason: "launch after upgrade")
        drainMainQueue()

        XCTAssertEqual(fake.unsubscribed, ["alerts"])
        XCTAssertTrue(fake.subscribed.contains(topicHash(baseUrl: homeServer, topic: "alerts")))
        XCTAssertTrue(store.getSubscriptionsPendingFcmSubscribe().isEmpty)
    }

    // The same topic on both servers: the home server's old raw name `x` is exactly the name the
    // built-in server's `x` now needs. Tearing it down would kill push for the new subscription.
    func testRebindNeverTearsDownANameAnotherSubscriptionNowNeeds() {
        let fake = FakeFcmSubscriber()
        let (reconciler, store, _) = makeReconciler(fake, bindingsAppBaseUrl: nil)
        saveConfirmedSubscription(store, baseUrl: Config.appBaseUrl, topic: "x")
        saveConfirmedSubscription(store, baseUrl: homeServer, topic: "x")

        reconciler.reconcile(reason: "launch after upgrade")
        drainMainQueue()

        XCTAssertFalse(fake.unsubscribed.contains("x"), "raw `x` is still needed by the built-in server's `x`")
        XCTAssertEqual(fake.unsubscribed, [topicHash(baseUrl: Config.appBaseUrl, topic: "x")])
        XCTAssertTrue(fake.subscribed.contains("x"))
        XCTAssertTrue(fake.subscribed.contains(topicHash(baseUrl: homeServer, topic: "x")))
        XCTAssertTrue(store.getSubscriptionsPendingFcmSubscribe().isEmpty)
    }

    func testUnchangedBaseUrlTearsNothingDownAndRebindsNothing() {
        let fake = FakeFcmSubscriber()
        let (reconciler, store, _) = makeReconciler(fake) // recorded == current
        reconciler.noteRegistrationToken("token-one")
        drainMainQueue()
        saveConfirmedSubscription(store, baseUrl: Config.appBaseUrl, topic: "news")
        saveConfirmedSubscription(store, baseUrl: homeServer, topic: "alerts")
        let subscribedBefore = fake.subscribed

        reconciler.reconcile(reason: "foreground")
        drainMainQueue()

        XCTAssertEqual(fake.unsubscribed, [], "nothing was renamed, so nothing is torn down")
        XCTAssertEqual(fake.subscribed, subscribedBefore, "and confirmed rows are not rebound")
    }

    // Upgrading while offline: the teardowns fail. That must not stop the new names binding, or
    // push stays dead until some unrelated event happens to invalidate the rows again.
    func testFailedTeardownDoesNotBlockBindingTheNewNames() {
        let fake = FakeFcmSubscriber()
        fake.failures["alerts"] = FakeFcmSubscriber.Boom() // only affects the teardown of raw `alerts`
        let (reconciler, store, _) = makeReconciler(fake, bindingsAppBaseUrl: nil)
        saveConfirmedSubscription(store, baseUrl: homeServer, topic: "alerts")

        reconciler.reconcile(reason: "launch after upgrade, offline teardown")
        drainMainQueue()

        XCTAssertEqual(fake.unsubscribed, ["alerts"], "the teardown was attempted")
        XCTAssertTrue(fake.subscribed.contains(topicHash(baseUrl: homeServer, topic: "alerts")))
        XCTAssertTrue(store.getSubscriptionsPendingFcmSubscribe().isEmpty, "the new name still ends up bound")
    }

    func testUnchangedRegistrationTokenDoesNotRequeue() {
        let fake = FakeFcmSubscriber()
        let (reconciler, store, _) = makeReconciler(fake)
        _ = store.saveSubscription(baseUrl: Config.appBaseUrl, topic: "alerts")

        reconciler.noteRegistrationToken("token-one")
        reconciler.reconcile(reason: "first")
        drainMainQueue()

        XCTAssertFalse(reconciler.noteRegistrationToken("token-one"), "same token is a no-op")
        XCTAssertTrue(store.getSubscriptionsPendingFcmSubscribe().isEmpty)
    }

    // Firebase hands us a nil token on transient failures; treating that as a
    // rotation would pointlessly requeue (and re-bind) everything.
    func testMissingRegistrationTokenLeavesStateIntact() {
        let fake = FakeFcmSubscriber()
        let (reconciler, store, _) = makeReconciler(fake)
        _ = store.saveSubscription(baseUrl: Config.appBaseUrl, topic: "alerts")

        reconciler.noteRegistrationToken("token-one")
        reconciler.reconcile(reason: "first")
        drainMainQueue()

        XCTAssertFalse(reconciler.noteRegistrationToken(nil))
        XCTAssertFalse(reconciler.noteRegistrationToken(""))
        XCTAssertTrue(store.getSubscriptionsPendingFcmSubscribe().isEmpty, "state untouched")
    }

    // MARK: Confirmations must be ordered against teardowns (#40)
    //
    // FCM can apply a subscribe and a teardown in either order relative to when their callbacks
    // arrive. The dangerous ordering is: subscribe applied, teardown applied (binding now gone),
    // then the subscribe's callback arrives last. If that callback is allowed to write
    // fcmSubscribed = true, the flag reads confirmed for a binding that does not exist and no later
    // reconcile rebuilds it — silent, permanent push death.

    func testAConfirmationThatArrivesAfterATeardownIsRejected() {
        let fake = FakeFcmSubscriber()
        let (reconciler, store, _) = makeReconciler(fake)
        let subscription = store.saveSubscription(baseUrl: Config.appBaseUrl, topic: "alerts")
        deleteAfterTest(subscription)

        // A round dispatches a subscribe; hold its callback.
        fake.deferCompletions = true
        reconciler.reconcile(reason: "test")
        XCTAssertTrue(fake.subscribed.contains("alerts"), "premise: a subscribe is in flight")

        // A teardown for the same topic settles while that confirmation is still in flight.
        fake.deferCompletions = false
        reconciler.unsubscribe(baseUrl: Config.appBaseUrl, topic: "alerts")

        // Only now does the subscribe's callback arrive.
        fake.flushPendingCompletions()
        drainMainQueue()
        drainMainQueue()

        // A second bind is the discriminator. Had the stale confirmation been accepted, the row
        // would already read subscribed, the rebuild round would find nothing pending, and exactly
        // one subscribe would ever have been issued. Two means the confirmation was rejected and
        // the binding was genuinely re-established *after* the teardown settled.
        XCTAssertGreaterThanOrEqual(fake.subscribed.filter { $0 == "alerts" }.count, 2,
                                    "the superseded confirmation must be rejected and the binding rebuilt")
        XCTAssertTrue(subscription.fcmSubscribed,
                      "and the topic must end up genuinely bound, not left silently stale")
    }

    func testATokenRotationStillInvalidatesAnInFlightConfirmation() {
        // The generation moved from the reconciler into Store; this pins that the original
        // ntfy#1305 protection survived the move.
        let fake = FakeFcmSubscriber()
        let (reconciler, store, _) = makeReconciler(fake)
        let subscription = store.saveSubscription(baseUrl: Config.appBaseUrl, topic: "alerts")
        deleteAfterTest(subscription)

        fake.deferCompletions = true
        reconciler.reconcile(reason: "first round")

        reconciler.noteRegistrationToken("token-two")

        fake.flushPendingCompletions()
        drainMainQueue()

        XCTAssertFalse(subscription.fcmSubscribed,
                       "a binding made under the previous token must not be reported as confirmed")
    }

    func testATeardownForADeletedTopicStillSchedulesAReplacementRound() {
        // The bump rejects EVERY confirmation in flight, not just the torn-down topic's. If the
        // teardown was for a topic that is gone for good, there is no rebuild to trigger — but the
        // unrelated topics whose confirmations were just dropped still need a round, or they stay
        // stale with nothing scheduled to fix them and push stays down.
        let fake = FakeFcmSubscriber()
        let (reconciler, store, _) = makeReconciler(fake)
        let other = store.saveSubscription(baseUrl: Config.appBaseUrl, topic: "unrelated")
        deleteAfterTest(other)

        fake.deferCompletions = true
        reconciler.reconcile(reason: "first round")
        XCTAssertTrue(fake.subscribed.contains("unrelated"), "premise: a subscribe is in flight")

        // A teardown settles for a topic that has no row at all.
        fake.deferCompletions = false
        reconciler.unsubscribe(baseUrl: Config.appBaseUrl, topic: "long-gone")

        // The in-flight confirmation now arrives and is correctly rejected.
        fake.flushPendingCompletions()
        drainMainQueue()
        drainMainQueue()

        XCTAssertTrue(other.fcmSubscribed,
                      "an unrelated topic whose confirmation was collateral damage must be rebound "
                          + "by a successor round, not left stale")
    }

    func testATokenRotationCannotHaveThePollFlagRestoredByAnOldConfirmation() {
        // Ordering trap: resetting pollTopicFcmSubscribed before invalidating left a window where an
        // old-token poll confirmation could set it back to true. Nothing resets it again, so the new
        // token would never bind ~poll at all — push silently dead for the poll path.
        let fake = FakeFcmSubscriber()
        let (reconciler, _, defaults) = makeReconciler(fake)

        fake.deferCompletions = true
        reconciler.reconcile(reason: "old token round")
        XCTAssertTrue(fake.subscribed.contains(FcmSubscriptionReconciler.pollTopic),
                      "premise: the poll topic subscribe is in flight")

        reconciler.noteRegistrationToken("token-two")

        fake.flushPendingCompletions()
        drainMainQueue()

        XCTAssertFalse(defaults.bool(forKey: "pollTopicFcmSubscribed"),
                       "the old token's poll confirmation must not survive the rotation")
    }

    func testAConfirmationFromTheCurrentGenerationIsAccepted() {
        // The control: with nothing superseding it, a confirmation must still land. Otherwise the
        // ordering guard would "fix" the race by never confirming anything.
        let fake = FakeFcmSubscriber()
        let (reconciler, store, _) = makeReconciler(fake)
        let subscription = store.saveSubscription(baseUrl: Config.appBaseUrl, topic: "alerts")
        deleteAfterTest(subscription)

        reconciler.reconcile(reason: "test")
        drainMainQueue()

        XCTAssertTrue(subscription.fcmSubscribed, "an uncontested confirmation must be applied")
        XCTAssertTrue(store.getSubscriptionsPendingFcmSubscribe().isEmpty)
    }

    func testUnsubscribeDropsTheFirebaseTopic() {
        let fake = FakeFcmSubscriber()
        let (reconciler, _, _) = makeReconciler(fake)

        reconciler.unsubscribe(baseUrl: Config.appBaseUrl, topic: "alerts")

        XCTAssertEqual(fake.unsubscribed, ["alerts"])
    }

    // MARK: Rounds that a token rotation has superseded must not confirm anything
    //
    // Observed on a real launch: the APNs callback started a round, the FCM token then
    // arrived and marked every topic stale, the follow-up reconcile was dropped because a
    // round was in flight, and that older round's completions set `fcmSubscribed = true`
    // anyway. The flags then read confirmed for bindings made under the *previous* token,
    // so no later reconcile would rebuild them — the silent, permanent push death of
    // ntfy#1305, reintroduced by the fix for it.

    func testTokenRotationDuringAnInFlightRoundDiscardsThatRoundsConfirmations() {
        let fake = FakeFcmSubscriber()
        let (reconciler, store, _) = makeReconciler(fake)
        _ = store.saveSubscription(baseUrl: Config.appBaseUrl, topic: "alerts")

        fake.deferCompletions = true
        reconciler.reconcile(reason: "APNs token registered")
        XCTAssertTrue(fake.subscribed.contains("alerts"), "the round must have started")

        // The token rotates while those subscribes are still open.
        reconciler.noteRegistrationToken("rotated-token")

        // Firebase now answers the calls the *old* token issued.
        fake.deferCompletions = false
        fake.flushPendingCompletions()
        drainMainQueue()

        drainMainQueue()

        // The superseded round's confirmation must not count. Evidence is a SECOND bind: had that
        // stale confirmation been accepted, the row would read subscribed, the rebuild round would
        // find nothing pending, and only one bind would ever have been issued — which is exactly
        // how ntfy#1305 died silently.
        XCTAssertGreaterThanOrEqual(fake.subscribed.filter { $0 == "alerts" }.count, 2,
                                    "a bind confirmed under the superseded token must be rejected "
                                        + "and the topic rebound against the new one")
        XCTAssertTrue(store.getSubscriptionsPendingFcmSubscribe().isEmpty,
                      "and that rebuild must then confirm it, rather than leaving push dead")
    }

    func testReconcileRequestedWhileARoundIsInFlightRunsAfterIt() {
        let fake = FakeFcmSubscriber()
        let (reconciler, store, _) = makeReconciler(fake)
        _ = store.saveSubscription(baseUrl: Config.appBaseUrl, topic: "first")

        fake.deferCompletions = true
        reconciler.reconcile(reason: "first round")
        XCTAssertTrue(fake.subscribed.contains("first"))

        // A subscription added mid-round: its reconcile is asked for while the first is open.
        _ = store.saveSubscription(baseUrl: Config.appBaseUrl, topic: "second")
        reconciler.reconcile(reason: "subscribed to second")
        XCTAssertFalse(fake.subscribed.contains("second"),
                       "the queued request must not run concurrently with the open round")

        fake.deferCompletions = false
        fake.flushPendingCompletions()
        drainMainQueue()
        drainMainQueue()

        XCTAssertTrue(fake.subscribed.contains("second"),
                      "a reconcile requested during a round must be honoured once it finishes, "
                        + "not dropped — otherwise a topic added mid-round stays unbound")
    }

    // MARK: - Core Data model versioning — an installed app must survive the upgrade
    //
    // `fcmSubscribed` (ntfy#1305) is the first attribute added to the model since a build
    // shipped to TestFlight, which makes the upgrade path load-bearing for the first time.
    //
    // Core Data can only infer a lightweight migration if the model version the *existing*
    // store was created with is still present in the compiled `.momd`. Editing
    // `Model.xcdatamodel/contents` in place — the obvious way to add an attribute, and what
    // the original change did — deletes that shape from the bundle, so `loadPersistentStores`
    // fails with "missing source managed object model". `Store.init` only logs that error and
    // carries on, so the app would come up with NO persistent store: every subscription and
    // notification gone, every save silently dropped, for every user upgrading from build 13.
    //
    // These pin the invariant rather than the symptom: ship every past model version, and keep
    // a store created by an older one openable under the current one. Both fail on a tree where
    // the model was edited in place (there is only one version, so there is no `previous` to
    // create the fixture store with).

    /// All compiled model versions inside the app's `.momd`, oldest-shape first is not
    /// guaranteed — callers pick by shape, not by order.
    private func compiledModelVersionURLs() throws -> [URL] {
        let momd = try XCTUnwrap(
            Bundle(for: type(of: self)).url(forResource: Store.modelName, withExtension: "momd")
                ?? Bundle.main.url(forResource: Store.modelName, withExtension: "momd"),
            "compiled \(Store.modelName).momd not found in the test host bundle"
        )
        let urls = try FileManager.default
            .contentsOfDirectory(at: momd, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mom" }
        return urls
    }

    // MARK: credentials — passwords belong in injected credential storage, not Core Data
    //
    // Upstream (and this fork until now) wrote per-server passwords as a plain String on the Core
    // Data `User` entity, which put them in the app-group SQLite in the clear. These pin the fix:
    // new writes never touch the column, an old store gets lifted into credential storage, and a
    // failed credential write must NOT clear the only copy of the password. The unsigned suite uses
    // an explicit fake; a separate signed-only integration test covers the Security framework.

    func testSavingAUserKeepsPasswordOutOfCoreDataAndWritesInjectedCredentialStore() throws {
        let baseUrl = "https://keychain-test-\(UUID().uuidString).example"

        Store.shared.saveUser(baseUrl: baseUrl, username: "phil", password: "hunter2")
        defer {
            if let u = Store.shared.getUser(baseUrl: baseUrl) { Store.shared.context.delete(u) }
        }

        let stored = try XCTUnwrap(Store.shared.getUser(baseUrl: baseUrl))
        XCTAssertEqual(stored.username, "phil")
        XCTAssertTrue(stored.password?.isEmpty ?? true,
                      "the password must never be written to Core Data — that store rides along in "
                        + "unencrypted device backups. (Blanked rather than nil: the model declares "
                        + "the attribute non-optional, and assigning nil rolls the whole save back.)")
        XCTAssertEqual(credentialStore.password(baseUrl: baseUrl), "hunter2",
                       "and it must be retrievable from the injected credential store")
        XCTAssertEqual(Store.shared.getBasicUser(baseUrl: baseUrl)?.password, "hunter2",
                       "auth must still resolve the password end to end")
    }

    func testMigrationLiftsLegacyPlaintextPasswordIntoInjectedCredentialStoreAndClearsColumn() throws {
        let baseUrl = "https://legacy-cred-\(UUID().uuidString).example"

        // Simulate a store written by an older build: password sitting in Core Data.
        let context = Store.shared.context
        let user = User(context: context)
        user.baseUrl = baseUrl
        user.username = "olduser"
        user.password = "legacy-secret"
        defer { context.delete(user) }

        XCTAssertNil(credentialStore.password(baseUrl: baseUrl),
                     "precondition: nothing in injected credential storage yet")

        let migrated = Store.shared.migrateCredentialsToKeychain()

        XCTAssertGreaterThanOrEqual(migrated, 1)
        XCTAssertEqual(credentialStore.password(baseUrl: baseUrl), "legacy-secret",
                       "the legacy password must land in injected credential storage")
        XCTAssertTrue(user.password?.isEmpty ?? true, "and the plaintext column must be cleared")
        XCTAssertEqual(Store.shared.getBasicUser(baseUrl: baseUrl)?.password, "legacy-secret",
                       "auth keeps working across the migration")
    }

    func testMigrationIsIdempotent() throws {
        let baseUrl = "https://idempotent-cred-\(UUID().uuidString).example"
        let context = Store.shared.context
        let user = User(context: context)
        user.baseUrl = baseUrl
        user.username = "u"
        user.password = "p"
        defer { context.delete(user) }

        XCTAssertGreaterThanOrEqual(Store.shared.migrateCredentialsToKeychain(), 1)
        let second = Store.shared.migrateCredentialsToKeychain()
        XCTAssertEqual(second, 0, "a second launch must find nothing left to migrate")
        XCTAssertEqual(credentialStore.password(baseUrl: baseUrl), "p")
    }

    func testInjectedCredentialStoreRoundTripAndDelete() {
        let baseUrl = "https://roundtrip-\(UUID().uuidString).example"

        XCTAssertTrue(credentialStore.setPassword("first", baseUrl: baseUrl))
        XCTAssertEqual(credentialStore.password(baseUrl: baseUrl), "first")
        XCTAssertTrue(credentialStore.setPassword("second", baseUrl: baseUrl), "overwrite must work")
        XCTAssertEqual(credentialStore.password(baseUrl: baseUrl), "second")
        XCTAssertTrue(credentialStore.setPassword("", baseUrl: baseUrl), "empty clears the entry")
        XCTAssertNil(credentialStore.password(baseUrl: baseUrl))
        XCTAssertTrue(credentialStore.setPassword("third", baseUrl: baseUrl))
        XCTAssertTrue(credentialStore.setPassword(nil, baseUrl: baseUrl), "nil clears the entry")
        XCTAssertNil(credentialStore.password(baseUrl: baseUrl))
    }

    func testStoreDefaultsToProductionKeychainCredentialStore() {
        let store = Store(inMemory: true)
        XCTAssertTrue(
            store.credentialStore === KeychainCredentialStore.shared,
            "app and NSE Store instances must default to the Security-framework implementation"
        )
    }

    func testManyStoresShareOneManagedObjectModelAndKeepEntitiesUnambiguous() throws {
        // Retain all of the stores at once to reproduce the suite's cumulative behavior: Core Data
        // keeps every separately loaded model registered even after its Store would otherwise fall
        // out of scope. Two stores are enough to violate identity; sixteen makes the production
        // failure mode explicit without relying on the surrounding suite's test count or order.
        let stores = (0..<16).map { _ in
            Store(inMemory: true, credentialStore: InMemoryCredentialStore())
        }
        let models = try stores.map { store in
            try XCTUnwrap(store.context.persistentStoreCoordinator?.managedObjectModel)
        }
        let uniqueModelIdentities = Set(models.map(ObjectIdentifier.init))

        XCTAssertEqual(
            uniqueModelIdentities.count,
            1,
            "every Store in a process must use the same NSManagedObjectModel instance"
        )
        guard uniqueModelIdentities.count == 1, let model = models.first else { return }

        XCTAssertTrue(User.entity() === model.entitiesByName["User"])
        XCTAssertTrue(Subscription.entity() === model.entitiesByName["Subscription"])
        XCTAssertTrue(ntfy.Notification.entity() === model.entitiesByName["Notification"])
        XCTAssertTrue(Preference.entity() === model.entitiesByName["Preference"])
    }

    func testKeychainCredentialStoreRoundTripWhenSignedHostIsAvailable() throws {
        let keychain = KeychainCredentialStore.shared
        try XCTSkipUnless(
            keychain.isAvailable,
            "real Keychain integration requires a signed test host with an application-identifier "
                + "entitlement; the mandated unsigned command cannot access SecItem storage"
        )
        let baseUrl = "https://real-keychain-\(UUID().uuidString).example"
        defer { keychain.deletePassword(baseUrl: baseUrl) }

        XCTAssertTrue(keychain.setPassword("first", baseUrl: baseUrl))
        XCTAssertEqual(keychain.password(baseUrl: baseUrl), "first")
        XCTAssertTrue(keychain.setPassword("second", baseUrl: baseUrl), "overwrite must work")
        XCTAssertEqual(keychain.password(baseUrl: baseUrl), "second")
        XCTAssertTrue(keychain.setPassword("", baseUrl: baseUrl), "empty clears the entry")
        XCTAssertNil(keychain.password(baseUrl: baseUrl))
    }

    func testRealKeychainHTTPHeadersRoundTripWhenAvailable() throws {
        let keychain = KeychainCredentialStore.shared
        try XCTSkipUnless(
            keychain.isAvailable,
            "Real Keychain integration requires a signed test host with an application-identifier "
                + "entitlement; the documented unsigned xcodebuild command has no Keychain access."
        )
        let baseUrl = "https://real-header-keychain-\(UUID().uuidString).example"
        defer { keychain.deleteHTTPHeaders(baseUrl: baseUrl) }

        let headers = ["CF-Access-Client-Id": "id", "CF-Access-Client-Secret": "secret"]
        XCTAssertTrue(keychain.setHTTPHeaders(headers, baseUrl: baseUrl + "/"))
        XCTAssertEqual(keychain.httpHeaders(baseUrl: baseUrl), headers)
        XCTAssertTrue(keychain.deleteHTTPHeaders(baseUrl: baseUrl))
        XCTAssertEqual(keychain.httpHeaders(baseUrl: baseUrl), [:])
    }

    func testEditingAUserWithABlankPasswordLeavesCredentialUntouched() throws {
        let baseUrl = "https://edit-credential-\(UUID().uuidString).example"
        Store.shared.saveUser(baseUrl: baseUrl, username: "before", password: "keep-me")
        let user = try XCTUnwrap(Store.shared.getUser(baseUrl: baseUrl))
        deleteAfterTest(user)

        let passwordUpdate = passwordForUserEdit(
            enteredPassword: "",
            storedPassword: user.password,
            isNewUser: false
        )
        XCTAssertNil(passwordUpdate, "the editor must represent a blank existing-user field as unchanged")
        Store.shared.saveUser(baseUrl: baseUrl, username: "after", password: passwordUpdate)

        XCTAssertEqual(Store.shared.getUser(baseUrl: baseUrl)?.username, "after")
        XCTAssertEqual(credentialStore.password(baseUrl: baseUrl), "keep-me",
                       "saving an unrelated edit must not delete the stored credential")
        XCTAssertEqual(Store.shared.getBasicUser(baseUrl: baseUrl)?.password, "keep-me")
    }

    // MARK: unread state — badges on the subscription list + swipe-to-toggle
    //
    // `read` is a Model 3 addition. Its model default is deliberately YES: lightweight migration
    // stamps the default onto every existing row, so a default of NO would mark a user's entire
    // notification history unread on upgrade and light up every topic with a badge. New arrivals
    // set read = false explicitly at insert instead.

    func testMigratedNotificationsDefaultToReadSoUpgradesDoNotLightUpEveryTopic() throws {
        let versions = try compiledModelVersionURLs()
        let models = versions.compactMap { NSManagedObjectModel(contentsOf: $0) }
        let previous = try XCTUnwrap(
            models.first {
                $0.entitiesByName["Notification"]?.attributesByName["read"] == nil
                    && $0.entitiesByName["Subscription"]?.attributesByName["fcmSubscribed"] != nil
            },
            "no shipped model version without `read` — the pre-unread version was edited away"
        )
        let current = try XCTUnwrap(
            models.first { $0.entitiesByName["Notification"]?.attributesByName["read"] != nil },
            "no model version WITH `read`"
        )

        let storeUrl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unread-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeUrl) }

        let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: previous)
        try oldCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                              at: storeUrl, options: nil)
        let oldContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        oldContext.persistentStoreCoordinator = oldCoordinator
        let old = NSEntityDescription.insertNewObject(forEntityName: "Notification", into: oldContext)
        old.setValue("pre-unread-1", forKey: "id")
        old.setValue(Int64(1), forKey: "time")
        old.setValue("an old message", forKey: "message")
        try oldContext.save()
        for store in oldCoordinator.persistentStores { try oldCoordinator.remove(store) }

        let newCoordinator = NSPersistentStoreCoordinator(managedObjectModel: current)
        try newCoordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: nil, at: storeUrl,
            options: [NSMigratePersistentStoresAutomaticallyOption: true,
                      NSInferMappingModelAutomaticallyOption: true])
        let newContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        newContext.persistentStoreCoordinator = newCoordinator
        let migrated = try newContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "Notification"))

        XCTAssertEqual(migrated.count, 1, "the pre-upgrade notification must survive")
        XCTAssertEqual(
            migrated.first?.value(forKey: "read") as? Bool, true,
            "history must migrate in as READ — defaulting to unread would badge every topic the "
                + "moment a user updates the app"
        )
    }

    func testUnreadCountCountsOnlyUnreadNotifications() {
        let context = Store.shared.context
        let subscription = Subscription(context: context)
        subscription.baseUrl = "https://ntfy.sh"
        subscription.topic = "unread-count"
        defer { context.delete(subscription) }

        var made: [ntfy.Notification] = []
        for (i, isRead) in [false, false, true].enumerated() {
            let n = ntfy.Notification(context: context)
            n.id = "unread-count-\(i)"
            n.time = Int64(i)
            n.message = "m\(i)"
            n.read = isRead
            n.subscription = subscription
            made.append(n)
        }
        defer { made.forEach { context.delete($0) } }

        XCTAssertEqual(subscription.notificationCount(), 3)
        XCTAssertEqual(subscription.unreadCount(), 2, "only the unread ones count toward the badge")
        XCTAssertTrue(subscription.hasUnread())
    }

    func testMarkingASubscriptionReadClearsTheBadgeAndUnreadRestoresIt() {
        let context = Store.shared.context
        let subscription = Subscription(context: context)
        subscription.baseUrl = "https://ntfy.sh"
        subscription.topic = "toggle-read"
        defer { context.delete(subscription) }

        var made: [ntfy.Notification] = []
        for i in 0..<3 {
            let n = ntfy.Notification(context: context)
            n.id = "toggle-read-\(i)"
            n.time = Int64(i)
            n.message = "m\(i)"
            n.read = false
            n.subscription = subscription
            made.append(n)
        }
        defer { made.forEach { context.delete($0) } }

        XCTAssertEqual(subscription.unreadCount(), 3)

        Store.shared.setRead(true, forSubscription: subscription)
        XCTAssertEqual(subscription.unreadCount(), 0, "swiping Read must clear the whole topic")
        XCTAssertFalse(subscription.hasUnread())

        Store.shared.setRead(false, forSubscription: subscription)
        XCTAssertEqual(subscription.unreadCount(), 3, "the whole-topic API still flips every notification")
        XCTAssertTrue(subscription.hasUnread())
    }

    func testMarkingATopicReadMaterializesOnlyRowsThatChange() throws {
        // Keep the app's subscription-list observer out of this measurement: it legitimately
        // re-fetches after a save and would materialize rows independently of `setRead`.
        let store = Store(inMemory: true)
        let context = store.context
        let subscription = NSEntityDescription.insertNewObject(
            forEntityName: "Subscription", into: context
        ) as! Subscription
        subscription.baseUrl = "https://ntfy.sh"
        subscription.topic = "read-fault-scope-\(UUID().uuidString)"

        var notifications: [ntfy.Notification] = []
        for i in 0..<40 {
            let notification = NSEntityDescription.insertNewObject(
                forEntityName: "Notification", into: context
            ) as! ntfy.Notification
            notification.id = "read-fault-scope-\(i)-\(UUID().uuidString)"
            notification.time = Int64(i)
            notification.message = "m\(i)"
            notification.read = i != 0 // one row must change; the other 39 are history
            notification.subscription = subscription
            notifications.append(notification)
        }
        try context.save()
        defer {
            context.delete(subscription)
            try? context.save()
        }

        // Re-fault every row while retaining object references so the test can observe which rows
        // the operation materializes. `isFault` itself does not fire a fault.
        notifications.forEach { context.refresh($0, mergeChanges: false) }
        XCTAssertTrue(notifications.allSatisfy(\.isFault), "test premise: all history starts faulted")

        store.setRead(true, forSubscription: subscription)

        let materialized = notifications.filter { !$0.isFault }
        XCTAssertEqual(materialized.count, 1,
                       "marking one unread row must not materialize the topic's already-read history")
        XCTAssertEqual(materialized.first?.read, true)
    }

    func testMarkingAFullyReadTopicUnreadFlagsOnlyTheNewestMessage() {
        // What the swipe actually calls. Flipping the whole topic back would badge a fully-read
        // topic with its entire history; the badge should mean "one new thing to look at".
        let context = Store.shared.context
        let subscription = Subscription(context: context)
        subscription.baseUrl = "https://ntfy.sh"
        subscription.topic = "unread-newest"
        defer { context.delete(subscription) }

        var made: [ntfy.Notification] = []
        for i in 0..<5 {
            let n = ntfy.Notification(context: context)
            n.id = "unread-newest-\(i)"
            n.time = Int64(100 + i) // i == 4 is the newest
            n.message = "m\(i)"
            n.read = true
            n.subscription = subscription
            made.append(n)
        }
        defer { made.forEach { context.delete($0) } }

        XCTAssertEqual(subscription.unreadCount(), 0)

        Store.shared.markMostRecentUnread(subscription: subscription)

        XCTAssertEqual(subscription.unreadCount(), 1,
                       "marking a read topic unread must flag exactly one message, not the history")
        XCTAssertEqual(subscription.lastNotification()?.id, "unread-newest-4",
                       "and it must be the newest one")
        XCTAssertEqual(subscription.lastNotification()?.read, false)
    }

    // MARK: - App icon badge (ntfy#1462, ntfy-ios#24)
    //
    // The per-topic badges landed first; the icon badge is the same number rolled up. It is
    // asserted as a delta against a baseline because Store.shared is one in-memory store shared by
    // the whole test class, so other tests' rows are legitimately in the count.

    /// Builds `count` unread notifications on a throwaway subscription and returns a teardown block.
    private func seedUnread(_ count: Int, topic: String, read: Bool = false) -> () -> Void {
        let context = Store.shared.context
        let subscription = Subscription(context: context)
        subscription.baseUrl = "https://ntfy.sh"
        subscription.topic = topic

        var made: [ntfy.Notification] = []
        for i in 0..<count {
            let n = ntfy.Notification(context: context)
            n.id = "\(topic)-\(i)"
            n.time = Int64(i)
            n.message = "m\(i)"
            n.read = read
            n.subscription = subscription
            made.append(n)
        }
        try? context.save()
        return {
            made.forEach { context.delete($0) }
            context.delete(subscription)
            try? context.save()
        }
    }

    func testTotalUnreadCountSpansEverySubscription() {
        let baseline = Store.shared.totalUnreadCount()

        let teardownA = seedUnread(2, topic: "badge-total-a")
        defer { teardownA() }
        let teardownB = seedUnread(3, topic: "badge-total-b")
        defer { teardownB() }

        XCTAssertEqual(Store.shared.totalUnreadCount(), baseline + 5,
                       "the icon badge is the roll-up of every topic's unread count, not one topic's")
    }

    func testTotalUnreadCountIgnoresReadNotifications() {
        let baseline = Store.shared.totalUnreadCount()

        let teardownRead = seedUnread(4, topic: "badge-read", read: true)
        defer { teardownRead() }

        XCTAssertEqual(Store.shared.totalUnreadCount(), baseline,
                       "already-read messages must not keep the icon badged")
    }

    func testMarkingATopicReadBringsTheTotalDown() throws {
        let baseline = Store.shared.totalUnreadCount()

        let teardown = seedUnread(3, topic: "badge-clear")
        defer { teardown() }
        XCTAssertEqual(Store.shared.totalUnreadCount(), baseline + 3)

        let subscription = try XCTUnwrap(
            Store.shared.getSubscription(baseUrl: "https://ntfy.sh", topic: "badge-clear"))
        Store.shared.setRead(true, forSubscription: subscription)

        XCTAssertEqual(Store.shared.totalUnreadCount(), baseline,
                       "swiping a topic Read has to clear its share of the icon badge too")
    }

    func testModifySetsTheBadgeToTheUnreadTotal() {
        // Red before the fix: `modify` never touched `badge`, so the icon stayed clean no matter
        // how many messages piled up while the app wasn't running — ntfy#1462.
        let teardown = seedUnread(2, topic: "badge-on-content")
        defer { teardown() }

        let expected = Store.shared.totalUnreadCount()
        XCTAssertGreaterThanOrEqual(expected, 2)

        let content = modifiedContent(priority: nil, title: "T")

        XCTAssertEqual(content.badge?.intValue, expected,
                       "the delivered payload must carry the unread total — it is the only thing "
                           + "that can move the icon badge while the app never runs")
    }

    // MARK: - Delivery-path correctness batch

    func testPriorityIsClampedIntoTheModelsAllowedRange() {
        // RED before the fix: the raw value went straight onto the managed object, and the model
        // constrains priority to 1...5. Core Data validates at save time, so ONE bad value fails the
        // whole batch save — and the catch rolls back the lastNotificationId advance with it, so the
        // next poll re-fetches the same window and fails identically. The topic stops storing
        // messages permanently, silently.
        XCTAssertEqual(Store.clampPriority(6), 5, "a server that lets Priority: 6 through must not wedge the topic")
        XCTAssertEqual(Store.clampPriority(-1), 1)
        XCTAssertEqual(Store.clampPriority(99), 5)
        // 0 and nil both mean "not set" and map to ntfy's default.
        XCTAssertEqual(Store.clampPriority(0), 3)
        XCTAssertEqual(Store.clampPriority(nil), 3)
        // In-range values are untouched.
        for p in Int16(1)...Int16(5) {
            XCTAssertEqual(Store.clampPriority(p), p)
        }
    }

    func testPushPathStillDeliversForAnAlreadyStoredMessage() {
        // A guard against an attractive-looking "optimisation": suppressing NSE delivery whenever
        // the message id is already in the store. It is wrong, twice over, and the failure mode is
        // a notification the user never sees:
        //   1. SubscriptionManager.subscribe polls `since=all` through the completion-discarding
        //      poll(_:) overload, so the server's whole cached history is persisted with no banner
        //      ever shown. A genuinely new message published during that window gets stored by the
        //      poll first — suppressing its push would erase its only notification.
        //   2. The Notification uniqueness constraint is `id` alone, unscoped by subscription, so
        //      two independent servers minting the same id collide and the second server's real
        //      message would be dropped as a "duplicate".
        // Until a durable per-notification "was alerted" flag exists, an occasional re-alert beats
        // a dropped first banner. Delivering twice is recoverable; not delivering is not.
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: "dupe-topic")
        deleteAfterTest(subscription)

        let message = Message(id: "dupe-1", time: 1, event: "message", topic: "dupe-topic",
                              message: "hi", title: nil, priority: nil, tags: nil)

        XCTAssertTrue(Store.shared.save(notificationFromMessage: message, baseUrl: "https://ntfy.sh", topic: "dupe-topic"),
                      "first delivery must be persisted and delivered")
        XCTAssertTrue(Store.shared.save(notificationFromMessage: message, baseUrl: "https://ntfy.sh", topic: "dupe-topic"),
                      "a redelivery of an already-stored id must STILL deliver — a stored row does "
                          + "not prove the user was ever alerted")
        XCTAssertFalse(Store.shared.save(notificationFromMessage: message, baseUrl: "https://ntfy.sh", topic: "no-such-topic"),
                       "an unknown topic is the one case that falls back to the raw push content")
    }

    func testSubscriptionMatchesIgnoresBaseUrlTrailingSlash() {
        // RED before the fix: the delivered notification's raw `base_url` was compared against the
        // normalized stored one, so a self-hosted server whose base-url carries a trailing slash
        // never matched — opening the topic never cleared its banners from Notification Center.
        let context = Store.shared.context
        let subscription = Subscription(context: context)
        subscription.baseUrl = "https://ntfy.example.com" // stored normalized
        subscription.topic = "alerts"
        defer { context.delete(subscription) }

        XCTAssertTrue(subscription.matches(baseUrl: "https://ntfy.example.com/", topic: "alerts"),
                      "a trailing slash in the server's configured base-url must still match")
        XCTAssertTrue(subscription.matches(baseUrl: "https://ntfy.example.com", topic: "alerts"))
        XCTAssertFalse(subscription.matches(baseUrl: "https://ntfy.example.com", topic: "other"))
        XCTAssertFalse(subscription.matches(baseUrl: "https://other.example.com", topic: "alerts"),
                       "a different server must never match — topic names collide across servers")
    }

    func testEmptyStateExampleTargetsTheSubscriptionsOwnServer() {
        // The empty-topic instructions used to hard-code ntfy.sh, so a self-hosted user following
        // them published their test message to the public server instead of their own.
        let context = Store.shared.context
        let subscription = Subscription(context: context)
        subscription.baseUrl = "https://ntfy.example.com"
        subscription.topic = "selfhosted"
        defer { context.delete(subscription) }

        XCTAssertEqual(subscription.shortUrlString(), "ntfy.example.com/selfhosted")
        XCTAssertFalse(subscription.shortUrlString().contains("ntfy.sh"),
                       "the publish example must point at the topic's own server")
    }

    // MARK: - A write from the extension's process must reach the visible list

    func testTheRemoteChangeBroadcastMakesTheListPickUpAStoreLevelWrite() throws {
        // RED before the fix: a row committed by the notification service extension's *process* was
        // invisible to the app's list. An NSFetchedResultsController's membership changes only when
        // the context it observes processes a save, and a cross-process commit never produces one;
        // Store.hardRefresh()'s refreshAllObjects() only re-faults objects the view context has
        // already registered, which a row from another process is not. So a push arriving while the
        // topic list was on screen left it stale until the user navigated away and back.
        //
        // NSBatchInsertRequest is the honest in-process stand-in: it writes straight to the store
        // and notifies no context, which is exactly what the extension's commit looks like from in
        // here. (Subscription is used rather than Notification because batch inserts cannot set
        // relationships, and the notification fetch is scoped to a subscription — the observable
        // and its re-fetch path are the same either way.)
        let observable = SubscriptionsObservable()
        let baseline = observable.subscriptions.count

        let insert = NSBatchInsertRequest(entity: Subscription.entity(), objects: [[
            "baseUrl": "https://remote-write.example.com",
            "topic": "written-by-the-extension",
            "fcmSubscribed": true,
        ]])
        _ = try Store.shared.context.execute(insert)
        defer {
            if let stray = Store.shared.getSubscription(baseUrl: "https://remote-write.example.com",
                                                        topic: "written-by-the-extension") {
                Store.shared.context.delete(stray)
                try? Store.shared.context.save()
            }
        }

        XCTAssertEqual(observable.subscriptions.count, baseline,
                       "premise: a store-level write is invisible to the fetched-results controller")

        NotificationCenter.default.post(name: Store.didChangeRemotely, object: nil)

        // The observer is registered against the main queue; drain it once so the assertion does
        // not depend on whether the post was delivered synchronously.
        let settled = expectation(description: "observable absorbed the broadcast")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 10)

        XCTAssertEqual(observable.subscriptions.count, baseline + 1,
                       "Store.didChangeRemotely must drive a re-fetch, or a pushed message never "
                           + "appears until the user navigates away and back")
        XCTAssertTrue(observable.subscriptions.contains { $0.topic == "written-by-the-extension" })
    }

    // MARK: - Notification timestamps always carry a time (ntfy#1205)
    //
    // Before this, anything not from today lost its time entirely: yesterday rendered as the bare
    // word "yesterday", older messages as a bare date. There was no way to tell whether an alert
    // landed at 09:00 or 23:00 — which is precisely what ntfy#1205 asks for.
    //
    // These use the REAL current date on purpose. `doesRelativeDateFormatting` decides "is this
    // yesterday?" against the system clock, so it cannot be driven by an injected `now` — a test
    // built on a fake date silently exercises the absolute-date path instead of the relative one.
    // Region is pinned to en_US so AM/PM is predictable; expectations are built with a formatter
    // rather than string literals, because iOS separates the time from AM/PM with a narrow no-break
    // space (U+202F) that does not survive being typed into a test.

    private func referenceTime(_ date: Date, locale: Locale = Locale(identifier: "en_US")) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    func testTodaysNotificationShowsTheTimeWithoutADate() {
        let now = Date()
        let calendar = Calendar.current
        let locale = Locale(identifier: "en_US")
        // Midday today, so the assertion cannot straddle a day boundary.
        let today = calendar.date(bySettingHour: 12, minute: 0, second: 0,
                                  of: calendar.startOfDay(for: now))!

        let rendered = ntfy.Notification.shortDateTime(for: today, now: now,
                                                       calendar: calendar, locale: locale)

        XCTAssertEqual(rendered, referenceTime(today),
                       "today shows the time and no date — the list is already chronological")
    }

    func testYesterdaysNotificationKeepsItsTime() throws {
        // RED before the fix: this returned the bare string "yesterday", with no time at all.
        let now = Date()
        let calendar = Calendar.current
        let locale = Locale(identifier: "en_US")
        // Built from calendar components, not elapsed seconds: on a spring-forward day the civil
        // day is only 23 hours long, so `startOfDay + 23*3600` lands on TODAY's midnight and the
        // test would fail once a year, in some timezones only.
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let yesterdayEvening = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: yesterdayStart)!

        let rendered = ntfy.Notification.shortDateTime(for: yesterdayEvening, now: now,
                                                       calendar: calendar, locale: locale)

        XCTAssertTrue(rendered.contains(referenceTime(yesterdayEvening)),
                      "yesterday must still say WHEN — got \(rendered)")
        // doesRelativeDateFormatting resolves "yesterday" against the real clock when the string is
        // built, so a run that straddles local midnight would legitimately disagree with the `now`
        // captured above. Skip rather than fail in that vanishingly rare case.
        guard calendar.isDate(now, inSameDayAs: Date()) else {
            throw XCTSkip("the local day rolled over mid-test")
        }
        XCTAssertTrue(rendered.localizedCaseInsensitiveContains("yesterday"),
                      "and should still read as yesterday — got \(rendered)")
    }

    func testAnOlderNotificationShowsBothDateAndTime() {
        // RED before the fix: this returned a bare date with no time at all.
        let now = Date()
        let calendar = Calendar.current
        let locale = Locale(identifier: "en_US")
        let lastWeekStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!
        let lastWeek = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: lastWeekStart)!

        let rendered = ntfy.Notification.shortDateTime(for: lastWeek, now: now,
                                                       calendar: calendar, locale: locale)

        XCTAssertTrue(rendered.contains(referenceTime(lastWeek)),
                      "an older message must still say when — got \(rendered)")
        XCTAssertTrue(rendered.contains("/"),
                      "and which day — got \(rendered)")
    }

    func testTheRelativeWordIsLocalizedRatherThanHardcoded() {
        // The old code returned the literal English "yesterday" to every user regardless of region.
        // Relative formatting is locale-aware, so a German build gets "Gestern".
        let now = Date()
        let calendar = Calendar.current
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let yesterday = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: yesterdayStart)!

        let german = ntfy.Notification.shortDateTime(for: yesterday, now: now, calendar: calendar,
                                                     locale: Locale(identifier: "de_DE"))

        XCTAssertFalse(german.isEmpty)
        XCTAssertFalse(german.localizedCaseInsensitiveContains("yesterday"),
                       "the relative word must come from the locale, not a hardcoded English "
                           + "literal — got \(german)")
    }

    // MARK: - Topic sort order (ntfy#1740)

    private func seedTopic(_ topic: String, displayName: String? = nil,
                           messageTimes: [Int64] = []) -> Subscription {
        let context = Store.shared.context
        let subscription = Subscription(context: context)
        subscription.baseUrl = "https://ntfy.sh"
        subscription.topic = topic
        subscription.customDisplayName = displayName
        for (i, time) in messageTimes.enumerated() {
            let n = ntfy.Notification(context: context)
            n.id = "\(topic)-\(i)"
            n.time = time
            n.message = "m"
            n.read = true
            n.priority = 3
            n.subscription = subscription
        }
        try? context.save()
        return subscription
    }

    func testLastNotificationTimesReturnsTheNewestPerSubscription() throws {
        let a = seedTopic("sort-a", messageTimes: [100, 500, 300])
        let b = seedTopic("sort-b", messageTimes: [900])
        let empty = seedTopic("sort-empty")
        defer { [a, b, empty].forEach { Store.shared.delete(subscription: $0) } }

        let summaries = try XCTUnwrap(Store.shared.subscriptionSummaries(),
                                      "the aggregate must succeed on a healthy store")
        let times = summaries.mapValues { $0.lastTime }

        XCTAssertEqual(times[a.objectID], 500, "the newest message wins, not the last inserted")
        XCTAssertEqual(times[b.objectID], 900)
        XCTAssertNil(times[empty.objectID] ?? nil,
                     "a topic with no messages must be absent, not zero — zero would sort it as "
                         + "the oldest rather than as having no activity")
    }

    func testSubscriptionSummariesAggregateTotalsUnreadAndNewest() throws {
        let context = Store.shared.context
        let busy = seedTopic("summary-busy", messageTimes: [100, 500, 300])
        let quiet = seedTopic("summary-quiet", messageTimes: [42])
        let empty = seedTopic("summary-empty")
        defer { [busy, quiet, empty].forEach { Store.shared.delete(subscription: $0) } }

        // Mark one of the busy topic's three as unread; seedTopic writes them read.
        if let newest = busy.lastNotification() {
            newest.read = false
            try? context.save()
        }

        let summaries = try XCTUnwrap(Store.shared.subscriptionSummaries())

        XCTAssertEqual(summaries[busy.objectID]?.total, 3)
        XCTAssertEqual(summaries[busy.objectID]?.unread, 1, "unread is counted separately from the total")
        XCTAssertEqual(summaries[busy.objectID]?.lastTime, 500, "newest, not last inserted")

        XCTAssertEqual(summaries[quiet.objectID]?.total, 1)
        XCTAssertEqual(summaries[quiet.objectID]?.unread, 0)
        XCTAssertEqual(summaries[quiet.objectID]?.lastTime, 42)

        XCTAssertNil(summaries[empty.objectID],
                     "a topic with no messages is absent rather than a zero row — the sort relies "
                         + "on that to place it as 'no activity' instead of 'oldest'")
    }

    func testSubscriptionSummariesMatchTheirPerObjectEquivalents() throws {
        // The aggregate replaces notificationCount()/unreadCount()/lastNotification() in the row.
        // Pin that it agrees with them, so the cheap path cannot drift from the obvious one.
        let context = Store.shared.context
        let subscription = seedTopic("summary-parity", messageTimes: [10, 20, 30, 40])
        defer { Store.shared.delete(subscription: subscription) }

        if let notifications = subscription.notifications as? Set<ntfy.Notification> {
            for n in notifications where n.time <= 20 { n.read = false }
            try? context.save()
        }

        let summary = try XCTUnwrap(Store.shared.subscriptionSummaries())[subscription.objectID]

        XCTAssertEqual(summary?.total, subscription.notificationCount())
        XCTAssertEqual(summary?.unread, subscription.unreadCount())
        XCTAssertEqual(summary?.lastTime, subscription.lastNotification()?.time)
    }

    // MARK: Pinned topics — swipe right to pin, pinned rows sort above the rest

    private func makePinTestSubscriptions(_ topics: [String]) -> [Subscription] {
        let context = Store.shared.context
        let made = topics.map { topic -> Subscription in
            let subscription = Subscription(context: context)
            subscription.baseUrl = "https://pin-test.example.com"
            subscription.topic = topic
            return subscription
        }
        try? context.save()
        return made
    }

    private func removePinTestSubscriptions(_ subscriptions: [Subscription]) {
        subscriptions.forEach { Store.shared.context.delete($0) }
        try? Store.shared.context.save()
    }

    private func pinTestOrder(_ observable: SubscriptionsObservable) -> [String] {
        observable.subscriptions
            .filter { $0.baseUrl == "https://pin-test.example.com" }
            .compactMap { $0.topic }
    }

    func testPinnedTopicsSortAboveTheRestAndKeepTheChosenOrderWithinEachGroup() {
        let made = makePinTestSubscriptions(["pin-a", "pin-b", "pin-c", "pin-d"])
        defer { removePinTestSubscriptions(made) }
        let observable = SubscriptionsObservable()
        XCTAssertEqual(pinTestOrder(observable), ["pin-a", "pin-b", "pin-c", "pin-d"],
                       "premise: alphabetical with nothing pinned")

        Store.shared.setPinned(true, forSubscription: made[3])
        Store.shared.setPinned(true, forSubscription: made[2])
        observable.refetch()

        XCTAssertEqual(pinTestOrder(observable), ["pin-c", "pin-d", "pin-a", "pin-b"],
                       "pinned topics lead, and the name order still holds inside both groups")

        Store.shared.setPinned(false, forSubscription: made[2])
        observable.refetch()
        XCTAssertEqual(pinTestOrder(observable), ["pin-d", "pin-a", "pin-b", "pin-c"],
                       "unpinning drops a topic back into its normal place")
    }

    func testPinningReordersTheLiveListWithoutAnExplicitRefetch() {
        // The swipe action only calls Store.setPinned; nothing re-fetches. The list must move the
        // row on its own, the way it does when the app is actually used.
        let made = makePinTestSubscriptions(["pin-live-a", "pin-live-b"])
        defer { removePinTestSubscriptions(made) }
        let observable = SubscriptionsObservable()
        XCTAssertEqual(pinTestOrder(observable), ["pin-live-a", "pin-live-b"], "premise")

        Store.shared.setPinned(true, forSubscription: made[1])
        let settled = expectation(description: "main queue drained")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 10)

        XCTAssertEqual(pinTestOrder(observable), ["pin-live-b", "pin-live-a"],
                       "a pin must lift the row in the list that is already on screen")
    }

    func testPinnedTopicsLeadUnderRecentActivityOrderToo() {
        let made = makePinTestSubscriptions(["pin-quiet", "pin-busy"])
        let context = Store.shared.context
        let message = ntfy.Notification(context: context)
        message.id = "pin-test-\(UUID().uuidString)"
        message.time = Int64(Date().timeIntervalSince1970)
        message.message = "recent"
        message.subscription = made[1]
        try? context.save()
        Store.shared.saveTopicSortOrder(.recentActivity)
        defer {
            Store.shared.saveTopicSortOrder(.name)
            context.delete(message)
            removePinTestSubscriptions(made)
        }
        let observable = SubscriptionsObservable()
        XCTAssertEqual(pinTestOrder(observable), ["pin-busy", "pin-quiet"],
                       "premise: newest activity first")

        Store.shared.setPinned(true, forSubscription: made[0])
        observable.refetch()
        XCTAssertEqual(pinTestOrder(observable), ["pin-quiet", "pin-busy"],
                       "a pinned topic stays on top even when it has no recent activity")
    }

    func testAPinIsWrittenToTheStoreSoItSurvivesARelaunch() throws {
        let made = makePinTestSubscriptions(["pin-persisted"])
        defer { removePinTestSubscriptions(made) }

        Store.shared.setPinned(true, forSubscription: made[0])

        // A context of its own reads from the persistent store, not from the view context's
        // in-memory objects — so this only passes if the pin was actually saved.
        let fresh = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        fresh.persistentStoreCoordinator = Store.shared.context.persistentStoreCoordinator
        var stored: Bool?
        fresh.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Subscription")
            request.predicate = NSPredicate(format: "topic == %@", "pin-persisted")
            stored = (try? fresh.fetch(request))?.first?.value(forKey: "pinned") as? Bool
        }
        XCTAssertEqual(stored, true)
    }

    func testMigratedSubscriptionsArriveUnpinned() throws {
        let models = try compiledModelVersionURLs().compactMap { NSManagedObjectModel(contentsOf: $0) }
        let previous = try XCTUnwrap(
            models.first {
                $0.entitiesByName["Subscription"]?.attributesByName["pinned"] == nil
                    && $0.entitiesByName["Notification"]?.attributesByName["read"] != nil
            },
            "no shipped model version without `pinned` — the pre-pin version was edited away"
        )
        let current = try XCTUnwrap(
            models.first { $0.entitiesByName["Subscription"]?.attributesByName["pinned"] != nil },
            "no model version WITH `pinned`"
        )

        let storeUrl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pin-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeUrl) }

        let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: previous)
        try oldCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                              at: storeUrl, options: nil)
        let oldContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        oldContext.persistentStoreCoordinator = oldCoordinator
        let old = NSEntityDescription.insertNewObject(forEntityName: "Subscription", into: oldContext)
        old.setValue("https://ntfy.sh", forKey: "baseUrl")
        old.setValue("pre-pin", forKey: "topic")
        try oldContext.save()
        for store in oldCoordinator.persistentStores { try oldCoordinator.remove(store) }

        let newCoordinator = NSPersistentStoreCoordinator(managedObjectModel: current)
        try newCoordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: nil, at: storeUrl,
            options: [NSMigratePersistentStoresAutomaticallyOption: true,
                      NSInferMappingModelAutomaticallyOption: true])
        let newContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        newContext.persistentStoreCoordinator = newCoordinator
        let migrated = try newContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "Subscription"))

        XCTAssertEqual(migrated.count, 1, "the pre-upgrade subscription must survive")
        XCTAssertEqual(migrated.first?.value(forKey: "pinned") as? Bool, false,
                       "upgrading must not pin anything the user didn't pin")
    }

    func testTopicSortOrderDefaultsToNameAndRoundTrips() {
        XCTAssertEqual(Store.shared.getTopicSortOrder(), .name,
                       "an existing install's list must not silently rearrange on upgrade")

        Store.shared.saveTopicSortOrder(.recentActivity)
        XCTAssertEqual(Store.shared.getTopicSortOrder(), .recentActivity)

        Store.shared.saveTopicSortOrder(.name)
        XCTAssertEqual(Store.shared.getTopicSortOrder(), .name)
    }

    func testAnUnknownStoredSortOrderFallsBackToTheDefault() {
        // Forward compatibility: a value written by a newer build must not map onto the wrong case.
        Store.shared.saveTopicSortOrder(.recentActivity)
        Store.shared.saveRawTopicSortOrderForTesting("sortByVibes")

        XCTAssertEqual(Store.shared.getTopicSortOrder(), .name)
        Store.shared.saveTopicSortOrder(.name)
    }

    func testEveryPreviousModelVersionIsStillShipped() throws {
        let versions = try compiledModelVersionURLs()
        XCTAssertGreaterThanOrEqual(
            versions.count, 2,
            "the .xcdatamodeld must keep the shipped model version alongside the new one — "
                + "editing Model.xcdatamodel in place strands every existing install with an "
                + "unopenable store (found: \(versions.map { $0.lastPathComponent }))"
        )
    }

    func testStoreCreatedWithThePreviousModelVersionOpensUnderTheCurrentModel() throws {
        let versions = try compiledModelVersionURLs()
        let models = versions.compactMap { NSManagedObjectModel(contentsOf: $0) }

        // The pre-#1305 shape is the one whose Subscription entity has no `fcmSubscribed`.
        let previous = try XCTUnwrap(
            models.first { ($0.entitiesByName["Subscription"]?.attributesByName["fcmSubscribed"]) == nil },
            "no shipped model version without `fcmSubscribed` — the old version was edited away"
        )
        let current = try XCTUnwrap(
            models.first { ($0.entitiesByName["Subscription"]?.attributesByName["fcmSubscribed"]) != nil },
            "no model version WITH `fcmSubscribed`"
        )

        let storeUrl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("migration-\(UUID().uuidString).sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: storeUrl)
        }

        // 1. Create a store the way an already-installed build 13 would have.
        let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: previous)
        try oldCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                              at: storeUrl, options: nil)
        let oldContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        oldContext.persistentStoreCoordinator = oldCoordinator
        let subscription = NSEntityDescription.insertNewObject(forEntityName: "Subscription", into: oldContext)
        subscription.setValue("https://ntfy.sh", forKey: "baseUrl")
        subscription.setValue("upgrade-survivor", forKey: "topic")
        try oldContext.save()
        for store in oldCoordinator.persistentStores {
            try oldCoordinator.remove(store)
        }

        // 2. Open it with the current model exactly as Store.init does.
        let newCoordinator = NSPersistentStoreCoordinator(managedObjectModel: current)
        let options: [AnyHashable: Any] = [
            NSMigratePersistentStoresAutomaticallyOption: true,
            NSInferMappingModelAutomaticallyOption: true,
        ]
        XCTAssertNoThrow(
            try newCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                                  at: storeUrl, options: options),
            "a store created by the shipped model version must migrate into the current one — "
                + "if this throws, upgrading the app wipes the user's subscriptions"
        )

        // 3. The user's data is still there, and the new attribute defaults sanely.
        let newContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        newContext.persistentStoreCoordinator = newCoordinator
        let request = NSFetchRequest<NSManagedObject>(entityName: "Subscription")
        let migrated = try newContext.fetch(request)
        XCTAssertEqual(migrated.count, 1, "the pre-upgrade subscription must survive the migration")
        XCTAssertEqual(migrated.first?.value(forKey: "topic") as? String, "upgrade-survivor")
        XCTAssertEqual(migrated.first?.value(forKey: "fcmSubscribed") as? Bool, false,
                       "a migrated row must land in the retry queue so its FCM binding is (re)established")
    }

    // MARK: - End-to-end encrypted topics (upstream ntfy E2E draft: binwiederhier/ntfy#69, PR #354)
    //
    // Vectors come from implementations that are not this Swift code:
    //   - upstream's own Go tests (crypto/crypto_test.go at PR #354 head a66731641c52): a derived-key
    //     hex, and JWEs made by upstream's PHP and Python examples;
    //   - Python `cryptography` (scripts/e2e-interop/interop.py) with fixed IVs, for a full payload
    //     and a byte-for-byte encryption comparison.
    // The other direction (Swift output decrypting in Python) is scripts/e2e-interop/run.sh.

    private static let upstreamPassword = "secr3t password"
    private static let upstreamTopicUrl = "https://ntfy.sh/mysecret"
    private static let vectorPassword = "vector password ✓"
    private static let vectorTopicUrl = "https://ntfy-me.com/e2e-vectors"
    /// interop.py encrypt <vectorPassword> <vectorTopicUrl> '{"message":"Disk 92% full",...}' 000102030405060708090a0b
    private static let pythonFullPayloadJWE = "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..AAECAwQFBgcICQoL.QsacIqhbH51ZmwLO96X8VNqjtlRPVNTpGjP6AcseZauXBxl9wZULe9Hi70Ejtt7pKdWpyq6_UbvghMevDg2Aww3Bc6M_dWP24WMsC8MnO_ngi04ShxpjqMllT12nCJkv7YkcCoXRTIPbxgM03IzG8MXMF0Q4Is1F7JMvsQ0VbKJM_5KbME3LLKk8r1AZs_sfpTgIC6GvKS5kC3zAEMYoZKLrZjja3hHJ26lXNTH_0-N1p_3KOF4Y_sxFHlfo5xj-RoUlnwgWuAVkLANJyON0KQsRAVfiZyfbUg_XEev8ye3tNQduf_vlIfRW8Em5JJ29Gu2PU2oOSyZKLtkcqcCbLIRUU-2wa9bhKnS8Ef4BK2ANDlGm-hA41yT-1s0boxzDgWCMwVCrq0LLLpAueRG_UwToTG9FaBKgdtAljbHAK2LrcvwB.LUqXQy0ChytWj2F_uLKsTA"
    /// interop.py encrypt <vectorPassword> <vectorTopicUrl> 'plain text, not JSON' 0c0d0e0f1011121314151617
    private static let pythonPlainTextJWE = "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..DA0ODxAREhMUFRYX.9W1edLGO1g4lI3ouB5e1eCfFVFU.y2sgqWt8XuVwv2WKtojYfg"
    private static let upstreamPHPJWE = "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..vbe1Qv_-mKYbUgce.EfmOUIUi7lxXZG_o4bqXZ9pmpr1Rzs4Y5QLE2XD2_aw_SQ.y2hadrN5b2LEw7_PJHhbcA"
    private static let upstreamPythonJWE = "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..gSRYZeX6eBhlj13w.LOchcxFXwALXE2GqdoSwFJEXdMyEbLfLKV9geXr17WrAN-nH7ya1VQ_Y6ebT1w.2eyLaTUfc_rpKaZr4-5I1Q"

    private func hex(_ data: Data?) -> String? {
        data?.map { String(format: "%02x", $0) }.joined()
    }

    private func vectorKey() throws -> Data {
        try XCTUnwrap(TopicEncryption.deriveKey(password: Self.vectorPassword, topicUrl: Self.vectorTopicUrl))
    }

    func testKeyDerivationMatchesUpstreamGoAndPythonVectors() {
        XCTAssertEqual(hex(TopicEncryption.deriveKey(password: Self.upstreamPassword, topicUrl: Self.upstreamTopicUrl)),
                       "30b7e72f6273da6e59d2dec535466e548da3eafc98650c9664c06edab707fa25",
                       "upstream crypto_test.go TestDeriveKey")
        XCTAssertEqual(hex(TopicEncryption.deriveKey(password: Self.vectorPassword, topicUrl: Self.vectorTopicUrl)),
                       "6cde5921f6e2babaf157141135dc95510c08f1b0a3b97e9c2f06a3ad184f7eb1",
                       "Python hashlib.pbkdf2_hmac, non-ASCII password")
    }

    func testDecryptsUpstreamPHPAndPythonExampleCiphertexts() throws {
        let key = try XCTUnwrap(TopicEncryption.deriveKey(password: Self.upstreamPassword, topicUrl: Self.upstreamTopicUrl))
        XCTAssertEqual(String(decoding: try TopicEncryption.decrypt(Self.upstreamPHPJWE, key: key), as: UTF8.self),
                       #"{"message":"Secret!","priority":5}"#)
        XCTAssertEqual(String(decoding: try TopicEncryption.decrypt(Self.upstreamPythonJWE, key: key), as: UTF8.self),
                       #"{"message":"Python says hi","tags":["secret"]}"#)
    }

    func testSwiftEncryptionIsByteIdenticalToPythonForTheSameKeyAndIV() throws {
        let iv = Data([0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17])
        let jwe = try TopicEncryption.encrypt(Data("plain text, not JSON".utf8), key: try vectorKey(), iv: iv)
        XCTAssertEqual(jwe, Self.pythonPlainTextJWE)
        XCTAssertTrue(jwe.hasPrefix("eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0.."),
                      #"header must be exactly {"alg":"dir","enc":"A256GCM"} with an empty key segment"#)
    }

    func testFullPythonPayloadDecodesIntoEveryNtfyField() throws {
        let outer = Message(id: "e2e-full", time: 1, event: "message", topic: "e2e-vectors",
                            message: Self.pythonFullPayloadJWE, priority: 3)
        let ingested = TopicEncryption.ingest(outer, key: try vectorKey())
        XCTAssertEqual(ingested.encryption, .decrypted)
        XCTAssertNil(ingested.ciphertext)
        let m = ingested.message
        XCTAssertEqual(m.message, "Disk 92% full")
        XCTAssertEqual(m.title, "nas01")
        XCTAssertEqual(m.tags, ["warning", "disk"])
        XCTAssertEqual(m.priority, 5)
        XCTAssertEqual(m.click, "https://example.com/nas")
        XCTAssertEqual(m.contentType, "text/markdown")
        XCTAssertEqual(m.actions?.map(\.label), ["Open", "Clean"])
        XCTAssertEqual(m.actions?.map(\.id), ["e2e-full-e2e0", "e2e-full-e2e1"],
                       "action ids must be derived from the message id so the app and the extension agree")
        XCTAssertEqual(m.actions?.last?.method, "POST")
        XCTAssertEqual(m.actions?.last?.clear, true)
        XCTAssertEqual(m.id, "e2e-full", "outer envelope fields are kept")
    }

    func testAnAuthenticatedNonJSONPlaintextIsShownAsText() throws {
        let outer = Message(id: "e2e-text", time: 1, event: "message", topic: "t", message: Self.pythonPlainTextJWE)
        let ingested = TopicEncryption.ingest(outer, key: try vectorKey())
        XCTAssertEqual(ingested.encryption, .decrypted)
        XCTAssertEqual(ingested.message.message, "plain text, not JSON")
    }

    func testWrongPasswordTamperedTagAndWrongTopicUrlEachFailCleanly() throws {
        let wrongPassword = try XCTUnwrap(TopicEncryption.deriveKey(password: "not it", topicUrl: Self.vectorTopicUrl))
        let wrongTopic = try XCTUnwrap(TopicEncryption.deriveKey(password: Self.vectorPassword,
                                                                 topicUrl: "https://ntfy-me.com/other-topic"))
        var parts = Self.pythonPlainTextJWE.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var tag = try XCTUnwrap(TopicEncryption.base64urlDecode(parts[4]))
        tag[0] ^= 0x01
        parts[4] = TopicEncryption.base64urlEncode(tag)
        let tampered = parts.joined(separator: ".")

        for (name, text, key) in [("wrong password", Self.pythonPlainTextJWE, wrongPassword),
                                  ("wrong topic URL (salt)", Self.pythonPlainTextJWE, wrongTopic),
                                  ("tampered tag", tampered, try vectorKey())] {
            XCTAssertThrowsError(try TopicEncryption.decrypt(text, key: key), name) { error in
                XCTAssertEqual(error as? TopicEncryption.Failure, .authenticationFailed, name)
            }
            let ingested = TopicEncryption.ingest(Message(id: "x", time: 1, event: "message", topic: "t", message: text), key: key)
            XCTAssertEqual(ingested.encryption, .locked, name)
            XCTAssertEqual(ingested.message.message, TopicEncryption.lockedPlaceholder, name)
        }
    }

    func testOversizedPayloadIsRefusedRatherThanTurnedIntoAnAttachment() throws {
        let big = EncryptedPayload(message: String(repeating: "x", count: 3_100))
        XCTAssertThrowsError(try TopicEncryption.encrypt(big, key: try vectorKey())) { error in
            guard case .tooLarge = error as? TopicEncryption.Failure else {
                return XCTFail("expected tooLarge, got \(error)")
            }
        }
        XCTAssertNoThrow(try TopicEncryption.encrypt(EncryptedPayload(message: String(repeating: "x", count: 2_900)),
                                                     key: try vectorKey()))
    }

    func testShapeDetectionAcceptsUpstreamJWEAndRejectsLookalikes() {
        let header = "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0"
        let iv = "DA0ODxAREhMUFRYX"
        let ct = "9W1edLGO1g4lI3ouB5e1eCfFVFU"
        let tag = "y2sgqWt8XuVwv2WKtojYfg"
        func b64(_ s: String) -> String { TopicEncryption.base64urlEncode(Data(s.utf8)) }

        XCTAssertTrue(TopicEncryption.isEncrypted(Self.pythonPlainTextJWE))
        XCTAssertTrue(TopicEncryption.isEncrypted(Self.upstreamPHPJWE))
        XCTAssertTrue(TopicEncryption.isEncrypted(Self.pythonPlainTextJWE + "\n"), "a trailing newline from a file body")
        XCTAssertTrue(TopicEncryption.isEncrypted("\(b64(#"{"enc":"A256GCM","alg":"dir"}"#))..\(iv).\(ct).\(tag)"),
                      "key order in the header is not significant")

        let lookalikes: [(String, String)] = [
            ("plain text", "Backup finished. All good."),
            ("empty", ""),
            ("five dotted words", "a.b.c.d.e"),
            ("dots in a sentence", "v1..2.3.4"),
            ("a URL", "https://example.com/a..b.c.d"),
            ("JWT (3 segments)", "\(header).\(ct).\(tag)"),
            ("JWE with an encrypted key (RSA-OAEP style)", "\(b64(#"{"alg":"RSA-OAEP","enc":"A256GCM"}"#)).\(ct).\(iv).\(ct).\(tag)"),
            ("non-empty key segment", "\(header).\(ct).\(iv).\(ct).\(tag)"),
            ("A128GCM", "\(b64(#"{"alg":"dir","enc":"A128GCM"}"#))..\(iv).\(ct).\(tag)"),
            ("extra header field (zip)", "\(b64(#"{"alg":"dir","enc":"A256GCM","zip":"DEF"}"#))..\(iv).\(ct).\(tag)"),
            ("header not JSON", "\(b64("hello"))..\(iv).\(ct).\(tag)"),
            ("padded base64", "\(header)=..\(iv).\(ct).\(tag)"),
            ("standard base64 alphabet", "\(header)..\(iv).\(ct)+/.\(tag)"),
            ("16-byte IV", "\(header)..\(TopicEncryption.base64urlEncode(Data(count: 16))).\(ct).\(tag)"),
            ("12-byte tag", "\(header)..\(iv).\(ct).\(TopicEncryption.base64urlEncode(Data(count: 12)))"),
            ("six segments", "\(header)..\(iv).\(ct).\(tag).x"),
        ]
        for (name, text) in lookalikes {
            XCTAssertFalse(TopicEncryption.isEncrypted(text), name)
            let ingested = TopicEncryption.ingest(Message(id: "l", time: 1, event: "message", topic: "t", message: text), key: nil)
            XCTAssertEqual(ingested.encryption, .none, name)
            XCTAssertEqual(ingested.message.message, text, "\(name) must render untouched")
        }
    }

    // Trust boundary: the server can't read or forge the payload, but it controls every outer field.

    /// An outer message dressed with every server-controllable presentation field.
    private func dressedOuter(id: String, body: String) -> Message {
        Message(
            id: id, time: 42, event: "message", topic: "t", message: body,
            title: "server title", priority: 5, tags: ["warning"],
            actions: [Action(id: "srv", action: "view", label: "Pay now", url: "https://evil.example/pay")],
            click: "https://evil.example/click", pollId: "poll-1",
            attachment: MessageAttachment(name: "invoice.pdf", type: "application/pdf", size: 1, expires: nil,
                                          url: "https://evil.example/invoice.pdf"),
            contentType: "text/markdown", icon: "https://evil.example/icon.png"
        )
    }

    func testDecryptedMessageTakesNoPresentationFieldsFromTheServer() throws {
        // RED before the fix: merge() let outer fields fill every gap the payload left.
        let body = try TopicEncryption.encrypt(EncryptedPayload(message: "genuine"), key: try vectorKey())
        let ingested = TopicEncryption.ingest(dressedOuter(id: "dressed-1", body: body), key: try vectorKey())
        XCTAssertEqual(ingested.encryption, .decrypted)
        let m = ingested.message
        XCTAssertEqual(m.message, "genuine")
        XCTAssertNil(m.title, "outer title")
        XCTAssertNil(m.click, "outer click URL")
        XCTAssertNil(m.actions, "outer actions")
        XCTAssertNil(m.icon, "outer icon")
        XCTAssertNil(m.attachment, "outer attachment (unauthenticated; dropped)")
        XCTAssertNil(m.tags, "outer tags")
        XCTAssertNil(m.priority, "outer priority")
        XCTAssertNil(m.contentType, "outer content type")
        XCTAssertEqual(m.id, "dressed-1", "envelope: id is kept for dedupe")
        XCTAssertEqual(m.time, 42, "envelope: time is kept for ordering")
        XCTAssertEqual(m.topic, "t")
        XCTAssertEqual(m.pollId, "poll-1")
        XCTAssertEqual(m.encryption, .decrypted)
    }

    func testLockedPlaceholderCarriesNothingFromTheServer() throws {
        // RED before the fix: the placeholder kept the outer icon, attachment, tags and priority.
        let body = try TopicEncryption.encrypt(EncryptedPayload(message: "genuine"), key: try vectorKey())
        let ingested = TopicEncryption.ingest(dressedOuter(id: "dressed-2", body: body), key: nil)
        XCTAssertEqual(ingested.encryption, .locked)
        let m = ingested.message
        XCTAssertEqual(m.message, TopicEncryption.lockedPlaceholder)
        XCTAssertNil(m.title)
        XCTAssertNil(m.click)
        XCTAssertNil(m.actions)
        XCTAssertNil(m.icon)
        XCTAssertNil(m.attachment)
        XCTAssertNil(m.tags)
        XCTAssertNil(m.priority, "a locked message must not ring as priority 5")
        XCTAssertNil(m.contentType)
        XCTAssertEqual(m.id, "dressed-2")
    }

    func testPlaintextOnATopicWithAPasswordIsMarkedNotEncrypted() throws {
        // RED before the fix: it was stored as an ordinary message, indistinguishable from the sender's.
        let (subscription, _) = try encryptedTopic("e2e-inject")
        deleteNotificationsAfterTest(ids: ["e2e-inject-1"])
        let reported = Store.shared.save(
            notificationsFromMessages: [Message(id: "e2e-inject-1", time: 1, event: "message", topic: "e2e-inject",
                                                message: "Click here to re-enter your password", title: "Admin")],
            withSubscription: subscription
        )
        XCTAssertEqual(reported.first?.encryption, .unencrypted, "the banner path must know")
        XCTAssertEqual(reported.first?.message, "Click here to re-enter your password", "shown, not dropped")
        let row = try XCTUnwrap(storedNotification("e2e-inject-1"))
        XCTAssertEqual(row.encryptionState, .unencrypted)
        XCTAssertEqual(row.message, "Click here to re-enter your password")

        let content = UNMutableNotificationContent()
        content.modify(message: try XCTUnwrap(reported.first), baseUrl: "https://ntfy-me.com")
        XCTAssertEqual(content.subtitle, TopicEncryption.unencryptedMarker, "the push carries the marker")
    }

    func testPlaintextOnATopicWithoutAPasswordIsUnchanged() throws {
        let plain = dressedOuter(id: "plain-1", body: "hello")
        let ingested = TopicEncryption.ingest(plain, key: nil)
        XCTAssertEqual(ingested.encryption, .none)
        XCTAssertEqual(ingested.message.encryption, .none)
        XCTAssertEqual(ingested.message.title, "server title")
        XCTAssertEqual(ingested.message.click, "https://evil.example/click")
        XCTAssertEqual(ingested.message.actions?.first?.id, "srv")
        XCTAssertNotNil(ingested.message.attachment)
        XCTAssertEqual(ingested.message.priority, 5)

        let content = UNMutableNotificationContent()
        content.modify(message: ingested.message, baseUrl: "https://ntfy-me.com")
        XCTAssertEqual(content.subtitle, "", "no marker on an ordinary topic")
    }

    // Store / ingest paths

    private func encryptedTopic(_ topic: String, password: String? = "topic password") throws -> (Subscription, Data) {
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy-me.com", topic: topic)
        deleteAfterTest(subscription)
        let url = topicUrl(baseUrl: "https://ntfy-me.com", topic: topic)
        let key = try XCTUnwrap(TopicEncryption.deriveKey(password: "topic password", topicUrl: url))
        if let password {
            XCTAssertNotNil(Store.shared.setEncryptionPassword(password, for: subscription))
        }
        return (subscription, key)
    }

    private func sealed(_ payload: EncryptedPayload, key: Data) throws -> String {
        try TopicEncryption.encrypt(payload, key: key)
    }

    private func storedNotification(_ id: String) -> ntfy.Notification? {
        var found: ntfy.Notification?
        Store.shared.context.performAndWait {
            let request = Notification.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id)
            found = try? Store.shared.context.fetch(request).first
        }
        return found
    }

    func testPollPathDecryptsOnIngestAndMarksTheRow() throws {
        let (subscription, key) = try encryptedTopic("e2e-poll")
        let body = try sealed(EncryptedPayload(message: "secret body", title: "secret title", tags: ["lock"], priority: 4), key: key)
        deleteNotificationsAfterTest(ids: ["e2e-poll-1"])

        let reported = Store.shared.save(
            notificationsFromMessages: [Message(id: "e2e-poll-1", time: 1, event: "message", topic: "e2e-poll", message: body)],
            withSubscription: subscription
        )
        XCTAssertEqual(reported.first?.message, "secret body", "the background-poll banner must show plaintext")
        XCTAssertEqual(reported.first?.title, "secret title")

        let row = try XCTUnwrap(storedNotification("e2e-poll-1"))
        XCTAssertEqual(row.message, "secret body")
        XCTAssertEqual(row.title, "secret title")
        XCTAssertEqual(row.tags, "lock")
        XCTAssertEqual(row.priority, 4)
        XCTAssertEqual(row.encryptionState, .decrypted)
        XCTAssertNil(row.ciphertext)
    }

    func testPushPathReturnsTheDecryptedMessageForTheBanner() throws {
        let (_, key) = try encryptedTopic("e2e-push")
        let body = try sealed(EncryptedPayload(message: "pushed secret"), key: key)
        deleteNotificationsAfterTest(ids: ["e2e-push-1"])

        let shown = Store.shared.ingest(
            pushedMessage: Message(id: "e2e-push-1", time: 1, event: "message", topic: "e2e-push", message: body),
            baseUrl: "https://ntfy-me.com", topic: "e2e-push"
        )
        XCTAssertEqual(shown?.message?.message, "pushed secret", "the NSE modifies the banner from this message")
        XCTAssertEqual(storedNotification("e2e-push-1")?.encryptionState, .decrypted)
    }

    func testWithoutAPasswordTheRowIsAPlaceholderThatKeepsTheCiphertext() throws {
        let (subscription, key) = try encryptedTopic("e2e-nokey", password: nil)
        let body = try sealed(EncryptedPayload(message: "you can't see me", title: "hidden"), key: key)
        deleteNotificationsAfterTest(ids: ["e2e-nokey-1"])

        let shown = Store.shared.ingest(
            pushedMessage: Message(id: "e2e-nokey-1", time: 1, event: "message", topic: "e2e-nokey", message: body),
            baseUrl: "https://ntfy-me.com", topic: "e2e-nokey"
        )
        XCTAssertEqual(shown?.message?.message, TopicEncryption.lockedPlaceholder, "never show ciphertext in a banner")
        let row = try XCTUnwrap(storedNotification("e2e-nokey-1"))
        XCTAssertEqual(row.message, TopicEncryption.lockedPlaceholder)
        XCTAssertEqual(row.title, "")
        XCTAssertEqual(row.encryptionState, .locked)
        XCTAssertEqual(row.ciphertext, body)
        _ = subscription
    }

    func testSettingThePasswordLaterUnlocksStoredMessagesAndAWrongOneDoesNot() throws {
        let (subscription, key) = try encryptedTopic("e2e-retry", password: nil)
        let body = try sealed(EncryptedPayload(message: "late secret", title: "late", tags: ["tada"], priority: 2), key: key)
        deleteNotificationsAfterTest(ids: ["e2e-retry-1"])
        Store.shared.save(
            notificationsFromMessages: [Message(id: "e2e-retry-1", time: 1, event: "message", topic: "e2e-retry", message: body)],
            withSubscription: subscription
        )
        XCTAssertEqual(storedNotification("e2e-retry-1")?.encryptionState, .locked, "premise")

        XCTAssertEqual(Store.shared.setEncryptionPassword("wrong one", for: subscription), 0)
        XCTAssertEqual(storedNotification("e2e-retry-1")?.encryptionState, .locked, "a wrong password opens nothing")

        XCTAssertEqual(Store.shared.setEncryptionPassword("topic password", for: subscription), 1)
        let row = try XCTUnwrap(storedNotification("e2e-retry-1"))
        XCTAssertEqual(row.message, "late secret")
        XCTAssertEqual(row.title, "late")
        XCTAssertEqual(row.tags, "tada")
        XCTAssertEqual(row.priority, 2)
        XCTAssertEqual(row.encryptionState, .decrypted)
        XCTAssertNil(row.ciphertext)
    }

    func testUnencryptedMessagesAreUntouchedAndNeverReadTheKeychain() throws {
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy-me.com", topic: "e2e-plain")
        deleteAfterTest(subscription)
        let ids = (1...5).map { "e2e-plain-\($0)" }
        deleteNotificationsAfterTest(ids: ids)
        let reads = topicSecrets.readCount

        let reported = Store.shared.save(
            notificationsFromMessages: ids.map { Message(id: $0, time: 1, event: "message", topic: "e2e-plain",
                                                         message: "a.b.c.d.e plain", title: "t") },
            withSubscription: subscription
        )
        XCTAssertEqual(reported.first?.message, "a.b.c.d.e plain")
        XCTAssertEqual(reported.first?.encryption, NotificationEncryption.none)
        XCTAssertEqual(storedNotification("e2e-plain-1")?.encryptionState, NotificationEncryption.none)
        // The topic's `encrypted` flag answers "does it have a password"; the Keychain isn't touched.
        XCTAssertEqual(topicSecrets.readCount, reads)
    }

    func testUnsubscribingForgetsTheTopicPassword() throws {
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy-me.com", topic: "e2e-forget")
        XCTAssertNotNil(Store.shared.setEncryptionPassword("pw", for: subscription))
        let url = topicUrl(baseUrl: "https://ntfy-me.com", topic: "e2e-forget")
        XCTAssertNotNil(topicSecrets.topicPassword(topicUrl: url).value, "premise")

        XCTAssertTrue(Store.shared.delete(subscription: subscription))
        XCTAssertEqual(topicSecrets.topicPassword(topicUrl: url), .notFound)
        XCTAssertEqual(topicSecrets.topicKey(topicUrl: url), .notFound)
    }

    func testTheCachedKeyIsUsedSoTheExtensionNeverRunsPBKDF2() throws {
        let (subscription, key) = try encryptedTopic("e2e-cache")
        let url = topicUrl(baseUrl: "https://ntfy-me.com", topic: "e2e-cache")
        XCTAssertEqual(topicSecrets.topicKey(topicUrl: url), .found(key), "setting a password caches its derived key")
        XCTAssertEqual(Store.shared.encryptionKey(baseUrl: "https://ntfy-me.com", topic: "e2e-cache"), key)
        // A password whose key is missing (partial write) still works, and the key is re-cached.
        topicSecrets.dropKey(topicUrl: url)
        XCTAssertEqual(Store.shared.encryptionKey(baseUrl: "https://ntfy-me.com", topic: "e2e-cache"), key)
        XCTAssertEqual(topicSecrets.topicKey(topicUrl: url), .found(key))
        // The extension may not run PBKDF2: there a missing key leaves the topic unavailable (fail closed).
        topicSecrets.dropKey(topicUrl: url)
        Store.shared.allowsKeyDerivation = false
        defer { Store.shared.allowsKeyDerivation = true }
        XCTAssertEqual(Store.shared.topicKeyState(for: subscription), .unavailable)
        XCTAssertEqual(topicSecrets.topicKey(topicUrl: url), .notFound, "nothing derived")
    }

    func testPublishEncryptsEverythingWhenTheTopicHasAPassword() throws {
        let (subscription, key) = try encryptedTopic("e2e-publish")
        let request = try XCTUnwrap(ApiService.shared.publishRequest(
            subscription: subscription, user: nil, message: "from the app", title: "app title",
            priority: 5, tags: ["phone"],
            encryptionKey: Store.shared.encryptionKey(baseUrl: "https://ntfy-me.com", topic: "e2e-publish")
        ))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Encoding"), "jwe", "the header upstream's Go client sends")
        XCTAssertNil(request.value(forHTTPHeaderField: "Title"), "the title must not leak in a header")
        XCTAssertNil(request.value(forHTTPHeaderField: "Priority"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Tags"))
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertFalse(body.contains("from the app"))
        let payload = try TopicEncryption.decryptPayload(body, key: key)
        XCTAssertEqual(payload, EncryptedPayload(message: "from the app", title: "app title", tags: ["phone"], priority: 5))

        // Control: the same publish without a key is the unchanged plaintext request.
        let plain = try XCTUnwrap(ApiService.shared.publishRequest(
            subscription: subscription, user: nil, message: "from the app", title: "app title", priority: 5, tags: ["phone"]
        ))
        XCTAssertNil(plain.value(forHTTPHeaderField: "X-Encoding"))
        XCTAssertEqual(plain.value(forHTTPHeaderField: "Title"), "app title")
        XCTAssertEqual(plain.httpBody, Data("from the app".utf8))
    }

    func testRealKeychainStoresTopicSecretsWhenTheHostIsSigned() throws {
        let keychain = KeychainCredentialStore.shared
        guard keychain.isAvailable else {
            throw XCTSkip("unsigned test host has no keychain; run signed for real SecItem coverage")
        }
        let url = "https://keychain-test.example/\(UUID().uuidString.prefix(8))"
        let key = Data(repeating: 7, count: 32)
        XCTAssertTrue(keychain.setTopicSecret(password: "pw ✓", key: key, topicUrl: url))
        XCTAssertEqual(keychain.topicPassword(topicUrl: url), .found("pw ✓"))
        XCTAssertEqual(keychain.topicKey(topicUrl: url), .found(key))
        XCTAssertTrue(keychain.deleteTopicSecret(topicUrl: url))
        XCTAssertEqual(keychain.topicPassword(topicUrl: url), .notFound, "not found is not a failure")
        XCTAssertEqual(keychain.topicKey(topicUrl: url), .notFound)
    }

    // Fail closed: the topic's `encrypted` flag, not a Keychain read, decides whether it has a password.

    private func plainMessage(_ id: String, topic: String) -> Message {
        Message(id: id, time: 1, event: "message", topic: topic, message: "plaintext from anyone")
    }

    func testAnUnreadableKeyNeverMakesAnEncryptedTopicLookUnencrypted() throws {
        // RED before: an unreadable key read as "no password", so injected plaintext looked ordinary.
        let (subscription, key) = try encryptedTopic("e2e-locked-out")
        deleteNotificationsAfterTest(ids: ["e2e-locked-out-1", "e2e-locked-out-2"])
        topicSecrets.failReads = errSecInteractionNotAllowed
        defer { topicSecrets.failReads = nil }

        let reported = Store.shared.save(
            notificationsFromMessages: [
                plainMessage("e2e-locked-out-1", topic: "e2e-locked-out"),
                Message(id: "e2e-locked-out-2", time: 2, event: "message", topic: "e2e-locked-out",
                        message: try sealed(EncryptedPayload(message: "secret"), key: key)),
            ],
            withSubscription: subscription
        )
        XCTAssertEqual(reported.map(\.encryption), [.unencrypted, .locked])
        XCTAssertEqual(storedNotification("e2e-locked-out-1")?.encryptionState, .unencrypted)
        XCTAssertEqual(storedNotification("e2e-locked-out-2")?.encryptionState, .locked)
        XCTAssertEqual(Store.shared.topicKeyState(for: subscription), .unavailable)
        XCTAssertEqual(Store.shared.encryptionPasswordState(for: subscription), .unreadable,
                       "settings must say on-but-unreadable, not off")
    }

    func testAFailedKeyReadIsNotTreatedAsMissingAndNothingIsRewritten() throws {
        let (subscription, _) = try encryptedTopic("e2e-read-fails")
        let url = topicUrl(baseUrl: "https://ntfy-me.com", topic: "e2e-read-fails")
        topicSecrets.failReads = errSecInteractionNotAllowed
        XCTAssertEqual(Store.shared.topicKeyState(for: subscription), .unavailable)
        topicSecrets.failReads = nil
        XCTAssertNotNil(topicSecrets.topicKey(topicUrl: url).value, "the stored key survives a failed read")
    }

    func testLockedMessagesOpenOnTheirOwnOnceTheKeyIsReadableAgain() throws {
        // RED before: only setting the password again retried locked rows.
        let (subscription, key) = try encryptedTopic("e2e-heal")
        deleteNotificationsAfterTest(ids: ["e2e-heal-1"])
        topicSecrets.failReads = errSecInteractionNotAllowed
        Store.shared.save(
            notificationsFromMessages: [Message(id: "e2e-heal-1", time: 1, event: "message", topic: "e2e-heal",
                                                message: try sealed(EncryptedPayload(message: "after unlock"), key: key))],
            withSubscription: subscription
        )
        XCTAssertEqual(storedNotification("e2e-heal-1")?.encryptionState, .locked, "premise")
        XCTAssertEqual(Store.shared.retryLockedMessages(), 0, "still unreadable: nothing opens")

        topicSecrets.failReads = nil
        let reads = topicSecrets.readCount
        XCTAssertEqual(Store.shared.retryLockedMessages(), 1)
        XCTAssertEqual(storedNotification("e2e-heal-1")?.message, "after unlock")
        XCTAssertEqual(storedNotification("e2e-heal-1")?.encryptionState, .decrypted)
        XCTAssertEqual(topicSecrets.readCount - reads, 1, "one key read for the topic that had locked rows")

        let idle = topicSecrets.readCount
        XCTAssertEqual(Store.shared.retryLockedMessages(), 0)
        XCTAssertEqual(topicSecrets.readCount, idle, "no locked rows, no Keychain read")
    }

    func testAFailedKeychainWriteLeavesTheTopicOff() throws {
        let (subscription, _) = try encryptedTopic("e2e-write-fails", password: nil)
        topicSecrets.failWrites = true
        defer { topicSecrets.failWrites = false }
        XCTAssertNil(Store.shared.setEncryptionPassword("pw", for: subscription))
        XCTAssertFalse(subscription.encrypted)
        XCTAssertEqual(Store.shared.encryptionPasswordState(for: subscription), .off)
    }

    func testAFailedKeychainDeleteKeepsTheTopicEncrypted() throws {
        // RED before: removal ignored a failed delete and nothing recorded the topic as still encrypted.
        let (subscription, _) = try encryptedTopic("e2e-delete-fails")
        deleteNotificationsAfterTest(ids: ["e2e-delete-fails-1"])
        topicSecrets.failDeletes = true
        defer { topicSecrets.failDeletes = false }
        XCTAssertFalse(Store.shared.removeEncryptionPassword(for: subscription))
        XCTAssertTrue(subscription.encrypted, "the flag must not flip when the secret is still there")
        XCTAssertEqual(Store.shared.encryptionPasswordState(for: subscription), .on("topic password"))
        Store.shared.save(notificationsFromMessages: [plainMessage("e2e-delete-fails-1", topic: "e2e-delete-fails")],
                          withSubscription: subscription)
        XCTAssertEqual(storedNotification("e2e-delete-fails-1")?.encryptionState, .unencrypted)

        topicSecrets.failDeletes = false
        XCTAssertTrue(Store.shared.removeEncryptionPassword(for: subscription))
        XCTAssertFalse(subscription.encrypted)
        XCTAssertEqual(Store.shared.encryptionPasswordState(for: subscription), .off)
    }

    func testAResubscribeNeverRevivesASecretThatOutlivedTheUnsubscribe() throws {
        // RED before: the settings screen and ingest read whatever the Keychain still held.
        let first = Store.shared.saveSubscription(baseUrl: "https://ntfy-me.com", topic: "e2e-revive")
        XCTAssertNotNil(Store.shared.setEncryptionPassword("old pw", for: first))
        topicSecrets.failDeletes = true
        XCTAssertTrue(Store.shared.delete(subscription: first), "a stuck secret doesn't block unsubscribing")
        topicSecrets.failDeletes = false
        let url = topicUrl(baseUrl: "https://ntfy-me.com", topic: "e2e-revive")
        XCTAssertNotNil(topicSecrets.topicPassword(topicUrl: url).value, "premise: the secret outlived it")

        let again = Store.shared.saveSubscription(baseUrl: "https://ntfy-me.com", topic: "e2e-revive")
        deleteAfterTest(again)
        deleteNotificationsAfterTest(ids: ["e2e-revive-1"])
        XCTAssertFalse(again.encrypted)
        XCTAssertEqual(Store.shared.encryptionPasswordState(for: again), .off)
        Store.shared.save(notificationsFromMessages: [plainMessage("e2e-revive-1", topic: "e2e-revive")],
                          withSubscription: again)
        XCTAssertEqual(storedNotification("e2e-revive-1")?.encryptionState, NotificationEncryption.none)
    }

    func testALongLivedExtensionSeesAPasswordSetSinceItLoadedTheTopic() throws {
        // RED before: ingest(pushedMessage:) used the context's cached row, whose `encrypted` was false.
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy-me.com", topic: "e2e-stale")
        deleteAfterTest(subscription)
        deleteNotificationsAfterTest(ids: ["e2e-stale-1", "e2e-stale-2"])
        XCTAssertFalse(subscription.encrypted, "premise: this context has the row loaded as unencrypted")

        // The app (another context, standing in for the other process) sets the password.
        let url = topicUrl(baseUrl: "https://ntfy-me.com", topic: "e2e-stale")
        let key = try XCTUnwrap(TopicEncryption.deriveKey(password: "pw", topicUrl: url))
        topicSecrets.setTopicSecret(password: "pw", key: key, topicUrl: url)
        let other = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        other.persistentStoreCoordinator = Store.shared.context.persistentStoreCoordinator
        let objectID = subscription.objectID
        try other.performAndWait {
            (try other.existingObject(with: objectID) as? Subscription)?.encrypted = true
            try other.save()
        }

        let plain = Store.shared.ingest(pushedMessage: plainMessage("e2e-stale-1", topic: "e2e-stale"),
                                        baseUrl: "https://ntfy-me.com", topic: "e2e-stale")
        XCTAssertEqual(plain?.message?.encryption, .unencrypted, "plaintext on the now-encrypted topic is marked")
        let sealedMessage = Message(id: "e2e-stale-2", time: 2, event: "message", topic: "e2e-stale",
                                    message: try sealed(EncryptedPayload(message: "hello"), key: key))
        let opened = Store.shared.ingest(pushedMessage: sealedMessage, baseUrl: "https://ntfy-me.com", topic: "e2e-stale")
        XCTAssertEqual(opened?.message?.encryption, .decrypted)
        XCTAssertEqual(opened?.message?.message, "hello")
    }

    func testAReplayedPushShowsTheNeutralPlaceholderNotTheServersAlert() throws {
        // Without the filtering entitlement iOS shows the original alert when the extension hands back
        // empty content, so a replay must be answered with neutral content, never with nothing.
        let jwe = try sealed(EncryptedPayload(message: "pay invoice 42"), key: try vectorKey())
        let pushed = UNMutableNotificationContent()
        pushed.title = "Bank: action required"
        pushed.subtitle = "server subtitle"
        pushed.body = jwe
        pushed.categoryIdentifier = "server-actions"
        let shown = UNNotificationContent.replayedEncryptedMessage(pushed)
        XCTAssertEqual(shown.body, TopicEncryption.lockedPlaceholder)
        XCTAssertEqual(shown.title, "")
        XCTAssertEqual(shown.subtitle, "")
        XCTAssertEqual(shown.categoryIdentifier, "")

        // A poll_request push carries the server's generic text, not the JWE; still neutral.
        let poll = UNMutableNotificationContent()
        poll.title = "Server says"
        poll.body = "New message"
        let shownForPoll = UNNotificationContent.replayedEncryptedMessage(poll)
        XCTAssertEqual(shownForPoll.body, TopicEncryption.lockedPlaceholder)
        XCTAssertEqual(shownForPoll.title, "")
    }

    // Replay: a captured ciphertext re-posted under a fresh id authenticates, so it is caught by its IV.

    func testAReplayedCiphertextIsDroppedOnEveryPath() throws {
        let (subscription, key) = try encryptedTopic("e2e-replay")
        let body = try sealed(EncryptedPayload(message: "pay invoice 42"), key: key)
        let other = try sealed(EncryptedPayload(message: "different"), key: key)
        let ids = ["e2e-replay-1", "e2e-replay-2", "e2e-replay-3", "e2e-replay-4", "e2e-replay-5"]
        deleteNotificationsAfterTest(ids: ids)
        func msg(_ id: String, _ body: String) -> Message {
            Message(id: id, time: 1, event: "message", topic: "e2e-replay", message: body)
        }

        XCTAssertEqual(Store.shared.save(notificationsFromMessages: [msg(ids[0], body)], withSubscription: subscription).count, 1)
        // Poll path: same ciphertext, fresh id.
        XCTAssertEqual(Store.shared.save(notificationsFromMessages: [msg(ids[1], body)], withSubscription: subscription).count, 0)
        XCTAssertNil(storedNotification(ids[1]))
        // Push path.
        guard case .replay = Store.shared.ingest(pushedMessage: msg(ids[2], body), baseUrl: "https://ntfy-me.com", topic: "e2e-replay") else {
            return XCTFail("the push path must report the replay")
        }
        XCTAssertNil(storedNotification(ids[2]))
        // Both copies in one batch: the first is kept.
        let batch = Store.shared.save(notificationsFromMessages: [msg(ids[3], other), msg(ids[4], other)], withSubscription: subscription)
        XCTAssertEqual(batch.map(\.id), [ids[3]])
        XCTAssertNil(storedNotification(ids[4]))
        // A re-delivery of the same id is still just a duplicate, not a replay of itself.
        guard case .stored = Store.shared.ingest(pushedMessage: msg(ids[0], body), baseUrl: "https://ntfy-me.com", topic: "e2e-replay") else {
            return XCTFail("redelivery of the original must not be reported as a replay")
        }
    }

    func testAReplayThatArrivedLockedIsRemovedWhenThePasswordIsSet() throws {
        let (subscription, key) = try encryptedTopic("e2e-replay-locked", password: nil)
        let body = try sealed(EncryptedPayload(message: "once"), key: key)
        let ids = ["e2e-replay-locked-1", "e2e-replay-locked-2"]
        deleteNotificationsAfterTest(ids: ids)
        Store.shared.save(
            notificationsFromMessages: [
                Message(id: ids[0], time: 1, event: "message", topic: "e2e-replay-locked", message: body),
                Message(id: ids[1], time: 2, event: "message", topic: "e2e-replay-locked", message: body),
            ],
            withSubscription: subscription
        )
        XCTAssertEqual(storedNotification(ids[1])?.encryptionState, .locked, "premise: locked copies can't be compared yet")
        XCTAssertEqual(Store.shared.setEncryptionPassword("topic password", for: subscription), 1)
        XCTAssertEqual(storedNotification(ids[0])?.message, "once", "the earliest copy is kept")
        XCTAssertNil(storedNotification(ids[1]), "the replayed copy is removed")
    }

    func testTopicSecretsStayOnThisDeviceButUserCredentialsAreUnchanged() {
        // Topic secrets are excluded from backups and device transfer; the privacy policy relies on it.
        XCTAssertEqual(KeychainCredentialStore.topicSecretAccessibility, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    func testPasswordsAreTrimmedOnEntry() throws {
        let (subscription, key) = try encryptedTopic("e2e-trim", password: " topic password \n")
        XCTAssertEqual(Store.shared.encryptionPasswordState(for: subscription), .on("topic password"))
        XCTAssertEqual(Store.shared.topicKeyState(for: subscription), .key(key), "the same key the sender derives")
        XCTAssertNil(Store.shared.setEncryptionPassword("   ", for: subscription), "whitespace only is no password")
    }

    func testCopiedSecretsStayLocalAndExpire() {
        let now = Date(timeIntervalSince1970: 1_000)
        let options = SecretPasteboard.options(now: now)
        XCTAssertEqual(options[.localOnly] as? Bool, true, "no Universal Clipboard")
        XCTAssertEqual(options[.expirationDate] as? Date, now.addingTimeInterval(120))
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        SecretPasteboard.copy("pw", to: pasteboard)
        XCTAssertEqual(pasteboard.string, "pw")
    }

    func testATooLargeEncryptedPublishReportsWhyInsteadOfVanishing() throws {
        // RED before: publishRequest returned nil and publish returned without calling anyone.
        let (subscription, key) = try encryptedTopic("e2e-too-big")
        let failed = expectation(description: "the caller learns why nothing was sent")
        let sent = expectation(description: "nothing is sent")
        sent.isInverted = true
        var reported: ApiService.PublishError?
        ApiService.shared.publish(
            subscription: subscription, user: nil,
            message: String(repeating: "x", count: 4000), title: "",
            encryptionKey: key,
            session: StubURLProtocol.session(status: 200, body: Data()),
            completionHandler: { sent.fulfill() },
            failureHandler: { reported = $0; failed.fulfill() }
        )
        wait(for: [failed, sent], timeout: 0.5)
        guard case .tooLargeToEncrypt(let bytes) = reported else { return XCTFail("got \(String(describing: reported))") }
        XCTAssertGreaterThan(bytes, TopicEncryption.maxMessageBytes)
    }

    func testARefusedPublishReportsTheHttpStatus() {
        let subscription = Subscription(context: Store.shared.context)
        subscription.baseUrl = "https://ntfy.sh"
        subscription.topic = "read-only"
        defer { Store.shared.context.delete(subscription) }
        let failed = expectation(description: "failure reported")
        var reported: ApiService.PublishError?
        ApiService.shared.publish(
            subscription: subscription, user: nil, message: "hello", title: "title",
            session: StubURLProtocol.session(status: 403, body: Data()),
            failureHandler: { reported = $0; failed.fulfill() }
        )
        wait(for: [failed], timeout: 2)
        XCTAssertEqual(reported, .http(403))
    }

    func testTheExtensionsEarlyExitNeverShowsCiphertextOrServerText() throws {
        let jwe = try sealed(EncryptedPayload(message: "secret"), key: try vectorKey())
        let pushed = UNMutableNotificationContent()
        pushed.title = "Bank: action required"
        pushed.subtitle = "server subtitle"
        pushed.body = jwe
        pushed.categoryIdentifier = "server-actions"
        pushed.userInfo = ["id": "abc", "topic": "t"]
        let shown = UNNotificationContent.encryptionSafeFallback(pushed)
        XCTAssertEqual(shown.body, TopicEncryption.lockedPlaceholder)
        XCTAssertFalse(shown.body.contains(jwe))
        XCTAssertEqual(shown.title, "", "no server-supplied title next to an encrypted body")
        XCTAssertEqual(shown.subtitle, "")
        XCTAssertEqual(shown.categoryIdentifier, "", "no server-defined action buttons")
        XCTAssertEqual(shown.userInfo["id"] as? String, "abc", "tapping still opens the topic")

        // The ciphertext in the title instead of the body is caught too.
        let inTitle = UNMutableNotificationContent()
        inTitle.title = jwe
        XCTAssertEqual(UNNotificationContent.encryptionSafeFallback(inTitle).title, "")

        // Ordinary pushes are shown exactly as received.
        let plain = UNMutableNotificationContent()
        plain.title = "Backup"
        plain.body = "finished"
        let unchanged = UNNotificationContent.encryptionSafeFallback(plain)
        XCTAssertEqual(unchanged.title, "Backup")
        XCTAssertEqual(unchanged.body, "finished")
    }

    func testASecretOrphanedByAReinstallNeverRevivesEncryption() throws {
        // The Keychain outlives an app delete; Core Data doesn't. A fresh, unflagged subscription must
        // neither read nor use the old secret.
        let url = topicUrl(baseUrl: "https://ntfy-me.com", topic: "e2e-reinstall")
        let oldKey = try XCTUnwrap(TopicEncryption.deriveKey(password: "old pw", topicUrl: url))
        topicSecrets.setTopicSecret(password: "old pw", key: oldKey, topicUrl: url)
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy-me.com", topic: "e2e-reinstall")
        deleteAfterTest(subscription)
        deleteNotificationsAfterTest(ids: ["e2e-reinstall-1", "e2e-reinstall-2"])
        let reads = topicSecrets.readCount

        Store.shared.save(notificationsFromMessages: [
            plainMessage("e2e-reinstall-1", topic: "e2e-reinstall"),
            Message(id: "e2e-reinstall-2", time: 2, event: "message", topic: "e2e-reinstall",
                    message: try sealed(EncryptedPayload(message: "old secret"), key: oldKey)),
        ], withSubscription: subscription)
        XCTAssertEqual(storedNotification("e2e-reinstall-1")?.encryptionState, NotificationEncryption.none)
        XCTAssertEqual(storedNotification("e2e-reinstall-2")?.encryptionState, .locked, "the orphaned key is not used")
        XCTAssertEqual(topicSecrets.readCount, reads, "unflagged topics never read the Keychain")
        XCTAssertEqual(Store.shared.encryptionPasswordState(for: subscription), .off)
        XCTAssertEqual(Store.shared.topicKeyState(for: subscription), .notEncrypted)
    }

    func testModel5MigrationLeavesExistingNotificationsUnencrypted() throws {
        let models = try compiledModelVersionURLs().compactMap { NSManagedObjectModel(contentsOf: $0) }
        let previous = try XCTUnwrap(
            models.first {
                $0.entitiesByName["Notification"]?.attributesByName["encryption"] == nil
                    && $0.entitiesByName["Subscription"]?.attributesByName["pinned"] != nil
            },
            "no shipped model version without `encryption` — Model 4 was edited away"
        )
        let current = try XCTUnwrap(
            models.first { $0.entitiesByName["Notification"]?.attributesByName["encryption"] != nil },
            "no model version WITH `encryption`"
        )
        let storeUrl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("e2e-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeUrl) }

        let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: previous)
        try oldCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeUrl, options: nil)
        let oldContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        oldContext.persistentStoreCoordinator = oldCoordinator
        let old = NSEntityDescription.insertNewObject(forEntityName: "Notification", into: oldContext)
        old.setValue("pre-e2e", forKey: "id")
        old.setValue("an old message", forKey: "message")
        let oldSubscription = NSEntityDescription.insertNewObject(forEntityName: "Subscription", into: oldContext)
        oldSubscription.setValue("https://ntfy-me.com", forKey: "baseUrl")
        oldSubscription.setValue("pre-e2e-topic", forKey: "topic")
        try oldContext.save()
        for store in oldCoordinator.persistentStores { try oldCoordinator.remove(store) }

        let newCoordinator = NSPersistentStoreCoordinator(managedObjectModel: current)
        try newCoordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: nil, at: storeUrl,
            options: [NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true])
        let newContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        newContext.persistentStoreCoordinator = newCoordinator
        let migrated = try newContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "Notification"))
        XCTAssertEqual(migrated.count, 1, "the pre-upgrade notification must survive")
        XCTAssertEqual(migrated.first?.value(forKey: "message") as? String, "an old message")
        XCTAssertEqual(migrated.first?.value(forKey: "encryption") as? Int16, 0)
        XCTAssertNil(migrated.first?.value(forKey: "ciphertext"))
        let migratedSubscriptions = try newContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "Subscription"))
        XCTAssertEqual(migratedSubscriptions.count, 1)
        XCTAssertEqual(migratedSubscriptions.first?.value(forKey: "encrypted") as? Bool, false,
                       "existing topics come out of the upgrade unencrypted")
    }

    func testSendersSnippetsCarryTheTopicUrlAndThePasswordOnlyOnRequest() {
        let url = "https://ntfy-me.com/my-topic"
        for snippet in [TopicEncryptionSnippets.node(topicUrl: url), TopicEncryptionSnippets.python(topicUrl: url)] {
            XCTAssertTrue(snippet.contains("\"\(url)\""))
            XCTAssertTrue(snippet.contains(TopicEncryptionSnippets.passwordPlaceholder))
            XCTAssertTrue(snippet.contains("50000"))
            XCTAssertTrue(snippet.contains("4096"), "senders must fail loudly above the server limit")
        }
        let tricky = #"he said "hi" \ ✓"#
        let node = TopicEncryptionSnippets.node(topicUrl: url, password: tricky)
        XCTAssertTrue(node.contains(#""he said \"hi\" \\ ✓""#), "a password must be a properly escaped literal")
        XCTAssertFalse(node.contains(TopicEncryptionSnippets.passwordPlaceholder))
    }

    func testPasswordStrengthHintFlagsShortPasswordsAndPassesGeneratedOnes() {
        XCTAssertEqual(TopicPasswordStrength("password"), .weak)
        XCTAssertEqual(TopicPasswordStrength("hunter22"), .weak)
        let generated = TopicEncryption.generatePassword()
        XCTAssertEqual(generated.count, 24)
        XCTAssertNotNil(TopicEncryption.base64urlDecode(generated))
        XCTAssertEqual(TopicPasswordStrength(generated), .strong)
        XCTAssertNotEqual(generated, TopicEncryption.generatePassword())
    }

    // MARK: Config outward links — must point at THIS app, never upstream's
    //
    // A shipped build sent "Rate the app" to upstream's App Store listing
    // (id 1625396347) and "Report a bug" to upstream's issue tracker, because
    // both were inline literals in AboutView carried over from the fork base.
    // Users rated someone else's app and filed our bugs on a maintainer who
    // never shipped this code. These pin the corrected values.

    /// Upstream ntfy's App Store id. Present ONLY so the tests below can assert
    /// we never point at it again.
    private static let upstreamAppStoreId = "1625396347"

    func testAppStoreIdIsOursNotUpstreams() {
        // APP_STORE_ID comes from the build configuration; a build without one shows no review link.
        guard let id = Config.appStoreId else { return XCTAssertNil(Config.reviewUrl) }
        XCTAssertNotEqual(id, Self.upstreamAppStoreId,
                          "this is upstream's app on a different team — never ours")
        XCTAssertTrue(id.allSatisfy(\.isNumber), "App Store ids are numeric, got \(id)")
    }

    func testReviewUrlOpensOurReviewComposer() throws {
        guard let id = Config.appStoreId else { return XCTAssertNil(Config.reviewUrl) }
        let url = try XCTUnwrap(Config.reviewUrl, "a build with an App Store id must have a review link")
        XCTAssertTrue(url.contains(id), "review link must target our own listing")
        XCTAssertFalse(url.contains(Self.upstreamAppStoreId),
                       "review link must never target upstream's listing")
        XCTAssertTrue(url.contains("action=write-review"),
                      "should open the review composer, not just the listing")
        XCTAssertNotNil(URL(string: url), "must be a URL UIApplication can actually open")
    }

    func testBugReportsGoToOurSupportPageNotUpstream() {
        XCTAssertFalse(Config.supportUrl.contains("binwiederhier"),
                       "our users' bug reports must not land on upstream's tracker")
        XCTAssertNotNil(URL(string: Config.supportUrl))
    }

    // MARK: Build identity comes from the build configuration

    /// Keychain service names are `<AppBundleIdBase>.serverPassword` and so on, and items are found by
    /// those exact strings. If `AppBundleIdBase` drifted from the bundle id the build is signed with,
    /// an update would silently lose every saved login and topic password.
    func testBuildIdentityMatchesTheSignedBundle() {
        XCTAssertEqual(Config.bundleIdBase, Bundle.main.bundleIdentifier,
                       "AppBundleIdBase must be the app's own bundle id (APP_BUNDLE_ID)")
        for (name, value) in [("AppGroupId", Config.appGroupId), ("AppKeychainGroup", Config.keychainGroup)] {
            XCTAssertFalse(value.isEmpty, "\(name) is empty")
            XCTAssertFalse(value.contains("$("), "\(name) was not expanded: \(value)")
        }
        XCTAssertTrue(Config.appGroupId.hasPrefix("group."), "App Group ids start with group.")
        XCTAssertEqual(Store.appGroup, Config.appGroupId)
        XCTAssertEqual(KeychainCredentialStore.accessGroup, Config.keychainGroup)
    }

    // MARK: Message wrapping never inserts a hyphen

    /// A hyphen inserted by the line breaker is not in the backing string, so it
    /// cannot be found by reading the text. It is visible in the geometry: the
    /// line's typographic width exceeds the width of the characters that line
    /// actually covers, by the width of the hyphen glyph. That difference is the
    /// only honest way to assert "nothing extra was drawn".
    @available(iOS 16.0, *)
    private func insertedGlyphWidths(in textView: MessageTextView) -> [CGFloat] {
        textView.layoutIfNeeded()
        _ = textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude))
        guard
            let layout = textView.textLayoutManager,
            let content = layout.textContentManager
        else {
            return []
        }
        let drawn = textView.attributedText ?? NSAttributedString(string: "")
        layout.ensureLayout(for: content.documentRange)
        var extras: [CGFloat] = []
        layout.enumerateTextLayoutFragments(
            from: content.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            let start = content.offset(
                from: content.documentRange.location, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let location = start + line.characterRange.location
                guard location < drawn.length else { continue }
                let length = min(line.characterRange.length, drawn.length - location)
                let covered = drawn.attributedSubstring(
                    from: NSRange(location: location, length: length))
                let difference = line.typographicBounds.width - covered.size().width
                if difference > 1.0 {
                    extras.append(difference)
                }
            }
            return true
        }
        return extras
    }

    @available(iOS 16.0, *)
    private func makeMessageTextView(_ body: String, width: CGFloat, style: MessageTextStyle = .body) -> MessageTextView {
        let textView = MessageTextView(frame: CGRect(x: 0, y: 0, width: width, height: 500))
        configureMessageTextView(textView, isInteractionEnabled: true)
        textView.setMessageText(
            makeMessageNSAttributedString(renderMessageBody(body, contentType: nil), style: style))
        return textView
    }

    @available(iOS 16.0, *)
    private func laidOutLines(_ textView: MessageTextView) -> [String] {
        textView.layoutIfNeeded()
        _ = textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude))
        guard
            let layout = textView.textLayoutManager,
            let content = layout.textContentManager
        else {
            return []
        }
        let drawn = textView.attributedText ?? NSAttributedString(string: "")
        layout.ensureLayout(for: content.documentRange)
        var lines: [String] = []
        layout.enumerateTextLayoutFragments(
            from: content.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            let start = content.offset(
                from: content.documentRange.location, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let location = start + line.characterRange.location
                guard location < drawn.length else { continue }
                let length = min(line.characterRange.length, drawn.length - location)
                lines.append(
                    drawn.attributedSubstring(
                        from: NSRange(location: location, length: length)).string)
            }
            return true
        }
        return lines
    }

    /// The reported bug: a 64-character hex token displayed as `…b32e-` / `fa674…`,
    /// and the operator's paste of what they read on screen was rejected.
    func testLongTokenRendersWithNoInsertedHyphen() throws {
        guard #available(iOS 16.0, *) else { throw XCTSkip("TextKit 2 inspection needs iOS 16") }
        let token = "911ea0f8c3d94b1a7e26f0b5a9d4c8e3b32efa6741d09c25b8e37a1f4c601896"
        let textView = makeMessageTextView(token, width: 200)
        let lines = laidOutLines(textView)
        XCTAssertGreaterThan(lines.count, 1, "the token must actually wrap for this test to mean anything")
        XCTAssertEqual(
            insertedGlyphWidths(in: textView), [],
            "the line breaker drew a character the message does not contain — lines: \(lines)")
        XCTAssertEqual(lines.joined(), token, "wrapping must not alter the token's characters")
    }

    func testLongTokenInATitleRendersWithNoInsertedHyphen() throws {
        guard #available(iOS 16.0, *) else { throw XCTSkip("TextKit 2 inspection needs iOS 16") }
        let token = "911ea0f8c3d94b1a7e26f0b5a9d4c8e3b32efa6741d09c25b8e37a1f4c601896"
        let textView = makeMessageTextView(token, width: 200, style: .title)
        XCTAssertEqual(insertedGlyphWidths(in: textView), [],
                       "titles hyphenate on the same path bodies do")
    }

    /// Character wrapping would also fix the token, and would quietly make every
    /// ordinary message worse by breaking words in half. Prose must keep its word
    /// boundaries, so the fix has to be conditional rather than global.
    func testOrdinaryProseStillBreaksAtWordBoundaries() throws {
        guard #available(iOS 16.0, *) else { throw XCTSkip("TextKit 2 inspection needs iOS 16") }
        let prose = "Deployment finished successfully on production cluster with zero downtime reported"
        let textView = makeMessageTextView(prose, width: 200)
        let lines = laidOutLines(textView)
        XCTAssertGreaterThan(lines.count, 1)
        for line in lines.dropLast() {
            XCTAssertTrue(
                line.hasSuffix(" "),
                "'\(line)' was broken mid-word; prose must still wrap at word boundaries")
        }
        XCTAssertEqual(insertedGlyphWidths(in: textView), [])
    }

    /// The wrapping decision depends on the width, so it has to be re-made from
    /// the original message when the width changes — not compounded on the last
    /// decision, and not frozen at whatever width the view first had.
    func testWrappingIsRecomputedWhenTheViewGetsWider() throws {
        guard #available(iOS 16.0, *) else { throw XCTSkip("TextKit 2 inspection needs iOS 16") }
        let prose = "Deployment finished successfully on production cluster with zero downtime"
        let textView = makeMessageTextView(prose, width: 60)
        _ = laidOutLines(textView)
        textView.frame = CGRect(x: 0, y: 0, width: 300, height: 500)
        let lines = laidOutLines(textView)
        XCTAssertGreaterThan(lines.count, 1)
        for line in lines.dropLast() {
            XCTAssertTrue(
                line.hasSuffix(" "),
                "'\(line)' kept the narrow width's character wrapping after the view grew")
        }
    }

    /// What the user copies is the answer to "why was my pasted key rejected".
    /// The inserted hyphen is drawn, not stored, so a system copy of the whole
    /// body must hand over the token exactly.
    func testSystemCopyOfAWrappedTokenCarriesTheTokenExactly() throws {
        guard #available(iOS 16.0, *) else { throw XCTSkip("TextKit 2 inspection needs iOS 16") }
        let token = "911ea0f8c3d94b1a7e26f0b5a9d4c8e3b32efa6741d09c25b8e37a1f4c601896"
        UIPasteboard.general.items = []
        addTeardownBlock { UIPasteboard.general.items = [] }
        let textView = makeMessageTextView(token, width: 200)
        _ = laidOutLines(textView)
        textView.selectAll(nil)
        textView.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, token,
                       "copying the displayed body must not carry a rendered hyphen")
    }

    func testWideEnoughLinesLeaveWordWrappingAlone() {
        XCTAssertEqual(
            messageLineBreakMode(widestTokenWidth: 120, availableWidth: 200), .byWordWrapping)
        XCTAssertEqual(
            messageLineBreakMode(widestTokenWidth: 260, availableWidth: 200), .byCharWrapping)
        XCTAssertEqual(
            messageLineBreakMode(widestTokenWidth: 260, availableWidth: 0), .byWordWrapping,
            "an unlaid-out view must not be treated as a zero-width line")
    }

    /// A URL is one token even though it is full of punctuation, and a message
    /// that mixes prose with an over-long token still has to lose the hyphen.
    func testMixedProseAndTokenStillRendersWithoutAnInsertedHyphen() throws {
        guard #available(iOS 16.0, *) else { throw XCTSkip("TextKit 2 inspection needs iOS 16") }
        let body = "Your deploy key is 911ea0f8c3d94b1a7e26f0b5a9d4c8e3b32efa6741d09c25b8e37a1f4c601896 keep it safe"
        let textView = makeMessageTextView(body, width: 200)
        XCTAssertEqual(insertedGlyphWidths(in: textView), [])
        XCTAssertEqual(laidOutLines(textView).joined(), body)
    }

    func testDocsStillPointAtNtfysOwnDocumentation() {
        // Deliberately NOT de-upstreamed: ntfy.sh/docs is the real documentation
        // for the protocol this app speaks, and linking it is correct.
        XCTAssertEqual(Config.docsUrl, "https://ntfy.sh/docs")
    }
}

// MARK: - Newcomer setup (blind new-user test, 2026-10-07)

/// A first-time user copies the command the app shows and runs it. On the default server a command
/// without a scheme (`curl -d "hi" ntfy-me.com/topic`) gets a 301 and the message is never delivered,
/// so every command the app shows must carry the full URL.
final class NewcomerSetupTests: XCTestCase {

    // Both footers must distinguish ntfy.sh's official-app push project from a configurable server.
    func testNtfyShVariantsExplainForegroundDeliveryAndMigration() {
        let hint = "Topics on ntfy.sh have no instant banners in this app. Messages appear when you open "
            + "the app or refresh. For banners, move your topic to ntfy-me.com. "
            + "See https://ntfy-me.com/docs/migrate."
        let prefix = "When subscribing to new topics, this server will be used as a default. Leave it empty "
            + "to use \(Config.appServerDescription). "
        for url in ["https://ntfy.sh", "http://ntfy.sh", "https://ntfy.sh/", "http://ntfy.sh///",
                    "HTTPS://NTFY.SH/", "http://Ntfy.Sh", "  https://NTFY.SH/\n"] {
            let normalized = normalizeBaseUrl(url)
            XCTAssertEqual(Config.ntfyShDeliveryHint(baseUrl: normalized), hint, url)
            XCTAssertEqual(Config.subscriptionServerFooter(baseUrl: normalized, useAnother: true), hint, url)
            XCTAssertEqual(Config.subscriptionServerFooter(baseUrl: normalized, useAnother: false), hint, url)
            XCTAssertEqual(Config.defaultServerFooter(baseUrl: url), prefix + hint, url)
        }
    }

    func testSelfHostedFootersExplainTheOfficialAppTradeoff() {
        let ownServerHint = "For instant delivery from your own server, add \"upstream-base-url: https://ntfy-me.com\" "
            + "to its config. Without it, messages may arrive with significant delay. A server has one upstream; using "
            + "ntfy-me.com stops instant delivery to the official ntfy iOS app on that server. "
            + "See https://ntfy-me.com/docs/self-hosting."
        let defaultHint = "When subscribing to new topics, this server will be used as a default. Leave it empty "
            + "to use \(Config.appServerDescription). " + ownServerHint
        for url in ["https://ntfy-me.com", "http://ntfy.home.lan:8080", "https://ntfy.sh.example.com",
                    "https://example.com/ntfy.sh"] {
            XCTAssertNil(Config.ntfyShDeliveryHint(baseUrl: url), url)
            XCTAssertEqual(Config.subscriptionServerFooter(baseUrl: url, useAnother: true), ownServerHint, url)
            XCTAssertEqual(Config.defaultServerFooter(baseUrl: url), defaultHint, url)
        }
        XCTAssertEqual(Config.subscriptionServerFooter(baseUrl: "https://ntfy-me.com", useAnother: false),
                       "New topics use \(Config.appServerDescription). Any ntfy server works: turn on "
                        + "\"Use another server\" or change the default in Settings. "
                        + "Your scripts must send to ntfy-me.com; the same topic name on ntfy.sh is a different topic.")
        XCTAssertEqual(Config.subscriptionServerFooter(baseUrl: "http://ntfy.home.lan:8080", useAnother: false),
                       "New topics use your default server, ntfy.home.lan:8080.")
        XCTAssertEqual(Config.defaultServerFooter(baseUrl: ""), defaultHint)
    }

    /// Typing a name with the toggle off creates a topic on the built-in server, not ntfy.sh.
    func testBuiltInServerWarnsScriptsMustMoveAndTopicNamesAreSeparate() {
        let warning = "Your scripts must send to ntfy-me.com; the same topic name on ntfy.sh is a different topic."
        XCTAssertTrue(Config.subscriptionServerFooter(baseUrl: "https://ntfy-me.com", useAnother: false)
            .hasSuffix(warning))
        for (url, useAnother) in [("https://ntfy-me.com", true), ("https://ntfy.sh", false),
                                  ("https://ntfy.home.io", false)] {
            XCTAssertFalse(Config.subscriptionServerFooter(baseUrl: url, useAnother: useAnother)
                .contains(warning), "Only the built-in default should show this warning: \(url)")
        }
    }

    /// Exercise the actual UIKit renderer: link attributes alone are inert if editing/selection is wrong.
    func testBothFootersRenderInteractiveDocumentationLinksAndClearStaleLinks() {
        for (url, documentation) in [("https://ntfy.sh", "https://ntfy-me.com/docs/migrate"),
                                      ("https://ntfy.home.io", "https://ntfy-me.com/docs/self-hosting")] {
            for copy in [Config.subscriptionServerFooter(baseUrl: url, useAnother: true),
                         Config.defaultServerFooter(baseUrl: url)] {
                let footer = ServerFooterText(text: copy)
                let view = footer.makeTextView()
                view.frame = CGRect(x: 0, y: 0, width: 320, height: 1)
                view.layoutIfNeeded()
                XCTAssertEqual(view.attributedText.string, copy)
                XCTAssertFalse(view.isEditable)
                XCTAssertTrue(view.isSelectable)
                XCTAssertTrue(view.isUserInteractionEnabled)
                XCTAssertFalse(view.isScrollEnabled)
                let range = (copy as NSString).range(of: documentation)
                XCTAssertNotEqual(range.location, NSNotFound, copy)
                guard range.location != NSNotFound else { continue }
                var linkRange = NSRange()
                XCTAssertEqual(view.attributedText.attribute(.link, at: range.location,
                    effectiveRange: &linkRange) as? URL, URL(string: documentation))
                XCTAssertEqual(linkRange, range, "The sentence's trailing period must not be part of the URL")
                XCTAssertGreaterThan(view.intrinsicContentSize.height, 1, "Footer must expand to show its text")
                ServerFooterText(text: "New topics use your default server, ntfy.home.io.").updateText(view)
                view.attributedText.enumerateAttribute(.link,
                    in: NSRange(location: 0, length: view.attributedText.length)) { link, _, _ in
                    XCTAssertNil(link, "Changing servers must remove the previous documentation link")
                }
            }
        }
    }

    func testPublishUrlAlwaysCarriesTheScheme() {
        XCTAssertEqual(PublishCommand.publishUrl(baseUrl: "https://ntfy-me.com", topic: "alerts"),
                       "https://ntfy-me.com/alerts")
        XCTAssertEqual(PublishCommand.publishUrl(baseUrl: "https://ntfy-me.com/", topic: "alerts"),
                       "https://ntfy-me.com/alerts", "a trailing slash must not double up")
        XCTAssertEqual(PublishCommand.publishUrl(baseUrl: "http://ntfy.home.lan:8080", topic: "t"),
                       "http://ntfy.home.lan:8080/t", "an explicit http server keeps its own scheme")
        XCTAssertEqual(PublishCommand.publishUrl(baseUrl: "ntfy.example.com", topic: "t"),
                       "https://ntfy.example.com/t", "a stored base URL without a scheme gets https")
        XCTAssertEqual(PublishCommand.publishUrl(baseUrl: "HTTPS://Ntfy.Example.com", topic: "t"),
                       "HTTPS://Ntfy.Example.com/t", "an upper-case scheme is still a scheme")
    }

    func testSimpleCommandPublishesToTheFullUrl() {
        let command = PublishCommand.simple(baseUrl: "https://ntfy-me.com", topic: "alerts-abc")
        XCTAssertTrue(command.hasPrefix("curl "), command)
        XCTAssertTrue(command.hasSuffix(" 'https://ntfy-me.com/alerts-abc'"), command)
        XCTAssertTrue(command.contains("-d '"), command)
        XCTAssertFalse(command.contains(" ntfy-me.com/"), "no scheme-less URL anywhere: \(command)")
    }

    func testTitledCommandSetsTitleAndPriorityAndPublishesToTheFullUrl() {
        let command = PublishCommand.titled(baseUrl: "https://ntfy.home.io/", topic: "backups")
        XCTAssertTrue(command.hasPrefix("curl "), command)
        XCTAssertTrue(command.contains("-H 'Title: "), command)
        XCTAssertTrue(command.contains("-H 'Priority: high'"), command)
        XCTAssertTrue(command.hasSuffix(" 'https://ntfy.home.io/backups'"), command)
    }

    func testShownCommandsAreSingleLineSoTheyPasteIntoAShell() {
        for command in [PublishCommand.simple(baseUrl: "https://ntfy-me.com", topic: "a"),
                        PublishCommand.titled(baseUrl: "https://ntfy-me.com", topic: "a")] {
            XCTAssertFalse(command.contains("\n"), command)
            XCTAssertFalse(command.hasPrefix("$"), "the copied text must not carry a prompt: \(command)")
        }
    }

    func testRandomTopicNameIsAValidTopic() {
        for _ in 0..<500 {
            let name = TopicNameGenerator.random()
            XCTAssertTrue(isValidTopicName(name), name)
        }
    }

    func testRandomTopicNameIsHardToGuess() {
        // Topic names are the password on a public server. At least 64 bits of randomness.
        let bits = Double(TopicNameGenerator.randomCharacterCount)
            * log2(Double(TopicNameGenerator.alphabet.count))
        XCTAssertGreaterThanOrEqual(bits, 64)
        var seen = Set<String>()
        for _ in 0..<2000 { seen.insert(TopicNameGenerator.random()) }
        XCTAssertEqual(seen.count, 2000, "random names must not repeat")
    }

    func testRandomTopicNameAvoidsLookAlikeCharacters() {
        // Someone may have to type the name on another machine. 0/O and 1/l/I get mixed up.
        let ambiguous = Set("0O1lIo")
        XCTAssertTrue(Set(TopicNameGenerator.alphabet).isDisjoint(with: ambiguous))
        for _ in 0..<200 {
            let random = TopicNameGenerator.random().dropFirst(TopicNameGenerator.prefix.count)
            XCTAssertTrue(Set(random).isDisjoint(with: ambiguous), String(random))
        }
    }

    func testRandomTopicNameDrawsFromTheGivenGenerator() {
        var a = SeededGenerator(seed: 42)
        var b = SeededGenerator(seed: 42)
        var c = SeededGenerator(seed: 43)
        let first = TopicNameGenerator.random(using: &a)
        XCTAssertEqual(first, TopicNameGenerator.random(using: &b))
        XCTAssertNotEqual(first, TopicNameGenerator.random(using: &c))
        XCTAssertTrue(first.hasPrefix(TopicNameGenerator.prefix), first)
    }

    func testTopicNameValidation() {
        XCTAssertTrue(isValidTopicName("phil_alerts-2"))
        XCTAssertFalse(isValidTopicName(""))
        XCTAssertFalse(isValidTopicName("has space"))
        XCTAssertFalse(isValidTopicName("slash/topic"))
        XCTAssertFalse(isValidTopicName(String(repeating: "a", count: 65)))
        XCTAssertTrue(isValidTopicName(String(repeating: "a", count: 64)))
    }

    func testHelpLinkPointsAtTheQuickStartForTheDefaultServer() {
        // ntfy.sh's examples publish to ntfy.sh, not to the server this app uses.
        XCTAssertEqual(Config.helpUrl, "https://ntfy-me.com/")
    }

    func testPermissionPromptWaitsForAFirstTopicOnAFreshInstall() {
        typealias P = NotificationPermissionPolicy
        XCTAssertFalse(P.shouldRequestAtLaunch(status: .notDetermined, hasSubscriptions: false, primerOffered: false),
                       "a fresh install must not get a cold permission prompt at launch")
        XCTAssertTrue(P.shouldRequestAtLaunch(status: .notDetermined, hasSubscriptions: true, primerOffered: false),
                      "topics from before this flow, never offered the explanation, must still be asked")
        XCTAssertTrue(P.shouldRequestAtLaunch(status: .authorized, hasSubscriptions: false, primerOffered: false))
        XCTAssertTrue(P.shouldRequestAtLaunch(status: .denied, hasSubscriptions: false, primerOffered: true))
    }

    func testNotNowSurvivesARelaunch() {
        // RED before the fix (review finding 2): subscribe, "Not now", relaunch: topics exist and the
        // status is still notDetermined, so the launch path showed the cold system prompt.
        let defaults = UserDefaults(suiteName: "NewcomerSetupTests-\(UUID().uuidString)")!
        XCTAssertFalse(NotificationPermissionPolicy.primerOffered(in: defaults), "premise: fresh install")
        NotificationPermissionPolicy.recordPrimerOffered(in: defaults)
        XCTAssertTrue(NotificationPermissionPolicy.primerOffered(in: defaults))
        XCTAssertFalse(NotificationPermissionPolicy.shouldRequestAtLaunch(
            status: .notDetermined, hasSubscriptions: true,
            primerOffered: NotificationPermissionPolicy.primerOffered(in: defaults)),
            "someone who saw the explanation and deferred must not get a cold prompt on the next launch")
    }

    // MARK: Shell quoting (review finding 6)

    func testCommandsKeepShellSpecialCharactersInsideOneArgument() {
        // RED before the fix: the URL was bare, so `&` backgrounded curl and `$` expanded.
        for base in ["https://example.com/ntfy&prod", "https://example.com/a$HOME;b", "https://example.com/it's"] {
            for command in [PublishCommand.simple(baseUrl: base, topic: "t"),
                            PublishCommand.titled(baseUrl: base, topic: "t")] {
                guard let words = posixWords(command) else {
                    return XCTFail("an unquoted shell metacharacter would be interpreted: \(command)")
                }
                XCTAssertEqual(words.first, "curl", command)
                XCTAssertEqual(words.last, "\(base)/t", "the URL must reach curl as one literal argument: \(command)")
            }
        }
    }

    func testShellQuotingEscapesEmbeddedSingleQuotes() {
        XCTAssertEqual(PublishCommand.shellQuoted("it's"), "'it'\\''s'")
        XCTAssertEqual(posixWords(PublishCommand.shellQuoted("a'b&c$d")), ["a'b&c$d"])
    }

    // MARK: Auth-aware commands (review finding 3)

    func testCommandsForALoggedInServerAskForThePasswordInsteadOfEmbeddingIt() {
        let auth = PublishCommand.Auth(username: "phil", headerNames: [])
        for command in [PublishCommand.simple(baseUrl: "https://ntfy.home.io", topic: "t", auth: auth),
                        PublishCommand.titled(baseUrl: "https://ntfy.home.io", topic: "t", auth: auth)] {
            let words = posixWords(command)
            XCTAssertNotNil(words, command)
            guard let words, let index = words.firstIndex(of: "--user") else {
                return XCTFail("a server with a saved login needs --user: \(command)")
            }
            XCTAssertEqual(words[index + 1], "phil", "user name only, so curl prompts for the password")
            XCTAssertFalse(words[index + 1].contains(":"), "no password in the copied text")
        }
    }

    func testCommandsForAServerWithCustomHeadersCarryPlaceholders() {
        let auth = PublishCommand.Auth(username: nil, headerNames: ["CF-Access-Client-Id"])
        let words = posixWords(PublishCommand.simple(baseUrl: "https://ntfy.home.io", topic: "t", auth: auth)) ?? []
        XCTAssertTrue(words.contains("CF-Access-Client-Id: \(PublishCommand.headerValuePlaceholder)"), "\(words)")
        XCTAssertFalse(words.contains("--user"))
    }

    func testAnonymousCommandsCarryNoAuth() {
        let command = PublishCommand.simple(baseUrl: "https://ntfy-me.com", topic: "t")
        XCTAssertFalse(command.contains("--user"), command)
        XCTAssertTrue(PublishCommand.Auth.none.isEmpty)
    }

    // MARK: Polling (review findings 1 and 4)

    func testOnlyOnePollPerTopicIsInFlight() {
        // RED before round 1: every caller started its own request.
        let guardian = PollGuard()
        XCTAssertTrue(guardian.begin(key: "k"))
        XCTAssertFalse(guardian.begin(key: "k"), "a second poll of the same topic is skipped while one runs")
        XCTAssertTrue(guardian.begin(key: "other"), "other topics are independent")
        guardian.end(key: "k")
        XCTAssertTrue(guardian.begin(key: "k"), "the next poll runs once the first ended")
    }

    func testAPollWhileOneIsInFlightIsSkippedAndUnsubscribingMeanwhileIsSafe() {
        // Through SubscriptionManager: the live loop's second poll is answered at once without a
        // request, and unsubscribing while the first is out neither crashes nor queues anything.
        let manager = SubscriptionManager(store: Store.shared)
        let subscription = Store.shared.saveSubscription(baseUrl: "http://127.0.0.1:9", topic: "poll-skip-\(UUID().uuidString.prefix(8))")
        let key = subscription.urlString()
        let first = expectation(description: "first poll finished")
        manager.pollWithOutcome(subscription, skipIfInFlight: true) { outcome in
            XCTAssertFalse(outcome.succeeded, "nothing listens on port 9")
            first.fulfill()
        }
        var skipped: PollOutcome?
        manager.pollWithOutcome(subscription, skipIfInFlight: true) { skipped = $0 }
        XCTAssertNotNil(skipped, "the second caller is answered synchronously, not queued")
        XCTAssertEqual(skipped?.succeeded, true, "a skip isn't a failure, so the live loop doesn't back off")
        XCTAssertTrue(Store.shared.delete(subscription: subscription))
        wait(for: [first], timeout: 35)
        XCTAssertTrue(PollGuard.shared.begin(key: key), "the guard is released after the request ends")
        PollGuard.shared.end(key: key)
    }

    func testABackgroundPollDuringAnInFlightLivePollStillRunsAndReturnsNewData() {
        // Round 3, finding 1. RED at 6bef17d: every caller went through the guard, so a background
        // fetch arriving while the open topic's live poll was out got "success, nothing new" at once,
        // reported .noData and never alerted for the message.
        let topic = "poll-background-\(UUID().uuidString.prefix(8))"
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: topic)
        let message = Message(id: "bg-\(topic)", time: 600, event: "message", topic: topic, message: "hi", title: nil)
        addTeardownBlock { _ = Store.shared.delete(subscription: subscription) } // cascades to its notifications
        var fetched = 0
        var manager = SubscriptionManager(store: Store.shared)
        manager.fetch = { _, completion in fetched += 1; completion([message], nil) }
        let key = subscription.urlString()
        XCTAssertTrue(PollGuard.shared.begin(key: key), "premise: the live loop's poll is in flight")
        defer { PollGuard.shared.end(key: key) }

        var live: PollOutcome?
        manager.pollWithOutcome(subscription, skipIfInFlight: true) { live = $0 }
        XCTAssertEqual(fetched, 0, "the live loop's next poll is skipped while its previous one is out")
        XCTAssertEqual(live?.newMessages.count, 0)

        var background: PollOutcome?
        manager.pollWithOutcome(subscription) { background = $0 }
        XCTAssertEqual(fetched, 1, "a background (one-shot) poll always makes its own request")
        XCTAssertEqual(background?.succeeded, true)
        XCTAssertEqual(background?.newMessages.map(\.id), [message.id], "and gets the new message to alert for")
    }

    func testLivePollBacksOffWhileTheServerFails() {
        XCTAssertEqual(LivePollSchedule.delay(afterConsecutiveFailures: 0), 10)
        XCTAssertEqual(LivePollSchedule.delay(afterConsecutiveFailures: 1), 20)
        XCTAssertEqual(LivePollSchedule.delay(afterConsecutiveFailures: 3), 80)
        XCTAssertEqual(LivePollSchedule.delay(afterConsecutiveFailures: 50), 300, "capped at five minutes")
    }

    func testOneShotRequestsReleaseTheirSession() {
        // RED before the fix: a delegate session is kept alive by the system until invalidated, and
        // ApiService never invalidated one, so each poll leaked a session and its delegate.
        weak var weakSession: URLSession?
        let done = expectation(description: "request finished")
        autoreleasepool {
            let request = URLRequest(url: URL(string: "http://127.0.0.1:9/t/json?poll=1")!)
            weakSession = ApiService(credentialStore: InMemoryCredentialStore())
                .runOneShot(request, timeout: 5, baseUrl: "http://127.0.0.1:9") { _, _, _ in done.fulfill() }
        }
        wait(for: [done], timeout: 10)
        let deadline = Date().addingTimeInterval(3)
        while weakSession != nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNil(weakSession, "the one-shot session must be invalidated and released once its task ends")
    }
    func testPrimingOnlyWhenIOSWouldActuallyAsk() {
        XCTAssertTrue(NotificationPermissionPolicy.shouldPrime(status: .notDetermined))
        XCTAssertFalse(NotificationPermissionPolicy.shouldPrime(status: .authorized))
        XCTAssertFalse(NotificationPermissionPolicy.shouldPrime(status: .denied))
        XCTAssertFalse(NotificationPermissionPolicy.shouldPrime(status: .provisional))
    }
}

/// Splits a command the way a POSIX shell would, for the subset the app emits: words separated by
/// spaces, single-quoted strings taken literally, a backslash escaping the next character. Returns
/// nil if any shell metacharacter (`&`, `;`, `|`, `$`, backtick, redirects, parentheses, double
/// quote) is left unquoted, because a
/// real shell would act on it rather than pass it to curl.
private func posixWords(_ command: String) -> [String]? {
    var words: [String] = []
    var current = ""
    var inWord = false
    var quoted = false
    var escaped = false
    for character in command {
        if escaped {
            current.append(character)
            escaped = false
            continue
        }
        if quoted {
            if character == "'" { quoted = false } else { current.append(character) }
            continue
        }
        switch character {
        case "'":
            quoted = true
            inWord = true
        case " ":
            if inWord { words.append(current); current = ""; inWord = false }
        case "\\":
            escaped = true
            inWord = true
        case "&", ";", "|", "$", "`", "<", ">", "(", ")", "\"", "\n":
            return nil
        default:
            current.append(character)
            inWord = true
        }
    }
    if quoted || escaped { return nil }
    if inWord { words.append(current) }
    return words
}

/// Deterministic SplitMix64, so a test can pin what the generator does with its random source.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: Retired built-in server migration (1.12/1.13 shipped a private server as the default)
//
// Topics added on that server get 403 forever. The migration moves them to ntfy-me.com once, unless a
// login for the old server is saved on the device (the operator's own phone uses it on purpose).

extension ntfyTests {
    private var retired: String { RetiredDefaultServerMigration.retiredBaseUrl! }
    private var replacement: String { RetiredDefaultServerMigration.replacementBaseUrl }

    private func makeMigrationFixture() -> (Store, UserDefaults, FakeFcmSubscriber, FcmSubscriptionReconciler) {
        let store = Store.shared
        store.getSubscriptions()?.forEach { store.delete(subscription: $0) }
        store.context.performAndWait {
            ((try? store.context.fetch(User.fetchRequest())) ?? []).forEach { store.context.delete($0) }
            try? store.context.save()
        }
        store.saveDefaultBaseUrl(baseUrl: nil)
        RetiredDefaultServerMigration.fetchFaultForTesting = nil
        addTeardownBlock { RetiredDefaultServerMigration.fetchFaultForTesting = nil }
        let defaults = UserDefaults(suiteName: "ntfyTests-migration-\(UUID().uuidString)")!
        // Bindings already follow the current app base URL, so only the migration's own rebind shows up.
        defaults.set(Config.appBaseUrl, forKey: FcmSubscriptionReconciler.defaultsKeyBindingsAppBaseUrl)
        let fake = FakeFcmSubscriber()
        let reconciler = FcmSubscriptionReconciler(store: store, subscriber: fake, defaults: defaults)
        return (store, defaults, fake, reconciler)
    }

    /// Inserts a row with `baseUrl` stored verbatim (saveSubscription would normalize it), bound and
    /// carrying `messages` notifications.
    @discardableResult
    private func insertSubscription(_ store: Store, baseUrl: String, topic: String, messages: Int = 0,
                                    encrypted: Bool = false) -> Subscription {
        var subscription: Subscription!
        store.context.performAndWait {
            subscription = Subscription(context: store.context)
            subscription.baseUrl = baseUrl
            subscription.topic = topic
            subscription.encrypted = encrypted
            subscription.fcmSubscribed = true
            subscription.lastNotificationId = messages > 0 ? "old-server-id" : nil
            for index in 0..<messages {
                let notification = Notification(context: store.context)
                notification.id = UUID().uuidString
                notification.time = Int64(index + 1)
                notification.message = "message \(index)"
                notification.subscription = subscription
            }
            do { try store.context.save() } catch { XCTFail("cannot save fixture: \(error)") }
        }
        return subscription
    }

    private func subscriptions(_ store: Store, topic: String) -> [(baseUrl: String, count: Int)] {
        var result: [(String, Int)] = []
        store.context.performAndWait {
            result = (store.getSubscriptions() ?? [])
                .filter { $0.topic == topic }
                .map { ($0.baseUrl ?? "", $0.notificationCount()) }
        }
        return result
    }

    func testMigrationTargetsTheShippedDefaultAndTheCurrentOne() {
        XCTAssertEqual(normalizeBaseUrl(Config.appBaseUrl), replacement,
                       "the replacement must be the built-in server this build ships")
        XCTAssertFalse(RetiredDefaultServerMigration.isRetiredServer(Config.appBaseUrl))
    }

    func testCredentialLessRetiredTopicMovesAndKeepsItsNotifications() {
        let (store, defaults, fake, reconciler) = makeMigrationFixture()
        insertSubscription(store, baseUrl: retired, topic: "garage", messages: 2)

        let outcome = RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler)
        drainMainQueue()

        XCTAssertEqual(outcome?.moved, ["garage"])
        let rows = subscriptions(store, topic: "garage")
        XCTAssertEqual(rows.map(\.baseUrl), [replacement], "moved, not copied")
        XCTAssertEqual(rows.first?.count, 2, "stored notifications come along")
        let moved = store.getSubscription(baseUrl: replacement, topic: "garage")
        XCTAssertNil(moved?.lastNotificationId, "the old server's message id means nothing on the new one")
        XCTAssertTrue(fake.unsubscribed.contains(topicHash(baseUrl: retired, topic: "garage")),
                      "the old hashed FCM name is torn down")
        XCTAssertFalse(fake.unsubscribed.contains("garage"), "raw `garage` is the name the moved row now needs")
        XCTAssertTrue(fake.subscribed.contains("garage"), "the moved row is bound under its new name")
        XCTAssertTrue(store.getSubscriptionsPendingFcmSubscribe().isEmpty, "and the bind is confirmed")
        XCTAssertTrue(defaults.bool(forKey: RetiredDefaultServerMigration.defaultsKeyCompleted))
    }

    func testRetiredTopicWithASavedLoginStays() {
        let (store, defaults, fake, reconciler) = makeMigrationFixture()
        insertSubscription(store, baseUrl: retired, topic: "garage", messages: 1)
        store.saveUser(baseUrl: retired, username: "owner", password: "secret")
        store.saveDefaultBaseUrl(baseUrl: retired)

        let outcome = RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler)
        drainMainQueue()

        XCTAssertEqual(outcome?.keptForSavedLogin, true)
        XCTAssertEqual(subscriptions(store, topic: "garage").map(\.baseUrl), [retired])
        XCTAssertEqual(store.getDefaultBaseUrl(), retired, "the default server preference stays too")
        XCTAssertEqual(fake.unsubscribed, [])
        XCTAssertTrue(defaults.bool(forKey: RetiredDefaultServerMigration.defaultsKeyCompleted),
                      "a deliberate setup is final; never revisit it")
    }

    func testKeychainPasswordOrHeadersAloneAlsoCountAsALogin() {
        for setUpCredential in [
            { (store: Store) in _ = store.credentialStore.setPassword("secret", baseUrl: self.retired) },
            { (store: Store) in _ = store.credentialStore.setHTTPHeaders(["X-Token": "t"], baseUrl: self.retired + "/") },
        ] {
            credentialStore = InMemoryCredentialStore()
            Store.shared.credentialStore = credentialStore
            let (store, defaults, _, reconciler) = makeMigrationFixture()
            insertSubscription(store, baseUrl: retired, topic: "garage")
            setUpCredential(store)

            let outcome = RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler)

            XCTAssertEqual(outcome?.keptForSavedLogin, true)
            XCTAssertEqual(subscriptions(store, topic: "garage").map(\.baseUrl), [retired])
        }
    }

    func testUnreadableCredentialsDeferTheMigrationInsteadOfGuessing() {
        let (store, defaults, _, reconciler) = makeMigrationFixture()
        insertSubscription(store, baseUrl: retired, topic: "garage")
        credentialStore.setHeaderReadsFail(true)

        XCTAssertNil(RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler))
        XCTAssertEqual(subscriptions(store, topic: "garage").map(\.baseUrl), [retired])
        XCTAssertFalse(defaults.bool(forKey: RetiredDefaultServerMigration.defaultsKeyCompleted), "retries next launch")

        credentialStore.setHeaderReadsFail(false)
        XCTAssertEqual(RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler)?.moved,
                       ["garage"])
    }

    func testOtherServersAreUntouched() {
        let (store, defaults, fake, reconciler) = makeMigrationFixture()
        let others = ["https://ntfy.sh", "https://home.example.com", "https://ntfy.retired.example.example.com",
                      "http://ntfy.retired.example", "https://ntfy.retired.example:8443",
                      "https://ntfy.retired.example/sub"]
        for (index, baseUrl) in others.enumerated() {
            insertSubscription(store, baseUrl: baseUrl, topic: "t\(index)", messages: 1)
        }
        store.saveDefaultBaseUrl(baseUrl: "https://home.example.com")

        let outcome = RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler)
        drainMainQueue()

        XCTAssertEqual(outcome?.moved, [])
        for (index, baseUrl) in others.enumerated() {
            XCTAssertEqual(subscriptions(store, topic: "t\(index)").map(\.baseUrl), [baseUrl])
        }
        XCTAssertEqual(store.getDefaultBaseUrl(), "https://home.example.com")
        XCTAssertEqual(fake.unsubscribed, [])
        XCTAssertTrue(store.getSubscriptionsPendingFcmSubscribe().isEmpty, "no binding was disturbed")
    }

    func testMigrationRunsOnlyOnce() {
        let (store, defaults, _, reconciler) = makeMigrationFixture()
        insertSubscription(store, baseUrl: retired, topic: "first")
        XCTAssertEqual(RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler)?.moved,
                       ["first"])

        // A topic the user adds on the old server afterwards is their own explicit choice.
        insertSubscription(store, baseUrl: retired, topic: "later")
        XCTAssertNil(RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler))
        XCTAssertEqual(subscriptions(store, topic: "later").map(\.baseUrl), [retired])
        XCTAssertEqual(subscriptions(store, topic: "first").map(\.baseUrl), [replacement])
    }

    func testRetiredServerSpellingVariantsAllMatch() {
        for variant in ["https://ntfy.retired.example", "https://ntfy.retired.example/",
                        "https://ntfy.retired.example///", "  https://ntfy.retired.example/ \n",
                        "HTTPS://NTFY.RETIRED.EXAMPLE", "https://ntfy.retired.example:443"] {
            XCTAssertTrue(RetiredDefaultServerMigration.isRetiredServer(variant), variant)
        }
    }

    func testStoredSpellingVariantsMoveAndFoldIntoOneRow() {
        let (store, defaults, _, reconciler) = makeMigrationFixture()
        insertSubscription(store, baseUrl: retired + "/", topic: "garage", messages: 1)
        insertSubscription(store, baseUrl: "HTTPS://NTFY.retired.example", topic: "garage", messages: 2)
        insertSubscription(store, baseUrl: replacement, topic: "door", messages: 1)
        insertSubscription(store, baseUrl: retired, topic: "door", messages: 3)

        let outcome = RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler)
        drainMainQueue()

        XCTAssertEqual(Set(outcome?.moved ?? []), ["garage"])
        XCTAssertEqual(Set(outcome?.merged ?? []), ["garage", "door"])
        let garage = subscriptions(store, topic: "garage")
        XCTAssertEqual(garage.map(\.baseUrl), [replacement], "one row per topic, no duplicates")
        XCTAssertEqual(garage.first?.count, 3)
        let door = subscriptions(store, topic: "door")
        XCTAssertEqual(door.map(\.baseUrl), [replacement])
        XCTAssertEqual(door.first?.count, 4, "the old row's notifications join the existing ntfy-me.com row")
    }

    func testDefaultServerPreferenceOnTheRetiredServerMoves() {
        let (store, defaults, _, reconciler) = makeMigrationFixture()
        store.saveDefaultBaseUrl(baseUrl: retired + "/")
        XCTAssertEqual(store.getDefaultBaseUrl(), retired, "sanity: the preference holds the retired server")

        let outcome = RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler)

        XCTAssertEqual(outcome?.defaultServerMoved, true)
        XCTAssertEqual(store.getDefaultBaseUrl(), replacement)
    }

    func testEncryptedRetiredTopicIsLeftAlone() {
        let (store, defaults, fake, reconciler) = makeMigrationFixture()
        insertSubscription(store, baseUrl: retired, topic: "vault", messages: 1, encrypted: true)

        let outcome = RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler)
        drainMainQueue()

        XCTAssertEqual(outcome?.skippedEncrypted, ["vault"])
        XCTAssertEqual(subscriptions(store, topic: "vault").map(\.baseUrl), [retired],
                       "its key is salted with the topic URL, so moving it would break decryption")
        XCTAssertEqual(fake.unsubscribed, [])
    }

    // MARK: Review round: credentials under any spelling, fail closed, durable FCM cleanup, folds, notice

    private var pendingObsolete: (UserDefaults) -> [String] {
        { FcmSubscriptionReconciler.pendingObsoleteTopicNames(defaults: $0) }
    }

    func testHeaderOrPasswordUnderAVariantStoredSpellingCountsAsALogin() {
        let variants = ["https://NTFY.retired.example", "https://ntfy.retired.example:443",
                        "HTTPS://ntfy.retired.example:443/"]
        for variant in variants {
            for useHeaders in [true, false] {
                credentialStore = InMemoryCredentialStore()
                Store.shared.credentialStore = credentialStore
                let (store, defaults, fake, reconciler) = makeMigrationFixture()
                insertSubscription(store, baseUrl: variant, topic: "garage")
                if useHeaders {
                    credentialStore.setHTTPHeaders(["Authorization": "Bearer t"], baseUrl: variant)
                } else {
                    credentialStore.setPassword("secret", baseUrl: normalizeBaseUrl(variant))
                }

                let outcome = RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler)
                drainMainQueue()

                XCTAssertEqual(outcome?.keptForSavedLogin, true, "\(variant) headers: \(useHeaders)")
                XCTAssertEqual(subscriptions(store, topic: "garage").map(\.baseUrl), [variant])
                XCTAssertEqual(fake.unsubscribed, [])
                XCTAssertTrue(RetiredDefaultServerMigration.pendingNoticeTopics(defaults: defaults).isEmpty)
            }
        }
    }

    func testCredentialsSavedOnlyUnderTheDefaultPreferenceSpellingCountAsALogin() {
        let (store, defaults, _, reconciler) = makeMigrationFixture()
        insertSubscription(store, baseUrl: retired, topic: "garage")
        let spelling = "https://ntfy.retired.example:443"
        store.saveDefaultBaseUrl(baseUrl: spelling)
        credentialStore.setHTTPHeaders(["X-Token": "t"], baseUrl: spelling)

        XCTAssertEqual(RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler)?
            .keptForSavedLogin, true)
        XCTAssertEqual(subscriptions(store, topic: "garage").map(\.baseUrl), [retired])
    }

    func testAnyLoginForEitherRetiredHostKeepsEverything() {
        let userSpellings = ["http://ntfy.retired.example", "https://ntfy.retired.example:8443/sub",
                             "https://push.retired.example", "https://PUSH.retired.example."]
        for spelling in userSpellings {
            let (store, defaults, _, reconciler) = makeMigrationFixture()
            insertSubscription(store, baseUrl: retired, topic: "garage")
            store.saveUser(baseUrl: spelling, username: "owner", password: "secret")

            XCTAssertEqual(RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler)?
                .keptForSavedLogin, true, spelling)
            XCTAssertEqual(subscriptions(store, topic: "garage").map(\.baseUrl), [retired], spelling)
        }
        // And a Keychain password for the legacy host with no row naming it at all.
        credentialStore = InMemoryCredentialStore()
        Store.shared.credentialStore = credentialStore
        let (store, defaults, _, reconciler) = makeMigrationFixture()
        insertSubscription(store, baseUrl: retired, topic: "garage")
        credentialStore.setPassword("secret", baseUrl: "https://push.retired.example")
        XCTAssertEqual(RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler)?
            .keptForSavedLogin, true)
    }

    func testRetiredHostMatchingIsBroadOnlyForThoseTwoHosts() {
        for match in ["https://push.retired.example", "http://ntfy.retired.example:80/x", "ntfy.retired.example",
                      "HTTPS://NTFY.RETIRED.EXAMPLE:443/"] {
            XCTAssertTrue(RetiredDefaultServerMigration.isRetiredHost(match), match)
        }
        for other in ["https://ntfy-me.com", "https://ntfy.retired.example.example.com", "https://retired.example",
                      "https://ntfy.sh"] {
            XCTAssertFalse(RetiredDefaultServerMigration.isRetiredHost(other), other)
        }
    }

    func testUnreadablePasswordDefersTheMigration() {
        let (store, defaults, fake, reconciler) = makeMigrationFixture()
        insertSubscription(store, baseUrl: retired, topic: "garage")
        credentialStore.setPasswordReadsFail(true)

        XCTAssertNil(RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler))
        drainMainQueue()
        XCTAssertEqual(subscriptions(store, topic: "garage").map(\.baseUrl), [retired])
        XCTAssertFalse(defaults.bool(forKey: RetiredDefaultServerMigration.defaultsKeyCompleted), "retries next launch")
        XCTAssertEqual(fake.unsubscribed, [])
        XCTAssertTrue(pendingObsolete(defaults).isEmpty)

        credentialStore.setPasswordReadsFail(false)
        XCTAssertEqual(RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler)?.moved,
                       ["garage"])
    }

    func testStoreReadFailuresChangeNothingAndRetry() {
        struct Unreadable: Error {}
        for entity in ["Subscription", "User", "Preference"] {
            let (store, defaults, fake, reconciler) = makeMigrationFixture()
            insertSubscription(store, baseUrl: retired, topic: "garage")
            store.saveDefaultBaseUrl(baseUrl: retired)
            RetiredDefaultServerMigration.fetchFaultForTesting = { $0 == entity ? Unreadable() : nil }

            XCTAssertNil(RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler), entity)
            drainMainQueue()
            XCTAssertEqual(subscriptions(store, topic: "garage").map(\.baseUrl), [retired], entity)
            XCTAssertEqual(store.getDefaultBaseUrl(), retired, entity)
            XCTAssertFalse(defaults.bool(forKey: RetiredDefaultServerMigration.defaultsKeyCompleted), entity)
            XCTAssertTrue(pendingObsolete(defaults).isEmpty, entity)
            XCTAssertEqual(fake.unsubscribed, [], entity)

            RetiredDefaultServerMigration.fetchFaultForTesting = nil
            XCTAssertEqual(RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler)?.moved,
                           ["garage"], entity)
        }
    }

    func testKillBetweenTheSaveAndTheTeardownStillTearsDownTheOldName() {
        let (store, defaults, _, _) = makeMigrationFixture()
        XCTAssertEqual(defaults.string(forKey: FcmSubscriptionReconciler.defaultsKeyBindingsAppBaseUrl), Config.appBaseUrl,
                       "bindings already follow this build, so no app-base-URL rebind will rediscover the old name")
        insertSubscription(store, baseUrl: retired, topic: "garage")
        let oldHash = topicHash(baseUrl: retired, topic: "garage")

        // The launch dies right after the save: no reconciler ever runs.
        XCTAssertEqual(RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: nil)?.moved,
                       ["garage"])
        XCTAssertTrue(pendingObsolete(defaults).contains(oldHash), "the old name was queued durably")

        // Worse: the completion flag was lost too, so the migration reruns and finds no retired row.
        defaults.removeObject(forKey: RetiredDefaultServerMigration.defaultsKeyCompleted)
        XCTAssertEqual(RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: nil)?.moved, [])

        // Next launch: a fresh reconciler drains the queue once the APNs token is there.
        let nextLaunch = FakeFcmSubscriber()
        nextLaunch.hasApnsToken = false
        let reconciler = FcmSubscriptionReconciler(store: store, subscriber: nextLaunch, defaults: defaults)
        reconciler.reconcile(reason: "launch")
        XCTAssertEqual(nextLaunch.unsubscribed, [], "nothing before the token is ready")
        nextLaunch.hasApnsToken = true
        reconciler.reconcile(reason: "APNs token")
        drainMainQueue()

        XCTAssertEqual(nextLaunch.unsubscribed, [oldHash], "raw `garage` is needed by the moved row, so it stays")
        XCTAssertTrue(nextLaunch.subscribed.contains("garage"))
        XCTAssertTrue(pendingObsolete(defaults).isEmpty, "drained after a successful teardown")
    }

    func testFailedTeardownStaysQueuedForTheNextLaunchWithoutLooping() {
        let (store, defaults, fake, reconciler) = makeMigrationFixture()
        insertSubscription(store, baseUrl: retired, topic: "garage")
        let oldHash = topicHash(baseUrl: retired, topic: "garage")
        fake.failures[oldHash] = FakeFcmSubscriber.Boom()

        RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler)
        drainMainQueue()
        reconciler.reconcile(reason: "foreground")
        drainMainQueue()

        XCTAssertEqual(fake.unsubscribed.filter { $0 == oldHash }.count, 1, "one attempt per launch")
        XCTAssertEqual(pendingObsolete(defaults), [oldHash], "kept for a later launch")

        let nextLaunch = FakeFcmSubscriber()
        FcmSubscriptionReconciler(store: store, subscriber: nextLaunch, defaults: defaults).reconcile(reason: "launch")
        drainMainQueue()
        XCTAssertEqual(nextLaunch.unsubscribed, [oldHash])
        XCTAssertTrue(pendingObsolete(defaults).isEmpty)
    }

    func testQueuedNameThatASubscriptionNeedsIsNeverTornDown() {
        let (store, defaults, fake, reconciler) = makeMigrationFixture()
        insertSubscription(store, baseUrl: replacement, topic: "garage")
        FcmSubscriptionReconciler.enqueueObsoleteTopicNames(["garage"], defaults: defaults)

        reconciler.reconcile(reason: "launch")
        drainMainQueue()

        XCTAssertEqual(fake.unsubscribed, [])
        XCTAssertTrue(pendingObsolete(defaults).isEmpty, "a bound name has nothing to tear down")
    }

    func testFoldIntoAVariantSpelledReplacementRowMovesItToTheCanonicalUrl() {
        let (store, defaults, fake, reconciler) = makeMigrationFixture()
        let variant = "https://ntfy-me.com:443"
        insertSubscription(store, baseUrl: variant, topic: "door", messages: 1)
        insertSubscription(store, baseUrl: retired, topic: "door", messages: 2)

        let outcome = RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler)
        drainMainQueue()

        XCTAssertEqual(outcome?.merged, ["door"])
        let door = subscriptions(store, topic: "door")
        XCTAssertEqual(door.map(\.baseUrl), [replacement], "push lookups and FCM names use the exact canonical URL")
        XCTAssertEqual(door.first?.count, 3)
        XCTAssertTrue(fake.subscribed.contains("door"), "rebound under the built-in server's raw name")
        XCTAssertTrue(fake.unsubscribed.contains(topicHash(baseUrl: variant, topic: "door")), "its hashed name is torn down")
        XCTAssertTrue(store.getSubscriptionsPendingFcmSubscribe().isEmpty)
        XCTAssertTrue(pendingObsolete(defaults).isEmpty)
    }

    func testEncryptedVariantSpelledReplacementRowIsNeverRewritten() {
        let (store, defaults, _, reconciler) = makeMigrationFixture()
        let variant = "https://ntfy-me.com:443"
        insertSubscription(store, baseUrl: variant, topic: "door", messages: 1, encrypted: true)
        insertSubscription(store, baseUrl: retired, topic: "door", messages: 2)

        let outcome = RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler)
        drainMainQueue()

        XCTAssertEqual(outcome?.moved, ["door"])
        XCTAssertEqual(outcome?.merged, [])
        XCTAssertEqual(Set(subscriptions(store, topic: "door").map(\.baseUrl)), [variant, replacement],
                       "the encrypted row keeps the URL its key is salted with")
    }

    func testMovedTopicsAreRecordedForAOneTimeNotice() {
        let (store, defaults, _, reconciler) = makeMigrationFixture()
        insertSubscription(store, baseUrl: retired, topic: "garage")
        insertSubscription(store, baseUrl: replacement, topic: "door")
        insertSubscription(store, baseUrl: retired, topic: "door")
        insertSubscription(store, baseUrl: retired, topic: "vault", encrypted: true)

        RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler)
        drainMainQueue()

        let topics = RetiredDefaultServerMigration.pendingNoticeTopics(defaults: defaults)
        XCTAssertEqual(topics, ["door", "garage"], "moved and merged topics; the encrypted one did not move")
        let message = RetiredDefaultServerMigration.noticeMessage(topics: topics)
        XCTAssertTrue(message.contains("https://ntfy-me.com/garage"))
        XCTAssertTrue(message.contains("https://ntfy-me.com/door"))
        XCTAssertTrue(message.contains("https://ntfy-me.com/<topic>"))
        RetiredDefaultServerMigration.dismissNotice(defaults: defaults)
        XCTAssertTrue(RetiredDefaultServerMigration.pendingNoticeTopics(defaults: defaults).isEmpty)
    }

    func testNothingMovedMeansNoNotice() {
        let (store, defaults, _, reconciler) = makeMigrationFixture()
        insertSubscription(store, baseUrl: "https://ntfy.sh", topic: "garage")
        RetiredDefaultServerMigration.runIfNeeded(store: store, defaults: defaults, reconciler: reconciler)
        XCTAssertTrue(RetiredDefaultServerMigration.pendingNoticeTopics(defaults: defaults).isEmpty)
    }
}

final class FirstTopicTestTests: XCTestCase {
    func testFirstNotificationUsesDefaultPriorityAndPlainAppCopy() {
        XCTAssertEqual(FirstTopicTest.priority, 3)
        XCTAssertEqual(FirstTopicTest.title, "NTFY me test")
        XCTAssertEqual(FirstTopicTest.body, "This is a test notification from NTFY me. Your topic is ready.")
    }
}

final class LaunchExperiencePolicyTests: XCTestCase {
    private let current = "1.17.0"
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testUpdateRangesAreNumericNewestFirstAndCapped() {
        let entries = ["1.8", "1.9", "1.10", "1.11", "1.12"].map {
            ReleaseNotes(version: $0, bullets: ["Change \($0)"])
        }
        let result = LaunchExperiencePolicy.update(current: "1.11", lastSeen: "1.9",
                                                  hasSubscriptions: true, entries: entries)
        XCTAssertEqual(result.entries.map(\.version), ["1.11", "1.10"])
        XCTAssertFalse(result.recordNow)
        XCTAssertEqual(LaunchExperiencePolicy.update(current: "1.12", lastSeen: "1.8",
            hasSubscriptions: true, entries: entries).entries.map(\.version), ["1.12", "1.11"])
        XCTAssertFalse(LaunchExperiencePolicy.isNewer("1.17.0", than: "1.17"))
        XCTAssertTrue(LaunchExperiencePolicy.isNewer("1.10", than: "1.9.99"))
    }

    func testFreshInstallLegacyUpdateSameVersionDowngradeAndMissingEntries() {
        let fresh = LaunchExperiencePolicy.update(current: current, lastSeen: nil, hasSubscriptions: false)
        XCTAssertTrue(fresh.entries.isEmpty)
        XCTAssertTrue(fresh.recordNow)
        let legacy = LaunchExperiencePolicy.update(current: current, lastSeen: nil, hasSubscriptions: true)
        XCTAssertEqual(legacy.entries.map(\.version), [current, "1.16.0"],
                       "an update from before the card existed shows the two newest releases")
        XCTAssertFalse(legacy.recordNow)
        let update = LaunchExperiencePolicy.update(current: current, lastSeen: "1.15.0", hasSubscriptions: true)
        XCTAssertEqual(update.entries.map(\.version), ["1.17.0", "1.16.0"])
        for version in [current, "1.18.0", "1.17"] {
            let result = LaunchExperiencePolicy.update(current: current, lastSeen: version, hasSubscriptions: true)
            XCTAssertTrue(result.entries.isEmpty)
            XCTAssertFalse(result.recordNow)
        }
        let missing = LaunchExperiencePolicy.update(current: "1.18.0", lastSeen: current, hasSubscriptions: true)
        XCTAssertTrue(missing.entries.isEmpty)
        XCTAssertTrue(missing.recordNow)
    }

    func testReviewEligibilityCoversEveryGateAndTwoDayBoundary() {
        func eligible(topic: Int = 1, total: Int = 3, prompted: String? = nil,
                      age: TimeInterval? = 172800, hasSubscriptions: Bool = true,
                      notice: Bool = false, active: Bool = true) -> Bool {
            LaunchExperiencePolicy.shouldRequestReview(current: current, lastPrompted: prompted,
                topicCount: topic, totalCount: total, firstLaunch: age.map { now.addingTimeInterval(-$0) },
                hasSubscriptions: hasSubscriptions, now: now, noticeShown: notice, foregroundActive: active)
        }
        XCTAssertTrue(eligible())
        XCTAssertFalse(eligible(topic: 0))
        XCTAssertFalse(eligible(total: 2))
        XCTAssertFalse(eligible(prompted: current))
        XCTAssertTrue(eligible(prompted: "1.16.0"))
        XCTAssertFalse(eligible(age: 172799))
        XCTAssertFalse(eligible(age: -1))
        XCTAssertTrue(eligible(age: nil)) // Existing subscriber before first-launch tracking.
        XCTAssertFalse(eligible(age: nil, hasSubscriptions: false))
        XCTAssertFalse(eligible(notice: true)) // Both launch notices share session suppression.
        XCTAssertFalse(eligible(active: false))
    }

    func testSessionPersistsFirstLaunchAndSuppressesReviewAfterEitherNotice() {
        let suite = "LaunchExperienceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = LaunchExperience(defaults: defaults, current: current)
        session.prepare(hasSubscriptions: false, movedTopicsPending: false, now: now)
        XCTAssertEqual(defaults.object(forKey: LaunchExperience.firstLaunchKey) as? Date, now)
        XCTAssertEqual(defaults.string(forKey: LaunchExperience.seenKey), session.current)
        XCTAssertTrue(session.entries.isEmpty)
        XCTAssertFalse(session.noticeShown)

        defaults.removeObject(forKey: LaunchExperience.seenKey)
        defaults.removeObject(forKey: LaunchExperience.firstLaunchKey)
        let moved = LaunchExperience(defaults: defaults, current: current)
        moved.prepare(hasSubscriptions: true, movedTopicsPending: true, now: now)
        XCTAssertTrue(moved.noticeShown)
        XCTAssertEqual(defaults.object(forKey: LaunchExperience.firstLaunchKey) as? Date,
                       now.addingTimeInterval(-172800))
        moved.dismissWhatsNew()
        XCTAssertEqual(defaults.string(forKey: LaunchExperience.seenKey), moved.current)
        XCTAssertTrue(moved.noticeShown)

        defaults.removeObject(forKey: LaunchExperience.seenKey)
        let updated = LaunchExperience(defaults: defaults, current: current)
        updated.prepare(hasSubscriptions: true, movedTopicsPending: false, now: now)
        updated.presentWhatsNew()
        XCTAssertTrue(updated.showingWhatsNew)
        XCTAssertTrue(updated.noticeShown)
        updated.dismissWhatsNew()
        XCTAssertTrue(updated.entries.isEmpty)
        XCTAssertTrue(updated.noticeShown)
        updated.prepare(hasSubscriptions: true, movedTopicsPending: false, now: now.addingTimeInterval(100))
        XCTAssertTrue(updated.entries.isEmpty)
        XCTAssertEqual(defaults.object(forKey: LaunchExperience.firstLaunchKey) as? Date,
                       now.addingTimeInterval(-172800))
    }
}
