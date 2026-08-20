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

    // MARK: - Departure

    /// The convoy mid-departure: `placed` names the hulls already standing at
    /// the event, and everything else is still at the depot.
    private func departingConvoy(placed: Set<String>) -> [Device] {
        func site(_ code: String) -> String { placed.contains(code) ? "X-1" : "HUB-1" }
        return [
            EventRunFixtures.device(
                "CARRIER", type: "surge_carrier", location: site("CARRIER"), tags: ["auto:carrier"]
            ),
            EventRunFixtures.courier(attachedTo: "CARRIER", location: site("CARRIER")),
            EventRunFixtures.device(
                "FREIGHT-1", type: "cargo_freighter", location: site("FREIGHT-1"),
                cargoUsed: 500, cargoCapacity: 500
            ),
            EventRunFixtures.device(
                "FREIGHT-2", type: "cargo_freighter", location: site("FREIGHT-2"),
                cargoUsed: 300, cargoCapacity: 500
            ),
        ]
    }

    private func departing(_ placed: Set<String>) -> MissionAction {
        action(.departing, departingConvoy(placed: placed), ["FREIGHT-1", "FREIGHT-2"])
    }

    /// Ordering the lead freighter must not end the step: the second hull has
    /// no order yet, and `confirmingArrival` waits on every one of them.
    @Test func departingKeepsTheStepWhileAHullIsStillAtTheDepot() {
        #expect(departing(["CARRIER"]) == .dispatch(
            kind: .travel, deviceCode: "FREIGHT-1",
            params: CommandParams(destination: "X-1"),
            nextStep: EventRun.Step.departing.rawValue
        ))
    }

    /// The leg the stalled run never dispatched.
    @Test func departingOrdersTheSecondFreighterOnceTheFirstIsPlaced() {
        #expect(departing(["CARRIER", "FREIGHT-1"]) == .dispatch(
            kind: .travel, deviceCode: "FREIGHT-2",
            params: CommandParams(destination: "X-1"),
            nextStep: EventRun.Step.departing.rawValue
        ))
    }

    /// Only a whole convoy standing at the event ends the step.
    @Test func departingAdvancesOnlyWhenEveryHullStands() {
        #expect(
            departing(["CARRIER", "FREIGHT-1", "FREIGHT-2"])
                == .advanceStep(nextStep: EventRun.Step.confirmingArrival.rawValue)
        )
    }

    /// Walk `departing` as the executor does — dispatch, place that hull,
    /// re-enter only while the dispatch still names this step. Every hull must
    /// carry an order before the convoy reaches `confirmingArrival`.
    @Test func everyHullIsOrderedBeforeTheStepEnds() {
        var placed: Set<String> = []
        var ordered: [String] = []
        for _ in 0..<4 {
            guard case let .dispatch(_, deviceCode, _, nextStep) = departing(placed) else { break }
            ordered.append(deviceCode)
            placed.insert(deviceCode)
            guard nextStep == EventRun.Step.departing.rawValue else { break }
        }
        #expect(ordered == ["CARRIER", "FREIGHT-1", "FREIGHT-2"])
        #expect(departing(placed) == .advanceStep(nextStep: EventRun.Step.confirmingArrival.rawValue))
    }

    // MARK: - Departing abreast

    /// The convoy mid-departure with `crossing` naming the hulls whose travel op
    /// is open. `placed` teleports a hull to the event; `crossing` is the state
    /// between the two, and the one the live run spends its whole leg in.
    private func departing(placed: Set<String> = [], crossing: Set<String>) -> MissionAction {
        let ops = crossing.reduce(into: [String: GameModels.Operation]()) { ops, code in
            ops[code] = GameModels.Operation(
                id: "OP-\(code)", entityCode: code, kind: OperationKind.travel.rawValue,
                status: .active, source: .poll, startedAt: now, completesAt: nil,
                lastConfirmedAt: now, detail: .object([:])
            )
        }
        return EventRun().nextAction(
            directive: directive(step: .departing, codes: ["FREIGHT-1", "FREIGHT-2"]),
            world: EventRunFixtures.world(
                devices: departingConvoy(placed: placed), event: Megaproject.event(), now: now,
                openOperations: ops
            )
        )
    }

    /// The whole speed-up in one assertion: a carrier in the air does not hold
    /// the freighter at the depot. Serialised, a convoy costs one whole crossing
    /// per hull; abreast, it costs one.
    @Test func aCrossingCarrierDoesNotHoldTheFreighterAtTheDepot() {
        #expect(departing(crossing: ["CARRIER"]) == .dispatch(
            kind: .travel, deviceCode: "FREIGHT-1",
            params: CommandParams(destination: "X-1"),
            nextStep: EventRun.Step.departing.rawValue
        ))
    }

    /// Nor does a crossing freighter hold the one behind it.
    @Test func aCrossingFreighterDoesNotHoldTheNextOne() {
        #expect(departing(crossing: ["CARRIER", "FREIGHT-1"]) == .dispatch(
            kind: .travel, deviceCode: "FREIGHT-2",
            params: CommandParams(destination: "X-1"),
            nextStep: EventRun.Step.departing.rawValue
        ))
    }

    /// A convoy wholly in the air waits — nothing left to order, and nothing
    /// standing at the event yet either.
    @Test func aConvoyWhollyInTheAirWaits() {
        #expect(departing(crossing: ["CARRIER", "FREIGHT-1", "FREIGHT-2"]) == .wait)
    }

    /// Walk the executor the way it actually runs: each dispatch puts that hull
    /// in the air rather than at the event, and NOTHING arrives. Every hull must
    /// still carry an order — three ticks, not three crossings.
    @Test func everyHullIsOrderedWithoutWaitingForAnArrival() {
        var crossing: Set<String> = []
        var ordered: [String] = []
        for _ in 0..<4 {
            guard case let .dispatch(_, deviceCode, _, _) = departing(crossing: crossing) else { break }
            ordered.append(deviceCode)
            crossing.insert(deviceCode)
        }
        #expect(ordered == ["CARRIER", "FREIGHT-1", "FREIGHT-2"])
        #expect(departing(crossing: crossing) == .wait)
    }

    /// The step still ends on arrivals, not on orders: a hull placed and a hull
    /// crossing is not a convoy that has landed.
    @Test func aMixedConvoyWaitsRatherThanAdvancing() {
        #expect(
            departing(placed: ["CARRIER", "FREIGHT-1"], crossing: ["FREIGHT-2"]) == .wait
        )
    }

    // MARK: - Returning abreast

    /// The convoy on the way home, `crossing` naming the hulls already in the air.
    private func returning(crossing: Set<String>) -> MissionAction {
        let ops = crossing.reduce(into: [String: GameModels.Operation]()) { ops, code in
            ops[code] = GameModels.Operation(
                id: "OP-\(code)", entityCode: code, kind: OperationKind.travel.rawValue,
                status: .active, source: .poll, startedAt: now, completesAt: nil,
                lastConfirmedAt: now, detail: .object([:])
            )
        }
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1"),
            EventRunFixtures.courier(attachedTo: "CARRIER", location: "X-1"),
            EventRunFixtures.device("FREIGHT-1", type: "cargo_freighter", location: "X-1"),
            EventRunFixtures.device("FREIGHT-2", type: "cargo_freighter", location: "X-1"),
        ]
        return EventRun().nextAction(
            directive: directive(step: .returning, codes: ["FREIGHT-1", "FREIGHT-2"]),
            world: EventRunFixtures.world(
                devices: devices, event: Megaproject.event(), now: now, openOperations: ops
            )
        )
    }

    /// The return leg answers to the same rule as the outbound one.
    @Test func aCrossingCarrierDoesNotHoldTheFreighterAtTheEvent() {
        #expect(returning(crossing: ["CARRIER"]) == .dispatch(
            kind: .travel, deviceCode: "FREIGHT-1",
            params: CommandParams(destination: "HUB-1"),
            nextStep: EventRun.Step.returning.rawValue
        ))
    }

    /// A convoy wholly in the air on the way home waits rather than unloading a
    /// hold that has not landed.
    @Test func aConvoyFlyingHomeWaitsRatherThanDepositing() {
        #expect(returning(crossing: ["CARRIER", "FREIGHT-1", "FREIGHT-2"]) == .wait)
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
