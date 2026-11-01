import Foundation
import CoreFoundation
import MetricKit
import CryptoKit

enum DiagnosticKind: String, CaseIterable, Codable {
    case crash, hang, cpu, diskWrite, launch

    var payloadKey: String {
        switch self {
        case .crash: return "crashDiagnostics"
        case .hang: return "hangDiagnostics"
        case .cpu: return "cpuExceptionDiagnostics"
        case .diskWrite: return "diskWriteExceptionDiagnostics"
        case .launch: return "appLaunchDiagnostics"
        }
    }

    var title: String {
        switch self {
        case .crash: return String(localized: "Crash")
        case .hang: return String(localized: "Hang")
        case .cpu: return String(localized: "CPU usage")
        case .diskWrite: return String(localized: "Disk writes")
        case .launch: return String(localized: "App launch")
        }
    }
}

struct DiagnosticReport: Identifiable {
    let id: String
    let kind: DiagnosticKind
    /// End of Apple's reporting period, not a promise of an exact crash time.
    let date: Date
}

/// Projects Apple's JSON onto known structural fields. Never persist the original payload.
/// Unknown fields, exception prose, signposts, binary paths and custom metadata are omitted.
enum DiagnosticPrivacy {
    static func project(_ diagnostic: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        if let metadata = diagnostic["diagnosticMetaData"] as? [String: Any] {
            var safe: [String: Any] = measurements(metadata)
            for key in ["exceptionType", "exceptionCode", "signal", "pid"] {
                if let number = metadata[key] as? NSNumber { safe[key] = number }
            }
            for key in ["isTestFlightApp", "lowPowerModeEnabled"] {
                if let value = metadata[key] as? NSNumber,
                   CFGetTypeID(value) == CFBooleanGetTypeID() { safe[key] = value }
            }
            let patterns = [
                "appVersion": #"[0-9]+(?:\.[0-9]+){0,3}"#,
                "appBuildVersion": #"[0-9]+(?:\.[0-9]+){0,3}"#,
                "osVersion": #"(?:iPhone OS|iOS|iPadOS|Mac OS X|macOS) [0-9]+(?:\.[0-9]+){0,2}(?: \([A-Za-z0-9]+\))?"#,
                "deviceType": #"(?:iPhone|iPad|iPod|Mac)[0-9]+,[0-9]+"#,
                "platformArchitecture": #"(?:arm64e?|armv7s?|x86_64)"#
            ]
            for (key, pattern) in patterns {
                if let value = matched(metadata[key], pattern) { safe[key] = value }
            }
            if let value = terminationPrefix(metadata["terminationReason"]) { safe["terminationReason"] = value }
            if let reason = metadata["exceptionReason"] as? [String: Any] {
                var identifiers: [String: String] = [:]
                for key in ["exceptionName", "className"] {
                    if let value = matched(reason[key], #"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*"#) {
                        identifiers[key] = value
                    }
                }
                // exceptionType is human-readable text, not a documented fixed kind.
                if !identifiers.isEmpty { safe["exceptionReason"] = identifiers }
            }
            result["diagnosticMetaData"] = safe
        }
        // Apple represents Measurement values as strings with units in MX JSON.
        result.merge(measurements(diagnostic)) { _, value in value }
        if let tree = diagnostic["callStackTree"] as? [String: Any] {
            var safe: [String: Any] = [:]
            if let value = tree["callStackPerThread"] as? Bool { safe["callStackPerThread"] = value }
            safe["callStacks"] = (tree["callStacks"] as? [[String: Any]] ?? []).prefix(256).map { stack in
                var item: [String: Any] = ["callStackRootFrames": frames(stack["callStackRootFrames"], depth: 0)]
                if let value = stack["threadAttributed"] as? Bool { item["threadAttributed"] = value }
                return item
            }
            result["callStackTree"] = safe
        }
        return result
    }

    private static func measurements(_ input: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in ["hangDuration", "totalCPUTime", "totalSampledTime", "totalWritesCaused", "launchDuration"] {
            if let value = matched(input[key], #"[0-9]+(?:\.[0-9]+)? (?:sec|ms|µs|ns|bytes|kB|MB|GB)"#) {
                result[key] = value
            }
        }
        return result
    }

    private static func frames(_ input: Any?, depth: Int) -> [[String: Any]] {
        guard depth < 128 else { return [] }
        return (input as? [[String: Any]] ?? []).prefix(512).map { frame in
            var safe: [String: Any] = [:]
            for key in ["address", "offsetIntoBinaryTextSegment", "sampleCount"] {
                if let value = frame[key] as? NSNumber { safe[key] = value }
            }
            if let uuid = frame["binaryUUID"] as? String, let value = UUID(uuidString: uuid) {
                safe["binaryUUID"] = value.uuidString
            }
            if let name = matched(frame["binaryName"], #"[A-Za-z_][A-Za-z0-9_.+\-]*"#) { safe["binaryName"] = name }
            if frame["subFrames"] != nil { safe["subFrames"] = frames(frame["subFrames"], depth: depth + 1) }
            return safe
        }
    }

    private static func terminationPrefix(_ input: Any?) -> String? {
        guard let value = input as? String, value.utf8.count <= 4096,
              let range = value.range(of: #"\ANamespace [A-Z][A-Z0-9_]{0,63}, Code (?:0x[0-9A-Fa-f]{1,16}|[0-9]{1,20})(?=$|[ \t\r\n,;])"#,
                                      options: .regularExpression) else { return nil }
        // The bounded prefix identifies the system kill; its process/bundle details never leave memory.
        return String(value[range])
    }

    private static func matched(_ input: Any?, _ pattern: String) -> String? {
        guard let value = input as? String, value.utf8.count <= 128,
              value.range(of: "^(?:" + pattern + ")$", options: .regularExpression)?.lowerBound == value.startIndex,
              value.range(of: "^(?:" + pattern + ")$", options: .regularExpression)?.upperBound == value.endIndex else { return nil }
        return value
    }
}

/// App-private, excluded from backup. UI and MetricKit callbacks share this lock; no raw data is logged.
final class DiagnosticReportStore {
    static let shared = DiagnosticReportStore(directory: FileManager.default.urls(for: .applicationSupportDirectory,
                                                                                in: .userDomainMask)[0]
        .appendingPathComponent("DiagnosticReports", isDirectory: true))
    static let changed = Foundation.Notification.Name("DiagnosticReportsChanged")
    static let maximumCount = 20
    static let maximumBytes = 10 * 1024 * 1024
    static let maximumReportBytes = 1024 * 1024
    static let maximumAge: TimeInterval = 30 * 24 * 60 * 60
    private let directory: URL
    private let lock = NSLock()
    private let now: () -> Date

    init(directory: URL, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    /// The callback and debug fixtures both enter here, before the first disk write.
    func receive(_ payload: Data) throws {
        guard payload.count <= 16 * Self.maximumReportBytes else { return }
        let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] ?? [:]
        lock.lock(); defer { lock.unlock() }
        try prepareDirectory()
        let end = Self.parseDate(object["timeStampEnd"]) ?? now()
        guard end >= now().addingTimeInterval(-Self.maximumAge), end <= now().addingTimeInterval(86400) else { return }
        for kind in DiagnosticKind.allCases {
            for diagnostic in (object[kind.payloadKey] as? [[String: Any]] ?? []).prefix(Self.maximumCount) {
                let safe: [String: Any] = ["schemaVersion": 1, "kind": kind.rawValue,
                                          "reportingPeriodEnd": ISO8601DateFormatter().string(from: end),
                                          "diagnostic": DiagnosticPrivacy.project(diagnostic)]
                let data = try JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys, .prettyPrinted])
                guard data.count <= Self.maximumReportBytes else { continue }
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let url = directory.appendingPathComponent("ntfy-\(kind.rawValue)-\(hash).json")
                if !FileManager.default.fileExists(atPath: url.path) {
                    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
                try prune() // Bound disk use even if one callback has many diagnostics.
            }
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    func reports() throws -> [DiagnosticReport] {
        lock.lock(); defer { lock.unlock() }
        try prepareDirectory()
        try prune()
        return try entries().map { $0.report }
    }

    /// Share the already-filtered file. No raw payload or second export cache exists.
    func file(for report: DiagnosticReport) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        try prune()
        guard let entry = try entries().first(where: { $0.report.id == report.id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return entry.url
    }

    func delete(_ report: DiagnosticReport) throws {
        lock.lock(); defer { lock.unlock() }
        guard let entry = try entries().first(where: { $0.report.id == report.id }) else { return }
        try FileManager.default.removeItem(at: entry.url)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func entries() throws -> [(report: DiagnosticReport, url: URL, bytes: Int)] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= Self.maximumReportBytes,
                      let data = try? Data(contentsOf: url),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let raw = object["kind"] as? String, let kind = DiagnosticKind(rawValue: raw),
                      let date = Self.parseDate(object["reportingPeriodEnd"]) else {
                    try FileManager.default.removeItem(at: url)
                    return nil
                }
                return (DiagnosticReport(id: url.lastPathComponent, kind: kind, date: date), url, size)
            }.sorted {
                $0.report.date == $1.report.date ? $0.report.id < $1.report.id : $0.report.date > $1.report.date
            }
    }

    private func prune() throws {
        var count = 0, bytes = 0
        for entry in try entries() {
            if entry.report.date < now().addingTimeInterval(-Self.maximumAge)
                || count >= Self.maximumCount || bytes + entry.bytes > Self.maximumBytes {
                try FileManager.default.removeItem(at: entry.url)
            } else {
                count += 1; bytes += entry.bytes
            }
        }
    }

    private static func parseDate(_ input: Any?) -> Date? {
        guard let value = input as? String, value.count <= 40 else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }
}

final class DiagnosticSubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticSubscriber()
    private let queue = DispatchQueue(label: "DiagnosticReports", qos: .utility)

    func start() {
        queue.async { _ = try? DiagnosticReportStore.shared.reports() }
        MXMetricManager.shared.add(self)
    }

    #if DEBUG
    /// Simulator verification only; the fixture takes exactly the production intake path.
    func receiveDebugFixtureIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["NTFY_DIAGNOSTIC_FIXTURE"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        try? DiagnosticReportStore.shared.receive(data)
    }
    #endif

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        queue.async {
            for payload in payloads {
                // Intentionally no error log: errors and payload descriptions may contain user text.
                try? DiagnosticReportStore.shared.receive(payload.jsonRepresentation())
            }
        }
    }

    // Daily aggregate metrics do not help a user attach an individual incident.
    func didReceive(_ payloads: [MXMetricPayload]) {}
}
