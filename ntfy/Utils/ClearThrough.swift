import Foundation

/// A topic-wide read captured before changing local flags. Equal-second candidates are resolved
/// in the server's publication order, never by treating opaque sequence or message IDs as counters.
struct ClearThroughIntent {
    let boundary: ClearRequest
    let candidates: [ClearRequest]
    let known: [ClearRequest]
}

enum ClearThroughResult { case sent, fallback, deferred }

/// Retains bounded read intent while reconciling an uncertain transaction. All state belongs to
/// this queue; network callbacks never touch managed objects. A restart leaves local read state intact.
final class ClearThroughCoordinator {
    static let maxPending = 20
    static let retention: TimeInterval = 300
    typealias Transport = (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void
    typealias Discovery = (String, BasicUser?, @escaping (ServerCapabilities) -> Void) -> Void
    private final class Work {
        let intent: ClearThroughIntent
        let created: TimeInterval
        var boundary: ClearRequest
        var published = false
        var retries = 0
        var reportedDeferred = false
        let storeMessages: ([Message]) -> Bool
        var completion: ((ClearThroughResult) -> Void)?
        init(_ intent: ClearThroughIntent, now: TimeInterval, storeMessages: @escaping ([Message]) -> Bool, completion: @escaping (ClearThroughResult) -> Void) {
            self.intent = intent; self.boundary = intent.boundary; self.created = now; self.storeMessages = storeMessages; self.completion = completion
        }
        var key: String { "\(intent.boundary.baseUrl)/\(intent.boundary.topic)" }
    }
    private let queue = DispatchQueue(label: "ntfy.clear-through")
    private var pending: [String: Work] = [:]
    private var oversized: [String: TimeInterval] = [:]
    private let api: ApiService
    private let cooldown: ServerCooldown
    private let discover: Discovery
    private let invalidate: (String) -> Void
    private let transport: Transport
    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    init(api: ApiService = .shared, cooldown: ServerCooldown = .shared,
         discover: @escaping Discovery = { ServerCapabilitiesCache.shared.discover(baseUrl: $0, user: $1, completion: $2) },
         invalidate: @escaping (String) -> Void = { ServerCapabilitiesCache.shared.invalidate(baseUrl: $0) },
         transport: @escaping Transport = { ServerExtensionTransport.shared.send($0, completion: $1) },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { DispatchQueue.global().asyncAfter(deadline: .now() + $0, execute: $1) }) {
        self.api = api; self.cooldown = cooldown; self.discover = discover; self.invalidate = invalidate
        self.transport = transport; self.now = now; self.schedule = schedule
    }

    func send(_ intent: ClearThroughIntent, storeMessages: @escaping ([Message]) -> Bool = { _ in true }, completion: @escaping (ClearThroughResult) -> Void) {
        queue.async {
            self.prune()
            self.cooldown.requestChanged(server: intent.boundary.baseUrl, kind: .clearThrough)
            let work = Work(intent, now: self.now(), storeMessages: storeMessages, completion: completion)
            if let old = self.pending[work.key] {
                if old.published { self.reportDeferred(old) }
                else { self.finish(old, .fallback) }
            }
            while self.pending.count >= Self.maxPending, let oldest = self.pending.min(by: { $0.value.created < $1.value.created })?.key {
                if let old = self.pending.removeValue(forKey: oldest) { self.reportDeferred(old) }
            }
            self.pending[work.key] = work
            if self.oversized[work.key].map({ $0 > self.now() }) == true { self.finish(work, .fallback); return }
            guard Self.valid(work.boundary), intent.candidates.count <= 1000 else { self.finish(work, .fallback); return }
            self.discover(work.boundary.baseUrl, work.boundary.user) { capability in
                self.queue.async {
                    guard self.current(work) else { return }
                    guard capability.clearThrough else { self.finish(work, .fallback); return }
                    // A cursor advanced by the NSE can skip an older, dropped push. Fetch the
                    // full cached order and store it before allowing a topic-wide clear.
                    self.poll(work, selectingBoundary: true)
                }
            }
        }
    }

    /// A later normal poll can settle a lost response without replaying individual clears.
    func reconcile(baseUrl: String, topic: String, messages: [Message]) {
        queue.async {
            self.prune()
            guard let work = self.pending["\(baseUrl)/\(topic)"], self.isCleared(work, messages: messages) else { return }
            self.finish(work, .sent)
        }
    }

    static func valid(_ boundary: ClearRequest) -> Bool {
        boundary.sequence.range(of: "^[-_A-Za-z0-9]{1,64}$", options: .regularExpression) != nil
            && boundary.messageId?.range(of: "^[A-Za-z0-9]{12}$", options: .regularExpression) != nil
    }

    func request(for boundary: ClearRequest) -> URLRequest? {
        guard Self.valid(boundary), let url = URL(string: "\(topicUrl(baseUrl: boundary.baseUrl, topic: boundary.topic))/\(boundary.sequence)/clear-through") else { return nil }
        var request = api.newRequest(url: url, baseUrl: boundary.baseUrl, user: boundary.user)
        request.httpMethod = "PUT"
        request.httpBody = Data()
        request.setValue(boundary.messageId, forHTTPHeaderField: "X-NtfyMe-Through-ID")
        return request
    }

    private func publish(_ work: Work) {
        guard current(work) else { return }
        guard let attempt = cooldown.claimAttempt(server: work.boundary.baseUrl,
            manual: work.retries == 0 && cooldown.hasNonTimeRefusal(server: work.boundary.baseUrl, kind: .clearThrough), kind: .clearThrough) else { deferWork(work); return }
        guard let request = request(for: work.boundary) else { finish(work, .fallback); return }
        work.published = true
        transport(request) { data, response, error in
            self.queue.async {
                guard self.current(work) else { return }
                let http = response as? HTTPURLResponse
                let status = error == nil ? http?.statusCode ?? 0 : 0
                switch status {
                case 200:
                    struct Receipt: Decodable { let cleared: Int; let through_id: String }
                    if let data, let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
                       receipt.through_id == work.boundary.messageId, (0...100).contains(receipt.cleared) {
                        self.cooldown.succeeded(server: work.boundary.baseUrl, attempt: attempt)
                        self.finish(work, .sent)
                    } else { self.poll(work) }
                case 404, 405:
                    self.invalidate(work.boundary.baseUrl); self.finish(work, .fallback)
                case 413:
                    self.oversized[work.key] = self.now() + Self.retention
                    self.finish(work, .fallback)
                case 409: self.poll(work, missingBoundary: true)
                case 429:
                    self.cooldown.limit(server: work.boundary.baseUrl, retryAfter: http?.value(forHTTPHeaderField: "Retry-After"),
                                        condition: http?.value(forHTTPHeaderField: "Retry-After-Condition"), kind: .clearThrough)
                    self.deferWork(work)
                case 401, 403: self.deferWork(work)
                case 400: self.deferWork(work)
                case 0, 500...599: self.poll(work)
                default: self.deferWork(work)
                }
            }
        }
    }

    private func poll(_ work: Work, selectingBoundary: Bool = false, missingBoundary: Bool = false) {
        guard current(work) else { return }
        guard cooldown.claim(server: work.boundary.baseUrl, manual: false, kind: .poll) else { deferWork(work); return }
        guard let url = URL(string: "\(topicUrl(baseUrl: work.boundary.baseUrl, topic: work.boundary.topic))/json?poll=1&since=all") else {
            deferWork(work); return
        }
        let request = api.newRequest(url: url, baseUrl: work.boundary.baseUrl, user: work.boundary.user)
        transport(request) { data, response, error in
            self.queue.async {
                guard self.current(work) else { return }
                let http = response as? HTTPURLResponse
                guard error == nil, http?.statusCode == 200, let data, data.count <= 4_000_000,
                      let messages = Self.messages(data) else {
                    if http?.statusCode == 429 {
                        self.cooldown.limit(server: work.boundary.baseUrl, retryAfter: http?.value(forHTTPHeaderField: "Retry-After"),
                                            condition: http?.value(forHTTPHeaderField: "Retry-After-Condition"), kind: .poll)
                    }
                    if selectingBoundary, error == nil, http?.statusCode == 200 { self.finish(work, .fallback) }
                    else { self.deferWork(work) }
                    return
                }
                guard work.storeMessages(messages) else { self.deferWork(work); return }
                if self.isCleared(work, messages: messages) { self.finish(work, .sent); return }
                if selectingBoundary {
                    let candidates = Dictionary(work.intent.candidates.compactMap { request in request.messageId.map { ($0, request) } }, uniquingKeysWith: { _, newest in newest })
                    guard let newest = messages.last(where: { $0.event == "message" && candidates[$0.id] != nil }),
                          let boundary = candidates[newest.id], boundary.sequence == newest.sequence else {
                        self.finish(work, .fallback); return
                    }
                    work.boundary = boundary
                    guard self.onlyReadMessagesThroughBoundary(work, messages: messages) else {
                        self.finish(work, .fallback); return
                    }
                    self.publish(work)
                } else if !self.onlyReadMessagesThroughBoundary(work, messages: messages) {
                    // An uncertain transaction may already have committed. Do not fan out.
                    self.deferWork(work)
                } else if work.retries < 2 {
                    work.retries += 1
                    self.schedule(TimeInterval(work.retries)) { self.queue.async { self.publish(work) } }
                } else if missingBoundary { self.finish(work, .fallback) }
                else { self.deferWork(work) }
            }
        }
    }

    private static func messages(_ data: Data) -> [Message]? {
        do { return try data.split(separator: 10).map { try JSONDecoder().decode(Message.self, from: Data($0)) } }
        catch { return nil }
    }

    private func isCleared(_ work: Work, messages: [Message]) -> Bool {
        var latest: [String: Message] = [:]
        for message in messages where message.topic == work.boundary.topic { latest[message.sequence] = message }
        // Absence is not proof of a committed transaction (cache eviction or expiry looks the same).
        return !work.intent.known.isEmpty && work.intent.known.allSatisfy { latest[$0.sequence]?.isControl == true }
    }

    /// A newly fetched message stays unread, even when its server timestamp precedes the
    /// boundary. Only versions in the local read snapshot may be cleared by this transaction.
    private func onlyReadMessagesThroughBoundary(_ work: Work, messages: [Message]) -> Bool {
        let topicMessages = messages.filter { $0.topic == work.boundary.topic }
        guard let boundaryIndex = topicMessages.lastIndex(where: { $0.id == work.boundary.messageId && $0.sequence == work.boundary.sequence }) else { return false }
        var latest: [String: Int] = [:]
        for (index, message) in topicMessages.enumerated() { latest[message.sequence] = index }
        let known = Dictionary(work.intent.known.compactMap { request in request.messageId.map { (request.sequence, $0) } }, uniquingKeysWith: { _, newest in newest })
        return latest.values.allSatisfy { index in
            let message = topicMessages[index]
            return index > boundaryIndex || message.event != "message" || known[message.sequence] == message.id
        }
    }

    private func current(_ work: Work) -> Bool {
        pending[work.key] === work && now() - work.created <= Self.retention
    }
    private func prune() {
        oversized = oversized.filter { $0.value > now() }
        if oversized.count > Self.maxPending, let oldest = oversized.min(by: { $0.value < $1.value })?.key { oversized.removeValue(forKey: oldest) }
        let stale = pending.filter { now() - $0.value.created > Self.retention }
        stale.forEach { pending.removeValue(forKey: $0.key); reportDeferred($0.value) }
    }
    private func finish(_ work: Work, _ result: ClearThroughResult) {
        pending.removeValue(forKey: work.key)
        let callback = work.completion; work.completion = nil
        callback?(result)
    }
    private func deferWork(_ work: Work) {
        // Keep the eventual success callback: a later ordinary poll may prove the transaction
        // committed, and self-hosted devices still need their one upstream wake after that proof.
        reportDeferred(work)
    }
    private func reportDeferred(_ work: Work) {
        guard !work.reportedDeferred else { return }
        work.reportedDeferred = true
        work.completion?(.deferred)
    }
}
