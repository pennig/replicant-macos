//
//  TravelSnapshotTests.swift
//  Replicould — DependencyClients
//
//  `TravelSnapshot(travelObject:)` parses a "travel-ish" JSON object into the
//  itinerary the device inspector's segmented progress bar draws. The same
//  parser serves two shapes with one field vocabulary: the device's live
//  `travel` block (remaining legs only) and a `travel` command response captured
//  at dispatch (the whole route, frozen). These tests pin both shapes, the
//  origin/destination label precedence, per-leg parsing, and the empty cases —
//  plus the `Device`/`Operation` accessors that pick the right subtree.
//

import Foundation
import Testing
import Utils
@testable import DependencyClients

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = DependencyClients.Operation

@Suite struct TravelSnapshotTests {

    // MARK: Fixtures

    /// A live in-transit `travel` block, matching a real payload: `origin` /
    /// `destination` are system-level, `final_destination` is the true endpoint,
    /// and `route` lists the remaining legs (leg 1 flagged `active`).
    private var liveTravelBlock: JSONValue {
        .object([
            "origin": .string("SOL"),
            "origin_name": .null,
            "destination": .string("ATIANFU"),
            "final_destination": .string("ATIANFU-BELT-1"),
            "final_destination_name": .null,
            "departed_at": .string("2026-07-01T19:16:11-05:00"),
            "final_arrives_at": .string("2026-07-01T19:37:34-05:00"),
            "route": .array([
                .object([
                    "leg": .number(1),
                    "active": .bool(true),
                    "from": .string("SOL-5-L4"),
                    "to": .string("ATIANFU-1-L4"),
                    "type": .string("surge"),
                    "time_seconds": .number(1233),
                ]),
                .object([
                    "leg": .number(2),
                    "from": .string("ATIANFU-1-L4"),
                    "to": .string("ATIANFU-BELT-1"),
                    "type": .string("cruise"),
                    "time_seconds": .number(49.5),
                ]),
            ]),
        ])
    }

    // MARK: Parsing — live block

    @Test func parsesOriginAndDestinationFromLiveBlock() throws {
        let snapshot = try #require(TravelSnapshot(travelObject: liveTravelBlock))
        #expect(snapshot.origin == "SOL")
        // Prefers the ultimate arrival point over the system-level destination.
        #expect(snapshot.destination == "ATIANFU-BELT-1")
    }

    @Test func parsesEveryLegInOrder() throws {
        let snapshot = try #require(TravelSnapshot(travelObject: liveTravelBlock))
        #expect(snapshot.legs.count == 2)

        let first = snapshot.legs[0]
        #expect(first.index == 1)
        #expect(first.from == "SOL-5-L4")
        #expect(first.to == "ATIANFU-1-L4")
        #expect(first.type == "surge")
        #expect(first.timeSeconds == 1233)
        #expect(first.active == true)

        let second = snapshot.legs[1]
        #expect(second.index == 2)
        #expect(second.type == "cruise")
        #expect(second.timeSeconds == 49.5)
        // Absent `active` defaults to false rather than nil.
        #expect(second.active == false)
    }

    @Test func totalLegSecondsSumsWhenEveryLegHasADuration() throws {
        let snapshot = try #require(TravelSnapshot(travelObject: liveTravelBlock))
        #expect(snapshot.totalLegSeconds == 1282.5)
    }

    // MARK: Parsing — flat command response

    /// The dispatch response is the same vocabulary but flat (no `travel`
    /// wrapper), and carries the whole route at departure.
    @Test func parsesFlatCommandResponseShape() throws {
        let response: JSONValue = .object([
            "origin": .string("SOL"),
            "destination": .string("ATIANFU"),
            "final_destination": .string("ATIANFU-BELT-1"),
            "route": .array([
                .object(["leg": .number(1), "to": .string("ATIANFU-1-L4"), "type": .string("surge"), "time_seconds": .number(1233)]),
                .object(["leg": .number(2), "to": .string("ATIANFU-BELT-1"), "type": .string("cruise"), "time_seconds": .number(49.5)]),
            ]),
        ])
        let snapshot = try #require(TravelSnapshot(travelObject: response))
        #expect(snapshot.origin == "SOL")
        #expect(snapshot.destination == "ATIANFU-BELT-1")
        #expect(snapshot.legs.count == 2)
        #expect(snapshot.legs.first?.type == "surge")
    }

    // MARK: Label precedence

    @Test func labelsPreferHumanNameThenFallBackToCode() throws {
        let named: JSONValue = .object([
            "origin": .string("SOL"),
            "origin_name": .string("Sol System"),
            "final_destination": .string("ATIANFU-BELT-1"),
            "final_destination_name": .string("Atianfu Belt"),
            "route": .array([]),
        ])
        let snapshot = try #require(TravelSnapshot(travelObject: named))
        #expect(snapshot.originLabel == "Sol System")
        #expect(snapshot.destinationLabel == "Atianfu Belt")
    }

    @Test func labelsFallBackToCodeWhenNameAbsent() throws {
        let snapshot = try #require(TravelSnapshot(travelObject: liveTravelBlock))
        #expect(snapshot.originLabel == "SOL")
        #expect(snapshot.destinationLabel == "ATIANFU-BELT-1")
    }

    @Test func destinationFallsBackToSystemLevelWhenNoFinalDestination() throws {
        let object: JSONValue = .object([
            "destination": .string("ATIANFU"),
            "route": .array([]),
        ])
        let snapshot = try #require(TravelSnapshot(travelObject: object))
        #expect(snapshot.destination == "ATIANFU")
    }

    // MARK: Leg edge cases

    @Test func legIndexFallsBackToPositionWhenAbsent() throws {
        let object: JSONValue = .object([
            "final_destination": .string("BETSU-7-L4"),
            "route": .array([
                .object(["to": .string("A")]),
                .object(["to": .string("B")]),
            ]),
        ])
        let snapshot = try #require(TravelSnapshot(travelObject: object))
        #expect(snapshot.legs.map(\.index) == [1, 2])
    }

    @Test func totalLegSecondsIsNilWhenAnyLegLacksDuration() throws {
        let object: JSONValue = .object([
            "final_destination": .string("BETSU-7-L4"),
            "route": .array([
                .object(["leg": .number(1), "time_seconds": .number(100)]),
                .object(["leg": .number(2)]),  // no duration
            ]),
        ])
        let snapshot = try #require(TravelSnapshot(travelObject: object))
        #expect(snapshot.totalLegSeconds == nil)
    }

    @Test func totalLegSecondsIsNilWhenRouteEmpty() throws {
        let object: JSONValue = .object(["final_destination": .string("BETSU-7-L4"), "route": .array([])])
        let snapshot = try #require(TravelSnapshot(travelObject: object))
        #expect(snapshot.legs.isEmpty)
        #expect(snapshot.totalLegSeconds == nil)
    }

    // MARK: Rejected inputs

    @Test func returnsNilForNonObject() {
        #expect(TravelSnapshot(travelObject: .string("nope")) == nil)
        #expect(TravelSnapshot(travelObject: .array([])) == nil)
        #expect(TravelSnapshot(travelObject: .null) == nil)
    }

    @Test func returnsNilForMissingObject() {
        #expect(TravelSnapshot(travelObject: nil) == nil)
    }

    @Test func returnsNilWhenNeitherDestinationNorRoutePresent() {
        // An object that carries no travel data isn't a travel payload.
        #expect(TravelSnapshot(travelObject: .object(["unrelated": .string("x")])) == nil)
    }

    @Test func parsesDestinationOnlyPayloadWithNoRoute() throws {
        // A destination with no route is still a (degenerate) travel payload.
        let snapshot = try #require(TravelSnapshot(travelObject: .object(["final_destination": .string("SOL")])))
        #expect(snapshot.destination == "SOL")
        #expect(snapshot.legs.isEmpty)
    }

    // MARK: Device / Operation accessors

    @Test func deviceTravelSnapshotReadsTheTravelBlock() throws {
        let device = makeDevice(detail: .object(["travel": liveTravelBlock]))
        let snapshot = try #require(device.travelSnapshot)
        #expect(snapshot.destination == "ATIANFU-BELT-1")
        #expect(snapshot.legs.count == 2)
    }

    @Test func deviceTravelSnapshotIsNilWithoutTravelBlock() {
        let device = makeDevice(detail: .object([:]))
        #expect(device.travelSnapshot == nil)
    }

    @Test func operationTravelSnapshotReadsTheStoredResult() throws {
        let op = makeOperation(detail: .object([
            "params": .object(["destination": .string("ATIANFU-BELT-1")]),
            "result": liveTravelBlock,
        ]))
        let snapshot = try #require(op.travelSnapshot)
        #expect(snapshot.origin == "SOL")
        #expect(snapshot.legs.count == 2)
    }

    /// An op adopted from a snapshot carries no `result`, so it has no frozen
    /// route of its own — the caller falls back to the device's live block.
    @Test func adoptedOperationHasNoTravelSnapshot() {
        let op = makeOperation(detail: .object([:]))
        #expect(op.travelSnapshot == nil)
    }

    // MARK: Builders

    private func makeDevice(detail: JSONValue) -> Device {
        Device(
            deviceCode: "965AC2C3", deviceType: "heaven_vessel", replicantCode: "R1",
            status: "travelling", location: nil, locationName: nil, operationalCapacity: 100,
            queueSize: 0, stowedInDeviceCode: nil, controllerDeviceCode: nil,
            attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: [], tags: [], detail: detail,
            updatedAt: Date(timeIntervalSince1970: 1_000), firstSeenAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func makeOperation(detail: JSONValue) -> Operation {
        Operation(
            id: "op1", entityCode: "965AC2C3", kind: OperationKind.travel.rawValue,
            status: OperationStatus.active, source: OperationSource.poll,
            startedAt: Date(timeIntervalSince1970: 0), completesAt: Date(timeIntervalSince1970: 1_283),
            lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: detail
        )
    }
}
