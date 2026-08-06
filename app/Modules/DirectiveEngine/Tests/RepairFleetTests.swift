import Foundation
import GameModels
import Testing
import Utils
@testable import DirectiveEngine

@Suite struct RepairFleetTests {
    @Test func botsAboardAreServiceOfferingDevicesStowedInTheVessel() {
        let bot = device("BOT1", type: "service_bot", stowedIn: "VESSEL", directives: ["patrol", "service"])
        let drone = device("DRONE1", type: "survey_drone", stowedIn: "VESSEL")
        let elsewhere = device("BOT2", type: "service_bot", stowedIn: "OTHER", directives: ["service"])
        let vessel = device("VESSEL", type: "heaven_vessel")
        let w = world(devices: [vessel, bot, drone, elsewhere])
        #expect(RepairFleet.bots(aboard: vessel, in: w).map(\.deviceCode) == ["BOT1"])
    }

    @Test func botsDeployedAtALocationExcludeStowedOnes() {
        let deployed = device("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
        let stowed = device("BOT2", type: "service_bot", location: nil, stowedIn: "VESSEL", directives: ["service"])
        let w = world(devices: [deployed, stowed])
        #expect(RepairFleet.bots(deployedAt: "SOL-3", in: w).map(\.deviceCode) == ["BOT1"])
    }

    @Test func aBotWithARepairBlockIsRepairing() {
        var bot = device("BOT1", type: "service_bot", directives: ["service"])
        bot.detail = .object(["repair": .object(["target_device_code": .string("DRONE1")])])
        #expect(RepairFleet.isRepairing(bot))
    }

    @Test func aBotWithNoRepairBlockIsIdle() {
        let bot = device("BOT1", type: "service_bot", directives: ["service"])
        #expect(!RepairFleet.isRepairing(bot))
    }

    @Test func anyDeviceUnderFiftyNeedsRepair() {
        let hurt = device("D1", type: "survey_drone", capacity: 49)
        let fine = device("D2", type: "survey_drone", capacity: 50)
        #expect(RepairFleet.needsRepair([hurt, fine]))
        #expect(!RepairFleet.needsRepair([fine]))
    }

    @Test func exactlyFiftyIsNotBelowTheThreshold() {
        #expect(!RepairFleet.needsRepair([device("D1", type: "survey_drone", capacity: 50)]))
    }

    @Test func theFleetIsTheDeployedBotsPlusWhateverIsAboard() {
        let vessel = device("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let bot = device("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
        let drone = device("DRONE1", type: "survey_drone", location: nil, stowedIn: "VESSEL")
        let stranger = device("OTHER", type: "survey_drone", location: "SOL-3")
        let w = world(devices: [vessel, bot, drone, stranger])
        #expect(RepairFleet.fleet(of: vessel, in: w).map(\.deviceCode) == ["BOT1", "DRONE1"])
    }
}
