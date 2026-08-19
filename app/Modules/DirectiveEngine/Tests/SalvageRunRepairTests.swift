//
//  SalvageRunRepairTests.swift
//  Replicould — DirectiveEngine
//
//  Service bots touring with a Salvage Run: deployed once per SYSTEM, armed,
//  left to hot-repair the mining drones across every body, recalled before the
//  vessel leaves. Plus the fleet-tag ownership that keeps two bot-carrying
//  fleets from recalling each other's bots.
//

import Foundation
import GameModels
import GameServices
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

private let salvageTag = "auto:salvage"

private func salvageDirective(
    step: String,
    targets: [String] = [],
    stepStartedAt: Date = repairFixtureNow,
    controllerCode: String? = nil,
    fleetTag: String? = nil
) -> Directive {
    repairDirective(
        step: step, deviceCode: "VESSEL", targets: targets, stepStartedAt: stepStartedAt,
        kind: .salvageRun, controllerCode: controllerCode, fleetTag: fleetTag
    )
}

private func bot(
    _ code: String,
    location: String? = "TOSLIT-3",
    stowedIn: String? = nil,
    tags: [String] = [salvageTag],
    currentDirective: String? = "service",
    currentDirectiveStatus: String? = "active",
    capacity: Double = 100,
    updatedAt: Date = repairFixtureNow,
    repairingTarget: String? = nil,
    travelArrival: Date? = nil
) -> Device {
    repairDevice(
        code, type: "service_bot", location: location, stowedIn: stowedIn,
        directives: ["patrol", "service"], currentDirective: currentDirective,
        currentDirectiveStatus: currentDirectiveStatus, capacity: capacity, tags: tags,
        updatedAt: updatedAt, repairingTarget: repairingTarget, travelArrival: travelArrival
    )
}

private let vessel = repairDevice("VESSEL", type: "heaven_vessel", location: "TOSLIT-3")

/// A live relay in TOSLIT, which is what makes the system read as meshed.
private let plantedRelay = repairDevice(
    "RELAY", type: "ftl_relay", location: "TOSLIT-1",
    features: ["relay"], status: "relaying"
)

private let liveToslit = StarSystem(
    designation: "TOSLIT",
    planets: [
        Planet(designation: "TOSLIT-3", moons: [
            Moon(designation: "TOSLIT-3-2", salvage: [
                SalvageSite(designation: "TOSLIT-3-2-SAL-1", resourcesAvailable: ["ore"]),
            ]),
        ]),
    ]
)

private let drainedToslit = StarSystem(designation: "TOSLIT", planets: [])

private let long = repairFixtureNow.addingTimeInterval(-60)

// MARK: - Arrival funnel

@Suite struct SalvageRunBotArrivalTests {
    @Test func arrivingAtAMeshedSystemDeploysBotsBeforeTouringIt() {
        let w = repairWorld(devices: [vessel, plantedRelay])
        let d = salvageDirective(step: SalvageRun.Step.travelling.rawValue, targets: ["TOSLIT"])
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .advanceStep(nextStep: SalvageRun.Step.deployingBots.rawValue))
    }

    /// These four names sit outside `SalvageRun.Step`'s vocabulary, so a row
    /// stuck on one waits like any other unrecognised string.
    @Test(arguments: ["emplacing", "activating", "confirmingRelay", "restocking"])
    func formerRelayStepNamesNowWait(_ step: String) {
        let w = repairWorld(devices: [vessel, plantedRelay])
        let d = salvageDirective(step: step, targets: ["TOSLIT"])
        #expect(SalvageRun().nextAction(directive: d, world: w) == .wait)
    }

    @Test func anUnknownStepStillWaits() {
        let w = repairWorld(devices: [vessel, plantedRelay])
        let d = salvageDirective(step: "notAStepAtAll", targets: ["TOSLIT"])
        #expect(SalvageRun().nextAction(directive: d, world: w) == .wait)
    }
}

// MARK: - Deploy

@Suite struct SalvageRunBotDeployTests {
    @Test func noBotAboardSkipsStraightToArming() {
        let w = repairWorld(devices: [vessel])
        let d = salvageDirective(step: SalvageRun.Step.deployingBots.rawValue, targets: ["TOSLIT"])
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .advanceStep(nextStep: SalvageRun.Step.armingBots.rawValue))
    }

    @Test func theFirstBotAboardIsDeployed() {
        let w = repairWorld(devices: [
            vessel,
            bot("BOT1", location: nil, stowedIn: "VESSEL"),
            bot("BOT2", location: nil, stowedIn: "VESSEL"),
        ])
        let d = salvageDirective(step: SalvageRun.Step.deployingBots.rawValue, targets: ["TOSLIT"])
        #expect(SalvageRun().nextAction(directive: d, world: w) == .dispatch(
            kind: .simple("deploy"), deviceCode: "BOT1",
            params: CommandParams(), nextStep: SalvageRun.Step.confirmingBotDeploy.rawValue
        ))
    }

    /// A bot wearing another fleet's tag is not this run's to command, even
    /// mis-staged aboard its vessel.
    @Test func anotherFleetsBotAboardIsNotDeployed() {
        let w = repairWorld(devices: [
            vessel,
            bot("BOT1", location: nil, stowedIn: "VESSEL", tags: ["auto:survey"]),
        ])
        let d = salvageDirective(step: SalvageRun.Step.deployingBots.rawValue, targets: ["TOSLIT"])
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .advanceStep(nextStep: SalvageRun.Step.armingBots.rawValue))
    }

    @Test func anUntaggedBotAnswersToWhoeverAsks() {
        let w = repairWorld(devices: [
            vessel,
            bot("BOT1", location: nil, stowedIn: "VESSEL", tags: []),
        ])
        let d = salvageDirective(step: SalvageRun.Step.deployingBots.rawValue, targets: ["TOSLIT"])
        #expect(SalvageRun().nextAction(directive: d, world: w) == .dispatch(
            kind: .simple("deploy"), deviceCode: "BOT1",
            params: CommandParams(), nextStep: SalvageRun.Step.confirmingBotDeploy.rawValue
        ))
    }

    /// A bot that will not deploy costs the repair, never the salvage.
    @Test func aBotThatWillNotDeployLetsTheRunMineUnrepaired() {
        let rounds = Array(
            repeating: [SalvageRun.Step.deployingBots.rawValue, SalvageRun.Step.confirmingBotDeploy.rawValue],
            count: 7
        ).flatMap { $0 }
        let w = repairWorld(
            devices: [vessel, bot("BOT1", location: nil, stowedIn: "VESSEL")],
            log: repairStepLog(rounds)
        )
        let d = salvageDirective(step: SalvageRun.Step.deployingBots.rawValue, targets: ["TOSLIT"])
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .advanceStep(nextStep: SalvageRun.Step.armingBots.rawValue))
    }

    @Test func aFreshlyOrderedDeployIsNotJudgedYet() {
        let w = repairWorld(devices: [vessel, bot("BOT1", location: nil, stowedIn: "VESSEL")])
        let d = salvageDirective(step: SalvageRun.Step.confirmingBotDeploy.rawValue, targets: ["TOSLIT"])
        #expect(SalvageRun().nextAction(directive: d, world: w) == .wait)
    }

    @Test func aLandedDeployLoopsBackForTheNextBot() {
        let w = repairWorld(devices: [
            vessel, bot("BOT1"), bot("BOT2", location: nil, stowedIn: "VESSEL"),
        ])
        let d = salvageDirective(
            step: SalvageRun.Step.confirmingBotDeploy.rawValue, targets: ["TOSLIT"], stepStartedAt: long
        )
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .advanceStep(nextStep: SalvageRun.Step.deployingBots.rawValue))
    }

    @Test func everyBotDeployedAdvancesToArming() {
        let w = repairWorld(devices: [vessel, bot("BOT1"), bot("BOT2")])
        let d = salvageDirective(
            step: SalvageRun.Step.confirmingBotDeploy.rawValue, targets: ["TOSLIT"], stepStartedAt: long
        )
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .advanceStep(nextStep: SalvageRun.Step.armingBots.rawValue))
    }

    @Test func anUnreadBotRowIsBoughtBeforeItIsBelieved() {
        let stale = bot(
            "BOT1", location: nil, stowedIn: "VESSEL",
            updatedAt: repairFixtureNow.addingTimeInterval(-600)
        )
        let w = repairWorld(devices: [vessel, stale])
        let d = salvageDirective(
            step: SalvageRun.Step.confirmingBotDeploy.rawValue, targets: ["TOSLIT"], stepStartedAt: long
        )
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .refreshDevices(deviceCodes: ["BOT1"], thenStall: nil))
    }
}

// MARK: - Arm

@Suite struct SalvageRunBotArmTests {
    /// A freshly deployed bot lands paused, so the run SETS its directive rather
    /// than inheriting whatever manual use left on it.
    @Test func aBotOnTheWrongDirectiveIsRenamed() {
        let w = repairWorld(devices: [
            vessel, bot("BOT1", currentDirective: "patrol", currentDirectiveStatus: "active"),
        ])
        let d = salvageDirective(step: SalvageRun.Step.armingBots.rawValue, targets: ["TOSLIT"])
        #expect(SalvageRun().nextAction(directive: d, world: w) == .dispatch(
            kind: .setDirective, deviceCode: "BOT1",
            params: CommandParams(directive: "service"),
            nextStep: SalvageRun.Step.confirmingBotArm.rawValue
        ))
    }

    @Test func aPausedServiceBotIsActivated() {
        let w = repairWorld(devices: [vessel, bot("BOT1", currentDirectiveStatus: "paused")])
        let d = salvageDirective(step: SalvageRun.Step.armingBots.rawValue, targets: ["TOSLIT"])
        #expect(SalvageRun().nextAction(directive: d, world: w) == .dispatch(
            kind: .simple("activate"), deviceCode: "BOT1",
            params: CommandParams(), nextStep: SalvageRun.Step.confirmingBotArm.rawValue
        ))
    }

    @Test func everyBotArmedTouringBegins() {
        let w = repairWorld(devices: [vessel, bot("BOT1"), bot("BOT2")])
        let d = salvageDirective(step: SalvageRun.Step.armingBots.rawValue, targets: ["TOSLIT"])
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .advanceStep(nextStep: SalvageRun.Step.positioning.rawValue))
    }

    /// Unarmable is loud: a paused bot repairs nothing, and reading that as
    /// "nothing to repair" is the silent failure the arm pair exists to close.
    @Test func aBotThatWillNotArmStalls() {
        let rounds = Array(
            repeating: [SalvageRun.Step.armingBots.rawValue, SalvageRun.Step.confirmingBotArm.rawValue],
            count: 7
        ).flatMap { $0 }
        let w = repairWorld(
            devices: [vessel, bot("BOT1", currentDirectiveStatus: "paused")],
            log: repairStepLog(rounds)
        )
        let d = salvageDirective(step: SalvageRun.Step.armingBots.rawValue, targets: ["TOSLIT"])
        #expect(SalvageRun().nextAction(directive: d, world: w) == .stall(.serviceBotNotArmed))
    }

    @Test func aLandedArmLoopsBackForTheNextBot() {
        let w = repairWorld(devices: [vessel, bot("BOT1"), bot("BOT2")])
        let d = salvageDirective(
            step: SalvageRun.Step.confirmingBotArm.rawValue, targets: ["TOSLIT"], stepStartedAt: long
        )
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .advanceStep(nextStep: SalvageRun.Step.positioning.rawValue))
    }
}

// MARK: - The repair gate

@Suite struct SalvageRunRepairGateTests {
    @Test func noBotDeployedLeavesAtOnce() {
        let w = repairWorld(devices: [vessel])
        let d = salvageDirective(
            step: SalvageRun.Step.repairing.rawValue, targets: ["TOSLIT"], stepStartedAt: long
        )
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .advanceStep(nextStep: SalvageRun.Step.stowingBots.rawValue))
    }

    @Test func aFleetNothingIsWornEnoughToHoldForLeavesAtOnce() {
        let drone = repairDevice(
            "DRONE1", type: "mining_drone", location: nil, stowedIn: "VESSEL", capacity: 100
        )
        let w = repairWorld(devices: [vessel, bot("BOT1"), drone])
        let d = salvageDirective(
            step: SalvageRun.Step.repairing.rawValue, targets: ["TOSLIT"], stepStartedAt: long
        )
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .advanceStep(nextStep: SalvageRun.Step.stowingBots.rawValue))
    }

    @Test func aWorkingBotHoldsTheVessel() {
        let drone = repairDevice(
            "DRONE1", type: "mining_drone", location: nil, stowedIn: "VESSEL", capacity: 28
        )
        let w = repairWorld(
            devices: [vessel, bot("BOT1", repairingTarget: "DRONE1"), drone]
        )
        let d = salvageDirective(
            step: SalvageRun.Step.repairing.rawValue, targets: ["TOSLIT"], stepStartedAt: long
        )
        #expect(SalvageRun().nextAction(directive: d, world: w) == .wait)
    }

    /// The exit is bot IDLENESS, never a capacity threshold — `service` restores
    /// to an unquantified level a threshold gate could wait on forever.
    @Test func idleBotsReleaseTheVesselEvenWithADroneStillWorn() {
        let drone = repairDevice(
            "DRONE1", type: "mining_drone", location: nil, stowedIn: "VESSEL", capacity: 28
        )
        let w = repairWorld(devices: [vessel, bot("BOT1"), drone])
        let d = salvageDirective(
            step: SalvageRun.Step.repairing.rawValue, targets: ["TOSLIT"], stepStartedAt: long
        )
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .advanceStep(nextStep: SalvageRun.Step.stowingBots.rawValue))
    }

    @Test func repairThatWillNotConvergeEscalates() {
        let drone = repairDevice(
            "DRONE1", type: "mining_drone", location: nil, stowedIn: "VESSEL", capacity: 28
        )
        let w = repairWorld(devices: [vessel, bot("BOT1", repairingTarget: "DRONE1"), drone])
        let d = salvageDirective(
            step: SalvageRun.Step.repairing.rawValue, targets: ["TOSLIT"],
            stepStartedAt: repairFixtureNow.addingTimeInterval(-(BotPhase.repairDeadline + 60))
        )
        #expect(SalvageRun().nextAction(directive: d, world: w) == .stall(.repairUnfinished))
    }

    /// A worn BOT is held for too: it is the failure that silently disables
    /// everything downstream, and its partner is what fixes it.
    @Test func aWornBotHoldsTheFleetJustAsADroneDoes() {
        let w = repairWorld(devices: [
            vessel, bot("BOT1", capacity: 20, repairingTarget: "BOT1"), bot("BOT2"),
        ])
        let d = salvageDirective(
            step: SalvageRun.Step.repairing.rawValue, targets: ["TOSLIT"], stepStartedAt: long
        )
        #expect(SalvageRun().nextAction(directive: d, world: w) == .wait)
    }
}

// MARK: - Recall

@Suite struct SalvageRunBotRecallTests {
    @Test func aDeployedBotIsRecalledBeforeTheVesselLeaves() {
        let w = repairWorld(devices: [vessel, bot("BOT1")])
        let d = salvageDirective(
            step: SalvageRun.Step.stowingBots.rawValue, targets: ["TOSLIT"], stepStartedAt: long
        )
        #expect(SalvageRun().nextAction(directive: d, world: w) == .dispatch(
            kind: .simple("recall"), deviceCode: "BOT1",
            params: CommandParams(), nextStep: SalvageRun.Step.confirmingBotStow.rawValue
        ))
    }

    /// A bot that cruised to another SITE in the target system is still this
    /// run's to bring home — the query is system-scoped, never site-scoped.
    @Test func aBotThatCruisedToAnotherSiteIsStillRecalled() {
        let w = repairWorld(devices: [vessel, bot("BOT1", location: "TOSLIT-9")])
        let d = salvageDirective(
            step: SalvageRun.Step.stowingBots.rawValue, targets: ["TOSLIT"], stepStartedAt: long
        )
        #expect(SalvageRun().nextAction(directive: d, world: w) == .dispatch(
            kind: .simple("recall"), deviceCode: "BOT1",
            params: CommandParams(), nextStep: SalvageRun.Step.confirmingBotStow.rawValue
        ))
    }

    @Test func everyBotHomeAdvancesTheTarget() {
        let w = repairWorld(devices: [vessel, bot("BOT1", location: nil, stowedIn: "VESSEL")])
        let d = salvageDirective(
            step: SalvageRun.Step.stowingBots.rawValue, targets: ["TOSLIT"], stepStartedAt: long
        )
        #expect(SalvageRun().nextAction(directive: d, world: w) == .advanceTarget)
    }

    /// An operation carrying no `completesAt` can never resolve, so it must
    /// never block the dispatch that would retire it.
    @Test func anOperationThatCanNeverCloseDoesNotBlockTheRecall() {
        let w = repairWorld(
            devices: [vessel, bot("BOT1")],
            openOperations: ["BOT1": STUCKOP_operation(
                entityCode: "BOT1", kind: "recall", completesAt: nil
            )]
        )
        let d = salvageDirective(
            step: SalvageRun.Step.stowingBots.rawValue, targets: ["TOSLIT"], stepStartedAt: long
        )
        #expect(SalvageRun().nextAction(directive: d, world: w) == .dispatch(
            kind: .simple("recall"), deviceCode: "BOT1",
            params: CommandParams(), nextStep: SalvageRun.Step.confirmingBotStow.rawValue
        ))
    }

    @Test func aRecallStillFlyingIsWaitedOut() {
        let w = repairWorld(
            devices: [vessel, bot("BOT1")],
            openOperations: ["BOT1": STUCKOP_operation(
                entityCode: "BOT1", kind: "recall",
                completesAt: repairFixtureNow.addingTimeInterval(120)
            )]
        )
        let d = salvageDirective(
            step: SalvageRun.Step.stowingBots.rawValue, targets: ["TOSLIT"], stepStartedAt: long
        )
        #expect(SalvageRun().nextAction(directive: d, world: w) == .wait)
    }

    /// A recall clears the bot's location for the whole cruise home, so the system
    /// reads empty and the run departs over a bot that is still on its way in.
    @Test func aRecallCruisingHomeIsWaitedOutThoughItClearedItsLocation() {
        let w = repairWorld(
            devices: [
                vessel,
                bot("BOT1", location: nil, travelArrival: repairFixtureNow.addingTimeInterval(120)),
            ],
            openOperations: ["BOT1": STUCKOP_operation(
                entityCode: "BOT1", kind: "recall",
                completesAt: repairFixtureNow.addingTimeInterval(120)
            )]
        )
        let d = salvageDirective(
            step: SalvageRun.Step.confirmingBotStow.rawValue, targets: ["TOSLIT"],
            stepStartedAt: repairFixtureNow.addingTimeInterval(-60)
        )
        #expect(SalvageRun().nextAction(directive: d, world: w) == .wait)
    }

    @Test func stowingDoesNotAdvanceOverABotStillCruisingHome() {
        let w = repairWorld(
            devices: [
                vessel,
                bot("BOT1", location: nil, travelArrival: repairFixtureNow.addingTimeInterval(120)),
            ],
            openOperations: ["BOT1": STUCKOP_operation(
                entityCode: "BOT1", kind: "recall",
                completesAt: repairFixtureNow.addingTimeInterval(120)
            )]
        )
        let d = salvageDirective(step: SalvageRun.Step.stowingBots.rawValue, targets: ["TOSLIT"])
        #expect(SalvageRun().nextAction(directive: d, world: w) == .wait)
    }

    /// Neither side of the query has a location: the vessel is under way and the
    /// bot is cruising in. The run must not read that as an empty system.
    @Test func aVesselUnderWayDoesNotAdvanceOverABotStillCruisingHome() {
        let travelling = repairDevice("VESSEL", type: "heaven_vessel", location: nil)
        let w = repairWorld(
            devices: [
                travelling,
                bot("BOT1", location: nil, travelArrival: repairFixtureNow.addingTimeInterval(120)),
            ],
            openOperations: ["BOT1": STUCKOP_operation(
                entityCode: "BOT1", kind: "recall",
                completesAt: repairFixtureNow.addingTimeInterval(120)
            )]
        )
        let d = salvageDirective(step: SalvageRun.Step.stowingBots.rawValue, targets: ["TOSLIT"])
        #expect(SalvageRun().nextAction(directive: d, world: w) == .wait)
    }

    /// A stowed bot also carries no location, and must NOT read as one in transit.
    @Test func aStowedBotDoesNotHoldTheRunAtTheSystem() {
        let w = repairWorld(
            devices: [vessel, bot("BOT1", location: nil, stowedIn: "VESSEL")],
            openOperations: ["BOT1": STUCKOP_operation(
                entityCode: "BOT1", kind: "recall",
                completesAt: repairFixtureNow.addingTimeInterval(120)
            )]
        )
        let d = salvageDirective(step: SalvageRun.Step.stowingBots.rawValue, targets: ["TOSLIT"])
        #expect(SalvageRun().nextAction(directive: d, world: w) == .advanceTarget)
    }

    @Test func aBotThatWillNotComeHomeStalls() {
        let rounds = Array(
            repeating: [SalvageRun.Step.stowingBots.rawValue, SalvageRun.Step.confirmingBotStow.rawValue],
            count: 7
        ).flatMap { $0 }
        let w = repairWorld(devices: [vessel, bot("BOT1")], log: repairStepLog(rounds))
        let d = salvageDirective(
            step: SalvageRun.Step.stowingBots.rawValue, targets: ["TOSLIT"], stepStartedAt: long
        )
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .stall(.serviceBotNotRecovered))
    }

    @Test func aRecallPastItsDeadlineStalls() {
        let w = repairWorld(devices: [vessel, bot("BOT1")])
        let d = salvageDirective(
            step: SalvageRun.Step.confirmingBotStow.rawValue, targets: ["TOSLIT"],
            stepStartedAt: repairFixtureNow.addingTimeInterval(-(BotPhase.recallDeadline + 60))
        )
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .stall(.serviceBotNotRecovered))
    }

    @Test func aLandedRecallLoopsBackForTheNextBot() {
        let w = repairWorld(devices: [vessel, bot("BOT1")])
        let d = salvageDirective(
            step: SalvageRun.Step.confirmingBotStow.rawValue, targets: ["TOSLIT"], stepStartedAt: long
        )
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .advanceStep(nextStep: SalvageRun.Step.stowingBots.rawValue))
    }

    @Test func confirmingWithNoBotOutAdvancesTheTarget() {
        let w = repairWorld(devices: [vessel])
        let d = salvageDirective(
            step: SalvageRun.Step.confirmingBotStow.rawValue, targets: ["TOSLIT"], stepStartedAt: long
        )
        #expect(SalvageRun().nextAction(directive: d, world: w) == .advanceTarget)
    }
}

// MARK: - Every exit from a system passes the recall

@Suite struct SalvageRunBotExitTests {
    @Test func aDrainedSystemRecallsBeforeAdvancing() {
        let w = repairWorld(devices: [vessel], systems: ["TOSLIT": drainedToslit])
        let d = salvageDirective(step: SalvageRun.Step.positioning.rawValue, targets: ["TOSLIT"])
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .advanceStep(nextStep: SalvageRun.Step.repairing.rawValue))
    }

    @Test func configuringADrainedSystemRecallsBeforeAdvancing() {
        let w = repairWorld(devices: [vessel], systems: ["TOSLIT": drainedToslit])
        let d = salvageDirective(step: SalvageRun.Step.configuring.rawValue, targets: ["TOSLIT"])
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .advanceStep(nextStep: SalvageRun.Step.repairing.rawValue))
    }

    @Test func verifyingADrainedSystemRecallsBeforeAdvancing() {
        let controller = repairDevice(
            "CTRL", type: "ami_mining_controller", location: nil, stowedIn: "VESSEL",
            directives: ["gather_salvage"]
        )
        let w = repairWorld(devices: [vessel, controller], systems: ["TOSLIT": drainedToslit])
        let d = salvageDirective(
            step: SalvageRun.Step.verifying.rawValue, targets: ["TOSLIT"], controllerCode: "CTRL"
        )
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .advanceStep(nextStep: SalvageRun.Step.repairing.rawValue))
    }

    @Test func aVanishedControllerRecallsBeforeAdvancing() {
        let w = repairWorld(devices: [vessel], systems: ["TOSLIT": liveToslit])
        let d = salvageDirective(
            step: SalvageRun.Step.verifying.rawValue, targets: ["TOSLIT"], controllerCode: "GONE"
        )
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .advanceStep(nextStep: SalvageRun.Step.repairing.rawValue))
    }

    @Test func anExhaustedQueueRecallsBeforeAdvancing() {
        let controller = repairDevice(
            "CTRL", type: "ami_mining_controller", location: nil, stowedIn: "VESSEL",
            directives: ["gather_salvage"]
        )
        let w = repairWorld(devices: [vessel, controller])
        let d = salvageDirective(step: SalvageRun.Step.verifying.rawValue, controllerCode: "CTRL")
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .advanceStep(nextStep: SalvageRun.Step.repairing.rawValue))
    }

    /// Bots are deployed once per SYSTEM, so moving to the next BODY must not
    /// recall and redeploy them — `service` is system-scoped and the bot cruises.
    @Test func theNextBodyInTheSameSystemKeepsTheBotsOut() {
        let controller = repairDevice(
            "CTRL", type: "ami_mining_controller", location: nil, stowedIn: "VESSEL",
            directives: ["gather_salvage"]
        )
        let w = repairWorld(
            devices: [vessel, controller, bot("BOT1")], systems: ["TOSLIT": liveToslit]
        )
        let d = salvageDirective(
            step: SalvageRun.Step.verifying.rawValue, targets: ["TOSLIT"], controllerCode: "CTRL"
        )
        #expect(SalvageRun().nextAction(directive: d, world: w)
            == .advanceStep(nextStep: SalvageRun.Step.positioning.rawValue))
    }
}

// MARK: - Cross-fleet ownership

@Suite struct ServiceBotOwnershipTests {
    @Test func aSalvageRunDoesNotRecallASurveyFleetsBot() {
        let w = repairWorld(devices: [vessel, bot("BOT1", tags: ["auto:survey"])])
        let d = salvageDirective(
            step: SalvageRun.Step.stowingBots.rawValue, targets: ["TOSLIT"], stepStartedAt: long
        )
        #expect(SalvageRun().nextAction(directive: d, world: w) == .advanceTarget)
    }

    @Test func aSurveyRunDoesNotRecallASalvageFleetsBot() {
        let surveyVessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let salvageBot = bot("BOT1", location: "SOL-3", tags: [salvageTag])
        let w = repairWorld(devices: [surveyVessel, salvageBot])
        let d = repairDirective(
            step: SurveyRun.Step.stowingBots.rawValue, deviceCode: "VESSEL",
            targets: ["SOL"], stepStartedAt: long
        )
        #expect(SurveyRun().nextAction(directive: d, world: w) == .advanceTarget)
    }

    /// Today's pair wears no tag at all, so the shipped Survey Run keeps working.
    @Test func anUntaggedBotStillAnswersToAnUntaggedRun() {
        let surveyVessel = repairDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let untagged = bot("BOT1", location: "SOL-3", tags: [])
        let w = repairWorld(devices: [surveyVessel, untagged])
        let d = repairDirective(
            step: SurveyRun.Step.stowingBots.rawValue, deviceCode: "VESSEL",
            targets: ["SOL"], stepStartedAt: long
        )
        #expect(SurveyRun().nextAction(directive: d, world: w) == .dispatch(
            kind: .simple("recall"), deviceCode: "BOT1",
            params: CommandParams(), nextStep: SurveyRun.Step.confirmingBotStow.rawValue
        ))
    }

    /// The run's own bot carries the HIGHER code, so a recall that ignored the
    /// owner would reach for the other theatre's `BOT1` first.
    @Test func aRunWithItsOwnTagClaimsOnlyItsOwnBots() {
        let theirs = bot("BOT1", tags: ["auto:salvage:AINALRAM-1"])
        let mine = bot("BOT2", tags: ["auto:salvage:DENEBED-9"])
        let w = repairWorld(devices: [vessel, theirs, mine])
        let owner = FleetTag(goal: .salvage, scope: .theatre(depot: "DENEBED-9"))
        #expect(RepairFleet.botsOut(near: "TOSLIT-3", in: w, owner: owner)
            .map(\.deviceCode) == ["BOT2"])
        let d = salvageDirective(
            step: SalvageRun.Step.stowingBots.rawValue, targets: ["TOSLIT"],
            stepStartedAt: long, fleetTag: "auto:salvage:DENEBED-9"
        )
        #expect(SalvageRun().nextAction(directive: d, world: w) == .dispatch(
            kind: .simple("recall"), deviceCode: "BOT2",
            params: CommandParams(), nextStep: SalvageRun.Step.confirmingBotStow.rawValue
        ))
    }
}
