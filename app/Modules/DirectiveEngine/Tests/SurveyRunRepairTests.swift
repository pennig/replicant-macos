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
        #expect(SurveyRun().nextAction(directive: d, world: w) == .stall(.serviceBotNotRecovered))
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

    /// A recall clears the bot's location for the whole cruise home, so the system
    /// reads empty and the run departs over a bot that is still on its way in.
    @Test func aRecallCruisingHomeIsWaitedOutThoughItClearedItsLocation() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "TAU-2")
        let bot = repairDevice(
            "BOT1", type: "service_bot", location: nil, directives: ["service"],
            travelArrival: repairFixtureNow.addingTimeInterval(120)
        )
        let open = STUCKOP_operation(
            entityCode: "BOT1", kind: "recall",
            completesAt: repairFixtureNow.addingTimeInterval(120)
        )
        let w = repairWorld(devices: [vessel, bot], openOperations: ["BOT1": open])
        let d = repairDirective(
            step: SurveyRun.Step.confirmingBotStow, deviceCode: "VESSEL", targets: ["TAU"],
            stepStartedAt: repairFixtureNow.addingTimeInterval(-60)
        )
        #expect(SurveyRun().nextAction(directive: d, world: w) == .wait)
    }

    @Test func stowingDoesNotAdvanceOverABotStillCruisingHome() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "TAU-2")
        let bot = repairDevice(
            "BOT1", type: "service_bot", location: nil, directives: ["service"],
            travelArrival: repairFixtureNow.addingTimeInterval(120)
        )
        let open = STUCKOP_operation(
            entityCode: "BOT1", kind: "recall",
            completesAt: repairFixtureNow.addingTimeInterval(120)
        )
        let w = repairWorld(devices: [vessel, bot], openOperations: ["BOT1": open])
        let d = repairDirective(step: SurveyRun.Step.stowingBots, deviceCode: "VESSEL", targets: ["TAU"])
        #expect(SurveyRun().nextAction(directive: d, world: w) == .wait)
    }

    /// Neither side of the query has a location: the vessel is under way and the
    /// bot is cruising in. The run must not read that as an empty system.
    @Test func aVesselUnderWayDoesNotAdvanceOverABotStillCruisingHome() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: nil)
        let bot = repairDevice(
            "BOT1", type: "service_bot", location: nil, directives: ["service"],
            travelArrival: repairFixtureNow.addingTimeInterval(120)
        )
        let open = STUCKOP_operation(
            entityCode: "BOT1", kind: "recall",
            completesAt: repairFixtureNow.addingTimeInterval(120)
        )
        let w = repairWorld(devices: [vessel, bot], openOperations: ["BOT1": open])
        let d = repairDirective(step: SurveyRun.Step.stowingBots, deviceCode: "VESSEL", targets: ["TAU"])
        #expect(SurveyRun().nextAction(directive: d, world: w) == .wait)
    }

    /// A stowed bot also carries no location, and must NOT read as one in transit.
    @Test func aStowedBotDoesNotHoldTheRunAtTheSystem() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "TAU-2")
        let bot = repairDevice(
            "BOT1", type: "service_bot", location: nil, stowedIn: "VESSEL", directives: ["service"]
        )
        let open = STUCKOP_operation(
            entityCode: "BOT1", kind: "recall",
            completesAt: repairFixtureNow.addingTimeInterval(120)
        )
        let w = repairWorld(devices: [vessel, bot], openOperations: ["BOT1": open])
        let d = repairDirective(step: SurveyRun.Step.stowingBots, deviceCode: "VESSEL", targets: ["TAU"])
        #expect(SurveyRun().nextAction(directive: d, world: w) == .advanceTarget)
    }

    @Test func anOpenRecallWithADeadlineIsNotRedispatched() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "TAU-2")
        let bot = repairDevice("BOT1", type: "service_bot", location: "TAU-9", directives: ["service"])
        let open = STUCKOP_operation(
            entityCode: "BOT1", kind: "recall",
            completesAt: repairFixtureNow.addingTimeInterval(120)
        )
        let w = repairWorld(devices: [vessel, bot], openOperations: ["BOT1": open])
        let d = repairDirective(step: SurveyRun.Step.stowingBots, deviceCode: "VESSEL", targets: ["TAU"])
        #expect(SurveyRun().nextAction(directive: d, world: w) == .wait)
    }

    @Test func anOpenRecallWithADeadlineStillStallsAtTheBackstop() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "TAU-2")
        let bot = repairDevice("BOT1", type: "service_bot", location: "TAU-9", directives: ["service"])
        let open = STUCKOP_operation(
            entityCode: "BOT1", kind: "recall",
            completesAt: repairFixtureNow.addingTimeInterval(120)
        )
        let w = repairWorld(devices: [vessel, bot], openOperations: ["BOT1": open])
        let past = repairFixtureNow.addingTimeInterval(-(SurveyRun.recallDeadline + 1))
        let d = repairDirective(step: SurveyRun.Step.stowingBots, deviceCode: "VESSEL", targets: ["TAU"], stepStartedAt: past)
        #expect(SurveyRun().nextAction(directive: d, world: w) == .stall(.serviceBotNotRecovered))
    }

    /// The live incident: a `recall` op written with no `completesAt` (the bot
    /// was already co-located, so the server's travel block never populated
    /// one) can never resolve. Waiting on it waits on nothing — dispatch again
    /// rather than stall silently for the full backstop.
    @Test func aRecallWithNoDeadlineIsRedispatchedRatherThanWaitedOn() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let bot = repairDevice("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
        let stuck = STUCKOP_operation(entityCode: "BOT1", kind: "recall", completesAt: nil)
        let w = repairWorld(devices: [vessel, bot], openOperations: ["BOT1": stuck])
        let d = repairDirective(step: SurveyRun.Step.stowingBots, deviceCode: "VESSEL")
        #expect(SurveyRun().nextAction(directive: d, world: w) == .dispatch(
            kind: .simple("recall"), deviceCode: "BOT1",
            params: CommandParams(),
            nextStep: SurveyRun.Step.confirmingBotStow
        ))
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
            if action == .stall(.serviceBotNotRecovered) { break }
            step = Self.nextStep(after: action) ?? step
        }
        #expect(action == .stall(.serviceBotNotRecovered))
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

    /// The live regression: the brain tags the survey bots `auto:survey`, and a
    /// run resolving no owner saw an empty fleet and silently never deployed.
    @Test func taggedBotsAboardStillDeployUnderTheDefaultFleetTag() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let bot = repairDevice(
            "BOT1", type: "service_bot", location: nil, stowedIn: "VESSEL",
            directives: ["service"], tags: ["auto:survey"]
        )
        let w = repairWorld(devices: [vessel, bot])
        let d = repairDirective(step: SurveyRun.Step.deployingBots, deviceCode: "VESSEL")
        #expect(SurveyRun().nextAction(directive: d, world: w) == .dispatch(
            kind: .simple("deploy"), deviceCode: "BOT1",
            params: CommandParams(),
            nextStep: SurveyRun.Step.confirmingBotDeploy
        ))
    }

    @Test func aTaggedWorkingBotStillHoldsTheVessel() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let bot = repairDevice(
            "BOT1", type: "service_bot", location: "SOL-3", directives: ["service"],
            tags: ["auto:survey"], repairingTarget: "DRONE1"
        )
        let drone = repairDevice("DRONE1", type: "survey_drone", location: nil, stowedIn: "VESSEL", capacity: 30)
        let w = repairWorld(devices: [vessel, bot, drone])
        let d = repairDirective(
            step: SurveyRun.Step.repairing, deviceCode: "VESSEL",
            stepStartedAt: repairFixtureNow.addingTimeInterval(-60)
        )
        #expect(SurveyRun().nextAction(directive: d, world: w) == .wait)
    }

    @Test func anExplicitFleetTagOverridesTheDefault() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let mine = repairDevice(
            "BOT1", type: "service_bot", location: nil, stowedIn: "VESSEL",
            directives: ["service"], tags: ["auto:survey:DENEBED-9"]
        )
        let theirs = repairDevice(
            "BOT2", type: "service_bot", location: nil, stowedIn: "VESSEL",
            directives: ["service"], tags: ["auto:survey:AINALRAM-1"]
        )
        let w = repairWorld(devices: [vessel, mine, theirs])
        let d = repairDirective(
            step: SurveyRun.Step.deployingBots, deviceCode: "VESSEL",
            fleetTag: "auto:survey:DENEBED-9"
        )
        #expect(SurveyRun().nextAction(directive: d, world: w) == .dispatch(
            kind: .simple("deploy"), deviceCode: "BOT1",
            params: CommandParams(),
            nextStep: SurveyRun.Step.confirmingBotDeploy
        ))
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
