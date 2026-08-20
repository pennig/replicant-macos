//
//  BotRosterTests.swift
//  Replicould — DirectiveEngine
//
//  The service-bot roster: who the run put out, and therefore who it may not
//  leave without. Every other bot query is scoped to a location, and both
//  scopes go blind at the moment that matters — a bot mid-hop has no location,
//  a bot left behind has one in a system the run has quit. Contract and the
//  incident behind it: `.claude/memory/bot-roster-departure-gate.md`.
//

import Foundation
import GameModels
import GameServices
import Testing
import Utils
@testable import DirectiveEngine

private let salvageTag = "auto:salvage"
private let rosterVessel = repairDevice("VESSEL", type: "heaven_vessel", location: "TOSLIT-3")
/// Past `probeDelay`, nowhere near `recallDeadline`, so a hold reads as a hold.
private let midStep = repairFixtureNow.addingTimeInterval(-60)

private func rosterDirective(
    step: String,
    botCodes: [String] = [],
    stepStartedAt: Date = midStep,
    deviceCode: String = "VESSEL"
) -> Directive {
    repairDirective(
        step: step, deviceCode: deviceCode, targets: ["TOSLIT"],
        stepStartedAt: stepStartedAt, kind: .salvageRun,
        fleetTag: salvageTag, botCodes: botCodes
    )
}

private func rosterBot(
    _ code: String,
    location: String? = "TOSLIT-3",
    stowedIn: String? = nil,
    tags: [String] = [salvageTag],
    updatedAt: Date = repairFixtureNow
) -> Device {
    repairDevice(
        code, type: "service_bot", location: location, stowedIn: stowedIn,
        directives: ["patrol", "service"], currentDirective: "service",
        currentDirectiveStatus: "active", tags: tags, updatedAt: updatedAt
    )
}

// MARK: - Enrolment

@Suite struct BotRosterEnrolmentTests {
    /// Enrolment happens before the first deploy, not after it lands: a deploy
    /// that half-succeeds still put a bot outside the hull.
    @Test func theDeployLegEnrolsTheBotsItIsAboutToPutOut() {
        let w = repairWorld(devices: [
            rosterVessel,
            rosterBot("BOT1", location: nil, stowedIn: "VESSEL"),
            rosterBot("BOT2", location: nil, stowedIn: "VESSEL"),
        ])
        let d = rosterDirective(step: SalvageRun.Step.deployingBots.rawValue)
        #expect(SalvageRun().nextAction(directive: d, world: w) == .enrolBots(
            deviceCodes: ["BOT1", "BOT2"],
            nextStep: SalvageRun.Step.deployingBots.rawValue
        ))
    }

    /// Enrolment must settle, or the deploy leg never reaches a dispatch.
    @Test func anAlreadyEnrolledFleetDeploysWithoutReEnrolling() {
        let w = repairWorld(devices: [
            rosterVessel,
            rosterBot("BOT1", location: nil, stowedIn: "VESSEL"),
            rosterBot("BOT2", location: nil, stowedIn: "VESSEL"),
        ])
        let d = rosterDirective(
            step: SalvageRun.Step.deployingBots.rawValue, botCodes: ["BOT1", "BOT2"]
        )
        #expect(SalvageRun().nextAction(directive: d, world: w) == .dispatch(
            kind: .simple("deploy"), deviceCode: "BOT1", params: CommandParams(),
            nextStep: SalvageRun.Step.confirmingBotDeploy.rawValue
        ))
    }

    /// Enrolment adds; rewriting the roster to "whatever is aboard right now"
    /// would drop precisely the bot that is lost.
    @Test func enrolmentAddsToTheRosterRatherThanReplacingIt() {
        let w = repairWorld(devices: [
            rosterVessel,
            rosterBot("BOT1", location: nil, stowedIn: "VESSEL"),
        ])
        let d = rosterDirective(
            step: SalvageRun.Step.deployingBots.rawValue, botCodes: ["STRANDED"]
        )
        #expect(SalvageRun().nextAction(directive: d, world: w) == .enrolBots(
            deviceCodes: ["STRANDED", "BOT1"],
            nextStep: SalvageRun.Step.deployingBots.rawValue
        ))
    }
}

// MARK: - The departure gate

@Suite struct BotRosterDepartureTests {
    /// A bot cruising on its own `service` directive carries no location and
    /// opens no operation, so both halves of `RepairFleet.botsOut` miss it.
    @Test func aBotMidHopWithNoOpenOperationHoldsTheDeparture() {
        let w = repairWorld(devices: [
            rosterVessel,
            rosterBot("BOT1", location: nil, stowedIn: nil),
            rosterBot("BOT2", location: nil, stowedIn: "VESSEL"),
        ])
        let d = rosterDirective(
            step: SalvageRun.Step.confirmingBotStow.rawValue, botCodes: ["BOT1", "BOT2"]
        )
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .advanceStep(nextStep: SalvageRun.Step.stowingBots.rawValue))
    }

    /// Kept separate so a change to which step the hold routes through cannot
    /// quietly turn the hold back into a departure.
    @Test func aBotMidHopNeverAdvancesTheTarget() {
        let w = repairWorld(devices: [
            rosterVessel,
            rosterBot("BOT1", location: nil, stowedIn: nil),
            rosterBot("BOT2", location: nil, stowedIn: "VESSEL"),
        ])
        let d = rosterDirective(
            step: SalvageRun.Step.confirmingBotStow.rawValue, botCodes: ["BOT1", "BOT2"]
        )
        #expect(SalvageRun().nextAction(directive: d, world: w) != .advanceTarget)
    }

    /// A bot in a system the vessel has left is unreachable by any recall the
    /// run can send, so it is an operator problem and must be said out loud.
    @Test func aBotLeftInAPreviousSystemStallsRatherThanVanishing() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "DUBUHE-7-41")
        let w = repairWorld(devices: [
            vessel,
            rosterBot("BOT1", location: "AMIRAM-1-7"),
            rosterBot("BOT2", location: nil, stowedIn: "VESSEL"),
        ])
        let d = rosterDirective(
            step: SalvageRun.Step.confirmingBotStow.rawValue, botCodes: ["BOT1", "BOT2"]
        )
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .stall(.serviceBotStranded, detail: "BOT1 at AMIRAM-1-7"))
    }

    /// A strand is NOT `serviceBotNotRecovered`: that one's guidance offers Skip,
    /// and skipping bypasses `stowingBots`, which is how bots get abandoned.
    @Test func aStrandIsNotTheOrdinaryRecallFailure() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "DUBUHE-7-41")
        let w = repairWorld(devices: [vessel, rosterBot("BOT1", location: "AMIRAM-1-7")])
        let d = rosterDirective(
            step: SalvageRun.Step.confirmingBotStow.rawValue, botCodes: ["BOT1"]
        )
        #expect(SalvageRun().nextAction(directive: d, world: w)
            != .stall(.serviceBotNotRecovered, detail: "BOT1 at AMIRAM-1-7"))
    }

    /// The brain drives only retry/cancel, and a retry cannot reach a bot in a
    /// system the vessel has left — so this must escalate to the operator.
    @Test func aStrandEscalatesRatherThanBeingRetriedByTheBrain() {
        #expect(DirectiveAttentionReason.serviceBotStranded.brainDisposition == .escalate)
    }

    /// The roster is a gate, not a brake: everyone home means the run leaves.
    @Test func aFullyStowedRosterLetsTheRunLeave() {
        let w = repairWorld(devices: [
            rosterVessel,
            rosterBot("BOT1", location: nil, stowedIn: "VESSEL"),
            rosterBot("BOT2", location: nil, stowedIn: "VESSEL"),
        ])
        let d = rosterDirective(
            step: SalvageRun.Step.confirmingBotStow.rawValue, botCodes: ["BOT1", "BOT2"]
        )
        #expect(SalvageRun().nextAction(directive: d, world: w) == .advanceTarget)
    }

    /// The ordinary case still gets an ordinary recall.
    @Test func aRosterMemberStillInSystemIsRecalled() {
        let w = repairWorld(devices: [rosterVessel, rosterBot("BOT1")])
        let d = rosterDirective(
            step: SalvageRun.Step.stowingBots.rawValue, botCodes: ["BOT1"]
        )
        #expect(SalvageRun().nextAction(directive: d, world: w) == .dispatch(
            kind: .simple("recall"), deviceCode: "BOT1", params: CommandParams(),
            nextStep: SalvageRun.Step.confirmingBotStow.rawValue
        ))
    }

    /// The roster ADDS to the location query. A bot an operator deployed by
    /// hand is enrolled nowhere, and must still be recalled.
    @Test func anUnenrolledBotDeployedInSystemIsStillRecalled() {
        let w = repairWorld(devices: [rosterVessel, rosterBot("BOT9")])
        let d = rosterDirective(step: SalvageRun.Step.stowingBots.rawValue, botCodes: [])
        #expect(SalvageRun().nextAction(directive: d, world: w) == .dispatch(
            kind: .simple("recall"), deviceCode: "BOT9", params: CommandParams(),
            nextStep: SalvageRun.Step.confirmingBotStow.rawValue
        ))
    }
}

// MARK: - The sibling engine

@Suite struct SurveyRunBotRosterTests {
    /// `BotPhase` is one copy serving both runs. Untagged bots and a nil
    /// `fleetTag`, because `RepairFleet.answers` rejects a fleet-tagged bot
    /// when there is no owner to match it against.
    @Test func theSurveyRunAlsoHoldsForABotMidHop() {
        let vessel = repairDevice("SVESSEL", type: "survey_vessel", location: "TOSLIT-3")
        let w = repairWorld(devices: [
            vessel,
            rosterBot("SBOT1", location: nil, stowedIn: nil, tags: []),
            rosterBot("SBOT2", location: nil, stowedIn: "SVESSEL", tags: []),
        ])
        let d = repairDirective(
            step: SurveyRun.Step.confirmingBotStow.rawValue, deviceCode: "SVESSEL",
            targets: ["TOSLIT"], stepStartedAt: midStep, kind: .surveyRun,
            botCodes: ["SBOT1", "SBOT2"]
        )
        #expect(SurveyRun().nextAction(directive: d, world: w)
            == .advanceStep(nextStep: SurveyRun.Step.stowingBots.rawValue))
    }
}
