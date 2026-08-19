//
//  EventRunMultiFreighterTests.swift
//  Replicould — DirectiveEngine
//
//  A payload wider than one hold: the convoy takes a freighter per hold and
//  still makes one trip.
//

import Foundation
import GameModels
import GameServices
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

@Suite("EventRun — a convoy of freighters")
struct EventRunMultiFreighterTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func convoy(_ holds: [Int], used: [Int] = []) -> [Device] {
        var devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.courier(attachedTo: "CARRIER"),
            EventRunFixtures.device(
                "BEACON", type: "ftl_beacon", attachedTo: "CARRIER",
                tags: [EventRun.fleetTag(forTheatre: "HUB-1").string]
            ),
        ]
        for (index, hold) in holds.enumerated() {
            devices.append(EventRunFixtures.device(
                "FREIGHT-\(index + 1)", type: "cargo_freighter",
                cargoUsed: index < used.count ? used[index] : 0, cargoCapacity: hold
            ))
        }
        return devices
    }

    private func hulls(_ devices: [Device]) -> [Device] {
        devices.filter { $0.deviceType == "cargo_freighter" }
    }

    private func directive(step: EventRun.Step, codes: [String]) -> Directive {
        var row = EventRunFixtures.directive(step: step.rawValue, now: now)
        row.freighterCodes = codes
        return row
    }

    private func action(_ step: EventRun.Step, _ devices: [Device], _ codes: [String]) -> MissionAction {
        EventRun().nextAction(
            directive: directive(step: step, codes: codes),
            world: EventRunFixtures.world(devices: devices, event: Megaproject.event(), now: now)
        )
    }

    /// 800 units over two 500-unit holds fills the first and puts the rest in
    /// the second.
    @Test func theBillDividesAcrossTheHolds() throws {
        let plan = try #require(
            EventRun.loadPlan(bill: ["carbon": 600, "conductive": 200], across: hulls(convoy([500, 500])))
        )
        #expect(plan.map(\.freighter.deviceCode) == ["FREIGHT-1", "FREIGHT-2"])
        #expect(plan[0].take == ["carbon": 500])
        #expect(plan[1].take == ["carbon": 100, "conductive": 200])
    }

    /// The same shares whether the lead hull is empty or already filled, which
    /// is what stops a mid-load recompute from re-cutting the bill.
    @Test func theSharesDoNotMoveOnceTheFirstIsLaden() throws {
        let bill = ["carbon": 600, "conductive": 200]
        let before = try #require(EventRun.loadPlan(bill: bill, across: hulls(convoy([500, 500]))))
        let after = try #require(
            EventRun.loadPlan(bill: bill, across: hulls(convoy([500, 500], used: [500])))
        )
        #expect(before.map(\.take) == after.map(\.take))
    }

    @Test func loadingFillsTheLeadHullFirst() {
        #expect(action(.loading, convoy([500, 500]), ["FREIGHT-1", "FREIGHT-2"]) == .dispatch(
            kind: .collectResources, deviceCode: "FREIGHT-1",
            params: CommandParams(resources: ["carbon": 500]),
            nextStep: EventRun.Step.confirmingLoad.rawValue
        ))
    }

    @Test func loadingThenFillsTheSecond() {
        #expect(
            action(.loading, convoy([500, 500], used: [500]), ["FREIGHT-1", "FREIGHT-2"]) == .dispatch(
                kind: .collectResources, deviceCode: "FREIGHT-2",
                params: CommandParams(resources: ["carbon": 100, "conductive": 200]),
                nextStep: EventRun.Step.confirmingLoad.rawValue
            )
        )
    }

    @Test func bothLadenDeparts() {
        #expect(
            action(.loading, convoy([500, 500], used: [500, 300]), ["FREIGHT-1", "FREIGHT-2"])
                == .advanceStep(nextStep: EventRun.Step.departing.rawValue)
        )
    }

    /// Two 500-unit holds take the 800 a single hull refused — the live stall,
    /// and the convoy that clears it.
    @Test func twoHoldsClearTheStallOneCouldNot() {
        #expect(
            action(.loading, convoy([500]), ["FREIGHT-1"])
                == .stall(.eventLoadExceedsHold, detail: "800 units, convoy holds 500")
        )
        if case .stall = action(.loading, convoy([500, 500]), ["FREIGHT-1", "FREIGHT-2"]) {
            Issue.record("two holds should take the load")
        }
    }

    /// A convoy still short of the payload says so with both numbers.
    @Test func aConvoyStillShortNamesBothNumbers() {
        #expect(
            action(.loading, convoy([300, 200]), ["FREIGHT-1", "FREIGHT-2"])
                == .stall(.eventLoadExceedsHold, detail: "800 units, convoy holds 500")
        )
    }

    /// The lease covers every hull, or another run takes one mid-convoy.
    @Test func ownershipReservesEveryHull() {
        var row = directive(step: .loading, codes: ["FREIGHT-1", "FREIGHT-2"])
        row.status = .running
        let devices = Dictionary(
            convoy([500, 500]).map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }
        )
        let ownership = Ownership.resolve(directives: [row], devices: devices, theatres: [])
        #expect(ownership.reserved.isSuperset(of: ["CARRIER", "FREIGHT-1", "FREIGHT-2"]))
    }

    /// A row written through the single-freighter mirror still leases its hull,
    /// so nothing that predates the list goes unreserved.
    @Test func theMirrorAloneStillLeases() {
        var row = EventRunFixtures.directive(step: EventRun.Step.loading.rawValue, now: now)
        row.freighterCodes = []
        row.freighterCode = "FREIGHT-1"
        #expect(row.leasedFreighters == ["FREIGHT-1"])
    }
}
