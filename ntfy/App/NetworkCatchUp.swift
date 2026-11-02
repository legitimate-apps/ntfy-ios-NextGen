import Foundation
import Network

/// Main-queue lifecycle and path policy. A usable path is a retry hint, not server reachability.
final class NetworkCatchUp {
    static let shared = NetworkCatchUp(
        hasUnreachable: { DeliveryHealthMonitor.shared.topics.values.contains { $0.failure == .unreachable } },
        poll: { recovering, done in
            let store = Store.shared
            SubscriptionManager(store: store).pollAll(store.getSubscriptions() ?? [], manual: false, recovering: recovering, completion: done)
        })
    private let hasUnreachable: () -> Bool
    private let poll: (Bool, @escaping () -> Void) -> Void
    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var monitor: NWPathMonitor?
    private var active = false, running = false, foreground = false, pending = false, seenPath = false
    private var path: String?
    private var generation = 0
    private var scheduled: Int?
    private var nextRecovery: TimeInterval = 0

    init(hasUnreachable: @escaping () -> Bool, poll: @escaping (Bool, @escaping () -> Void) -> Void,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) }) {
        self.hasUnreachable = hasUnreachable; self.poll = poll; self.now = now; self.schedule = schedule
    }

    func start() {
        guard monitor == nil, NSClassFromString("XCTestCase") == nil else { return }
        let monitor = NWPathMonitor(); self.monitor = monitor
        #if DEBUG
        if ProcessInfo.processInfo.environment["NTFY_RECONNECT_PATH_FILE"] != nil {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
                DispatchQueue.main.async {
                    guard let file = ProcessInfo.processInfo.environment["NTFY_RECONNECT_PATH_FILE"],
                          let value = try? String(contentsOfFile: file, encoding: .utf8) else { return }
                    NetworkCatchUp.shared.pathChanged(value.isEmpty ? nil : value)
                }
            }, "net.ntfy.debug.networkPath" as CFString, nil, .deliverImmediately)
            pathChanged(nil)
            return
        }
        #endif
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = path.status == .satisfied ? path.availableInterfaces.filter { path.usesInterfaceType($0.type) }
                .map { "\($0.type):\($0.name)" }.sorted().joined(separator: ",") : nil
            DispatchQueue.main.async { self?.pathChanged(signature) }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkCatchUp"))
    }

    func activate() {
        active = true; foreground = true; pending = false; generation += 1
        drain()
    }
    func deactivate() {
        active = false; foreground = false; pending = false; generation += 1
    }
    func pathChanged(_ signature: String?) {
        let changed = seenPath && signature != path
        seenPath = true; path = signature
        guard changed else { return }
        generation += 1
        if active && signature != nil { pending = true }
        drain()
    }
    private func drain() {
        guard active, !running else { return }
        if foreground { foreground = false; launch(recovering: false); return }
        guard pending, path != nil, hasUnreachable(), scheduled != generation else { return }
        let token = generation; scheduled = token
        schedule(max(0.5, nextRecovery - now())) { [weak self] in
            guard let self, self.generation == token else { return }
            self.scheduled = nil
            guard self.active, !self.running, self.path != nil, self.pending, self.hasUnreachable() else { return }
            self.pending = false; self.nextRecovery = self.now() + 30
            self.launch(recovering: true)
        }
    }
    private func launch(recovering: Bool) {
        running = true
        poll(recovering) { [weak self] in
            self?.running = false
            self?.drain()
        }
    }
}
