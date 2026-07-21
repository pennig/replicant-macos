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

private let logger = Logger(subsystem: "name.pennig.replicould", category: "EventStream")

public actor EventPipeline {

    private let streamClient: EventStreamClient
    private let fetchPage: @Sendable (_ cursor: String?) async throws -> GameEventsPage
    private let cursorStore: EventCursorStore

    private var seen: BoundedEventIDSet
    private var continuation: AsyncStream<GameEventEnvelope>.Continuation?
    private var streamTask: Task<Void, Never>?
    /// In-memory shadow of the newest *persisted* cursor, so saves stay monotonic
    /// even when catch-up pages and live frames interleave (see `persistCursor`).
    private var highWaterCursor: String?
    /// Bumped by every `start()`/`stop()`. A `start()` still awaiting its
    /// catch-up walk compares its entry generation before connecting, so a
    /// stop() (or a newer start()) during the walk can't be followed by a
    /// zombie connection from the superseded call.
    private var generation = 0

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
        self.init(
            streamClient: streamClient,
            fetchPage: { cursor in try await client.gameEvents(cursor: cursor, filtered: true) },
            cursorStore: cursorStore,
            dedupCapacity: dedupCapacity
        )
    }

    /// Testing seam: inject canned catch-up pages without conforming a full
    /// `APIProtocol` double (used by API and GameSync tests; production code
    /// uses the `client:` initializer above).
    public init(
        streamClient: EventStreamClient,
        fetchPage: @escaping @Sendable (_ cursor: String?) async throws -> GameEventsPage,
        cursorStore: EventCursorStore = UserDefaultsEventCursorStore(),
        dedupCapacity: Int = 4096
    ) {
        self.streamClient = streamClient
        self.fetchPage = fetchPage
        self.cursorStore = cursorStore
        self.seen = BoundedEventIDSet(capacity: dedupCapacity)
    }

    /// Begin consuming events and return the unified event stream.
    /// Single-consumer: call once and fan out in the app if needed.
    ///
    /// Startup is **sequential**, upholding the header's contract: when
    /// `catchUpIfOlderThan` is given and the persisted cursor is stale (or
    /// absent/unparseable), the catch-up pull runs to the tip *first* — emitting
    /// the gap as `.catchUp` — and only then does the SSE connection open, from
    /// the advanced cursor. Connecting first would make the server replay the
    /// whole gap over SSE tagged `.stream`, defeating every consumer that gates
    /// on provenance (e.g. the roster advance). A fresh cursor skips the pull:
    /// the stream's short replay-from-cursor is genuinely recent, so `.stream`
    /// is correct — and a needless walk would spend reads on every relaunch,
    /// whereas dedup absorbs the small overlap either way (we err toward walking).
    ///
    /// - Parameters:
    ///   - catchUpIfOlderThan: staleness window for the pre-connect catch-up
    ///     pull; nil skips the pull entirely (the caller owns catch-up).
    ///   - now: injectable clock for the staleness check.
    ///   - onStreamError: invoked when the SSE stream fails permanently (auth);
    ///     transient errors are retried inside the stream client.
    public func start(
        catchUpIfOlderThan freshWindow: TimeInterval? = nil,
        now: Date = Date(),
        onStreamError: (@Sendable (Error) -> Void)? = nil
    ) async -> AsyncStream<GameEventEnvelope> {
        let (stream, continuation) = AsyncStream.makeStream(of: GameEventEnvelope.self)
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stop() }
        }
        generation += 1
        let epoch = generation
        if let freshWindow {
            if let last = lastCursorDate(), now.timeIntervalSince(last) < freshWindow {
                logger.info("catch-up skipped — cursor fresh (\(Int(now.timeIntervalSince(last)))s old); stream replay covers it")
            } else {
                await runCatchUpLoudly()
            }
        }
        // A stop() — or a newer start() — while catch-up was walking must not be
        // followed by this call's connection; the generation stamp catches both
        // (a mere continuation-nil check would pass against a *successor's*
        // continuation).
        guard !Task.isCancelled, epoch == generation else { return stream }
        resumeStream(onStreamError: onStreamError)
        return stream
    }

    /// Run the startup catch-up, distinguishing "the gap was empty" from "the
    /// pull failed" — a swallowed failure would connect the stream from the
    /// stale cursor and let the server replay the gap as `.stream`, the exact
    /// S1 defect. Retries with backoff cover the wake-before-Wi-Fi case
    /// (blocking startup is fine — a connect would fail identically); after
    /// the attempts are spent, startup proceeds with a loud error, and the
    /// stream client's seeded stale-gap clock bounds the damage: within one
    /// staleness window it hands off and this repair runs again.
    private func runCatchUpLoudly() async {
        var delay: Duration = .seconds(2)
        for attempt in 1...5 {
            do {
                let recovered = try await catchUp()
                logger.info("catch-up: recovered \(recovered) event(s)")
                return
            } catch {
                guard !Task.isCancelled else { return }
                if attempt < 5 {
                    logger.notice("catch-up attempt \(attempt) failed (\(error)); retrying")
                    try? await Task.sleep(for: delay)
                    delay = min(delay * 2, .seconds(60))
                } else {
                    logger.error("⚠️ catch-up failed after \(attempt) attempts (\(error)) — connecting from the stale cursor; the stale-gap handoff will retry the repair within one staleness window")
                }
            }
        }
    }

    /// (Re)start SSE consumption from the persisted cursor. Safe to call after a
    /// stream error once connectivity is back; a no-op once the pipeline has
    /// been stopped (its stream is finished — a fresh `start()` is required).
    public func resumeStream(onStreamError: (@Sendable (Error) -> Void)? = nil) {
        guard continuation != nil else { return }
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
        var emitted = 0
        var pulled = 0
        var cursor: String? = stored
        while pulled < maxEvents {
            let page = try await fetchPage(cursor)
            guard !page.events.isEmpty else { break }
            for event in page.events {
                pulled += 1
                if seen.insert(event.id) {
                    continuation?.yield(event)
                    emitted += 1
                }
                persistCursor(event.id)
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
        generation += 1
        streamTask?.cancel()
        streamTask = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Private

    private func ingestStreamed(_ streamed: StreamedEvent) {
        defer { persistCursor(streamed.id) }
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

    /// Persist a cursor only when it advances past the newest one already saved.
    /// Blind last-write-wins would let a catch-up page save an *older* id after
    /// a live frame saved the tip (the two interleave at await points) — a quit
    /// in that window replays the gap on next launch against a fresh dedup set.
    private func persistCursor(_ id: String) {
        let current = highWaterCursor ?? cursorStore.load()
        guard Self.isOrderedAfter(id, current) else {
            // Loud when the *incoming* id doesn't parse: if the server's id
            // format ever drifts, silently dropping every save would freeze the
            // cursor forever (each launch re-walking from the frozen point).
            if Self.parseStreamID(id) == nil {
                logger.error("⚠️ unparseable stream id \(id, privacy: .public) — cursor not advanced")
            }
            if highWaterCursor == nil { highWaterCursor = current }
            return
        }
        highWaterCursor = id
        cursorStore.save(id)
    }

    /// Redis stream-ID ordering: compare `<ms>-<seq>` numerically. A nil/corrupt
    /// stored value is always superseded by a parseable candidate; an unparseable
    /// candidate never overwrites a parseable stored value (never regress the
    /// cursor onto garbage).
    static func isOrderedAfter(_ candidate: String, _ current: String?) -> Bool {
        guard let currentParts = parseStreamID(current) else { return true }
        guard let candidateParts = parseStreamID(candidate) else { return false }
        return candidateParts > currentParts
    }

    /// Parse `<ms>` or `<ms>-<seq>` into a comparable pair; nil when malformed.
    private static func parseStreamID(_ id: String?) -> (UInt64, UInt64)? {
        guard let id else { return nil }
        let parts = id.split(separator: "-", maxSplits: 1)
        guard let first = parts.first, let ms = UInt64(first) else { return nil }
        let seq = parts.count > 1 ? UInt64(parts[1]) : 0
        guard let seq else { return nil }
        return (ms, seq)
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
