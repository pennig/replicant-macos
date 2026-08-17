//
//  SalvageRunBotBoundTests.swift
//  Replicould — DirectiveEngine
//
//  What bounds the Salvage Run's bot loops: the confirm deadlines, the reads
//  each conclusion has to buy before it is believed, and the branches taken
//  when the vessel's own position is unknown.
//

import Foundation
import GameModels
import GameServices
import Testing
import Utils
@testable import DirectiveEngine

private let salvageTag = "auto:salvage"
private let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "TOSLIT-3")
private let long = repairFixtureNow.addingTimeInterval(-60)

private func boundDirective(step: String, stepStartedAt: Date) -> Directive {
    repairDirective(
        step: step, deviceCode: "VESSEL", targets: ["TOSLIT"],
        stepStartedAt: stepStartedAt, kind: .salvageRun
    )
}

private func boundBot(
    _ code: String,
    location: String? = "TOSLIT-3",
    stowedIn: String? = nil,
    currentDirectiveStatus: String? = "active",
    updatedAt: Date = repairFixtureNow
) -> Device {
    repairDevice(
        code, type: "service_bot", location: location, stowedIn: stowedIn,
        directives: ["patrol", "service"], currentDirective: "service",
        currentDirectiveStatus: currentDirectiveStatus, tags: [salvageTag], updatedAt: updatedAt
    )
}

// MARK: - The confirm loops terminate

@Suite struct SalvageRunBotConfirmBoundTests {
    /// A bot row that never refreshes must not buy a `.high` read every tick
    /// forever: past the deadline the run gives up the repair and mines on.
    @Test func aDeployThatNeverConfirmsGivesUpTheRepairRatherThanReadingForever() {
        let stale = boundBot(
            "BOT1", location: nil, stowedIn: "VESSEL",
            updatedAt: repairFixtureNow.addingTimeInterval(-9_000)
        )
        let w = repairWorld(devices: [vessel, stale])
        let d = boundDirective(
            step: SalvageRun.Step.confirmingBotDeploy.rawValue,
            stepStartedAt: repairFixtureNow.addingTimeInterval(-(SalvageRun.botConfirmDeadline + 60))
        )
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .advanceStep(nextStep: SalvageRun.Step.armingBots.rawValue))
    }

    /// The same bound on the arm side, but loud: a bot that never confirms armed
    /// repairs nothing, and reading that as "nothing to repair" is the silent
    /// failure the arm pair exists to close.
    @Test func anArmThatNeverConfirmsStallsRatherThanReadingForever() {
        let stale = boundBot(
            "BOT1", currentDirectiveStatus: "paused",
            updatedAt: repairFixtureNow.addingTimeInterval(-9_000)
        )
        let w = repairWorld(devices: [vessel, stale])
        let d = boundDirective(
            step: SalvageRun.Step.confirmingBotArm.rawValue,
            stepStartedAt: repairFixtureNow.addingTimeInterval(-(SalvageRun.botConfirmDeadline + 60))
        )
        #expect(SalvageRun().nextAction(directive: d, world: w) == .stall(.serviceBotNotArmed))
    }

    /// The deadline is checked BEFORE the staleness guard: a failing read never
    /// advances `updatedAt`, so the other order can never reach the escape.
    @Test func theDeadlineIsReachedEvenWhileTheRowsStayStale() {
        let stale = boundBot("BOT1", updatedAt: repairFixtureNow.addingTimeInterval(-9_000))
        let w = repairWorld(devices: [vessel, stale])
        let d = boundDirective(
            step: SalvageRun.Step.confirmingBotArm.rawValue,
            stepStartedAt: repairFixtureNow.addingTimeInterval(-(SalvageRun.botConfirmDeadline + 60))
        )
        #expect(SalvageRun().nextAction(directive: d, world: w)
            != .refreshDevices(deviceCodes: ["BOT1"], thenStall: nil))
    }
}

// MARK: - Nothing is judged off a row read before the command

@Suite struct SalvageRunBotFreshnessTests {
    /// The deployed rows are what `armingBots` judges, and nothing has read them
    /// since the deploy was ordered — so the hand-off buys that read.
    @Test func theDeployedRowsAreReadBeforeArmingJudgesThem() {
        let deployed = boundBot("BOT1", updatedAt: repairFixtureNow.addingTimeInterval(-600))
        let w = repairWorld(devices: [vessel, deployed])
        let d = boundDirective(step: SalvageRun.Step.confirmingBotDeploy.rawValue, stepStartedAt: long)
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .refreshDevices(deviceCodes: ["BOT1"], thenStall: nil))
    }

    /// "Everything is armed" is the conclusion that skips repair entirely, so it
    /// may not rest on a row nobody has read since the arm was ordered.
    @Test func allArmedIsNotConcludedFromAnUnreadRow() {
        let stale = boundBot("BOT1", updatedAt: repairFixtureNow.addingTimeInterval(-600))
        let w = repairWorld(devices: [vessel, stale])
        let d = boundDirective(step: SalvageRun.Step.confirmingBotArm.rawValue, stepStartedAt: long)
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .refreshDevices(deviceCodes: ["BOT1"], thenStall: nil))
    }

    /// Read once, then judge: a row post-dating the arm is believed without a
    /// second read.
    @Test func aFreshlyReadArmedRowNeedsNoSecondRead() {
        let w = repairWorld(devices: [vessel, boundBot("BOT1")])
        let d = boundDirective(step: SalvageRun.Step.confirmingBotArm.rawValue, stepStartedAt: long)
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .advanceStep(nextStep: SalvageRun.Step.positioning.rawValue))
    }
}

// MARK: - A vessel whose own position is unknown

@Suite struct SalvageRunBotUnknownPositionTests {
    /// A nil vessel location cannot answer the system-scoped query. With a bot
    /// of this fleet still out, that is uncertainty — never clearance to leave.
    @Test func anUnplaceableVesselDoesNotAdvanceOverADeployedBot() {
        let adrift = repairDevice("VESSEL", type: "heaven_vessel", location: nil)
        let w = repairWorld(devices: [adrift, boundBot("BOT1")])
        let d = boundDirective(step: SalvageRun.Step.stowingBots.rawValue, stepStartedAt: long)
        #expect(SalvageRun().nextAction(directive: d, world: w) == .wait)
    }

    /// Waiting is the throttled answer; once the vessel row is old enough the
    /// step buys the read that would place it.
    @Test func anUnplaceableVesselBuysAReadOnceItsOwnRowIsStale() {
        let adrift = repairDevice(
            "VESSEL", type: "heaven_vessel", location: nil,
            updatedAt: repairFixtureNow.addingTimeInterval(-600)
        )
        let w = repairWorld(devices: [adrift, boundBot("BOT1")])
        let d = boundDirective(step: SalvageRun.Step.stowingBots.rawValue, stepStartedAt: long)
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .refreshDevices(deviceCodes: ["VESSEL"], thenStall: nil))
    }

    @Test func anUnplaceableVesselWithEveryBotHomeAdvances() {
        let adrift = repairDevice("VESSEL", type: "heaven_vessel", location: nil)
        let home = boundBot("BOT1", location: nil, stowedIn: "VESSEL")
        let w = repairWorld(devices: [adrift, home])
        let d = boundDirective(step: SalvageRun.Step.stowingBots.rawValue, stepStartedAt: long)
        #expect(SalvageRun().nextAction(directive: d, world: w) == .advanceTarget)
    }

    @Test func anUnplaceableVesselStallsOnceTheRecallDeadlinePasses() {
        let adrift = repairDevice("VESSEL", type: "heaven_vessel", location: nil)
        let w = repairWorld(devices: [adrift, boundBot("BOT1")])
        let d = boundDirective(
            step: SalvageRun.Step.stowingBots.rawValue,
            stepStartedAt: repairFixtureNow.addingTimeInterval(-(SalvageRun.botRecallDeadline + 60))
        )
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .stall(.serviceBotNotRecovered))
    }

    @Test func anUnplaceableVesselHoldsTheRepairGateOverADeployedBot() {
        let adrift = repairDevice("VESSEL", type: "heaven_vessel", location: nil)
        let w = repairWorld(devices: [adrift, boundBot("BOT1")])
        let d = boundDirective(
            step: SalvageRun.Step.repairing.rawValue,
            stepStartedAt: repairFixtureNow.addingTimeInterval(-(SalvageRun.repairDeadline + 60))
        )
        #expect(SalvageRun().nextAction(directive: d, world: w) == .stall(.repairUnfinished))
    }

    /// Another fleet's bot out in the system is not this run's to wait on.
    @Test func anUnplaceableVesselIgnoresAnotherFleetsDeployedBot() {
        let adrift = repairDevice("VESSEL", type: "heaven_vessel", location: nil)
        let theirs = repairDevice(
            "BOT1", type: "service_bot", location: "TOSLIT-3",
            directives: ["patrol", "service"], currentDirective: "service",
            currentDirectiveStatus: "active", tags: ["auto:survey"]
        )
        let w = repairWorld(devices: [adrift, theirs])
        let d = boundDirective(step: SalvageRun.Step.stowingBots.rawValue, stepStartedAt: long)
        #expect(SalvageRun().nextAction(directive: d, world: w) == .advanceTarget)
    }
}
