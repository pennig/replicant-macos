//
//  SurveyRunBotArmTests.swift
//  Replicould — DirectiveEngine
//
//  Arming a just-deployed service bot: force the `service` directive active
//  rather than trust whatever it already carries, before the survey starts.
//

import Foundation
import GameModels
import GameServices
import Testing
import Utils
@testable import DirectiveEngine

@Suite struct SurveyRunBotArmTests {
    @Test func noBotDeployedAtArmingSkipsToConfiguring() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let w = repairWorld(devices: [vessel])
        let d = repairDirective(step: SurveyRun.Step.armingBots, deviceCode: "VESSEL")
        #expect(SurveyRun().nextAction(directive: d, world: w) == .advanceStep(nextStep: SurveyRun.Step.configuring))
    }

    /// The reported live defect, and the reason for two branches: a bot
    /// already reading `service` needs `activate`, never `set_directive` again
    /// — resending the name endlessly would never touch the paused status.
    @Test func aPausedServiceBotIsActivatedNotReDirected() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let bot = repairDevice(
            "BOT1", type: "service_bot", location: "SOL-3", directives: ["patrol", "service"],
            currentDirective: "service", currentDirectiveStatus: "paused"
        )
        let w = repairWorld(devices: [vessel, bot])
        let d = repairDirective(step: SurveyRun.Step.armingBots, deviceCode: "VESSEL")
        #expect(SurveyRun().nextAction(directive: d, world: w) == .dispatch(
            kind: OperationKind.simple("activate"), deviceCode: "BOT1",
            params: CommandParams(),
            nextStep: SurveyRun.Step.confirmingBotArm
        ))
    }

    /// `patrol` deactivates devices instead of hot-repairing them, so an
    /// active-but-wrong directive must never be trusted as armed.
    @Test func aBotLeftOnPatrolIsNeverInherited() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let bot = repairDevice(
            "BOT1", type: "service_bot", location: "SOL-3", directives: ["patrol", "service"],
            currentDirective: "patrol", currentDirectiveStatus: "active"
        )
        let w = repairWorld(devices: [vessel, bot])
        let d = repairDirective(step: SurveyRun.Step.armingBots, deviceCode: "VESSEL")
        #expect(SurveyRun().nextAction(directive: d, world: w) == .dispatch(
            kind: .setDirective, deviceCode: "BOT1",
            params: CommandParams(directive: "service"),
            nextStep: SurveyRun.Step.confirmingBotArm
        ))
    }

    /// The two facts are separate dispatches, name first: a bot on `patrol`
    /// gets renamed this round, then activated the round after — never both
    /// at once, since a mission returns exactly one action.
    @Test func aBotOnPatrolIsArmedInTwoRounds() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let onPatrol = repairDevice(
            "BOT1", type: "service_bot", location: "SOL-3", directives: ["patrol", "service"],
            currentDirective: "patrol", currentDirectiveStatus: "active"
        )
        let firstWorld = repairWorld(devices: [vessel, onPatrol])
        let firstAsk = repairDirective(step: SurveyRun.Step.armingBots, deviceCode: "VESSEL")
        #expect(SurveyRun().nextAction(directive: firstAsk, world: firstWorld) == .dispatch(
            kind: .setDirective, deviceCode: "BOT1",
            params: CommandParams(directive: "service"),
            nextStep: SurveyRun.Step.confirmingBotArm
        ))

        let renamed = repairDevice(
            "BOT1", type: "service_bot", location: "SOL-3", directives: ["patrol", "service"],
            currentDirective: "service", currentDirectiveStatus: "paused"
        )
        let secondWorld = repairWorld(devices: [vessel, renamed])
        let secondAsk = repairDirective(step: SurveyRun.Step.armingBots, deviceCode: "VESSEL")
        #expect(SurveyRun().nextAction(directive: secondAsk, world: secondWorld) == .dispatch(
            kind: OperationKind.simple("activate"), deviceCode: "BOT1",
            params: CommandParams(),
            nextStep: SurveyRun.Step.confirmingBotArm
        ))
    }

    @Test func anAlreadyArmedBotSkipsStraightToConfiguring() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let bot = repairDevice(
            "BOT1", type: "service_bot", location: "SOL-3", directives: ["service"],
            currentDirective: "service", currentDirectiveStatus: "active"
        )
        let w = repairWorld(devices: [vessel, bot])
        let d = repairDirective(step: SurveyRun.Step.armingBots, deviceCode: "VESSEL")
        #expect(SurveyRun().nextAction(directive: d, world: w) == .advanceStep(nextStep: SurveyRun.Step.configuring))
    }

    @Test func theSecondBotIsArmedAfterTheFirstLands() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let armed = repairDevice(
            "BOT1", type: "service_bot", location: "SOL-3", directives: ["service"],
            currentDirective: "service", currentDirectiveStatus: "active"
        )
        let unarmed = repairDevice(
            "BOT2", type: "service_bot", location: "SOL-3", directives: ["service"],
            currentDirective: "service", currentDirectiveStatus: "paused"
        )
        let w = repairWorld(devices: [vessel, armed, unarmed])
        let d = repairDirective(
            step: SurveyRun.Step.confirmingBotArm, deviceCode: "VESSEL",
            stepStartedAt: repairFixtureNow.addingTimeInterval(-60)
        )
        #expect(SurveyRun().nextAction(directive: d, world: w) == .advanceStep(nextStep: SurveyRun.Step.armingBots))
    }

    @Test func everyBotArmedAdvancesToConfiguring() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let a = repairDevice(
            "BOT1", type: "service_bot", location: "SOL-3", directives: ["service"],
            currentDirective: "service", currentDirectiveStatus: "active"
        )
        let b = repairDevice(
            "BOT2", type: "service_bot", location: "SOL-3", directives: ["service"],
            currentDirective: "service", currentDirectiveStatus: "active"
        )
        let w = repairWorld(devices: [vessel, a, b])
        let d = repairDirective(
            step: SurveyRun.Step.confirmingBotArm, deviceCode: "VESSEL",
            stepStartedAt: repairFixtureNow.addingTimeInterval(-60)
        )
        #expect(SurveyRun().nextAction(directive: d, world: w) == .advanceStep(nextStep: SurveyRun.Step.configuring))
    }

    @Test func aFreshlyOrderedArmIsNotJudgedYet() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let bot = repairDevice(
            "BOT1", type: "service_bot", location: "SOL-3", directives: ["service"],
            currentDirective: "service", currentDirectiveStatus: "paused"
        )
        let w = repairWorld(devices: [vessel, bot])
        let d = repairDirective(step: SurveyRun.Step.confirmingBotArm, deviceCode: "VESSEL", stepStartedAt: repairFixtureNow)
        #expect(SurveyRun().nextAction(directive: d, world: w) == .wait)
    }

    @Test func aStaleArmReadingRequestsARefresh() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let bot = repairDevice(
            "BOT1", type: "service_bot", location: "SOL-3", directives: ["service"],
            currentDirective: "service", currentDirectiveStatus: "paused",
            updatedAt: repairFixtureNow.addingTimeInterval(-120)
        )
        let w = repairWorld(devices: [vessel, bot])
        let d = repairDirective(
            step: SurveyRun.Step.confirmingBotArm, deviceCode: "VESSEL",
            stepStartedAt: repairFixtureNow.addingTimeInterval(-60)
        )
        #expect(SurveyRun().nextAction(directive: d, world: w) == .refreshDevices(deviceCodes: ["BOT1"], thenStall: nil))
    }

    /// The whole point of this fix: a bot that will not arm must surface a
    /// NAMED reason, never quietly proceed as though repair were happening.
    @Test func theArmLoopExhaustsAndStallsWithTheNamedReason() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let bot = repairDevice(
            "BOT1", type: "service_bot", location: "SOL-3", directives: ["service"],
            currentDirective: "service", currentDirectiveStatus: "paused"
        )
        let run = SurveyRun()
        var steps = [SurveyRun.Step.confirmingBotDeploy]
        var step = SurveyRun.Step.armingBots
        var action = MissionAction.wait
        for _ in 0..<(4 * SurveyRun.botDispatchRounds) {
            steps.append(step)
            let w = repairWorld(devices: [vessel, bot], log: repairStepLog(steps))
            let d = repairDirective(
                step: step, deviceCode: "VESSEL",
                stepStartedAt: repairFixtureNow.addingTimeInterval(-60)
            )
            action = run.nextAction(directive: d, world: w)
            if action == .stall(.serviceBotNotArmed) { break }
            step = Self.nextStep(after: action) ?? step
        }
        #expect(action == .stall(.serviceBotNotArmed))
    }

    private static func nextStep(after action: MissionAction) -> String? {
        switch action {
        case let .dispatch(_, _, _, next): next
        case let .advanceStep(next): next
        default: nil
        }
    }
}
