//
//  SurveyRunRepairTests.swift
//  Replicould — DirectiveEngine
//
//  Deploying service bots on arrival: dispatch one at a time, confirm each
//  landed before ordering the next, advance once none are left aboard.
//

import Foundation
import GameModels
import GameServices
import Testing
import Utils
@testable import DirectiveEngine

@Suite struct SurveyRunRepairTests {
    @Test func arrivalWithNoBotAboardSkipsStraightToConfiguring() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let w = repairWorld(devices: [vessel])
        let d = repairDirective(step: SurveyRun.Step.deployingBots, deviceCode: "VESSEL")
        #expect(SurveyRun().nextAction(directive: d, world: w) == .advanceStep(nextStep: SurveyRun.Step.configuring))
    }

    @Test func arrivalDeploysTheFirstBotStillAboard() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let a = repairDevice("BOT1", type: "service_bot", location: nil, stowedIn: "VESSEL", directives: ["service"])
        let b = repairDevice("BOT2", type: "service_bot", location: nil, stowedIn: "VESSEL", directives: ["service"])
        let w = repairWorld(devices: [vessel, a, b])
        let d = repairDirective(step: SurveyRun.Step.deployingBots, deviceCode: "VESSEL")
        #expect(SurveyRun().nextAction(directive: d, world: w) == .dispatch(
            kind: .simple("deploy"), deviceCode: "BOT1",
            params: CommandParams(),
            nextStep: SurveyRun.Step.confirmingBotDeploy
        ))
    }

    @Test func theSecondBotIsDeployedAfterTheFirstLands() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let out = repairDevice("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
        let aboard = repairDevice("BOT2", type: "service_bot", location: nil, stowedIn: "VESSEL", directives: ["service"])
        let w = repairWorld(devices: [vessel, out, aboard])
        let d = repairDirective(
            step: SurveyRun.Step.confirmingBotDeploy, deviceCode: "VESSEL",
            stepStartedAt: repairFixtureNow.addingTimeInterval(-60)
        )
        #expect(SurveyRun().nextAction(directive: d, world: w) == .advanceStep(nextStep: SurveyRun.Step.deployingBots))
    }

    @Test func everyBotDeployedAdvancesToArming() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let a = repairDevice("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
        let b = repairDevice("BOT2", type: "service_bot", location: "SOL-3", directives: ["service"])
        let w = repairWorld(devices: [vessel, a, b])
        let d = repairDirective(
            step: SurveyRun.Step.confirmingBotDeploy, deviceCode: "VESSEL",
            stepStartedAt: repairFixtureNow.addingTimeInterval(-60)
        )
        #expect(SurveyRun().nextAction(directive: d, world: w) == .advanceStep(nextStep: SurveyRun.Step.armingBots))
    }

    @Test func aFreshlyOrderedDeployIsNotJudgedYet() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let aboard = repairDevice("BOT1", type: "service_bot", location: nil, stowedIn: "VESSEL", directives: ["service"])
        let w = repairWorld(devices: [vessel, aboard])
        let d = repairDirective(step: SurveyRun.Step.confirmingBotDeploy, deviceCode: "VESSEL", stepStartedAt: repairFixtureNow)
        #expect(SurveyRun().nextAction(directive: d, world: w) == .wait)
    }

    @Test func aHealthyFleetLeavesWithoutWaiting() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let bot = repairDevice("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
        let drone = repairDevice("DRONE1", type: "survey_drone", location: nil, stowedIn: "VESSEL", capacity: 100)
        let w = repairWorld(devices: [vessel, bot, drone])
        let d = repairDirective(step: SurveyRun.Step.repairing, deviceCode: "VESSEL", stepStartedAt: repairFixtureNow.addingTimeInterval(-60))
        #expect(SurveyRun().nextAction(directive: d, world: w) == .advanceStep(nextStep: SurveyRun.Step.stowingBots))
    }

    @Test func aWorkingBotHoldsTheVessel() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let bot = repairDevice("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"], repairingTarget: "DRONE1")
        let drone = repairDevice("DRONE1", type: "survey_drone", location: nil, stowedIn: "VESSEL", capacity: 30)
        let w = repairWorld(devices: [vessel, bot, drone])
        let d = repairDirective(step: SurveyRun.Step.repairing, deviceCode: "VESSEL", stepStartedAt: repairFixtureNow.addingTimeInterval(-60))
        #expect(SurveyRun().nextAction(directive: d, world: w) == .wait)
    }

    @Test func idleBotsReleaseTheVesselEvenWithADroneStillWorn() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let bot = repairDevice("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
        let drone = repairDevice("DRONE1", type: "survey_drone", location: nil, stowedIn: "VESSEL", capacity: 30)
        let w = repairWorld(devices: [vessel, bot, drone])
        let d = repairDirective(step: SurveyRun.Step.repairing, deviceCode: "VESSEL", stepStartedAt: repairFixtureNow.addingTimeInterval(-60))
        #expect(SurveyRun().nextAction(directive: d, world: w) == .advanceStep(nextStep: SurveyRun.Step.stowingBots))
    }

    @Test func noBotDeployedSkipsTheGate() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let drone = repairDevice("DRONE1", type: "survey_drone", location: nil, stowedIn: "VESSEL", capacity: 30)
        let w = repairWorld(devices: [vessel, drone])
        let d = repairDirective(step: SurveyRun.Step.repairing, deviceCode: "VESSEL", stepStartedAt: repairFixtureNow.addingTimeInterval(-60))
        #expect(SurveyRun().nextAction(directive: d, world: w) == .advanceStep(nextStep: SurveyRun.Step.stowingBots))
    }

    @Test func aBotStillWorkingAtTheDeadlineEscalates() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let bot = repairDevice("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"], repairingTarget: "DRONE1")
        let drone = repairDevice("DRONE1", type: "survey_drone", location: nil, stowedIn: "VESSEL", capacity: 30)
        let w = repairWorld(devices: [vessel, bot, drone])
        let past = repairFixtureNow.addingTimeInterval(-(SurveyRun.repairDeadline + 1))
        let d = repairDirective(step: SurveyRun.Step.repairing, deviceCode: "VESSEL", stepStartedAt: past)
        #expect(SurveyRun().nextAction(directive: d, world: w) == .stall(.repairUnfinished))
    }

    @Test func aStaleIdleReadingDoesNotReleaseTheVessel() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let bot = repairDevice(
            "BOT1", type: "service_bot", location: "SOL-3", directives: ["service"],
            updatedAt: repairFixtureNow.addingTimeInterval(-120)
        )
        let drone = repairDevice("DRONE1", type: "survey_drone", location: nil, stowedIn: "VESSEL", capacity: 30)
        let w = repairWorld(devices: [vessel, bot, drone])
        let d = repairDirective(step: SurveyRun.Step.repairing, deviceCode: "VESSEL", stepStartedAt: repairFixtureNow.addingTimeInterval(-60))
        #expect(SurveyRun().nextAction(directive: d, world: w) == .refreshDevices(deviceCodes: ["BOT1"], thenStall: nil))
    }

    @Test func departureRecallsTheFirstBotStillOut() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let bot = repairDevice("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
        let w = repairWorld(devices: [vessel, bot])
        let d = repairDirective(step: SurveyRun.Step.stowingBots, deviceCode: "VESSEL")
        #expect(SurveyRun().nextAction(directive: d, world: w) == .dispatch(
            kind: .simple("recall"), deviceCode: "BOT1",
            params: CommandParams(),
            nextStep: SurveyRun.Step.confirmingBotStow
        ))
    }

    @Test func everyBotAboardAdvancesTheTarget() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let bot = repairDevice("BOT1", type: "service_bot", location: nil, stowedIn: "VESSEL", directives: ["service"])
        let w = repairWorld(devices: [vessel, bot])
        let d = repairDirective(
            step: SurveyRun.Step.confirmingBotStow, deviceCode: "VESSEL",
            stepStartedAt: repairFixtureNow.addingTimeInterval(-60)
        )
        #expect(SurveyRun().nextAction(directive: d, world: w) == .advanceTarget)
    }

    @Test func aBotThatNeverStowsDoesNotStrandTheRun() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let bot = repairDevice("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"], updatedAt: repairFixtureNow)
        let w = repairWorld(devices: [vessel, bot])
        let past = repairFixtureNow.addingTimeInterval(-(SurveyRun.recallDeadline + 1))
        let d = repairDirective(step: SurveyRun.Step.confirmingBotStow, deviceCode: "VESSEL", stepStartedAt: past)
        #expect(SurveyRun().nextAction(directive: d, world: w) == .stall(.dronesNotRecovered))
    }

    @Test func anUnknownVesselLocationDoesNotAbandonBotsAtRepairing() {
        let vessel = repairDevice(
            "VESSEL", type: "heaven_vessel", location: nil,
            updatedAt: repairFixtureNow.addingTimeInterval(-40)
        )
        let bot = repairDevice("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
        let w = repairWorld(devices: [vessel, bot])
        let d = repairDirective(step: SurveyRun.Step.repairing, deviceCode: "VESSEL", stepStartedAt: repairFixtureNow)
        #expect(SurveyRun().nextAction(directive: d, world: w) == .refreshDevices(deviceCodes: ["VESSEL"], thenStall: nil))
    }

    @Test func anUnknownVesselLocationDoesNotAbandonBotsAtStowingBots() {
        let vessel = repairDevice(
            "VESSEL", type: "heaven_vessel", location: nil,
            updatedAt: repairFixtureNow.addingTimeInterval(-40)
        )
        let bot = repairDevice("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
        let w = repairWorld(devices: [vessel, bot])
        let d = repairDirective(step: SurveyRun.Step.stowingBots, deviceCode: "VESSEL")
        #expect(SurveyRun().nextAction(directive: d, world: w) == .refreshDevices(deviceCodes: ["VESSEL"], thenStall: nil))
    }

    @Test func anUnknownVesselLocationDoesNotAbandonBotsAtConfirmingBotStow() {
        let vessel = repairDevice(
            "VESSEL", type: "heaven_vessel", location: nil,
            updatedAt: repairFixtureNow.addingTimeInterval(-40)
        )
        let bot = repairDevice("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
        let w = repairWorld(devices: [vessel, bot])
        let d = repairDirective(
            step: SurveyRun.Step.confirmingBotStow, deviceCode: "VESSEL",
            stepStartedAt: repairFixtureNow.addingTimeInterval(-60)
        )
        #expect(SurveyRun().nextAction(directive: d, world: w) == .refreshDevices(deviceCodes: ["VESSEL"], thenStall: nil))
    }

    @Test func aBotCruisedAcrossTheSystemStillHoldsTheVessel() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "TAU-2")
        let bot = repairDevice(
            "BOT1", type: "service_bot", location: "TAU-9", directives: ["service"],
            repairingTarget: "DRONE1"
        )
        let drone = repairDevice("DRONE1", type: "survey_drone", location: nil, stowedIn: "VESSEL", capacity: 30)
        let w = repairWorld(devices: [vessel, bot, drone])
        let d = repairDirective(
            step: SurveyRun.Step.repairing, deviceCode: "VESSEL", targets: ["TAU"],
            stepStartedAt: repairFixtureNow.addingTimeInterval(-60)
        )
        #expect(SurveyRun().nextAction(directive: d, world: w) == .wait)
    }

    @Test func aBotCruisedAcrossTheSystemIsRecalledRatherThanAbandoned() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "TAU-2")
        let bot = repairDevice("BOT1", type: "service_bot", location: "TAU-9", directives: ["service"])
        let w = repairWorld(devices: [vessel, bot])
        let d = repairDirective(step: SurveyRun.Step.stowingBots, deviceCode: "VESSEL", targets: ["TAU"])
        #expect(SurveyRun().nextAction(directive: d, world: w) == .dispatch(
            kind: .simple("recall"), deviceCode: "BOT1",
            params: CommandParams(),
            nextStep: SurveyRun.Step.confirmingBotStow
        ))
    }

    @Test func confirmingARecallDoesNotDepartOverABotStillAcrossTheSystem() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "TAU-2")
        let bot = repairDevice("BOT1", type: "service_bot", location: "TAU-9", directives: ["service"])
        let w = repairWorld(devices: [vessel, bot])
        let d = repairDirective(
            step: SurveyRun.Step.confirmingBotStow, deviceCode: "VESSEL", targets: ["TAU"],
            stepStartedAt: repairFixtureNow.addingTimeInterval(-60)
        )
        #expect(SurveyRun().nextAction(directive: d, world: w) == .advanceStep(nextStep: SurveyRun.Step.stowingBots))
    }

    @Test func aRecallStillCruisingIsWaitedOutOnItsOwnArrivalTime() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "TAU-2")
        let bot = repairDevice(
            "BOT1", type: "service_bot", location: "TAU-9", directives: ["service"],
            travelArrival: repairFixtureNow.addingTimeInterval(120)
        )
        let w = repairWorld(devices: [vessel, bot])
        let d = repairDirective(
            step: SurveyRun.Step.confirmingBotStow, deviceCode: "VESSEL", targets: ["TAU"],
            stepStartedAt: repairFixtureNow.addingTimeInterval(-60)
        )
        #expect(SurveyRun().nextAction(directive: d, world: w) == .wait)
    }

    @Test func anOpenRecallIsNotRedispatched() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "TAU-2")
        let bot = repairDevice("BOT1", type: "service_bot", location: "TAU-9", directives: ["service"])
        let open = GameModels.Operation(
            id: "OP1", entityCode: "BOT1", kind: "recall", status: .active, source: .optimistic,
            startedAt: repairFixtureNow, completesAt: nil,
            lastConfirmedAt: repairFixtureNow, detail: .object([:])
        )
        let w = repairWorld(devices: [vessel, bot], openOperations: ["BOT1": open])
        let d = repairDirective(step: SurveyRun.Step.stowingBots, deviceCode: "VESSEL", targets: ["TAU"])
        #expect(SurveyRun().nextAction(directive: d, world: w) == .wait)
    }

    @Test func theDeployLoopGivesUpAndSurveysUnrepaired() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let bot = repairDevice("BOT1", type: "service_bot", location: nil, stowedIn: "VESSEL", directives: ["service"])
        let run = SurveyRun()
        var steps = [SurveyRun.Step.travelling]
        var step = SurveyRun.Step.deployingBots
        var action = MissionAction.wait
        for _ in 0..<(4 * SurveyRun.botDispatchRounds) {
            steps.append(step)
            let w = repairWorld(devices: [vessel, bot], log: repairStepLog(steps))
            let d = repairDirective(
                step: step, deviceCode: "VESSEL",
                stepStartedAt: repairFixtureNow.addingTimeInterval(-60)
            )
            action = run.nextAction(directive: d, world: w)
            step = Self.nextStep(after: action) ?? step
            if step == SurveyRun.Step.configuring { break }
        }
        #expect(action == .advanceStep(nextStep: SurveyRun.Step.configuring))
    }

    @Test func theRecallLoopGivesUpAndEscalates() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let bot = repairDevice("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
        let run = SurveyRun()
        var steps = [SurveyRun.Step.repairing]
        var step = SurveyRun.Step.stowingBots
        var action = MissionAction.wait
        for _ in 0..<(4 * SurveyRun.botDispatchRounds) {
            steps.append(step)
            let w = repairWorld(devices: [vessel, bot], log: repairStepLog(steps))
            let d = repairDirective(
                step: step, deviceCode: "VESSEL",
                stepStartedAt: repairFixtureNow.addingTimeInterval(-60)
            )
            action = run.nextAction(directive: d, world: w)
            if action == .stall(.dronesNotRecovered) { break }
            step = Self.nextStep(after: action) ?? step
        }
        #expect(action == .stall(.dronesNotRecovered))
    }

    @Test func aBotlessFleetWithAnUnknownLocationAdvancesRatherThanStalling() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: nil)
        let drone = repairDevice("DRONE1", type: "survey_drone", location: nil, stowedIn: "VESSEL", capacity: 30)
        let w = repairWorld(devices: [vessel, drone])
        let run = SurveyRun()
        let repair = repairDirective(step: SurveyRun.Step.repairing, deviceCode: "VESSEL", targets: ["TAU"])
        #expect(run.nextAction(directive: repair, world: w) == .advanceStep(nextStep: SurveyRun.Step.stowingBots))
        let stow = repairDirective(step: SurveyRun.Step.stowingBots, deviceCode: "VESSEL", targets: ["TAU"])
        #expect(run.nextAction(directive: stow, world: w) == .advanceTarget)
        let confirm = repairDirective(
            step: SurveyRun.Step.confirmingBotStow, deviceCode: "VESSEL", targets: ["TAU"],
            stepStartedAt: repairFixtureNow.addingTimeInterval(-60)
        )
        #expect(run.nextAction(directive: confirm, world: w) == .advanceTarget)
    }

    private static func nextStep(after action: MissionAction) -> String? {
        switch action {
        case let .dispatch(_, _, _, next): next
        case let .advanceStep(next): next
        default: nil
        }
    }

    @Test func aRunWithNoBotsWalksTheOriginalPath() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let w = repairWorld(devices: [vessel])
        let run = SurveyRun()
        let deploy = repairDirective(step: SurveyRun.Step.deployingBots, deviceCode: "VESSEL")
        #expect(run.nextAction(directive: deploy, world: w) == .advanceStep(nextStep: SurveyRun.Step.configuring))
        let repair = repairDirective(
            step: SurveyRun.Step.repairing, deviceCode: "VESSEL",
            stepStartedAt: repairFixtureNow.addingTimeInterval(-60)
        )
        #expect(run.nextAction(directive: repair, world: w) == .advanceStep(nextStep: SurveyRun.Step.stowingBots))
        let stow = repairDirective(step: SurveyRun.Step.stowingBots, deviceCode: "VESSEL")
        #expect(run.nextAction(directive: stow, world: w) == .advanceTarget)
    }
}
