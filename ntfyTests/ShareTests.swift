import XCTest
import UniformTypeIdentifiers
@testable import ntfy

@MainActor
final class ShareTests: XCTestCase {
    private var store: Store!
    override func setUp() { super.setUp(); store = Store(inMemory: true) }
    private func topic(_ name: String = "share-tests", base: String = "https://example.org") -> Subscription {
        store.saveSubscription(baseUrl: base, topic: name)
    }
    func testWebURLProviderBecomesMessageBody() async throws {
        let url = URL(string: "https://example.org/story?q=one#two")!
        let provider = NSItemProvider(object: url as NSURL)
        let result = try await ShareItemLoader.load([provider])
        XCTAssertEqual(result.message, url.absoluteString)
        XCTAssertNil(result.fileURL)
        let request = try ApiService.shared.buildPublishRequest(subscription: topic(), user: nil, message: result.message, title: "Link").get()
        XCTAssertEqual(request.httpBody, Data(url.absoluteString.utf8))
    }
    func testSelectedTextProviderBecomesEditableMessage() async throws {
        let text = "Selected café text\nSecond line"
        let result = try await ShareItemLoader.load([NSItemProvider(object: text as NSString)])
        let model = ComposeModel(); model.message = result.message; model.title = "Edited title"; model.message += " edited"
        let request = try ApiService.shared.buildPublishRequest(subscription: topic(), user: .accessToken("tk_test"), message: model.message, title: model.title).get()
        XCTAssertEqual(result.message, text)
        XCTAssertEqual(request.httpBody, Data((text + " edited").utf8))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tk_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Title"), "Edited title")
    }
    func testImageFileRepresentationStagesExactBytesWithoutDecoding() async throws {
        try await checkFile(type: .jpeg, name: "large-photo.jpg", count: 18 * 1024 * 1024)
    }
    func testGenericFileRepresentationStagesExactBytes() async throws {
        try await checkFile(type: .pdf, name: "document.pdf", count: 8192)
    }
    private func checkFile(type: UTType, name: String, count: Int) async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let data = Data((0..<count).map { UInt8($0 % 251) })
        try data.write(to: source); defer { try? FileManager.default.removeItem(at: source) }
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { callback in
            callback(source, false, nil); return nil
        }
        let result = try await ShareItemLoader.load([provider])
        let staged = try XCTUnwrap(result.fileURL)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        XCTAssertNotEqual(source, staged); XCTAssertEqual(try Data(contentsOf: staged), data)
        let options = PublishOptions(fileURL: staged, attachmentLimit: Int64(count))
        let request = try ApiService.shared.buildPublishRequest(subscription: topic(), user: .basic(username: "user", password: "pass"), message: "caption", title: "File", options: options, streamFile: true).get()
        XCTAssertNil(request.httpBody); XCTAssertNil(request.httpBodyStream)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), String(count))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Message"), "caption")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic dXNlcjpwYXNz")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Filename"))
    }
    func testFileURLProviderUploadsRatherThanSendingLocalPath() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("share-file.txt")
        try Data("a file".utf8).write(to: source); defer { try? FileManager.default.removeItem(at: source) }
        let result = try await ShareItemLoader.load([NSItemProvider(item: source as NSURL, typeIdentifier: UTType.fileURL.identifier)])
        XCTAssertTrue(result.message.isEmpty)
        let staged = try XCTUnwrap(result.fileURL)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: staged), Data("a file".utf8))
    }
    func testMultipleAttachmentsAndUnsupportedItemsFailClosed() async throws {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: "org.example.unsupported", visibility: .all) { callback in
            callback(Data([1]), nil); return nil
        }
        do { _ = try await ShareItemLoader.load([provider]); XCTFail("Unsupported share accepted") }
        catch { XCTAssertNotNil(error as? ShareItemLoader.Failure) }
        do { _ = try await ShareItemLoader.load([]); XCTFail("Empty share accepted") }
        catch { XCTAssertNotNil(error as? ShareItemLoader.Failure) }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("duplicate.pdf")
        try Data([1,2,3]).write(to: source); defer { try? FileManager.default.removeItem(at: source) }
        let file = NSItemProvider(item: source as NSURL, typeIdentifier: UTType.fileURL.identifier)
        do { _ = try await ShareItemLoader.load([file, file]); XCTFail("Two files accepted") }
        catch { XCTAssertNotNil(error as? ShareItemLoader.Failure) }
    }
    func testTopicSelectionRemembersServerAndFallsBackAfterDeletion() {
        let a = topic("same", base: "https://a.example.org"), b = topic("same", base: "https://b.example.org")
        XCTAssertEqual(ShareTopicSelection.choose([a,b], lastURL: b.urlString()), b)
        XCTAssertEqual(ShareTopicSelection.choose([a], lastURL: b.urlString()), a)
        XCTAssertEqual(ShareTopicSelection.choose([b,a], lastURL: nil), a)
        XCTAssertNil(ShareTopicSelection.choose([], lastURL: b.urlString()))
    }
}

final class ShareBudgetTests: XCTestCase {
    func testWarmAppObservesExtensionRefusalAndOlderSuccessCannotEraseIt() throws {
        let name = "share-budget-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let app = ServerCooldown(defaults: defaults)
        let share = ServerCooldown(defaults: defaults)
        let attempt = try XCTUnwrap(app.claimAttempt(server: "https://budget.example.org", manual: true, kind: .publish))
        share.limit(server: "https://budget.example.org", retryAfter: "120", kind: .publish)
        XCTAssertFalse(app.claim(server: "https://budget.example.org", manual: true, kind: .publish))
        app.succeeded(server: "https://budget.example.org", attempt: attempt)
        XCTAssertFalse(ServerCooldown(defaults: defaults).claim(server: "https://budget.example.org", manual: true, kind: .publish))
    }
}

@MainActor
final class ShareNativeTests: XCTestCase {
    func testProviderToStockServerPhotoHasExactBytesAndTextLinkArrive() async throws {
        guard let base = ProcessInfo.processInfo.environment["COMPOSE_STOCK_URL"],
              let path = ProcessInfo.processInfo.environment["COMPOSE_PHOTO_PATH"] else { throw XCTSkip("Opt in with stock loopback URL and JPEG fixture") }
        let source = URL(fileURLWithPath: path)
        let bytes = try Data(contentsOf: source)
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier, fileOptions: [], visibility: .all) { completion in
            completion(source, false, nil);return nil
        }
        let content = try await ShareItemLoader.load([provider])
        let staged = try XCTUnwrap(content.fileURL)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        let store = Store(inMemory: true)
        let topic = store.saveSubscription(baseUrl: base, topic: "share-native-" + UUID().uuidString)
        let api = ApiService()
        let (account,_) = try await URLSession.shared.data(from: URL(string: base + "/v1/account")!)
        let limit = try XCTUnwrap(PublishOptions.attachmentLimit(from: account))
        let options = PublishOptions(filename: "large-photo.jpg", fileURL: staged, attachmentLimit: limit)
        func publish(_ message: String, _ options: PublishOptions = PublishOptions()) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
                api.publish(subscription: topic, user: nil, message: message, title: "From Share", options: options,
                    completionHandler: { continuation.resume() }, failureHandler: { continuation.resume(throwing: $0) })
            }
        }
        try await publish("Photo caption",options)
        let link = try await ShareItemLoader.load([NSItemProvider(object: URL(string:"https://example.org/shared")! as NSURL)])
        try await publish(link.message)
        let text = try await ShareItemLoader.load([NSItemProvider(object: "Selected text" as NSString)])
        try await publish(text.message)
        let (data,_) = try await URLSession.shared.data(from: URL(string:topic.urlString()+"/json?poll=1")!)
        let rows = try String(decoding:data,as:UTF8.self).split(separator:"\n").map { try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any] }
        XCTAssertEqual(rows.count,3)
        let attachment = try XCTUnwrap(rows[0]["attachment"] as? [String:Any])
        let url = try XCTUnwrap(attachment["url"] as? String)
        let (downloaded,_) = try await URLSession.shared.data(from: URL(string:url)!)
        XCTAssertEqual(downloaded,bytes)
        XCTAssertEqual(rows[0]["message"] as? String,"Photo caption")
        XCTAssertEqual(rows[1]["message"] as? String,"https://example.org/shared")
        XCTAssertEqual(rows[2]["message"] as? String,"Selected text")
        let receipt=XCTAttachment(data:data,uniformTypeIdentifier:"public.json");receipt.name="share-native-receipt";receipt.lifetime = .keepAlways;add(receipt)
    }
}

@MainActor
final class ShareTopicChangeTests: XCTestCase {
    func testChangingDestinationClearsRequestChangeRefusalEvenWithIdenticalContent() async throws {
        let base = "http://127.0.0.1:1"
        let store = Store(inMemory:true)
        let a = store.saveSubscription(baseUrl:base,topic:"first")
        let b = store.saveSubscription(baseUrl:base,topic:"second")
        let model = ComposeModel();model.message="Same text"
        let budget = ServerCooldown.shared
        budget.limit(server:base,retryAfter:nil,condition:"request-change",kind:.publish)
        XCTAssertTrue(budget.claim(server:base,manual:true,kind:.publish))
        model.send(subscription:a,store:store) {}
        for _ in 0..<100 where model.busy { try await Task.sleep(nanoseconds:1_000_000) }
        XCTAssertFalse(model.busy)
        model.send(subscription:b,store:store) {}
        XCTAssertFalse(budget.hasNonTimeRefusal(server:base,kind:.publish))
        budget.requestChanged(server:base,kind:.publish)
        model.close()
    }
}

final class ShareUserAgentTests: XCTestCase {
    func testShareExtensionDoesNotIdentifyAsNotificationService() {
        let kind=ApiService.ProcessKind(bundleURL:URL(fileURLWithPath:"/App/ntfy.app/PlugIns/ntfyShare.appex"))
        let agent=ApiService.makeUserAgent(processKind:kind)
        XCTAssertFalse(agent.contains("; NSE"))
        XCTAssertTrue(agent.contains("; Share"))
    }
}

final class ShareBudgetNormalizationTests: XCTestCase {
    func testFutureProbeRemainsClampedAcrossWarmRefresh() {
        let name="share-future-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        var now=Date(timeIntervalSince1970:1_700_000_000)
        let server="https://future.example.org", scope="https://future.example.org|118|publish"
        defaults.set([scope:now.timeIntervalSince1970+600],forKey:"deliveryBudgetCooldowns118r2")
        defaults.set([scope:"request-change"],forKey:"deliveryBudgetChanges118r2")
        defaults.set([scope:now.timeIntervalSince1970+31_536_000],forKey:"deliveryBudgetProbes118r2")
        let budget=ServerCooldown(defaults:defaults,now:{now})
        XCTAssertFalse(budget.claim(server:server,manual:true,kind:.publish))
        now=now.addingTimeInterval(61)
        XCTAssertTrue(budget.claim(server:server,manual:true,kind:.publish))
    }
    func testUnknownConditionCannotBypassTimedPauseDuringRefresh() {
        let name="share-condition-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        let now=Date(timeIntervalSince1970:1_700_000_000), scope="https://condition.example.org|118|publish"
        defaults.set([scope:now.timeIntervalSince1970+120],forKey:"deliveryBudgetCooldowns118r2")
        defaults.set([scope:"unknown"],forKey:"deliveryBudgetChanges118r2")
        let budget=ServerCooldown(defaults:defaults,now:{now})
        XCTAssertFalse(budget.claim(server:"https://condition.example.org",manual:true,kind:.publish))
    }
}
