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

    @Test func everyBotDeployedAdvancesToConfiguring() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let a = repairDevice("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
        let b = repairDevice("BOT2", type: "service_bot", location: "SOL-3", directives: ["service"])
        let w = repairWorld(devices: [vessel, a, b])
        let d = repairDirective(
            step: SurveyRun.Step.confirmingBotDeploy, deviceCode: "VESSEL",
            stepStartedAt: repairFixtureNow.addingTimeInterval(-60)
        )
        #expect(SurveyRun().nextAction(directive: d, world: w) == .advanceStep(nextStep: SurveyRun.Step.configuring))
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
}
