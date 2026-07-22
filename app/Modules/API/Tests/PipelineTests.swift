import Foundation
import Testing
import Utils
@testable import API

@Suite struct PipelineTests {

    // MARK: - SSE frame → envelope

    // The frame's `id:`/`event:` fields are authoritative; the rest comes from
    // the decoded `data:` body, and `category` falls back to the name's prefix.
    @Test func streamedFrameDecodesEnvelope() throws {
        let body = #"""
        {"category":"mining","event":"mining.started","device_code":"D1","star":"SOL","location":"SOL-5-BELT-1","payload":{"resource_type":"iron"},"created_at":"2026-05-10T08:55:27+01:00"}
        """#
        let streamed = StreamedEvent(id: "1779087998123-0", eventName: "mining.started", raw: Data(body.utf8))
        let event = try #require(GameEventEnvelope(streamed: streamed))

        #expect(event.id == "1779087998123-0")
        #expect(event.event == "mining.started")
        #expect(event.category == "mining")
        #expect(event.deviceCode == "D1")
        #expect(event.star == "SOL")
        #expect(event.location == "SOL-5-BELT-1")
        #expect(event.payload?["resource_type"]?.stringValue == "iron")
        #expect(event.provenance == .stream)
    }

    // The frame's id/event win over a body that repeats (or omits) them, and
    // `category` is derived from the dotted name when the body omits it.
    @Test func streamedFrameIDAndEventWinAndCategoryDerived() throws {
        let body = #"{"device_code":"D2","payload":{}}"#  // no id/event/category
        let streamed = StreamedEvent(id: "42-0", eventName: "travel.arrived", raw: Data(body.utf8))
        let event = try #require(GameEventEnvelope(streamed: streamed))
        #expect(event.id == "42-0")
        #expect(event.event == "travel.arrived")
        #expect(event.category == "travel", "category derived from the name prefix")
        #expect(event.payload == nil, "an empty payload collapses to nil")
    }

    // A malformed body yields nil rather than wedging the stream.
    @Test func streamedFrameMalformedBodyIsNil() {
        let streamed = StreamedEvent(id: "1-0", eventName: "mining.started", raw: Data("not json".utf8))
        #expect(GameEventEnvelope(streamed: streamed) == nil)
    }

    // A frame with neither a frame event name nor a body event is unusable.
    @Test func streamedFrameWithNoEventNameIsNil() {
        let streamed = StreamedEvent(id: "1-0", eventName: "", raw: Data(#"{"category":"x"}"#.utf8))
        #expect(GameEventEnvelope(streamed: streamed) == nil)
    }

    // MARK: - Cursor date

    // A Redis stream ID's leading component is a millisecond timestamp; the
    // pipeline decodes it to gate catch-up (skip when the cursor is fresh).
    @Test func cursorDateParsesRedisStreamID() {
        #expect(
            abs((EventPipeline.cursorDate("1779087998123-0")?.timeIntervalSince1970 ?? 0) - 1779087998.123) < 0.0005
        )
        // A bare ms value (no sequence suffix) still parses.
        #expect(abs((EventPipeline.cursorDate("1000")?.timeIntervalSince1970 ?? -1) - 1) < 0.0005)
        // Absent / malformed cursors degrade to nil (→ caller runs catch-up).
        #expect(EventPipeline.cursorDate(nil) == nil)
        #expect(EventPipeline.cursorDate("not-a-number") == nil)
    }

    // MARK: - Dedup set

    @Test func boundedSetEvictsOldest() {
        var set = BoundedEventIDSet(capacity: 2)
        #expect(set.insert("a"))
        #expect(set.insert("b"))
        #expect(!set.insert("a"), "still remembered")
        #expect(set.insert("c"), "evicts a")
        #expect(set.insert("a"), "a was evicted, re-insertable")
        #expect(!set.insert("c"))
    }
}
