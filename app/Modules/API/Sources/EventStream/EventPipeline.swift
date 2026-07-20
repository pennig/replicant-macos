//
//  EventPipeline.swift
//  Replicould — API (event stream)
//
//  The app's single source of game events, now a *single channel* over the
//  native SSE stream (`GET /v1/events/stream`) with the account-wide pull
//  (`GET /v1/events`) as catch-up. Both speak one envelope and one string
//  cursor, so dedup is a plain "have I seen this stream id?" — no fingerprinting.
//
//  Startup keeps the old two-tier behaviour without its complexity:
//    • Catch-up (stale/large gap): page the pull forward from the stored cursor
//      to the tip, emitting `.catchUp` events (which never move the roster), and
//      advance the cursor. Then open the stream from the tip → little/no replay.
//    • Warm (fresh cursor): skip the pull; open the stream from the cursor. The
//      server's short replay-from-cursor is genuinely recent, so `.stream` is
//      correct.
//    • Cold (no cursor): open the stream with no cursor → live from now. History
//      isn't replayed (the roster comes from `accounts/me`, devices from the
//      cold-load walk, and open ops from the DeadlineScheduler).
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "name.pennig.replicould.events", category: "pipeline")

public actor EventPipeline {

    private let streamClient: EventStreamClient
    private let client: any APIProtocol
    private let cursorStore: EventCursorStore

    private var seen: BoundedEventIDSet
    private var continuation: AsyncStream<GameEventEnvelope>.Continuation?
    private var streamTask: Task<Void, Never>?

    /// - Parameters:
    ///   - streamClient: the live SSE client.
    ///   - client: the generated game API client (for the catch-up pull); its
    ///     middleware shares the app's rate-limit budget.
    ///   - cursorStore: where the resume cursor lives.
    ///   - dedupCapacity: how many recent stream ids to remember — needs only to
    ///     cover the catch-up↔stream overlap window.
    public init(
        streamClient: EventStreamClient,
        client: any APIProtocol,
        cursorStore: EventCursorStore = UserDefaultsEventCursorStore(),
        dedupCapacity: Int = 4096
    ) {
        self.streamClient = streamClient
        self.client = client
        self.cursorStore = cursorStore
        self.seen = BoundedEventIDSet(capacity: dedupCapacity)
    }

    /// Begin consuming the stream and return the unified event stream.
    /// Single-consumer: call once and fan out in the app if needed.
    public func start(
        onStreamError: (@Sendable (Error) -> Void)? = nil
    ) -> AsyncStream<GameEventEnvelope> {
        let (stream, continuation) = AsyncStream.makeStream(of: GameEventEnvelope.self)
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stop() }
        }
        resumeStream(onStreamError: onStreamError)
        return stream
    }

    /// (Re)start SSE consumption from the persisted cursor. Safe to call after a
    /// stream error once connectivity is back.
    public func resumeStream(onStreamError: (@Sendable (Error) -> Void)? = nil) {
        streamTask?.cancel()
        streamTask = Task {
            do {
                for try await streamed in streamClient.stream(cursorStore.load()) {
                    self.ingestStreamed(streamed)
                }
            } catch {
                onStreamError?(error)
            }
        }
    }

    /// Reconcile against the authoritative account-wide log by paging *forward*
    /// from the persisted cursor, emitting anything missed while disconnected as
    /// `.catchUp`. Returns how many new events were emitted.
    ///
    /// On a cold start (no stored cursor) this is a no-op: history isn't replayed
    /// (the stream will seed the cursor from the live tip). The cursor advances to
    /// the newest id processed and is persisted, so the stream then opens from the
    /// tip with little/no replay.
    ///
    /// - Parameter maxEvents: safety cap on a single catch-up walk (bounds the
    ///   read burst when a gap is enormous).
    @discardableResult
    public func catchUp(maxEvents: Int = 2000) async throws -> Int {
        guard let stored = cursorStore.load() else { return 0 }
        let client = self.client
        var emitted = 0
        var pulled = 0
        var cursor: String? = stored
        while pulled < maxEvents {
            let page = try await client.gameEvents(cursor: cursor, filtered: true)
            guard !page.events.isEmpty else { break }
            for event in page.events {
                pulled += 1
                if seen.insert(event.id) {
                    continuation?.yield(event)
                    emitted += 1
                }
                cursorStore.save(event.id)
            }
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        return emitted
    }

    /// Wall-clock time of the last event we persisted, decoded from the stored
    /// cursor (a Redis stream ID `<ms>-<seq>`). Nil on a cold start or an
    /// unparseable value. Lets the caller skip catch-up when the cursor is fresh —
    /// the stream's replay-from-cursor already covers recent history.
    public func lastCursorDate() -> Date? {
        Self.cursorDate(cursorStore.load())
    }

    /// Parse a Redis stream ID's leading millisecond timestamp into a `Date`.
    /// Pure + static so it's unit-testable. Nil when absent or malformed.
    static func cursorDate(_ cursor: String?) -> Date? {
        guard
            let cursor,
            let msPart = cursor.split(separator: "-").first,
            let ms = Double(msPart)
        else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    public func stop() {
        streamTask?.cancel()
        streamTask = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Private

    private func ingestStreamed(_ streamed: StreamedEvent) {
        defer { cursorStore.save(streamed.id) }
        guard let event = GameEventEnvelope(streamed: streamed) else {
            // Undecodable body: advance the cursor and move on rather than
            // wedging the stream on one malformed entry.
            logger.error("⚠️ undecodable stream event id=\(streamed.id, privacy: .public) event=\(streamed.eventName, privacy: .public)")
            return
        }
        if seen.insert(event.id) {
            continuation?.yield(event)
        }
    }
}

/// A set with FIFO eviction: remembers the most recent `capacity` stream ids in
/// O(1) per insert. Bounds dedup memory to the catch-up↔stream overlap window.
struct BoundedEventIDSet {
    private var members: Set<String>
    private var order: [String?]
    private var writeIndex = 0
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.members = Set(minimumCapacity: self.capacity)
        self.order = Array(repeating: nil, count: self.capacity)
    }

    /// Returns true if the value was newly inserted (i.e. not a duplicate).
    @discardableResult
    mutating func insert(_ value: String) -> Bool {
        guard !members.contains(value) else { return false }
        if let evicted = order[writeIndex] {
            members.remove(evicted)
        }
        order[writeIndex] = value
        members.insert(value)
        writeIndex = (writeIndex + 1) % capacity
        return true
    }
}
