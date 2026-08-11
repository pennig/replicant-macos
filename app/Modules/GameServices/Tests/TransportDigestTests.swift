import API
import Foundation
import Testing
import Utils
@testable import GameServices

@Suite struct TransportDigestTests {
    private func envelope(_ payload: [String: JSONValue], createdAt: String? = nil) -> GameEventEnvelope {
        GameEventEnvelope(
            id: "1-0",
            category: "ami",
            event: "ami.transport.digest",
            deviceCode: "8D53C9B1",
            payload: payload,
            createdAt: createdAt
        )
    }

    @Test func itReadsALiveDigest() throws {
        let digest = try #require(
            TransportDigest(
                envelope: envelope([
                    "report": .object([
                        "cargo_capacity": .number(500),
                        "cargo_carried": .number(345),
                        "collect": .string("ACHERNUR-BELT-1"),
                        "deliver": .string("AINALRAM-BELT-1"),
                    ]),
                    "activity": .object([
                        "counts": .object(["transport.collected": .number(1)])
                    ]),
                    "devices": .array([
                        .object([
                            "device_code": .string("F7B455B6"),
                            "last_event": .string("transport.collected"),
                        ])
                    ]),
                ]),
                now: Date(timeIntervalSince1970: 0)
            )
        )
        #expect(digest.controllerCode == "8D53C9B1")
        #expect(digest.cargoCarried == 345)
        #expect(digest.collect == "ACHERNUR-BELT-1")
        #expect(digest.deliver == "AINALRAM-BELT-1")
        #expect(digest.collectedCount == 1)
        #expect(digest.deliveredCount == 0)
        #expect(digest.activeDeviceCode == "F7B455B6")
    }

    @Test func aDigestWithoutAControllerCodeIsRejected() {
        let bare = GameEventEnvelope(id: "1-0", category: "ami", event: "ami.transport.digest")
        #expect(TransportDigest(envelope: bare, now: Date()) == nil)
    }

    @Test func anAbsentCarriedFigureReadsAsZero() throws {
        let digest = try #require(
            TransportDigest(envelope: envelope(["report": .object([:])]), now: Date())
        )
        #expect(digest.cargoCarried == 0)
        #expect(digest.activeDeviceCode == nil)
    }

    // `collectedAt` is stamped from `observedAt` and drives calendar
    // day-bucketing, so a regression to always-`now` would silently re-date
    // every row without either branch being separately covered.
    @Test func observedAtUsesTheEnvelopesCreatedAtWhenItParses() throws {
        let e = envelope(["report": .object([:])], createdAt: "2026-08-01T12:00:00Z")
        let now = Date(timeIntervalSince1970: 0)
        let digest = try #require(TransportDigest(envelope: e, now: now))
        #expect(digest.observedAt == e.date)
        #expect(digest.observedAt != now)
    }

    @Test func observedAtFallsBackToNowWhenCreatedAtIsAbsent() throws {
        let e = envelope(["report": .object([:])])
        let now = Date(timeIntervalSince1970: 12_345)
        let digest = try #require(TransportDigest(envelope: e, now: now))
        #expect(digest.observedAt == now)
    }
}
