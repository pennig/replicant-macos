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

private func report(
    salvage: BrainGoalStatus, haul: BrainGoalStatus, mine: BrainGoalStatus = .idle(reason: "not evaluated"),
    mineDemandIncomplete: Bool = false
) -> BrainReport {
    BrainReport(
        decision: .idle(reason: "nothing"),
        ranked: [],
        theatres: [Theatre(depot: "SOL-3", system: "SOL", origin: .derived, readiness: .operational, stock: 0)],
        limits: BrainLimits(
            actionsRemaining: 54, actionsLimit: 60, actionsFloor: 6,
            readsRemaining: 108, readsLimit: 120, readsFloor: 12,
            hubStock: BrainCeiling.reserveFloors.mapValues { $0 * 10 }, hubStockFetchedAt: Date(timeIntervalSince1970: 0),
            reserveFloors: BrainCeiling.reserveFloors, rateLimitedAt: nil
        ),
        survey: .idle(reason: "none"),
        salvage: salvage, haul: haul, mine: mine,
        mineDemandIncomplete: mineDemandIncomplete,
        observedAt: Date(timeIntervalSince1970: 0)
    )
}

private func mineText(_ status: BrainGoalStatus) -> String {
    let r = report(salvage: .idle(reason: "none"), haul: .idle(reason: "none"), mine: status)
    return BrainWhy.goalLine(.mine, status: status, report: r).text
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

    @Test("the mine line names its belt and its carrier")
    func theMineLineNamesItsBeltAndCarrier() {
        #expect(
            mineText(.launched(vessel: "SC1", focus: "SOL-BELT-1", status: .running))
                == "installing at SOL-BELT-1 — carrier SC1"
        )
        #expect(mineText(.ready(vessel: "SC1")) == "ready to launch — carrier SC1")
        #expect(mineText(.idle(reason: "no printed mine fleet")) == "no printed mine fleet")
    }

    @Test("a halted mine install states the belt, never an active verb")
    func aHaltedMineInstallStatesThePlace() {
        let halted = mineText(.launched(vessel: "SC1", focus: "SOL-BELT-1", status: .needsAttention))
        #expect(halted == "halted, last SOL-BELT-1 — carrier SC1")
        #expect(!halted.contains("installing"))
    }
}

@Suite("The per-mine health line")
struct BrainWhyMineHealthTests {
    @Test("a fully healthy mine reads running, with no issues named")
    func aHealthyMineReadsRunning() {
        let health = BrainMineHealth(belt: "SOL-BELT-1", miningActive: true, surveyActive: true, ferryInForce: true)
        let row = BrainWhy.mineHealthLine(health)
        #expect(row.kind == .running)
        #expect(row.text == "mining, surveying and ferrying SOL-BELT-1")
    }

    /// The card-phrasing rule: `kind` alone carries "halted" — the spans state
    /// only the static fact, never restating the status as an active verb.
    @Test("a lapsed mining directive is halted and names exactly that")
    func aLapsedMiningDirectiveIsHalted() {
        let health = BrainMineHealth(belt: "SOL-BELT-1", miningActive: false, surveyActive: true, ferryInForce: true)
        let row = BrainWhy.mineHealthLine(health)
        #expect(row.kind == .halted)
        #expect(row.text == "mining directive inactive at SOL-BELT-1")
        #expect(!row.text.contains("halted"))
    }

    @Test("a belt with no ferry names that fact by itself")
    func aBeltWithNoFerryNamesThatFact() {
        let health = BrainMineHealth(belt: "SOL-BELT-1", miningActive: true, surveyActive: true, ferryInForce: false)
        let row = BrainWhy.mineHealthLine(health)
        #expect(row.kind == .halted)
        #expect(row.text == "no ferry in force at SOL-BELT-1")
    }

    @Test("designations render in the mono token")
    func designationsAreTagged() {
        let health = BrainMineHealth(belt: "SOL-BELT-1", miningActive: true, surveyActive: true, ferryInForce: true)
        #expect(BrainWhy.mineHealthLine(health).spans.contains { $0 == .designation("SOL-BELT-1") })
    }
}

/// A second, independent axis from `mineHealth`: present only while this
/// tick's siting ranked belts on an incomplete catalog. One test kills a
/// hard-coded-nil mutant, the other an always-renders one.
@Suite("The mine demand-degraded note")
struct BrainWhyMineDemandNoteTests {
    @Test("the note renders when this tick's siting ran on an incomplete catalog")
    func theNoteRendersWhenDemandIsIncomplete() {
        let why = BrainWhy.from(
            report: report(salvage: .idle(reason: "none"), haul: .idle(reason: "none"), mineDemandIncomplete: true)
        )
        #expect(
            why.mineDemandNote?.text
                == "mine siting incomplete — blueprint catalog empty, demand under-counted"
        )
    }

    @Test("the note is absent on the ordinary path")
    func theNoteIsAbsentOtherwise() {
        let why = BrainWhy.from(report: report(salvage: .idle(reason: "none"), haul: .idle(reason: "none")))
        #expect(why.mineDemandNote == nil)
    }
}
