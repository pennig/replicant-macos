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

    private var seen: BoundedFingerprintSet
    private var continuation: AsyncStream<UnifiedEvent>.Continuation?
    private var relayTask: Task<Void, Never>?

    /// - Parameters:
    ///   - relay: client for your Vercel relay.
    ///   - client: the generated game API client (from `ReplicantSpace.client`).
    ///     Backfill reads go through its middleware (auth, rate limiting,
    ///     logging), so it shares your app's rate-limit budget automatically.
    ///   - cursorStore: where the relay resume-point lives.
    ///   - dedupCapacity: how many recent fingerprints to remember. Should
    ///     comfortably exceed the largest backfill overlap (default: plenty).
    public init(
        relay: RelayClient,
        client: any APIProtocol,
        cursorStore: RelayCursorStore = UserDefaultsCursorStore(),
        dedupCapacity: Int = 4096
    ) {
        self.relay = relay
        self.client = client
        self.cursorStore = cursorStore
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

    /// Reconcile against the game's event log: fetch recent entries for the
    /// replicant, emit anything the relay channel missed (in chronological
    /// order), and return how many missed events were recovered — a nonzero
    /// return is your gap-detection signal.
    ///
    /// - Parameters:
    ///   - replicantCode: the log is per-replicant; loop over your clones.
    ///   - since: only consider entries after this instant (a 60s overlap
    ///     is applied — dedup absorbs it). Pass nil to take whatever the
    ///     fetched window covers.
    ///   - maxFetch: upper bound on how many entries to pull when `since` is
    ///     older than the first page (paging stops once this cap is hit).
    ///   - pageSize: entries per request while paging back through the log.
    @discardableResult
    public func backfill(
        replicantCode: String,
        since: Date?,
        maxFetch: Int = 1000,
        pageSize: Int = 100
    ) async throws -> Int {
        let cutoff = since?.addingTimeInterval(-60)

        // Page newest-first (`latest` on the first request, then follow
        // `nextCursor`) until we reach past `cutoff`, hit `maxFetch`, or
        // reach the log's beginning.
        var entries: [GameLogEntry] = []
        var cursor: Int?
        var isFirstPage = true
        while entries.count < maxFetch {
            let page = try await client.eventLog(
                replicantCode: replicantCode,
                cursor: cursor,
                limit: min(pageSize, maxFetch - entries.count),
                latest: isFirstPage ? true : nil
            )
            isFirstPage = false
            guard !page.entries.isEmpty else { break }
            entries.append(contentsOf: page.entries)

            guard let cutoff else { break }  // nil `since`: just the newest page
            let oldest = page.entries
                .compactMap { UnifiedEvent.parseTimestamp($0.createdAt) }
                .min()
            if let oldest, oldest <= cutoff { break }
            guard let next = page.nextCursor else { break }
            cursor = next
        }

        var recovered = entries
            .map { UnifiedEvent(gameLogEntry: $0, replicantCode: replicantCode) }
            .filter { event in
                guard let cutoff else { return true }
                guard let date = event.date else { return true }  // unparseable: keep, dedup decides
                return date >= cutoff
            }

        // Oldest first, so consumers see backfilled history in order.
        recovered.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }

        var emitted = 0
        for event in recovered where seen.insert(event.id) {
            continuation?.yield(event)
            emitted += 1
        }
        return emitted
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
