import XCTest
import Utils
@testable import API

final class PipelineTests: XCTestCase {

    // MARK: - SSE frame → envelope

    // The frame's `id:`/`event:` fields are authoritative; the rest comes from
    // the decoded `data:` body, and `category` falls back to the name's prefix.
    func testStreamedFrameDecodesEnvelope() throws {
        let body = #"""
        {"category":"mining","event":"mining.started","device_code":"D1","star":"SOL","location":"SOL-5-BELT-1","payload":{"resource_type":"iron"},"created_at":"2026-05-10T08:55:27+01:00"}
        """#
        let streamed = StreamedEvent(id: "1779087998123-0", eventName: "mining.started", raw: Data(body.utf8))
        let event = try XCTUnwrap(GameEventEnvelope(streamed: streamed))

        XCTAssertEqual(event.id, "1779087998123-0")
        XCTAssertEqual(event.event, "mining.started")
        XCTAssertEqual(event.category, "mining")
        XCTAssertEqual(event.deviceCode, "D1")
        XCTAssertEqual(event.star, "SOL")
        XCTAssertEqual(event.location, "SOL-5-BELT-1")
        XCTAssertEqual(event.payload?["resource_type"]?.stringValue, "iron")
        XCTAssertEqual(event.provenance, .stream)
    }

    // The frame's id/event win over a body that repeats (or omits) them, and
    // `category` is derived from the dotted name when the body omits it.
    func testStreamedFrameIDAndEventWinAndCategoryDerived() throws {
        let body = #"{"device_code":"D2","payload":{}}"#  // no id/event/category
        let streamed = StreamedEvent(id: "42-0", eventName: "travel.arrived", raw: Data(body.utf8))
        let event = try XCTUnwrap(GameEventEnvelope(streamed: streamed))
        XCTAssertEqual(event.id, "42-0")
        XCTAssertEqual(event.event, "travel.arrived")
        XCTAssertEqual(event.category, "travel", "category derived from the name prefix")
        XCTAssertNil(event.payload, "an empty payload collapses to nil")
    }

    // A malformed body yields nil rather than wedging the stream.
    func testStreamedFrameMalformedBodyIsNil() {
        let streamed = StreamedEvent(id: "1-0", eventName: "mining.started", raw: Data("not json".utf8))
        XCTAssertNil(GameEventEnvelope(streamed: streamed))
    }

    // A frame with neither a frame event name nor a body event is unusable.
    func testStreamedFrameWithNoEventNameIsNil() {
        let streamed = StreamedEvent(id: "1-0", eventName: "", raw: Data(#"{"category":"x"}"#.utf8))
        XCTAssertNil(GameEventEnvelope(streamed: streamed))
    }

    // MARK: - Cursor date

    // A Redis stream ID's leading component is a millisecond timestamp; the
    // pipeline decodes it to gate catch-up (skip when the cursor is fresh).
    func testCursorDateParsesRedisStreamID() {
        XCTAssertEqual(
            EventPipeline.cursorDate("1779087998123-0")?.timeIntervalSince1970 ?? 0,
            1779087998.123,
            accuracy: 0.0005
        )
        // A bare ms value (no sequence suffix) still parses.
        XCTAssertEqual(EventPipeline.cursorDate("1000")?.timeIntervalSince1970 ?? -1, 1, accuracy: 0.0005)
        // Absent / malformed cursors degrade to nil (→ caller runs catch-up).
        XCTAssertNil(EventPipeline.cursorDate(nil))
        XCTAssertNil(EventPipeline.cursorDate("not-a-number"))
    }

    // MARK: - Dedup set

    func testBoundedSetEvictsOldest() {
        var set = BoundedEventIDSet(capacity: 2)
        XCTAssertTrue(set.insert("a"))
        XCTAssertTrue(set.insert("b"))
        XCTAssertFalse(set.insert("a"), "still remembered")
        XCTAssertTrue(set.insert("c"), "evicts a")
        XCTAssertTrue(set.insert("a"), "a was evicted, re-insertable")
        XCTAssertFalse(set.insert("c"))
    }
}
