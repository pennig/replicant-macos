//
//  RepairFleetOwnershipTests.swift
//  Replicould — DirectiveEngine
//
//  The whole truth table for `RepairFleet.answers(_:to:)`, the predicate that
//  keeps two bot-carrying fleets from recalling each other's service bots.
//

import Foundation
import GameModels
import Testing
import Utils
@testable import DirectiveEngine

private func taggedBot(_ code: String, _ tags: [String]) -> Device {
    repairDevice(
        code, type: "service_bot", location: "SOL-3", directives: ["service"], tags: tags
    )
}

@Suite struct RepairFleetOwnershipTests {
    @Test func anUntaggedBotAnswersToEveryOwner() {
        let bot = taggedBot("BOT1", [])
        #expect(RepairFleet.answers(bot, to: nil))
        #expect(RepairFleet.answers(bot, to: "auto:salvage"))
        #expect(RepairFleet.answers(bot, to: "auto:survey"))
    }

    @Test func aTaggedBotAnswersOnlyToItsOwnFleet() {
        let bot = taggedBot("BOT1", ["auto:salvage"])
        #expect(RepairFleet.answers(bot, to: "auto:salvage"))
        #expect(!RepairFleet.answers(bot, to: "auto:survey"))
    }

    /// A run that names no fleet claims unowned bots only — which is what leaves
    /// the shipped Survey Run and its untagged pair working unchanged.
    @Test func aTaggedBotAnswersToNoOwnerAtAll() {
        #expect(!RepairFleet.answers(taggedBot("BOT1", ["auto:salvage"]), to: nil))
    }

    /// Ownership reads `auto:` tags alone: an operator's own labels must not
    /// make a bot look like somebody else's.
    @Test func aNonFleetTagLeavesTheBotUnowned() {
        let bot = taggedBot("BOT1", ["operator:keep", "colour:red"])
        #expect(RepairFleet.answers(bot, to: nil))
        #expect(RepairFleet.answers(bot, to: "auto:salvage"))
    }

    @Test func aBotWearingTwoFleetTagsAnswersToBoth() {
        let bot = taggedBot("BOT1", ["auto:salvage", "auto:survey"])
        #expect(RepairFleet.answers(bot, to: "auto:salvage"))
        #expect(RepairFleet.answers(bot, to: "auto:survey"))
        #expect(!RepairFleet.answers(bot, to: "auto:haul"))
    }

    /// Tags carry operator casing, so both sides must compare through
    /// `Device.normalizedTag` or a hand-tagged bot escapes its fleet.
    @Test func ownershipSurvivesCaseAndWhitespaceDrift() {
        let bot = taggedBot("BOT1", ["Auto:Survey"])
        #expect(RepairFleet.answers(bot, to: "auto:survey"))
        #expect(!RepairFleet.answers(bot, to: "auto:salvage"))
        #expect(!RepairFleet.answers(bot, to: nil))
        #expect(RepairFleet.answers(taggedBot("BOT2", ["auto:survey"]), to: " Auto:Survey "))
    }

    /// Both ends of the round trip must filter identically — a bot deployed
    /// under one predicate and recalled under a narrower one is abandoned.
    @Test func theAboardAndDeployedQueriesScopeIdentically() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let mine = repairDevice(
            "BOT1", type: "service_bot", location: nil, stowedIn: "VESSEL",
            directives: ["service"], tags: ["auto:salvage"]
        )
        let theirs = repairDevice(
            "BOT2", type: "service_bot", location: nil, stowedIn: "VESSEL",
            directives: ["service"], tags: ["auto:survey"]
        )
        let aboard = repairWorld(devices: [vessel, mine, theirs])
        #expect(RepairFleet.bots(aboard: vessel, in: aboard, owner: "auto:salvage")
            .map(\.deviceCode) == ["BOT1"])

        let out = repairWorld(devices: [
            vessel,
            taggedBot("BOT1", ["auto:salvage"]),
            taggedBot("BOT2", ["auto:survey"]),
        ])
        #expect(RepairFleet.bots(deployedNear: "SOL-3", in: out, owner: "auto:salvage")
            .map(\.deviceCode) == ["BOT1"])
        #expect(RepairFleet.anyBotDeployed(in: out, system: "SOL", owner: "auto:salvage"))
        #expect(!RepairFleet.anyBotDeployed(in: out, system: "SOL", owner: "auto:haul"))
    }

    /// The gate's fleet is owner-scoped on the deployed half and vessel-scoped
    /// on the stowed half, so another fleet's bot cannot hold this one.
    @Test func theRepairGatesFleetExcludesAnotherFleetsDeployedBot() {
        let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let theirs = taggedBot("BOT2", ["auto:survey"])
        let drone = repairDevice(
            "DRONE1", type: "mining_drone", location: nil, stowedIn: "VESSEL", capacity: 100
        )
        let w = repairWorld(devices: [vessel, theirs, drone])
        #expect(RepairFleet.fleet(of: vessel, in: w, owner: "auto:salvage")
            .map(\.deviceCode) == ["DRONE1"])
    }

    // MARK: - Per-theatre tag migration

    /// A bot never re-tagged for its theatre still answers to the per-theatre
    /// owner a freshly-launched directive now stamps — the migration path.
    @Test func aBareTaggedBotAnswersToATheatreScopedOwner() {
        let bot = taggedBot("BOT1", ["auto:survey"])
        #expect(RepairFleet.answers(bot, to: "auto:survey:AINALRAM-BELT-1"))
    }

    /// A bot migrated to ONE theatre must not answer for a different one —
    /// the root fallback must not blur theatres together.
    @Test func aTheatreTaggedBotDoesNotAnswerToAnotherTheatre() {
        let bot = taggedBot("BOT1", ["auto:survey:AINALRAM-BELT-1"])
        #expect(RepairFleet.answers(bot, to: "auto:survey:AINALRAM-BELT-1"))
        #expect(!RepairFleet.answers(bot, to: "auto:survey:DENEBED-BELT-1"))
    }
}
