//
//  EventRunOptionResolutionTests.swift
//  Replicould — DirectiveEngine
//
//  The executor must re-decide a multi-option event on the SAME catalogue the
//  ranking launched it under, and name an undecided one honestly.
//

import Foundation
import GameModels
import GameServices
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

/// `SKUT-3-EVT-003`'s shape, the live event that stranded a run: two options,
/// one pure-resource and one demanding a printed device.
private enum TwoOption {
    static let resourceOnly = "material_delivery"
    static let needsDevice = "tether_fabrication"

    static func event(chosenOption: String? = nil) -> LocationEvent {
        LocationEvent(
            designation: "X-1-EVT-001", location: "X-1", tier: 3, status: "active",
            detail: .object([
                "criteria": .array([
                    .object([
                        "name": .string(resourceOnly), "devices": .array([]),
                        "resources": .object(["structural": .number(200)]),
                    ]),
                    .object([
                        "name": .string(needsDevice),
                        "devices": .array([.object([
                            "count": .number(2),
                            "device_type": .string("structural_fabricator"),
                        ])]),
                        "resources": .object(["carbon": .number(100)]),
                    ]),
                ]),
                "rewards": .object(["xp": .number(500)]),
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast,
            chosenOption: chosenOption
        )
    }

    /// A catalogue holding the beacon but NOT `structural_fabricator` — the
    /// account state at launch, before the unlock landed.
    static let catalogueWithoutFabricator: [String: ResourceCost] = [
        EventPlan.beaconDeviceType: ResourceCost(structural: 50)
    ]

    /// The same catalogue after the unlock, which makes both options printable.
    static let catalogueWithFabricator: [String: ResourceCost] = [
        EventPlan.beaconDeviceType: ResourceCost(structural: 50),
        "structural_fabricator": ResourceCost(structural: 300, conductive: 150),
    ]

    static func convoy(now: Date) -> [Device] {
        [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.courier(),
            EventRunFixtures.device("PRINTER", type: "autofactory", updatedAt: now),
        ]
    }
}

@Suite("EventRun — multi-option resolution")
struct EventRunOptionResolutionTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    /// The live stall: the ranking decided under a catalogue that ruled the
    /// second option out, so the executor must reach the same verdict.
    @Test("printing decides on the catalogue that authorised the launch")
    func printingDecidesUnderCatalogue() {
        let world = EventRunFixtures.world(
            devices: TwoOption.convoy(now: now), event: TwoOption.event(), now: now,
            blueprintBills: TwoOption.catalogueWithoutFabricator
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now),
            world: world
        )
        #expect(action != .stall(.unreachableDevice))
        #expect(action == .dispatch(
            kind: .print, deviceCode: "PRINTER",
            params: CommandParams(
                deviceType: EventPlan.beaconDeviceType, quantity: 1,
                printTags: [EventRun.fleetTag(forTheatre: "HUB-1").string]
            ),
            nextStep: EventRun.Step.printing.rawValue
        ))
    }

    /// The ranking would never launch this, but an unlock mid-run reopens the
    /// choice. It is the operator's to make, and must read as one.
    @Test("printing names an undecided option rather than blaming a device")
    func printingNamesTheChoice() {
        let world = EventRunFixtures.world(
            devices: TwoOption.convoy(now: now), event: TwoOption.event(), now: now,
            blueprintBills: TwoOption.catalogueWithFabricator
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now),
            world: world
        )
        #expect(action == .stall(.eventOptionNotChosen, detail: "X-1-EVT-001"))
    }

    /// The operator's pick settles it even when both options stand.
    @Test("printing honours the operator's pick over an ambiguous catalogue")
    func printingHonoursThePick() {
        let world = EventRunFixtures.world(
            devices: TwoOption.convoy(now: now),
            event: TwoOption.event(chosenOption: TwoOption.resourceOnly), now: now,
            blueprintBills: TwoOption.catalogueWithFabricator
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now),
            world: world
        )
        #expect(action != .stall(.unreachableDevice))
        #expect(action != .stall(.eventOptionNotChosen, detail: "X-1-EVT-001"))
    }

    /// Every step that re-decides the event shares the guard, so none of them
    /// may report a reachability problem for a choice.
    @Test(
        "no step blames a device for an undecided option",
        arguments: [
            EventRun.Step.printing.rawValue,
            EventRun.Step.loading.rawValue,
            EventRun.Step.staging.rawValue,
        ]
    )
    func noStepBlamesADevice(step: String) {
        var devices = TwoOption.convoy(now: now)
        devices.append(contentsOf: EventRunFixtures.onSiteConvoy(updatedAt: now))
        let world = EventRunFixtures.world(
            devices: devices, event: TwoOption.event(), now: now,
            blueprintBills: TwoOption.catalogueWithFabricator
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: step, now: now), world: world
        )
        #expect(action != .stall(.unreachableDevice))
    }

    /// The brain must not spend its retry budget re-asking a question only the
    /// operator can answer.
    @Test("an undecided option is a decision request, never a retry")
    func undecidedIsADecisionRequest() {
        #expect(DirectiveAttentionReason.eventOptionNotChosen.brainDisposition == .decisionRequest)
    }
}
