import Foundation
import GameModels
import Testing
import Utils
@testable import DirectiveEngine

@Suite struct RepairFleetTests {
    @Test func botsAboardAreServiceOfferingDevicesStowedInTheVessel() {
        let bot = repairDevice("BOT1", type: "service_bot", stowedIn: "VESSEL", directives: ["patrol", "service"])
        let drone = repairDevice("DRONE1", type: "survey_drone", stowedIn: "VESSEL")
        let elsewhere = repairDevice("BOT2", type: "service_bot", stowedIn: "OTHER", directives: ["service"])
        let vessel = repairDevice("VESSEL", type: "heaven_vessel")
        let w = repairWorld(devices: [vessel, bot, drone, elsewhere])
        #expect(RepairFleet.bots(aboard: vessel, in: w).map(\.deviceCode) == ["BOT1"])
    }

    @Test func botsDeployedNearALocationExcludeStowedOnes() {
        let deployed = repairDevice("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
        let stowed = repairDevice("BOT2", type: "service_bot", location: nil, stowedIn: "VESSEL", directives: ["service"])
        let w = repairWorld(devices: [deployed, stowed])
        #expect(RepairFleet.bots(deployedNear: "SOL-3", in: w).map(\.deviceCode) == ["BOT1"])
    }

    @Test func botsDeployedNearALocationSpanTheWholeSystem() {
        let here = repairDevice("BOT1", type: "service_bot", location: "TAU-2", directives: ["service"])
        let cruised = repairDevice("BOT2", type: "service_bot", location: "TAU-9", directives: ["service"])
        let away = repairDevice("BOT3", type: "service_bot", location: "SOL-3", directives: ["service"])
        let w = repairWorld(devices: [here, cruised, away])
        #expect(RepairFleet.bots(deployedNear: "TAU-2", in: w).map(\.deviceCode) == ["BOT1", "BOT2"])
    }

    @Test func anyBotDeployedIgnoresAnotherSystemsBotWhenTheSystemIsKnown() {
        let away = repairDevice("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
        let w = repairWorld(devices: [away])
        #expect(RepairFleet.anyBotDeployed(in: w, system: nil))
        #expect(!RepairFleet.anyBotDeployed(in: w, system: "TAU"))
    }

    @Test func anyBotDeployedIsFalseForAFleetCarryingNone() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let drone = repairDevice("DRONE1", type: "survey_drone", location: nil, stowedIn: "VESSEL")
        #expect(!RepairFleet.anyBotDeployed(in: repairWorld(devices: [vessel, drone]), system: nil))
    }

    @Test func aBotWithARepairBlockIsRepairing() {
        var bot = repairDevice("BOT1", type: "service_bot", directives: ["service"])
        bot.detail = .object(["repair": .object(["target_device_code": .string("DRONE1")])])
        #expect(RepairFleet.isRepairing(bot))
    }

    @Test func aBotWithNoRepairBlockIsIdle() {
        let bot = repairDevice("BOT1", type: "service_bot", directives: ["service"])
        #expect(!RepairFleet.isRepairing(bot))
    }

    @Test func anyDeviceUnderFiftyNeedsRepair() {
        let hurt = repairDevice("D1", type: "survey_drone", capacity: 49)
        let fine = repairDevice("D2", type: "survey_drone", capacity: 50)
        #expect(RepairFleet.needsRepair([hurt, fine]))
        #expect(!RepairFleet.needsRepair([fine]))
    }

    @Test func exactlyFiftyIsNotBelowTheThreshold() {
        #expect(!RepairFleet.needsRepair([repairDevice("D1", type: "survey_drone", capacity: 50)]))
    }

    @Test func theFleetIsTheDeployedBotsPlusWhateverIsAboard() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let bot = repairDevice("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
        let drone = repairDevice("DRONE1", type: "survey_drone", location: nil, stowedIn: "VESSEL")
        let stranger = repairDevice("OTHER", type: "survey_drone", location: "SOL-3")
        let w = repairWorld(devices: [vessel, bot, drone, stranger])
        #expect(RepairFleet.fleet(of: vessel, in: w).map(\.deviceCode) == ["BOT1", "DRONE1"])
    }
}
