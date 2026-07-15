import XCTest
import Utils
@testable import API

final class PipelineTests: XCTestCase {

    // The core dedup invariant: the same logical event arriving via webhook
    // and via the game log must produce the same fingerprint.
    func testCrossChannelFingerprintsMatch() throws {
        let webhookJSON = """
        {
          "type": "event",
          "event_type": "device_cruise_arrived",
          "device_code": "F54FA154",
          "device_type": "heaven_vessel",
          "replicant_code": "57F0F6C8",
          "payload": {"location": "SOL-5-L5", "from_location": "PORRAMA-KUIPER"},
          "timestamp": "2026-05-10T08:55:27+01:00"
        }
        """
        let relayEvent = RelayEvent(id: "1779087998123-0", raw: Data(webhookJSON.utf8))
        let fromRelay = try UnifiedEvent(relayEvent: relayEvent)

        // Same event from the log: has `message`, lacks `replicant_code`,
        // keys in a different order, same instant rendered in UTC.
        let logJSON = """
        {
          "created_at": "2026-05-10T07:55:27Z",
          "device_code": "F54FA154",
          "device_type": "heaven_vessel",
          "event_type": "device_cruise_arrived",
          "message": "heaven_vessel F54FA154 arrived at SOL-5-L5",
          "payload": {"from_location": "PORRAMA-KUIPER", "location": "SOL-5-L5"}
        }
        """
        let entry = try JSONDecoder().decode(GameLogEntry.self, from: Data(logJSON.utf8))
        let fromLog = UnifiedEvent(gameLogEntry: entry, replicantCode: "57F0F6C8")

        XCTAssertEqual(fromRelay.id, fromLog.id, "channels must agree on identity")
        XCTAssertNil(fromRelay.message)
        XCTAssertNotNil(fromLog.message)
    }

    func testDistinctEventsGetDistinctFingerprints() throws {
        func event(timestamp: String, location: String) -> String {
            UnifiedEvent.fingerprint(
                type: "event",
                eventType: "device_cruise_arrived",
                deviceCode: "F54FA154",
                timestamp: timestamp,
                payload: ["location": .string(location)],
                fallbackRaw: nil
            )
        }
        let base = event(timestamp: "2026-05-10T08:55:27+01:00", location: "SOL-5-L5")
        XCTAssertNotEqual(base, event(timestamp: "2026-05-10T08:55:28+01:00", location: "SOL-5-L5"))
        XCTAssertNotEqual(base, event(timestamp: "2026-05-10T08:55:27+01:00", location: "SOL-5-L4"))
    }

    func testCanonicalJSONIsOrderIndependent() {
        let a = JSONValue.object(["b": .number(2), "a": .string("x"), "c": .bool(true)])
        let b = JSONValue.object(["c": .bool(true), "a": .string("x"), "b": .number(2)])
        XCTAssertEqual(a.canonicalString, b.canonicalString)
        XCTAssertEqual(a.canonicalString, #"{"a":"x","b":2,"c":true}"#)
    }

    func testCanonicalJSONNestedAndIntegral() {
        let value = JSONValue.object([
            "n": .number(5.0),
            "arr": .array([.null, .number(1.5)]),
            "inner": .object(["z": .string("q\"uote")]),
        ])
        XCTAssertEqual(
            value.canonicalString,
            #"{"arr":[null,1.5],"inner":{"z":"q\"uote"},"n":5}"#
        )
    }

    func testBoundedSetEvictsOldest() {
        var set = BoundedFingerprintSet(capacity: 2)
        XCTAssertTrue(set.insert("a"))
        XCTAssertTrue(set.insert("b"))
        XCTAssertFalse(set.insert("a"), "still remembered")
        XCTAssertTrue(set.insert("c"), "evicts a")
        XCTAssertTrue(set.insert("a"), "a was evicted, re-insertable")
        XCTAssertFalse(set.insert("c"))
    }

    // A Redis stream ID's leading component is a millisecond timestamp; the
    // pipeline decodes it to gate tier-2 backfill (skip when the cursor is fresh).
    func testCursorDateParsesRedisStreamID() {
        XCTAssertEqual(
            EventPipeline.cursorDate("1779087998123-0")?.timeIntervalSince1970 ?? 0,
            1779087998.123,
            accuracy: 0.0005
        )
        // A bare ms value (no sequence suffix) still parses.
        XCTAssertEqual(EventPipeline.cursorDate("1000")?.timeIntervalSince1970 ?? -1, 1, accuracy: 0.0005)
        // Absent / malformed cursors degrade to nil (→ caller backfills).
        XCTAssertNil(EventPipeline.cursorDate(nil))
        XCTAssertNil(EventPipeline.cursorDate("not-a-number"))
    }

    // MARK: - Forward-cursor backfill walk

    private func entry(id: Int, eventType: String) -> GameLogEntry {
        GameLogEntry(
            id: id,
            createdAt: "2026-06-10T08:09:51-05:00",
            deviceCode: nil,
            deviceType: nil,
            eventType: eventType,
            message: nil,
            payload: nil
        )
    }

    // Cold start (no stored cursor): read only the newest tail to record a
    // resume point, and replay nothing — so launch never flickers the roster
    // through historical waypoints.
    func testCollectForwardSeedsWithoutReplaying() async throws {
        let tail = EventLogPage(
            entries: [entry(id: 30, eventType: "arrived"), entry(id: 29, eventType: "stowed")],
            nextCursor: nil  // `latest=true` returns a null next_cursor
        )
        let walk = try await EventPipeline.collectForward(
            replicantCode: "R",
            storedCursor: nil,
            maxEvents: 2000,
            fetchPage: { cursor, latest in
                XCTAssertTrue(latest, "seed must request the latest tail")
                XCTAssertNil(cursor)
                return tail
            }
        )
        XCTAssertTrue(walk.seededOnly)
        XCTAssertTrue(walk.events.isEmpty)
        XCTAssertEqual(walk.newCursor, 30, "resume point is the tip (largest id)")
    }

    // Catch-up: page forward from the stored cursor, following each page's
    // next_cursor until the tip, in chronological order.
    func testCollectForwardPagesForwardFromCursor() async throws {
        let pages: [Int?: EventLogPage] = [
            41: EventLogPage(
                entries: [entry(id: 42, eventType: "a"), entry(id: 43, eventType: "b"), entry(id: 44, eventType: "c")],
                nextCursor: 44
            ),
            44: EventLogPage(entries: [entry(id: 45, eventType: "d")], nextCursor: 45),
            45: EventLogPage(entries: [], nextCursor: nil),
        ]
        var requested: [Int?] = []
        let walk = try await EventPipeline.collectForward(
            replicantCode: "R",
            storedCursor: 41,
            maxEvents: 2000,
            fetchPage: { cursor, latest in
                XCTAssertFalse(latest, "catch-up pages forward, never `latest`")
                requested.append(cursor)
                return pages[cursor] ?? EventLogPage(entries: [], nextCursor: nil)
            }
        )
        XCTAssertFalse(walk.seededOnly)
        XCTAssertEqual(walk.events.count, 4)
        XCTAssertEqual(walk.newCursor, 45)
        XCTAssertEqual(requested, [41, 44, 45], "follows next_cursor forward, stops on the empty page")
    }

    // A caught-up cursor (at the tip) yields an immediately-empty forward page:
    // nothing to emit, resume point unchanged. This is the quiet-launch path
    // that used to re-dump the newest 100 events and flicker the location.
    func testCollectForwardCaughtUpReturnsNothing() async throws {
        let walk = try await EventPipeline.collectForward(
            replicantCode: "R",
            storedCursor: 100,
            maxEvents: 2000,
            fetchPage: { _, _ in EventLogPage(entries: [], nextCursor: nil) }
        )
        XCTAssertFalse(walk.seededOnly)
        XCTAssertTrue(walk.events.isEmpty)
        XCTAssertEqual(walk.newCursor, 100, "resume point stays put when nothing is new")
    }
}
