import XCTest
@testable import ntfy

final class DiagnosticReportTests: XCTestCase {
    private var directory: URL!
    private var store: DiagnosticReportStore!
    private var clock = ISO8601DateFormatter().date(from: "2026-10-31T14:00:00Z")!
    private let secrets = ["private-server.invalid", "secret-topic-name", "tk_super_secret", "private.bundle.identifier", "private-container-marker"]

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = DiagnosticReportStore(directory: directory, now: { self.clock })
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        store = nil
    }
    private func fixture(_ kind: DiagnosticKind) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: kind.rawValue, withExtension: "json",
                                                        subdirectory: "DiagnosticFixtures"))
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
    private func receive(_ payload: [String: Any]) throws {
        try store.receive(JSONSerialization.data(withJSONObject: payload))
    }
    private func exported(_ report: DiagnosticReport) throws -> [String: Any] {
        let url = try store.file(for: report)
        let data = try Data(contentsOf: url)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for planted in secrets { XCTAssertFalse(text.contains(planted), "Sensitive text persisted/exported: \(planted)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count,
                       try store.reports().count, "No raw payload or export cache")
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testAppleShapedFixturesPreserveStacksAndMetadataWithoutFreeText() throws {
        for kind in DiagnosticKind.allCases { try receive(fixture(kind)) }
        let reports = try store.reports()
        XCTAssertEqual(Set(reports.map(\.kind)), Set(DiagnosticKind.allCases))
        for report in reports {
            let object = try exported(report)
            let diagnostic = try XCTUnwrap(object["diagnostic"] as? [String: Any])
            let metadata = try XCTUnwrap(diagnostic["diagnosticMetaData"] as? [String: Any])
            XCTAssertEqual(metadata["appVersion"] as? String, "1.21.0")
            XCTAssertEqual(metadata["osVersion"] as? String, "iPhone OS 26.5 (23F77)")
            XCTAssertNil(metadata["exceptionReason"])
            XCTAssertNil(metadata["terminationReason"])
            XCTAssertNil(metadata["virtualMemoryRegionInfo"])
            XCTAssertNil(metadata["bundleIdentifier"])
            XCTAssertNil(diagnostic["signpostData"])
            let tree = try XCTUnwrap(diagnostic["callStackTree"] as? [String: Any])
            let stacks = try XCTUnwrap(tree["callStacks"] as? [[String: Any]])
            let frames = try XCTUnwrap(stacks.first?["callStackRootFrames"] as? [[String: Any]])
            XCTAssertEqual(frames.first?["binaryUUID"] as? String, "70B89F27-1634-3580-A695-57CDB41D7743")
            XCTAssertEqual(frames.first?["address"] as? Int, 7170766264)
            XCTAssertEqual(frames.first?["offsetIntoBinaryTextSegment"] as? Int, 165304)
            let subframes = try XCTUnwrap(frames.first?["subFrames"] as? [[String: Any]])
            XCTAssertEqual(subframes.first?["offsetIntoBinaryTextSegment"] as? Int, 6948)
            XCTAssertEqual(frames.first?["binaryName"] as? String, "ntfy")
            XCTAssertEqual(subframes.first?["binaryName"] as? String, "libdyld.dylib")
            switch report.kind {
            case .crash: XCTAssertEqual(metadata["signal"] as? Int, 11)
            case .hang: XCTAssertEqual(metadata["hangDuration"] as? String, "7 sec")
            case .cpu: XCTAssertEqual(metadata["totalCPUTime"] as? String, "90 sec")
            case .diskWrite: XCTAssertEqual(metadata["totalWritesCaused"] as? String, "300 MB")
            case .launch: XCTAssertEqual(metadata["launchDuration"] as? String, "15 sec")
            }
        }
        XCTAssertTrue(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let reopened = DiagnosticReportStore(directory: directory, now: { self.clock })
        XCTAssertEqual(try reopened.reports().count, 5)
    }

    func testCrashIdentifiersSurviveIntakeWithoutRuntimeText() throws {
        let cases = [("Namespace RUNNINGBOARD, Code 0xdead10cc", "ntfy", "NSInvalidArgumentException", "NSException"),
                     ("Namespace SPRINGBOARD, Code 0x8badf00d", "UIKitCore", "Module.InvalidArgument", "Module.Exception_Class"),
                     ("Namespace SIGNAL, Code 9", "libswiftCore.dylib", "NSRangeException", "NSException")]
        for (termination, binary, name, className) in cases {
            var payload = try fixture(.crash)
            var diagnostics = payload[DiagnosticKind.crash.payloadKey] as! [[String: Any]]
            var metadata = diagnostics[0]["diagnosticMetaData"] as! [String: Any]
            metadata["terminationReason"] = termination + "; bundle private.bundle.identifier process details"
            metadata["exceptionReason"] = ["exceptionName": name, "className": className,
                                          "exceptionType": "ObjectiveC", "composedMessage": "https://" + secrets.prefix(3).joined(separator: "/"),
                                          "formatString": "URL %@", "arguments": secrets]
            diagnostics[0]["diagnosticMetaData"] = metadata
            diagnostics[0]["callStackTree"] = ["callStacks": [["callStackRootFrames": [[
                "binaryName": binary, "address": 7170766264, "subFrames": [[
                    "binaryName": "/private/var/mobile/Containers/private-container-marker/ntfy", "address": 123]]]]]]]
            payload[DiagnosticKind.crash.payloadKey] = diagnostics
            try receive(payload)
            let report = try XCTUnwrap(store.reports().first)
            let diagnostic = try exported(report)["diagnostic"] as! [String: Any]
            let safe = try XCTUnwrap(diagnostic["diagnosticMetaData"] as? [String: Any])
            XCTAssertEqual(safe["terminationReason"] as? String, termination)
            let reason = try XCTUnwrap(safe["exceptionReason"] as? [String: String])
            XCTAssertEqual(reason, ["exceptionName": name, "className": className])
            let tree = diagnostic["callStackTree"] as! [String: Any]
            let stacks = tree["callStacks"] as! [[String: Any]]
            let frames = stacks[0]["callStackRootFrames"] as! [[String: Any]]
            XCTAssertEqual(frames[0]["binaryName"] as? String, binary)
            let children = frames[0]["subFrames"] as! [[String: Any]]
            XCTAssertNil(children[0]["binaryName"])
            XCTAssertEqual(children[0]["address"] as? Int, 123)
            try store.delete(report)
        }
    }

    func testCrashIdentifierGrammarsRejectFreeTextPathsAndOverlongValues() throws {
        let invalidNames = ["bad class", "bad@class", "bad/name", "bad:name", "bad%name", "bad\n", "9Invalid", "Module..Name",
                            String(repeating: "A", count: 129)]
        let invalidBinaries = ["/private/var/mobile/Containers/private-container-marker/ntfy", "bad image", "bad\\image",
                               "bad:image", "bad@image", "bad%image", "bad\n", String(repeating: "A", count: 129)]
        let invalidTerminations = [" Namespace RUNNINGBOARD, Code 0xdead10cc", "prefix Namespace SIGNAL, Code 9",
                                   "Namespace runningboard, Code 9", "Namespace SIGNAL, Code 0xdead10cc/private.bundle.identifier",
                                   "Namespace SIGNAL, Code 0x12345678901234567", "Namespace SIGNAL, Code 123456789012345678901",
                                   "Namespace SIGNAL, Code 9" + String(repeating: " ", count: 4096)]
        for index in 0..<max(invalidNames.count, max(invalidBinaries.count, invalidTerminations.count)) {
            var payload = try fixture(.crash)
            var diagnostics = payload[DiagnosticKind.crash.payloadKey] as! [[String: Any]]
            var metadata = diagnostics[0]["diagnosticMetaData"] as! [String: Any]
            metadata["terminationReason"] = invalidTerminations[index % invalidTerminations.count]
            metadata["exceptionReason"] = ["className": invalidNames[index % invalidNames.count],
                                          "exceptionName": invalidNames[index % invalidNames.count],
                                          "exceptionType": "ObjectiveC", "composedMessage": "https://" + secrets.prefix(3).joined(separator: "/"),
                                          "arguments": secrets, "formatString": "private.bundle.identifier"]
            diagnostics[0]["diagnosticMetaData"] = metadata
            diagnostics[0]["callStackTree"] = ["callStacks": [["callStackRootFrames": [[
                "binaryName": invalidBinaries[index % invalidBinaries.count], "address": 123]]]]]
            payload[DiagnosticKind.crash.payloadKey] = diagnostics
            try receive(payload)
            let report = try XCTUnwrap(store.reports().first)
            let diagnostic = try exported(report)["diagnostic"] as! [String: Any]
            let safe = diagnostic["diagnosticMetaData"] as! [String: Any]
            XCTAssertNil(safe["terminationReason"])
            XCTAssertNil(safe["exceptionReason"])
            let tree = diagnostic["callStackTree"] as! [String: Any]
            let stacks = tree["callStacks"] as! [[String: Any]]
            let frames = stacks[0]["callStackRootFrames"] as! [[String: Any]]
            XCTAssertNil(frames[0]["binaryName"])
            try store.delete(report)
        }
    }

    func testUnknownNestedFieldsAndWrongTypesCannotBypassProjection() throws {
        var payload = try fixture(.crash)
        var diagnostics = payload[DiagnosticKind.crash.payloadKey] as! [[String: Any]]
        var metadata = diagnostics[0]["diagnosticMetaData"] as! [String: Any]
        let planted = secrets.joined(separator: " ")
        for key in ["appVersion", "appBuildVersion", "osVersion", "deviceType", "platformArchitecture", "signal", "hangDuration"] {
            metadata[key] = planted
        }
        diagnostics[0]["diagnosticMetaData"] = metadata
        diagnostics[0]["callStackTree"] = ["future": planted, "callStacks": [["callStackRootFrames": [[
            "binaryUUID": planted, "binaryName": planted, "address": planted, "subFrames": [["unknown": planted]]]]]]]
        payload[DiagnosticKind.crash.payloadKey] = diagnostics
        try receive(payload)
        let diagnostic = try exported(XCTUnwrap(store.reports().first))["diagnostic"] as! [String: Any]
        let safe = diagnostic["diagnosticMetaData"] as! [String: Any]
        XCTAssertNil(safe["appVersion"])
        XCTAssertNil(safe["signal"])
    }

    func testCountRetentionAndDeduplication() throws {
        for index in 0..<25 {
            var payload = try fixture(.crash)
            payload["timeStampEnd"] = ISO8601DateFormatter().string(from: clock.addingTimeInterval(Double(-index)))
            try receive(payload)
            XCTAssertLessThanOrEqual(try store.reports().count, 20)
        }
        let reports = try store.reports()
        XCTAssertEqual(reports.count, 20)
        XCTAssertEqual(reports.last?.date, clock.addingTimeInterval(-19))
        var newest = try fixture(.crash)
        newest["timeStampEnd"] = ISO8601DateFormatter().string(from: clock)
        try receive(newest)
        XCTAssertEqual(try store.reports().count, 20)
    }

    func testAgeRetentionAndDeleteRemoveTheSharedFile() throws {
        try receive(fixture(.hang))
        let report = try XCTUnwrap(store.reports().first)
        let sharedFile = try store.file(for: report)
        try store.delete(report)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sharedFile.path))
        XCTAssertThrowsError(try store.file(for: report))
        XCTAssertTrue(try store.reports().isEmpty)
        try receive(fixture(.cpu))
        clock = clock.addingTimeInterval(DiagnosticReportStore.maximumAge + 1)
        XCTAssertTrue(try store.reports().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        try receive(fixture(.diskWrite)) // Already expired when delivered.
        XCTAssertTrue(try store.reports().isEmpty)
    }

    func testByteRetentionAndOversizeReport() throws {
        var payload = try fixture(.hang)
        var diagnostics = payload[DiagnosticKind.hang.payloadKey] as! [[String: Any]]
        let frame: [String: Any] = ["binaryUUID": "70B89F27-1634-3580-A695-57CDB41D7743", "address": 7170766264,
                                    "offsetIntoBinaryTextSegment": 165304, "sampleCount": 1]
        let stack: [String: Any] = ["callStackRootFrames": Array(repeating: frame, count: 500)]
        diagnostics[0]["callStackTree"] = ["callStacks": Array(repeating: stack, count: 6)]
        payload[DiagnosticKind.hang.payloadKey] = diagnostics
        for index in 0..<20 {
            payload["timeStampEnd"] = ISO8601DateFormatter().string(from: clock.addingTimeInterval(Double(-index)))
            try receive(payload)
        }
        let reports = try store.reports()
        XCTAssertFalse(reports.isEmpty)
        XCTAssertLessThan(reports.count, 20, "Byte bound must evict before count bound")
        let sizes = try reports.map { try Data(contentsOf: store.file(for: $0)).count }
        XCTAssertLessThanOrEqual(sizes.reduce(0, +), DiagnosticReportStore.maximumBytes)
        XCTAssertLessThanOrEqual(sizes.max()!, DiagnosticReportStore.maximumReportBytes)
        diagnostics[0]["callStackTree"] = ["callStacks": Array(repeating: stack, count: 20)]
        payload[DiagnosticKind.hang.payloadKey] = diagnostics
        let ids = reports.map(\.id)
        try receive(payload)
        XCTAssertEqual(try store.reports().map(\.id), ids, "Oversize sanitized report must not be stored")
    }

    func testDailyMetricsAndMalformedPayloadDoNotProduceReports() throws {
        try store.receive(Data(#"{"cpuMetrics":{"cumulativeCPUTime":"100 sec"}}"#.utf8))
        XCTAssertTrue(try store.reports().isEmpty)
        XCTAssertThrowsError(try store.receive(Data("invalid".utf8)))
        XCTAssertTrue(try store.reports().isEmpty)
    }
}
