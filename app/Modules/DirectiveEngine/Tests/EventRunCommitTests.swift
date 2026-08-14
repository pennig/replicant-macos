//
//  EventRunCommitTests.swift
//  Replicould — DirectiveEngine
//
//  `EventRun`'s closing legs: the progress gate, the commit, the reward sweep.
//

import Foundation
import GameModels
import GameServices
import Testing
import Utils
@testable import DirectiveEngine

@Suite("EventRun — commit")
struct EventRunCommitTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    /// The convoy stood down at the event. `hold` is the freighter's cargo
    /// capacity, `used` what is still aboard; a nil `hold` leaves the row's
    /// variable tail without one.
    private func onSite(_ updatedAt: Date, hold: Int? = nil, used: Int = 0) -> [Device] {
        [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1", updatedAt: updatedAt),
            EventRunFixtures.device(
                "FREIGHT", type: "cargo_freighter", location: "X-1", updatedAt: updatedAt,
                cargoUsed: used, cargoCapacity: hold
            ),
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER", location: "X-1", updatedAt: updatedAt),
        ]
    }

    /// An event whose live progress reports met and a replicant present.
    private func metEvent(
        met: Bool, replicant: Bool, status: String = "active",
        rewards: [String: Int] = ["rares": 400]
    ) -> LocationEvent {
        LocationEvent(
            designation: "X-1-EVT-001", location: "X-1", tier: 1, status: status,
            objectivesMet: met,
            detail: .object([
                "criteria": .array([.object([
                    "name": .string("default"), "devices": .array([]),
                    "resources": .object(["structural": .number(200)]),
                ])]),
                "progress": .object([
                    "met": .bool(met), "replicant_present": .bool(replicant),
                    "options": .array([.object([
                        "name": .string("default"), "met": .bool(met), "devices": .array([]),
                        "resources": .array([.object([
                            "resource_type": .string("structural"),
                            "current": .number(met ? 200 : 0), "required": .number(200),
                            "met": .bool(met),
                        ])]),
                    ])]),
                ]),
                "rewards": .object([
                    "xp": .number(500),
                    "resources": .object(rewards.mapValues { .number(Double($0)) }),
                ]),
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
    }

    @Test("met plus a replicant on site commits")
    func commits() {
        let world = EventRunFixtures.world(
            devices: onSite(now), event: metEvent(met: true, replicant: true), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingProgress, now: now),
            world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.committing))
    }

    @Test("unmet progress buys a fresh ledger read before the deadline")
    func waitsForProgress() {
        let world = EventRunFixtures.world(
            devices: onSite(now), event: metEvent(met: false, replicant: true), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingProgress, now: now),
            world: world
        )
        #expect(action == .refreshEvents(thenStall: nil))
    }

    @Test("unmet past the deadline stalls eventCriteriaUnmet")
    func stallsOnUnmet() {
        let late = now.addingTimeInterval(EventRun.progressDeadline + 1)
        let world = EventRunFixtures.world(
            devices: onSite(late), event: metEvent(met: false, replicant: true), now: late
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingProgress, now: now),
            world: world
        )
        #expect(action == .stall(.eventCriteriaUnmet, detail: "X-1-EVT-001"))
    }

    @Test("a replicant that never arrives stalls rather than re-staging")
    func stallsOnAbsentReplicant() {
        let late = now.addingTimeInterval(EventRun.progressDeadline + 1)
        let world = EventRunFixtures.world(
            devices: onSite(late), event: metEvent(met: true, replicant: false), now: late
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingProgress, now: now),
            world: world
        )
        #expect(action == .stall(.eventCriteriaUnmet, detail: "X-1-EVT-001"))
    }

    @Test("an event closed by another path aborts to recovering, no stall")
    func abortsOnAlreadyCompleted() {
        let world = EventRunFixtures.world(
            devices: onSite(now),
            event: metEvent(met: true, replicant: true, status: "completed"), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingProgress, now: now),
            world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.recovering))
    }

    @Test("committing posts the empty POST")
    func posts() {
        let world = EventRunFixtures.world(
            devices: onSite(now), event: metEvent(met: true, replicant: true), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.committing, now: now),
            world: world
        )
        #expect(action == .completeEvent(
            location: "X-1", designation: "X-1-EVT-001", nextStep: EventRun.Step.collecting
        ))
    }

    @Test("a commit that left the event open stalls eventCommitRejected")
    func commitRejected() {
        let late = now.addingTimeInterval(EventRun.progressDeadline + 1)
        let world = EventRunFixtures.world(
            devices: onSite(late), event: metEvent(met: true, replicant: true), now: late
        )
        var directive = EventRunFixtures.directive(step: EventRun.Step.collecting, now: now)
        directive.targets = ["X-1-EVT-001"]
        let action = EventRun().nextAction(directive: directive, world: world)
        #expect(action == .stall(.eventCommitRejected, detail: "X-1-EVT-001"))
    }

    /// `collecting` against a closed event, with `hold` as the freighter's
    /// capacity and `used` as what is still aboard.
    private func sweep(rewards: [String: Int], hold: Int?, used: Int = 0) -> MissionAction {
        let world = EventRunFixtures.world(
            devices: onSite(now, hold: hold, used: used),
            event: metEvent(met: true, replicant: true, status: "completed", rewards: rewards),
            now: now
        )
        return EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.collecting, now: now),
            world: world
        )
    }

    /// The same world, judged as the three-way verdict `collecting` switches on.
    private func verdict(rewards: [String: Int], hold: Int?, used: Int = 0) -> EventRun.Sweep {
        EventRun.sweep(
            metEvent(met: true, replicant: true, status: "completed", rewards: rewards),
            into: onSite(now, hold: hold, used: used).first { $0.deviceCode == "FREIGHT" }!
        )
    }

    @Test("collecting names the reward's own types and amounts")
    func sweepsReward() {
        #expect(sweep(rewards: ["rares": 400, "structural": 50], hold: 500) == .dispatch(
            kind: .collectResources, deviceCode: "FREIGHT",
            params: CommandParams(resources: ["rares": 400, "structural": 50]),
            nextStep: EventRun.Step.recovering
        ))
    }

    @Test("a reward larger than the hold is clamped, not refused")
    func clampsToTheHold() {
        #expect(sweep(rewards: ["rares": 800, "structural": 500], hold: 500) == .dispatch(
            kind: .collectResources, deviceCode: "FREIGHT",
            params: CommandParams(resources: ["rares": 500]),
            nextStep: EventRun.Step.recovering
        ))
    }

    @Test("a row with no capacity in its tail asks for the whole manifest")
    func unknownCapacityAsksForEverything() {
        #expect(sweep(rewards: ["rares": 800, "structural": 500], hold: nil) == .dispatch(
            kind: .collectResources, deviceCode: "FREIGHT",
            params: CommandParams(resources: ["rares": 800, "structural": 500]),
            nextStep: EventRun.Step.recovering
        ))
    }

    @Test("an empty reward manifest goes home without a dispatch")
    func nothingToSweep() {
        let action = sweep(rewards: [:], hold: 500)
        #expect(action == .advanceStep(nextStep: EventRun.Step.recovering))
        if case .dispatch = action { Issue.record("an XP-only reward must not be collected") }
        #expect(verdict(rewards: [:], hold: 500) == .nothingPaid)
    }

    @Test("a full hold goes home rather than stalling, reward still on the ground")
    func fullHoldAdvances() {
        #expect(sweep(rewards: ["rares": 400], hold: 500, used: 500)
            == .advanceStep(nextStep: EventRun.Step.recovering))
        #expect(verdict(rewards: ["rares": 400], hold: 500, used: 500)
            == .willNotFit(["rares": 400]))
    }

    @Test("the three sweep outcomes are distinguishable, not two")
    func sweepTrichotomy() {
        #expect(verdict(rewards: [:], hold: 500) == .nothingPaid)
        #expect(verdict(rewards: ["rares": 400], hold: 500, used: 500) == .willNotFit(["rares": 400]))
        #expect(verdict(rewards: ["rares": 400], hold: 500) == .lift(["rares": 400]))
        #expect(verdict(rewards: ["rares": 800], hold: 500) == .lift(["rares": 500]))
    }
}
