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
import UniverseModels
import Utils
@testable import DirectiveEngine

@Suite("EventRun — commit")
struct EventRunCommitTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func onSite(_ updatedAt: Date) -> [Device] {
        [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1", updatedAt: updatedAt),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter", location: "X-1", updatedAt: updatedAt),
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER", location: "X-1", updatedAt: updatedAt),
        ]
    }

    /// An event whose live progress reports met and a replicant present.
    private func metEvent(met: Bool, replicant: Bool, status: String = "active") -> LocationEvent {
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
                "rewards": .object(["xp": .number(500), "resources": .object(["rares": .number(400)])]),
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

    @Test("collecting sweeps a reward pile into the empty freighter")
    func sweepsReward() {
        var world = EventRunFixtures.world(
            devices: onSite(now),
            event: metEvent(met: true, replicant: true, status: "completed"), now: now
        )
        world = WorldSnapshot(
            devices: world.devices, openOperations: [:],
            footprints: world.footprints.merging([
                "X-1": LocationFootprint(
                    location: "X-1", devices: 0, resources: 400, resourceSites: 0,
                    locationEvents: 1, replicants: 0, fetchedAt: now
                )
            ]) { _, new in new },
            theatres: world.theatres, locationEvents: world.locationEvents, now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.collecting, now: now),
            world: world
        )
        #expect(action == .dispatch(
            kind: .collectResources, deviceCode: "FREIGHT",
            params: CommandParams(resources: nil), nextStep: EventRun.Step.recovering
        ))
    }

    @Test("no pile left to lift goes home")
    func nothingToSweep() {
        let world = EventRunFixtures.world(
            devices: onSite(now),
            event: metEvent(met: true, replicant: true, status: "completed"), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.collecting, now: now),
            world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.recovering))
    }
}
