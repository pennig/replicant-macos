import XCTest
@testable import ReplicantKit

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
}
