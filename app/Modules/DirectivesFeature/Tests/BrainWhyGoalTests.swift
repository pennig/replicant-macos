//
//  BrainWhyGoalTests.swift
//  Replicould — Directives feature
//
//  The salvage and haul lines. A halted or paused run states a status and a
//  static fact, never a status and an active verb.
//

import DirectiveEngine
import Foundation
import Testing
@testable import DirectivesFeature

private func report(salvage: BrainGoalStatus, haul: BrainGoalStatus) -> BrainReport {
    BrainReport(
        decision: .idle(reason: "nothing"),
        ranked: [], hubLocation: "SOL-3",
        limits: BrainLimits(
            actionsRemaining: 54, actionsLimit: 60, actionsFloor: 6,
            hubStock: 41_000, hubStockFetchedAt: Date(timeIntervalSince1970: 0),
            spendFloor: 35_078, rateLimitedAt: nil
        ),
        survey: .idle(reason: "none"),
        salvage: salvage, haul: haul,
        observedAt: Date(timeIntervalSince1970: 0)
    )
}

private func salvageText(_ status: BrainGoalStatus) -> String {
    let r = report(salvage: status, haul: .idle(reason: "none"))
    return BrainWhy.goalLine(.salvage, status: status, report: r).text
}

private func haulText(_ status: BrainGoalStatus) -> String {
    let r = report(salvage: .idle(reason: "none"), haul: status)
    return BrainWhy.goalLine(.haul, status: status, report: r).text
}

@Suite("The salvage and haul why-view lines")
struct BrainWhyGoalTests {
    @Test("the four salvage states all read differently")
    func theFourSalvageStatesAllReadDifferently() {
        let running = salvageText(.launched(vessel: "V1", focus: "ALPAHARD", status: .running))
        let halted = salvageText(.launched(vessel: "V1", focus: "ALPAHARD", status: .needsAttention))
        let paused = salvageText(.launched(vessel: "V1", focus: "ALPAHARD", status: .paused))
        let ready = salvageText(.ready(vessel: "V1"))

        #expect(running == "working ALPAHARD — carrier V1")
        #expect(halted == "halted, last ALPAHARD — carrier V1")
        #expect(paused == "paused, last ALPAHARD — carrier V1")
        #expect(ready == "ready to launch — carrier V1")
        #expect(Set([running, halted, paused, ready]).count == 4)
    }

    /// The phrasing rule the survey build produced: a stopped run must not
    /// carry a verb asserting motion it is not making.
    @Test("a halted run states a place, never an active verb")
    func aHaltedRunStatesAPlaceNotAVerb() {
        let halted = salvageText(.launched(vessel: "V1", focus: "ALPAHARD", status: .needsAttention))
        #expect(!halted.contains("working"))
    }

    /// With `tendMesh` the only thing that can widen salvage's reach, the wait
    /// has to be named — an unqualified idle would present a coupling as an
    /// absence of value.
    @Test("an idle waiting on the mesh says so by name")
    func theMeshWaitIsNamed() {
        #expect(
            salvageText(.idle(reason: "no meshed salvage system with units left"))
                == "no meshed salvage system with units left"
        )
    }

    @Test("the haul line names its controller and its sink")
    func theHaulLineNamesItsSink() {
        #expect(
            haulText(.launched(vessel: "T1", focus: "SOL-3-1", status: .running))
                == "delivering to SOL-3-1 — controller T1"
        )
        #expect(haulText(.ready(vessel: "T1")) == "ready to launch — controller T1")
    }

    @Test("a launched row with no focus still reads as a status, not a blank")
    func aFocuslessRowStillReads() {
        #expect(
            salvageText(.launched(vessel: "V1", focus: nil, status: .running))
                == "no target yet — carrier V1"
        )
        #expect(
            haulText(.launched(vessel: "T1", focus: nil, status: .needsAttention))
                == "halted — no sink resolved — controller T1"
        )
    }

    @Test("designations render in the mono token, prose does not")
    func designationsAreTagged() {
        let line = BrainWhy.goalLine(
            .salvage,
            status: .launched(vessel: "V1", focus: "ALPAHARD", status: .running),
            report: report(salvage: .idle(reason: "none"), haul: .idle(reason: "none"))
        )
        #expect(line.spans.contains { $0 == .designation("ALPAHARD") })
    }
}
