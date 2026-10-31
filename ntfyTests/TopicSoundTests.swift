import XCTest
import SwiftUI
import CoreData
import AVFoundation
import UserNotifications
@testable import ntfy

final class TopicSoundTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var library: TopicSoundLibrary!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "TopicSoundTests.\(UUID().uuidString)"
        library = TopicSoundLibrary(defaults: UserDefaults(suiteName: suite)!, container: root)
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    private func message(_ priority: Int16? = 3) -> Message {
        Message(id: UUID().uuidString, time: 1_800_000_000, event: "message", topic: "alerts", message: "Sound test", priority: priority)
    }

    private func soundName(_ sound: UNNotificationSound?) -> String? {
        // The SDK has no public name getter. Inspect the secure-coding payload, not a private selector.
        guard let sound, let data = try? NSKeyedArchiver.archivedData(withRootObject: sound, requiringSecureCoding: true),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any] else { return nil }
        return objects.compactMap { $0 as? String }.first { $0.hasSuffix(".wav") }
    }

    func testDefaultAndEveryBuiltinUseExpectedNotificationSound() throws {
        try TopicSoundImporter.installBuiltins(library: library)
        let content = UNMutableNotificationContent()
        for priority: Int16? in [nil, 1, 2, 3, 4, 5] {
            content.configureInterruption(message: message(priority), criticalEnabled: false, criticalAuthorized: false)
            XCTAssertEqual(content.sound, .default)
            XCTAssertEqual(content.interruptionLevel, (priority ?? 3) <= 2 ? .passive : ((priority ?? 3) >= 4 ? .timeSensitive : .active))
        }
        for sound in TopicSound.builtins {
            XCTAssertNotNil(library.file(sound.id))
            library.setChoice(sound.id, for: "topic")
            content.configureInterruption(message: message(), soundName: library.resolvedChoice(for: "topic"))
            XCTAssertEqual(soundName(content.sound), sound.id)
        }
    }

    func testMissingUnreadableOrUnsafeFileFallsBackToDefaultNotSilence() throws {
        for name in ["gone.wav", "../outside.wav", "empty.wav"] {
            if name == "empty.wav" {
                try FileManager.default.createDirectory(at: library.directory!, withIntermediateDirectories: true)
                try Data().write(to: library.directory!.appendingPathComponent(name))
            }
            library.setChoice(name, for: "topic")
            let content = UNMutableNotificationContent()
            content.configureInterruption(message: message(), soundName: library.resolvedChoice(for: "topic"))
            XCTAssertEqual(content.sound, .default)
        }
    }

    func testPassiveHighAndCriticalMappingAndSilentSequenceUpdate() throws {
        try TopicSoundImporter.installBuiltins(library: library)
        let name = TopicSound.builtins[0].id
        for priority in [Int16(1), 2, 3, 4, 5] {
            for enabled in [false, true] {
                for authorized in [false, true] {
                    let content = UNMutableNotificationContent()
                    content.configureInterruption(message: message(priority), soundName: name,
                                                  criticalEnabled: enabled, criticalAuthorized: authorized)
                    if priority == 5 && enabled && authorized {
                        XCTAssertEqual(content.sound, .defaultCritical)
                        XCTAssertEqual(content.interruptionLevel, .critical)
                    } else {
                        XCTAssertEqual(soundName(content.sound), name)
                        XCTAssertEqual(content.interruptionLevel, priority <= 2 ? .passive : (priority >= 4 ? .timeSensitive : .active))
                    }
                }
            }
        }
        var update = message(5); update.isUpdate = true
        let content = UNMutableNotificationContent()
        content.configureInterruption(message: update, soundName: name, criticalEnabled: true, criticalAuthorized: true)
        XCTAssertNil(content.sound); XCTAssertEqual(content.interruptionLevel, .passive)
    }

    func testMutedTopicSilencesCustomAndCriticalSounds() throws {
        let store = Store(inMemory: true)
        let sub = store.saveSubscription(baseUrl: "https://sound.example", topic: "alerts")
        try store.setTopicMute(until: .distantFuture, subscription: sub)
        for critical in [false, true] {
            let content = UNMutableNotificationContent()
            content.configureInterruption(message: message(5), soundName: "ntfy-ping-v1.wav", criticalEnabled: critical, criticalAuthorized: critical)
            content.applyTopicMute(baseUrl: sub.baseUrl!, topic: sub.topic!, store: store)
            XCTAssertNil(content.sound); XCTAssertEqual(content.interruptionLevel, .passive)
        }
    }

    func testChoiceSurvivesRelaunchAndNSEReaderUsesSamePermanentIdentity() throws {
        let url = root.appendingPathComponent("shared.sqlite")
        let app = Store(inMemory: true, storeURL: url)
        let sub = app.saveSubscription(baseUrl: "https://sound.example/", topic: "alerts")
        try TopicSoundImporter.installBuiltins(library: library)
        let name = TopicSound.builtins[1].id
        library.setChoice(name, for: sub.objectID.uriRepresentation().absoluteString)
        let nse = Store(inMemory: true, storeURL: url)
        let independentLibrary = TopicSoundLibrary(defaults: UserDefaults(suiteName: suite)!, container: root)
        XCTAssertEqual(nse.topicSoundName(baseUrl: "https://sound.example/", topic: "alerts", library: independentLibrary), name)
        XCTAssertNil(nse.topicSoundName(baseUrl: "https://other.example", topic: "alerts", library: independentLibrary))
        XCTAssertNil(nse.topicSoundName(baseUrl: "https://sound.example", topic: "other", library: independentLibrary))
        for store in [nse, app] {
            store.context.reset()
            for disk in store.container.persistentStoreCoordinator.persistentStores {
                try store.container.persistentStoreCoordinator.remove(disk)
            }
        }
    }

    func testUnsubscribeClearsChoiceAndReaddedTopicInheritsDefault() throws {
        let store = Store(inMemory: true)
        let sub = store.saveSubscription(baseUrl: "https://sound.example", topic: "alerts")
        let identity = sub.objectID.uriRepresentation().absoluteString
        library.setChoice(TopicSound.builtins[0].id, for: identity)
        XCTAssertTrue(store.delete(subscription: sub, soundLibrary: library))
        XCTAssertNil(library.choice(for: identity))
        let replacement = store.saveSubscription(baseUrl: "https://sound.example", topic: "alerts")
        XCTAssertNotEqual(identity, replacement.objectID.uriRepresentation().absoluteString)
        XCTAssertNil(store.topicSoundName(baseUrl: "https://sound.example", topic: "alerts", library: library))
    }

    func testFailedUnsubscribeKeepsChoice() throws {
        let store = Store(inMemory: true)
        let sub = store.saveSubscription(baseUrl: "https://sound.example", topic: "keep")
        let identity = sub.objectID.uriRepresentation().absoluteString
        library.setChoice("ntfy-ping-v1.wav", for: identity)
        // An unrelated invalid insertion makes the real context save fail validation.
        let invalid = NSEntityDescription.insertNewObject(forEntityName: "Notification", into: store.context)
        invalid.setValue(nil, forKey: "id")
        invalid.setValue(nil, forKey: "message")
        XCTAssertFalse(store.delete(subscription: sub, soundLibrary: library))
        XCTAssertEqual(library.choice(for: identity), "ntfy-ping-v1.wav")
    }

    func testActualNSEDeliveryKeepsCustomSoundAfterFinalPriorityMapping() throws {
        let store = Store.shared
        let topic = "sound-nse-\(UUID().uuidString)"
        let sub = store.saveSubscription(baseUrl: "https://sound.example", topic: topic)
        defer { store.delete(subscription: sub, soundLibrary: library) }
        try TopicSoundImporter.installBuiltins(library: library)
        let name = TopicSound.builtins[1].id
        library.setChoice(name, for: sub.objectID.uriRepresentation().absoluteString)
        let service = NotificationService()
        service.soundLibrary = library
        var message = self.message(); message.topic = topic
        let content = UNMutableNotificationContent()
        content.userInfo = message.toUserInfo(); content.userInfo["base_url"] = sub.baseUrl!
        let request = UNNotificationRequest(identifier: message.id, content: content, trigger: nil)
        let done = expectation(description: "NSE content handler")
        DispatchQueue.global(qos: .userInitiated).async {
            service.didReceive(request) { output in
                XCTAssertEqual(self.soundName(output.sound), name)
                XCTAssertEqual(output.body, "Sound test")
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 8)
    }

    func testActualBackgroundPollSchedulerKeepsCustomSound() throws {
        let store = Store.shared
        let topic = "sound-app-\(UUID().uuidString)"
        let sub = store.saveSubscription(baseUrl: "https://sound.example", topic: topic)
        defer { store.delete(subscription: sub, soundLibrary: library) }
        try TopicSoundImporter.installBuiltins(library: library)
        let name = TopicSound.builtins[2].id
        library.setChoice(name, for: sub.objectID.uriRepresentation().absoluteString)
        let app = AppDelegate()
        app.soundLibrary = library
        app.beginNotificationBackgroundTask = { _ in .invalid }
        let done = expectation(description: "background poll scheduler")
        app.notificationScheduler = { request, completion in
            XCTAssertEqual(self.soundName(request.content.sound), name)
            XCTAssertEqual(request.content.body, "Sound test")
            completion(nil); done.fulfill()
        }
        var message = self.message(); message.topic = topic
        app.showNotification(baseUrl: sub.baseUrl!, message)
        wait(for: [done], timeout: 8)
    }

    @MainActor
    func testOpeningTopicWithDeliveredBannersUsesQueueSafeIdentityAndOnlyClearsThatTopic() throws {
        let center = UNUserNotificationCenter.current()
        let permission = expectation(description: "read notification permission")
        var allowed = false
        center.getNotificationSettings { settings in
            allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            permission.fulfill()
        }
        wait(for: [permission], timeout: 5)
        guard allowed else { throw XCTSkip("Native banner cleanup requires notification permission; logic tests run without it") }
        let original = center.delegate
        let delivery = TopicSoundDeliveryDelegate()
        center.delegate = delivery
        let topic = "sound-cleanup-\(UUID().uuidString)"
        let sub = Store.shared.saveSubscription(baseUrl: "https://sound.example", topic: topic)
        var ids: [String] = []
        defer {
            center.delegate = original
            center.removeDeliveredNotifications(withIdentifiers: ids)
            Store.shared.delete(subscription: sub, soundLibrary: library)
        }
        for name in [topic, "unrelated-\(topic)"] {
            let content = UNMutableNotificationContent()
            content.title = "Notification cleanup regression"
            content.body = "Fixture"
            content.userInfo = ["base_url": "https://sound.example/", "topic": name]
            let id = UUID().uuidString; ids.append(id)
            let scheduled = expectation(description: "schedule native fixture")
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
                XCTAssertNil(error); scheduled.fulfill()
            }
            wait(for: [scheduled], timeout: 5)
        }
        func deliveredIDs() -> Set<String> {
            let read = expectation(description: "read delivered fixtures")
            var result = Set<String>()
            center.getDeliveredNotifications { banners in result = Set(banners.map { $0.request.identifier }); read.fulfill() }
            wait(for: [read], timeout: 5)
            return result
        }
        let deliveryLimit = Date().addingTimeInterval(5)
        while !Set(ids).isSubset(of: deliveredIDs()) && Date() < deliveryLimit {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(Set(ids).isSubset(of: deliveredIDs()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: { $0.isKeyWindow })
        let window = UIWindow(windowScene: scene); window.frame = UIScreen.main.bounds
        window.rootViewController = UIHostingController(rootView: NavigationView {
            NotificationListView(subscription: sub).environmentObject(Store.shared)
        }.environment(\.scenePhase, .inactive))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let cleanupLimit = Date().addingTimeInterval(5)
        while deliveredIDs().contains(ids[0]) && Date() < cleanupLimit {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let remaining = deliveredIDs()
        XCTAssertFalse(remaining.contains(ids[0]))
        XCTAssertTrue(remaining.contains(ids[1]), "Opening one topic must leave other topics' banners intact")
    }

    private func compressedFixture(duration: Double) throws -> URL {
        let url = root.appendingPathComponent("Cash register.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let writer = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                      AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        for second in 0..<Int(ceil(duration)) {
            buffer.frameLength = AVAudioFrameCount(min(44_100, Int((duration - Double(second)) * 44_100)))
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 880 / 44_100) * 0.3) }
            try writer.write(from: buffer)
        }
        return url
    }

    func testCompressedAACImportConvertsToNotificationPCMAndUsesImportedName() throws {
        let source = try compressedFixture(duration: 1.25)
        let sound = try TopicSoundImporter.importFile(source, library: library)
        let file = try AVAudioFile(forReading: XCTUnwrap(library.file(sound.id)))
        XCTAssertEqual(file.fileFormat.settings[AVFormatIDKey] as? UInt32, kAudioFormatLinearPCM)
        XCTAssertEqual(file.fileFormat.sampleRate, 22_050)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 1.25, accuracy: 0.1)
        XCTAssertEqual(library.imports, [sound]); XCTAssertEqual(sound.title, "Cash register")
        library.setChoice(sound.id, for: "imported")
        let content = UNMutableNotificationContent()
        content.configureInterruption(message: message(), soundName: library.resolvedChoice(for: "imported"))
        XCTAssertEqual(soundName(content.sound), sound.id)
    }

    func testLongCompressedImportIsTrimmedBelowThirtySeconds() throws {
        let sound = try TopicSoundImporter.importFile(compressedFixture(duration: 31), library: library)
        let file = try AVAudioFile(forReading: XCTUnwrap(library.file(sound.id)))
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        XCTAssertEqual(seconds, 29, accuracy: 0.02); XCTAssertLessThan(seconds, 30)
        XCTAssertLessThanOrEqual(try Data(contentsOf: XCTUnwrap(library.file(sound.id))).count, 29 * 22_050 * 2 + 44)
    }

    func testUnreadableAndOversizedImportsNeverRegisterBrokenSound() throws {
        let unreadable = root.appendingPathComponent("broken.mp3")
        try Data("this is not audio".utf8).write(to: unreadable)
        XCTAssertThrowsError(try TopicSoundImporter.importFile(unreadable, library: library))
        XCTAssertThrowsError(try TopicSoundImporter.importFile(root.appendingPathComponent("absent.m4a"), library: library))
        let huge = root.appendingPathComponent("huge.wav")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(TopicSoundImporter.maximumBytes + 1)); try handle.close()
        XCTAssertThrowsError(try TopicSoundImporter.importFile(huge, library: library))
        XCTAssertTrue(library.imports.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.directory!.path))
    }

    func testBuiltinsAreDistinctBoundedPCMWithFades() throws {
        try TopicSoundImporter.installBuiltins(library: library)
        var contents = Set<Data>()
        for sound in TopicSound.builtins {
            let data = try Data(contentsOf: XCTUnwrap(library.file(sound.id)))
            contents.insert(data)
            let file = try AVAudioFile(forReading: XCTUnwrap(library.file(sound.id)))
            XCTAssertLessThan(Double(file.length) / file.fileFormat.sampleRate, 30)
            XCTAssertEqual(Array(data[44..<46]), [0, 0], "Attack starts at zero to avoid a click")
        }
        XCTAssertEqual(contents.count, 3)
    }
}

private final class TopicSoundDeliveryDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.list])
    }
}
