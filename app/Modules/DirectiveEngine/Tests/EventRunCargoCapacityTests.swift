//
//  EventRunCargoCapacityTests.swift
//  Replicould — DirectiveEngine
//
//  What the convoy collects: what the ledger still needs, and never more than
//  the hold reports it can take.
//

import Foundation
import GameModels
import GameServices
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

/// `SKUT-3-EVT-003`'s chosen option: 600 carbon + 200 conductive against a
/// 500-unit hold, which the server refused as "requesting 800.0, capacity 500".
private enum Megaproject {
    static let option = "tether_fabrication"

    static func event(carbonDelivered: Int = 0, conductiveDelivered: Int = 0) -> LocationEvent {
        LocationEvent(
            designation: "X-1-EVT-001", location: "X-1", tier: 3, status: "active",
            detail: .object([
                "criteria": .array([.object([
                    "name": .string(option), "devices": .array([]),
                    "resources": .object(["carbon": .number(600), "conductive": .number(200)]),
                ])]),
                "progress": .object([
                    "met": .bool(false),
                    "options": .array([.object([
                        "name": .string(option), "met": .bool(false), "devices": .array([]),
                        "resources": .array([
                            .object([
                                "resource_type": .string("carbon"),
                                "current": .number(Double(carbonDelivered)),
                                "required": .number(600), "met": .bool(false),
                            ]),
                            .object([
                                "resource_type": .string("conductive"),
                                "current": .number(Double(conductiveDelivered)),
                                "required": .number(200), "met": .bool(false),
                            ]),
                        ]),
                    ])]),
                ]),
                "rewards": .object(["xp": .number(500)]),
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast,
            chosenOption: option
        )
    }

    /// The convoy standing ready at the depot, everything already attached, so
    /// `loading` is down to the freighter.
    static func convoy(hold: Int?, used: Int = 0) -> [Device] {
        [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device(
                "FREIGHT", type: "cargo_freighter",
                cargoUsed: hold == nil ? nil : used, cargoCapacity: hold
            ),
            EventRunFixtures.courier(attachedTo: "CARRIER"),
            EventRunFixtures.device(
                "BEACON", type: "ftl_beacon", attachedTo: "CARRIER",
                tags: [EventRun.fleetTag(forTheatre: "HUB-1").string]
            ),
        ]
    }
}

@Suite("EventRun — the freighter's hold")
struct EventRunCargoCapacityTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func loadingAction(_ devices: [Device], _ event: LocationEvent) -> MissionAction {
        EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.loading.rawValue, now: now),
            world: EventRunFixtures.world(devices: devices, event: event, now: now)
        )
    }

    /// The live rejection, caught before it is dispatched: 800 units will not
    /// go into a 500-unit hold, and the server saying so is not a diagnosis.
    @Test func aLoadBiggerThanTheHoldStallsInsteadOfDispatching() {
        let action = loadingAction(Megaproject.convoy(hold: 500), Megaproject.event())
        #expect(action == .stall(.eventLoadExceedsHold, detail: "800 units for a hold of 500"))
    }

    /// A hold big enough collects the whole outstanding bill in one order.
    @Test func aLoadThatFitsIsCollected() {
        let action = loadingAction(Megaproject.convoy(hold: 1_000), Megaproject.event())
        #expect(action == .dispatch(
            kind: .collectResources, deviceCode: "FREIGHT",
            params: CommandParams(resources: ["carbon": 600, "conductive": 200]),
            nextStep: EventRun.Step.confirmingLoad.rawValue
        ))
    }

    /// The bill is what the ledger still needs, not what the option asks for.
    /// Re-sending the full requirement over-collects and never converges.
    @Test func theBillIsWhatIsStillOutstanding() {
        let action = loadingAction(
            Megaproject.convoy(hold: 500),
            Megaproject.event(carbonDelivered: 400, conductiveDelivered: 50)
        )
        #expect(action == .dispatch(
            kind: .collectResources, deviceCode: "FREIGHT",
            params: CommandParams(resources: ["carbon": 200, "conductive": 150]),
            nextStep: EventRun.Step.confirmingLoad.rawValue
        ))
    }

    /// Everything already delivered means nothing to collect — the convoy flies
    /// on rather than ordering an empty load.
    @Test func afullyDeliveredBillDepartsWithNoOrder() {
        let action = loadingAction(
            Megaproject.convoy(hold: 500),
            Megaproject.event(carbonDelivered: 600, conductiveDelivered: 200)
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.departing.rawValue))
    }

    /// A row carrying no `cargo_capacity` reports no hold, which is not a hold
    /// of size zero. Inventing a limit there would stall every convoy whose
    /// freighter row has not been read in detail yet.
    @Test func anUnreportedHoldIsNotTreatedAsEmpty() {
        let action = loadingAction(Megaproject.convoy(hold: nil), Megaproject.event())
        #expect(action == .dispatch(
            kind: .collectResources, deviceCode: "FREIGHT",
            params: CommandParams(resources: ["carbon": 600, "conductive": 200]),
            nextStep: EventRun.Step.confirmingLoad.rawValue
        ))
    }

    /// The hold's FREE space is the bound, so a part-laden freighter is judged
    /// on what is left in it.
    @Test func aPartLadenHoldIsJudgedOnWhatIsLeft() {
        let outstanding = EventPlan.outstandingResources(
            EventPlan.Option(
                name: Megaproject.option, devices: [:],
                resources: ["carbon": 600, "conductive": 200],
                deviceUnits: 0, resourceUnits: 800, unprintable: [], jobs: []
            ),
            in: Megaproject.event(carbonDelivered: 600)
        )
        #expect(outstanding == ["conductive": 200])
    }

    /// A hold that cannot take the load is not something a retry reaches.
    @Test func theStallIsEscalatedNotRetried() {
        #expect(DirectiveAttentionReason.eventLoadExceedsHold.brainDisposition == .escalate)
    }
}
