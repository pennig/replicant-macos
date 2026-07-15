import Foundation

/// Persists the relay cursor across app launches.
public protocol RelayCursorStore: Sendable {
    func load() -> String?
    func save(_ cursor: String)
}

public struct UserDefaultsCursorStore: RelayCursorStore {
    private let key: String
    // `UserDefaults` is thread-safe but not marked `Sendable`; the access here is safe.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(key: String = "replicant.relay.cursor", defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    public func load() -> String? { defaults.string(forKey: key) }
    public func save(_ cursor: String) { defaults.set(cursor, forKey: key) }
}

/// Persists the per-replicant game-log resume point (the last processed event
/// id) across launches, so tier-2 backfill pages *forward* from where it left
/// off instead of re-replaying the newest window every time.
public protocol GameLogCursorStore: Sendable {
    func load(replicantCode: String) -> Int?
    func save(_ cursor: Int, replicantCode: String)
}

public struct UserDefaultsGameLogCursorStore: GameLogCursorStore {
    private let prefix: String
    // `UserDefaults` is thread-safe but not marked `Sendable`; the access here is safe.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(prefix: String = "replicant.eventlog.cursor.", defaults: UserDefaults = .standard) {
        self.prefix = prefix
        self.defaults = defaults
    }

    // `object(forKey:) as? Int` (not `integer(forKey:)`) so an absent cursor
    // reads as nil rather than 0 — the seed path keys off exactly that nil.
    public func load(replicantCode: String) -> Int? {
        defaults.object(forKey: prefix + replicantCode) as? Int
    }
    public func save(_ cursor: Int, replicantCode: String) {
        defaults.set(cursor, forKey: prefix + replicantCode)
    }
}

/// The app's single source of game events.
///
/// Merges two channels into one deduplicated `AsyncStream<UnifiedEvent>`:
///
///   1. **Relay stream** (webhook → Redis log) — low latency, but webhooks
///      are at-most-once: a relay 500, a secret-rotation window, or a missed
///      delivery loses events permanently on that channel.
///   2. **Game event log** (`backfill`) — authoritative and re-readable,
///      but pull-only and rate-limited.
///
/// The webhook channel is treated as a fast *notification* path; the game
/// log is the source of truth for gap repair. Call `backfill` on app launch,
/// on wake, or after the relay stream errors, and anything the webhook
/// channel missed flows into the same stream the live events use — the app
/// has exactly one event-handling code path.
///
/// Dedup is fingerprint-based (see `UnifiedEvent.fingerprint`), with bounded
/// memory. Consumers should still treat events idempotently: a rare
/// duplicate is possible by design (it's the safe failure direction).
public actor EventPipeline {

    private let relay: RelayClient
    private let client: any APIProtocol
    private let cursorStore: RelayCursorStore
    private let gameLogCursorStore: GameLogCursorStore

    private var seen: BoundedFingerprintSet
    private var continuation: AsyncStream<UnifiedEvent>.Continuation?
    private var relayTask: Task<Void, Never>?

    /// - Parameters:
    ///   - relay: client for your Vercel relay.
    ///   - client: the generated game API client (from `ReplicantSpace.client`).
    ///     Backfill reads go through its middleware (auth, rate limiting,
    ///     logging), so it shares your app's rate-limit budget automatically.
    ///   - cursorStore: where the relay resume-point lives.
    ///   - gameLogCursorStore: where the per-replicant game-log resume point
    ///     (last processed event id) lives.
    ///   - dedupCapacity: how many recent fingerprints to remember. Should
    ///     comfortably exceed the largest backfill overlap (default: plenty).
    public init(
        relay: RelayClient,
        client: any APIProtocol,
        cursorStore: RelayCursorStore = UserDefaultsCursorStore(),
        gameLogCursorStore: GameLogCursorStore = UserDefaultsGameLogCursorStore(),
        dedupCapacity: Int = 4096
    ) {
        self.relay = relay
        self.client = client
        self.cursorStore = cursorStore
        self.gameLogCursorStore = gameLogCursorStore
        self.seen = BoundedFingerprintSet(capacity: dedupCapacity)
    }

    /// Begin consuming the relay and return the unified stream.
    /// Single-consumer: call once and fan out in the app if needed.
    ///
    /// If the relay polling loop throws (network down, relay misconfigured),
    /// `onRelayError` fires and relay consumption stops — the stream itself
    /// stays open so a subsequent `backfill` (and `resumeRelay`) can recover.
    public func start(
        onRelayError: (@Sendable (Error) -> Void)? = nil
    ) -> AsyncStream<UnifiedEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: UnifiedEvent.self)
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stop() }
        }
        resumeRelay(onRelayError: onRelayError)
        return stream
    }

    /// (Re)start relay consumption from the persisted cursor. Safe to call
    /// after a relay error once connectivity is back.
    public func resumeRelay(onRelayError: (@Sendable (Error) -> Void)? = nil) {
        relayTask?.cancel()
        relayTask = Task {
            do {
                for try await relayEvent in relay.stream(from: cursorStore.load()) {
                    self.ingestRelay(relayEvent)
                }
            } catch {
                onRelayError?(error)
            }
        }
    }

    /// Reconcile a replicant against the authoritative game event log by paging
    /// *forward* from the persisted resume point, emitting anything the relay
    /// channel missed (in chronological order). Returns how many events were
    /// emitted — a nonzero return is your gap-detection signal.
    ///
    /// Two modes, keyed on whether a resume cursor exists for this replicant:
    ///
    ///   - **Seed** (no stored cursor — cold start / newly-seen replicant):
    ///     read only the newest tail (`latest: true`) to record a resume point,
    ///     and emit *nothing*. History before first launch isn't replayed — the
    ///     roster's current location already comes from `accounts/me`, so
    ///     replaying it would just flicker the UI through stale waypoints.
    ///   - **Catch-up** (stored cursor): page forward from it (each page's
    ///     `nextCursor` is the largest id seen, fed back as the next `cursor`)
    ///     until the log's tip, emitting each genuinely-new event once. A quiet
    ///     account returns nothing → no replay.
    ///
    /// The resume point advances to the newest id processed and is persisted, so
    /// the next launch continues from exactly here.
    ///
    /// - Parameters:
    ///   - replicantCode: the log is per-replicant; loop over your clones.
    ///   - maxEvents: safety cap on how many entries a single catch-up walk pulls
    ///     (bounds the read burst when a gap is enormous).
    @discardableResult
    public func backfill(replicantCode: String, maxEvents: Int = 2000) async throws -> Int {
        let stored = gameLogCursorStore.load(replicantCode: replicantCode)
        // Capture the client (Sendable) locally so the fetch closure doesn't
        // capture the actor — `collectForward` runs off-isolation.
        let client = self.client
        let walk = try await Self.collectForward(
            replicantCode: replicantCode,
            storedCursor: stored,
            maxEvents: maxEvents,
            fetchPage: { cursor, latest in
                try await client.eventLog(
                    replicantCode: replicantCode,
                    cursor: cursor,
                    latest: latest ? true : nil
                )
            }
        )
        if let newCursor = walk.newCursor {
            gameLogCursorStore.save(newCursor, replicantCode: replicantCode)
        }
        // Seed only records a resume point; it must not replay history.
        guard !walk.seededOnly else { return 0 }

        var emitted = 0
        for event in walk.events where seen.insert(event.id) {
            continuation?.yield(event)
            emitted += 1
        }
        return emitted
    }

    /// The outcome of a forward walk: the events to emit (oldest-first), the
    /// resume point to persist (largest id seen, or the prior cursor when the
    /// walk found nothing new), and whether this was a seed (record-only).
    struct ForwardWalk {
        let events: [UnifiedEvent]
        let newCursor: Int?
        let seededOnly: Bool
    }

    /// Pure forward-cursor walk — no actor state, no network, so it's unit
    /// testable with a canned `fetchPage`. `fetchPage(cursor, latest)` mirrors
    /// `APIProtocol.eventLog`.
    static func collectForward(
        replicantCode: String,
        storedCursor: Int?,
        maxEvents: Int,
        fetchPage: (_ cursor: Int?, _ latest: Bool) async throws -> EventLogPage
    ) async throws -> ForwardWalk {
        // Seed: no resume point yet — record the tip, replay nothing.
        guard let storedCursor else {
            let tip = try await fetchPage(nil, true)
            let tipID = tip.entries.compactMap(\.id).max()
            return ForwardWalk(events: [], newCursor: tipID, seededOnly: true)
        }

        // Catch-up: page forward until the tip (nil `nextCursor`), an empty
        // page, or the safety cap. Entries are oldest-first within a page and
        // pages advance toward newest, so concatenation stays chronological.
        var events: [UnifiedEvent] = []
        var maxID = storedCursor
        var cursor: Int? = storedCursor
        while events.count < maxEvents {
            let page = try await fetchPage(cursor, false)
            guard !page.entries.isEmpty else { break }
            for entry in page.entries {
                events.append(UnifiedEvent(gameLogEntry: entry, replicantCode: replicantCode))
            }
            if let pageMax = page.entries.compactMap(\.id).max() {
                maxID = max(maxID, pageMax)
            }
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        return ForwardWalk(events: events, newCursor: maxID, seededOnly: false)
    }

    /// Wall-clock time of the last relay event we persisted, decoded from the
    /// stored cursor (a Redis stream ID `<ms>-<seq>`). Nil on a cold start (no
    /// cursor) or an unparseable value. Lets the tier-2 backfill skip itself when
    /// the cursor is fresh — tier-1 replay from it already covers recent history,
    /// so the per-replicant log walk would be redundant reads.
    public func lastCursorDate() -> Date? {
        Self.cursorDate(cursorStore.load())
    }

    /// Parse a Redis stream ID's leading millisecond timestamp into a `Date`.
    /// Pure + static so it's unit-testable without the actor. Nil when absent or
    /// malformed.
    static func cursorDate(_ cursor: String?) -> Date? {
        guard
            let cursor,
            let msPart = cursor.split(separator: "-").first,
            let ms = Double(msPart)
        else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    public func stop() {
        relayTask?.cancel()
        relayTask = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Private

    private func ingestRelay(_ relayEvent: RelayEvent) {
        defer { cursorStore.save(relayEvent.id) }
        guard let event = try? UnifiedEvent(relayEvent: relayEvent) else {
            // Undecodable payload: advance the cursor and move on rather
            // than wedging the stream on one malformed entry.
            return
        }
        if seen.insert(event.id) {
            continuation?.yield(event)
        }
    }
}

/// A set with FIFO eviction: remembers the most recent `capacity`
/// fingerprints in O(1) per insert.
struct BoundedFingerprintSet {
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
