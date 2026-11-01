import Foundation
import OSLog

/// App-only write-ahead journal. Neither extension writes this defaults key.
/// All instances share a lock; no Core Data or network call runs with it held.
final class FcmTeardownLedger {
    static let key = "fcmTeardownLedger.v1"
    static let legacyKeys = ["pendingFcmUnsubscribes", "pendingObsoleteFcmTopicNames"]
    static let horizon: TimeInterval = 30 * 24 * 60 * 60
    private static let lock = NSLock()
    private static let logger = Logger(subsystem: "FcmTeardownLedger", category: "retry")

    struct Entry: Codable, Equatable {
        let name: String
        let id: UUID
        let created: Date
        var attempts = 0
        var lastAttempt: Date?
        let obsolete: Bool

        var retryDelay: TimeInterval {
            min(3600, 30 * pow(2, Double(min(max(attempts - 1, 0), 7))))
        }
        func isDue(at now: Date) -> Bool {
            lastAttempt.map { now.timeIntervalSince($0) >= retryDelay } ?? true
        }
    }

    struct Change {
        let entry: Entry
        let previous: Entry?
    }

    struct GiveUp: Codable {
        let id: UUID
        let attempts: Int
        let date: Date
    }

    private struct State: Codable {
        var version = 1
        var entries: [String: Entry] = [:]
        var givenUpCount = 0
        var lastGiveUp: GiveUp?
    }

    private let defaults: UserDefaults
    private let now: () -> Date
    private let report: (String) -> Void

    init(defaults: UserDefaults, now: @escaping () -> Date = Date.init,
         report: @escaping (String) -> Void = { message in
             Log.w("FcmTeardownLedger", message)
             // Log is DEBUG-only. Unified logging and persisted summary survive Release builds.
             logger.warning("\(message, privacy: .public)")
         }) {
        self.defaults = defaults
        self.now = now
        self.report = report
    }

    private func read() -> State {
        var state = State()
        if let raw = defaults.object(forKey: Self.key) {
            if let data = raw as? Data, let decoded = try? JSONDecoder().decode(State.self, from: data),
               decoded.version == 1, decoded.entries.allSatisfy({ $0.key == $0.value.name && $0.value.attempts >= 0 && $0.value.attempts < Int.max }) {
                state = decoded
            } else {
                // Preserve the exact unknown value before using this version's journal. Never
                // reinterpret or discard retry intents belonging to an incompatible writer.
                let backup = Self.key + ".preserved." + UUID().uuidString
                defaults.set(raw, forKey: backup)
                guard defaults.synchronize() else { return state }
                defaults.removeObject(forKey: Self.key)
                report("Unrecognized FCM teardown journal preserved at \(backup)")
            }
        }
        for key in Self.legacyKeys {
            guard let raw = defaults.object(forKey: key) else { continue }
            guard let names = raw as? [String] else {
                // Keep unknown legacy data at its original key for a compatible build.
                report("Unrecognized FCM teardown format preserved at \(key)")
                continue
            }
            for name in names where state.entries[name] == nil {
                state.entries[name] = Entry(name: name, id: UUID(), created: now(),
                                            obsolete: key == Self.legacyKeys[1])
            }
            if write(state) {
                defaults.removeObject(forKey: key)
                defaults.synchronize()
            }
        }
        return state
    }

    @discardableResult private func write(_ state: State) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        defaults.set(data, forKey: Self.key)
        return defaults.synchronize()
    }

    var entries: [Entry] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return Array(read().entries.values)
    }

    @discardableResult func record(_ name: String, obsolete: Bool = false) -> Entry? {
        recordChange(name, obsolete: obsolete)?.entry
    }

    func recordChange(_ name: String, obsolete: Bool) -> Change? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var state = read()
        let entry = Entry(name: name, id: UUID(), created: now(), obsolete: obsolete)
        let change = Change(entry: entry, previous: state.entries[name])
        state.entries[name] = entry
        return write(state) ? change : nil
    }

    /// A failed migration may restore prior retry work, but cannot overwrite a newer intent.
    func rollback(_ change: Change) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var state = read()
        guard state.entries[change.entry.name]?.id == change.entry.id else { return }
        state.entries[change.entry.name] = change.previous
        write(state)
    }

    /// Every retirement, including liveness and rollback, compares durable intent identity.
    @discardableResult func remove(_ entry: Entry) -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var state = read()
        guard state.entries[entry.name]?.id == entry.id else { return false }
        state.entries.removeValue(forKey: entry.name)
        return write(state)
    }

    func attempt(_ entry: Entry) -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var state = read()
        guard var current = state.entries[entry.name], current.id == entry.id,
              current.isDue(at: now()), now().timeIntervalSince(current.created) < Self.horizon else { return false }
        current.attempts += 1
        current.lastAttempt = now()
        state.entries[entry.name] = current
        return write(state)
    }

    /// Expiry is also conditional: a snapshot must never expire a newer intent.
    func expire(_ entry: Entry) -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var state = read()
        guard let current = state.entries[entry.name], current.id == entry.id,
              now().timeIntervalSince(current.created) >= Self.horizon else { return false }
        state.entries.removeValue(forKey: entry.name)
        state.givenUpCount += 1
        state.lastGiveUp = GiveUp(id: current.id, attempts: current.attempts, date: now())
        guard write(state) else { return false }
        report("Giving up FCM teardown intent \(entry.id) after \(current.attempts) attempts at the 30-day horizon")
        return true
    }
}
