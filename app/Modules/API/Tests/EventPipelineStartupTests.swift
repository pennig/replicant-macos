//
//  EventPipelineStartupTests.swift
//  Replicould — API tests
//
//  Regression tests for the pipeline's startup contract (V3.3-S1/S2): a stale
//  cursor runs the catch-up pull to the tip *before* the SSE connection opens,
//  so the gap is emitted as `.catchUp` and the stream connects from the
//  advanced cursor — and cursor persistence is monotonic, so interleaved saves
//  can never regress the stored resume point.
//

import Foundation
import Testing
@testable import API

// MARK: - Doubles

/// Thread-safe in-memory `EventCursorStore`.
private final class MemoryCursorStore: EventCursorStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ initial: String? = nil) { self.value = initial }

    func load() -> String? { lock.withLock { value } }
    func save(_ cursor: String) { lock.withLock { value = cursor } }
    func clear() { lock.withLock { value = nil } }
}

/// Records the cursor each connect was asked to resume from, then replays a
/// canned list of frames and stays open (like a real SSE connection).
private final class RecordingStreamClient: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var connectCursors: [String?] = []
    private let frames: [StreamedEvent]

    init(frames: [StreamedEvent]) { self.frames = frames }

    var client: EventStreamClient {
        EventStreamClient { cursor in
            self.lock.withLock { self.connectCursors.append(cursor) }
            let frames = self.frames
            return AsyncThrowingStream { continuation in
                for frame in frames { continuation.yield(frame) }
                // Leave the stream open, as a live connection would.
            }
        }
    }
}

private func frame(id: String, event: String, deviceCode: String = "D1") -> StreamedEvent {
    StreamedEvent(
        id: id,
        eventName: event,
        raw: Data(#"{"device_code":"\#(deviceCode)"}"#.utf8)
    )
}

private func pulled(id: String, event: String) -> GameEventEnvelope {
    GameEventEnvelope(id: id, category: String(event.split(separator: ".").first ?? ""), event: event, provenance: .catchUp)
}

// MARK: - Startup sequencing

@Suite struct EventPipelineStartupTests {

    /// Stale cursor: the pull drains to the tip first (events emitted as
    /// `.catchUp`), and only then does the stream connect — from the *advanced*
    /// cursor, so the server cannot replay the gap as `.stream`.
    @Test func staleCursorCatchesUpBeforeConnecting() async throws {
        let store = MemoryCursorStore("100-0")  // epoch-ancient → stale
        let streamClient = RecordingStreamClient(frames: [
            frame(id: "102-0", event: "travel.arrived"),  // server overlap replay → deduped
            frame(id: "103-0", event: "mining.started"),
        ])
        let pages = CannedPages([
            "100-0": GameEventsPage(
                events: [pulled(id: "101-0", event: "travel.departed"), pulled(id: "102-0", event: "travel.arrived")],
                nextCursor: "102-0"
            ),
            "102-0": GameEventsPage(events: [], nextCursor: nil),
        ])
        let pipeline = EventPipeline(
            streamClient: streamClient.client,
            fetchPage: { cursor in pages.page(for: cursor) },
            cursorStore: store
        )

        let stream = await pipeline.start(catchUpIfOlderThan: 15 * 60)

        var received: [(id: String, provenance: GameEventEnvelope.Provenance)] = []
        for await event in stream {
            received.append((event.id, event.provenance))
            if received.count == 3 { break }
        }
        await pipeline.stop()

        // The gap arrived first, as .catchUp; the live frame after, as .stream;
        // the overlap frame (102-0) was deduped, not double-dispatched.
        #expect(received.map(\.id) == ["101-0", "102-0", "103-0"])
        #expect(received.map(\.provenance) == [.catchUp, .catchUp, .stream])
        // The SSE connection opened once, from the post-catch-up cursor.
        #expect(streamClient.connectCursors == ["102-0"])
        #expect(store.load() == "103-0")
    }

    /// Fresh cursor: no pull at all — the stream's own replay-from-cursor covers
    /// recent history, and `.stream` provenance is then genuinely live.
    @Test func freshCursorSkipsCatchUp() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let freshMS = UInt64(now.timeIntervalSince1970 * 1000) - 60_000  // 1 min old
        let freshID = "\(freshMS)-0"
        let store = MemoryCursorStore(freshID)
        // A sentinel frame lets the test consume one event before asserting, so
        // the connect is provably complete rather than racing the stream task.
        let sentinelID = "\(freshMS + 1)-0"
        let streamClient = RecordingStreamClient(frames: [
            frame(id: sentinelID, event: "mining.started")
        ])
        let pipeline = EventPipeline(
            streamClient: streamClient.client,
            fetchPage: { _ in
                Issue.record("catch-up must not run on a fresh cursor")
                return GameEventsPage(events: [], nextCursor: nil)
            },
            cursorStore: store
        )

        let stream = await pipeline.start(catchUpIfOlderThan: 15 * 60, now: now)
        for await event in stream {
            #expect(event.id == sentinelID)
            #expect(event.provenance == .stream)
            break
        }
        await pipeline.stop()

        #expect(streamClient.connectCursors == [freshID])
        #expect(store.load() == sentinelID)
    }

    /// `stop()` while the catch-up walk is suspended mid-page must not be
    /// followed by a zombie SSE connection from the superseded `start()`, and
    /// `resumeStream()` on a stopped pipeline is a no-op.
    @Test func stopDuringCatchUpDoesNotResurrectConnection() async throws {
        let store = MemoryCursorStore("100-0")  // stale → catch-up runs
        let streamClient = RecordingStreamClient(frames: [])
        let gate = Gate()
        let pipeline = EventPipeline(
            streamClient: streamClient.client,
            fetchPage: { _ in
                await gate.wait()
                return GameEventsPage(events: [], nextCursor: nil)
            },
            cursorStore: store
        )

        let startTask = Task { await pipeline.start(catchUpIfOlderThan: 15 * 60) }
        await gate.entered()          // fetchPage is suspended mid-walk
        await pipeline.stop()
        await gate.release()          // let the walk finish

        let stream = await startTask.value
        var received = false
        for await _ in stream { received = true }  // finished by stop()
        #expect(!received)
        #expect(streamClient.connectCursors.isEmpty, "the superseded start must not connect")

        await pipeline.resumeStream()
        #expect(streamClient.connectCursors.isEmpty, "resumeStream after stop is a no-op")
    }
}

/// Canned catch-up pages keyed by request cursor.
private struct CannedPages: Sendable {
    let pages: [String: GameEventsPage]
    init(_ pages: [String: GameEventsPage]) { self.pages = pages }
    func page(for cursor: String?) -> GameEventsPage {
        pages[cursor ?? ""] ?? GameEventsPage(events: [], nextCursor: nil)
    }
}

/// One-shot rendezvous: the test awaits `entered()` to know the closure is
/// suspended in `wait()`, then `release()` resumes it.
private actor Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var hasEntered = false

    func wait() async {
        hasEntered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        await withCheckedContinuation { waiter = $0 }
    }

    func entered() async {
        if hasEntered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }
}

// MARK: - Monotonic cursor ordering

@Suite struct CursorOrderingTests {

    @Test func redisIDOrdering() {
        // Strictly newer ms, or same ms with newer seq, advances.
        #expect(EventPipeline.isOrderedAfter("101-0", "100-5"))
        #expect(EventPipeline.isOrderedAfter("100-6", "100-5"))
        // Equal or older never advances (idempotent re-saves are no-ops).
        #expect(!EventPipeline.isOrderedAfter("100-5", "100-5"))
        #expect(!EventPipeline.isOrderedAfter("100-4", "100-5"))
        #expect(!EventPipeline.isOrderedAfter("99-9", "100-0"))
        // Numeric, not lexicographic: 9 < 10 even though "9" > "10".
        #expect(EventPipeline.isOrderedAfter("10-0", "9-0"))
        // A bare ms id compares as seq 0.
        #expect(EventPipeline.isOrderedAfter("100-1", "100"))
        #expect(!EventPipeline.isOrderedAfter("100", "100-1"))
        // Nil/corrupt stored values are always superseded by a parseable id…
        #expect(EventPipeline.isOrderedAfter("100-0", nil))
        #expect(EventPipeline.isOrderedAfter("100-0", "garbage"))
        // …but garbage never overwrites a parseable stored value.
        #expect(!EventPipeline.isOrderedAfter("garbage", "100-0"))
    }

    /// A catch-up page save that lands *after* a live frame already advanced the
    /// cursor must not regress the store (the S2 interleave, exercised through
    /// the public surface: the stream replays an id older than the tip).
    @Test func staleSaveDoesNotRegressCursor() async throws {
        let store = MemoryCursorStore("100-0")
        let streamClient = RecordingStreamClient(frames: [
            frame(id: "300-0", event: "mining.started"),
            frame(id: "200-0", event: "mining.stopped"),  // out-of-order replay
        ])
        let pipeline = EventPipeline(
            streamClient: streamClient.client,
            fetchPage: { _ in GameEventsPage(events: [], nextCursor: nil) },
            cursorStore: store
        )

        let stream = await pipeline.start(catchUpIfOlderThan: 15 * 60)
        var count = 0
        for await _ in stream {
            count += 1
            if count == 2 { break }
        }
        await pipeline.stop()

        #expect(store.load() == "300-0", "the older frame's save must not regress the tip")
    }
}
