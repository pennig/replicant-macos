//
//  BotPhaseTests.swift
//  Replicould — DirectiveEngine
//
//  The service-bot lifecycle, tested once here instead of twice per mission.
//

import Foundation
import GameModels
import GameServices
import Testing

@testable import DirectiveEngine

private let now = repairFixtureNow
private let vesselCode = "V1"
private let system = "SOL"

private func phase(_ phase: BotPhase.Phase, unrepairedStep: String = "armingBots") -> BotPhase {
    BotPhase(
        vesselCode: vesselCode, owner: nil, system: system, phase: phase,
        dispatchStep: "deployingBots", confirmStep: "confirmingBotDeploy", runNoun: "survey run",
        unrepairedStep: unrepairedStep
    )
}

private let vessel = repairDevice(vesselCode, type: "heaven_vessel", location: "SOL-3")

@Suite("Bot phase")
struct BotPhaseTests {
    @Test("deploy orders the first bot still aboard")
    func deployOrdersTheFirstBotAboard() {
        let bot = repairDevice("B1", type: "service_bot", location: nil,
                               stowedIn: vesselCode, directives: ["service"])
        let ctx = StepContext(
            directive: repairDirective(
                step: "deployingBots", deviceCode: vesselCode, targets: [system], stepStartedAt: now
            ),
            world: repairWorld(devices: [vessel, bot]), step: "deployingBots"
        )
        #expect(phase(.deploy).next(ctx) == .action(.dispatch(
            kind: .simple("deploy"), deviceCode: "B1",
            params: CommandParams(), nextStep: "confirmingBotDeploy"
        )))
    }

    /// The whole reason the mission keeps its own step names: Survey sends an
    /// empty hold to `configuring` and Salvage to `armingBots`.
    @Test("deploy with nothing aboard finishes rather than naming a step")
    func deployWithEmptyHoldFinishes() {
        let ctx = StepContext(
            directive: repairDirective(
                step: "deployingBots", deviceCode: vesselCode, targets: [system], stepStartedAt: now
            ),
            world: repairWorld(devices: [vessel]), step: "deployingBots"
        )
        #expect(phase(.deploy).next(ctx) == .finished)
    }

    /// The bound `stepStartedAt` cannot give: the confirm step re-stamps it,
    /// so a dispatch/confirm pair would reset its own deadline every round.
    @Test("deploy stops at the round budget and hands off to arming")
    func deployStopsAtTheRoundBudget() {
        let bot = repairDevice("B1", type: "service_bot", location: nil,
                               stowedIn: vesselCode, directives: ["service"])
        var log: [DirectiveLogEntry] = []
        for round in 0...BotPhase.dispatchRounds {
            log.append(DirectiveLogEntry(
                id: "S\(round)", directiveID: "D1", deviceCode: nil, kind: .stepStarted,
                summary: "Step: deployingBots", step: "deployingBots", operationID: nil,
                eventID: nil, occurredAt: now.addingTimeInterval(TimeInterval(round))
            ))
        }
        let ctx = StepContext(
            directive: repairDirective(
                step: "deployingBots", deviceCode: vesselCode, targets: [system], stepStartedAt: now
            ),
            world: repairWorld(devices: [vessel, bot], log: log), step: "deployingBots"
        )
        #expect(phase(.deploy).next(ctx) == .action(.advanceStep(nextStep: "armingBots")))
    }

    /// A one-bot fixture cannot see this: `.finished` here must route to arming
    /// so a bot already deployed still gets armed, not just an empty hold.
    @Test("deploy gives up with a bot already deployed and routes to arming")
    func deployGivesUpWithABotAlreadyDeployed() {
        let deployed = repairDevice("B0", type: "service_bot", location: "SOL-3",
                                    directives: ["service"], capacity: 10)
        let bot = repairDevice("B1", type: "service_bot", location: nil,
                               stowedIn: vesselCode, directives: ["service"])
        var log: [DirectiveLogEntry] = []
        for round in 0...BotPhase.dispatchRounds {
            log.append(DirectiveLogEntry(
                id: "S\(round)", directiveID: "D1", deviceCode: nil, kind: .stepStarted,
                summary: "Step: deployingBots", step: "deployingBots", operationID: nil,
                eventID: nil, occurredAt: now.addingTimeInterval(TimeInterval(round))
            ))
        }
        let ctx = StepContext(
            directive: repairDirective(
                step: "deployingBots", deviceCode: vesselCode, targets: [system], stepStartedAt: now
            ),
            world: repairWorld(devices: [vessel, deployed, bot], log: log), step: "deployingBots"
        )
        #expect(phase(.deploy).next(ctx) == .action(.advanceStep(nextStep: "armingBots")))
    }

    /// Deadline BEFORE the read. A failing read never advances `updatedAt`, so
    /// the other order loops forever at one high-priority read per tick.
    @Test("await repair stalls on the deadline rather than buying another read")
    func awaitRepairChecksTheDeadlineFirst() {
        let bot = repairDevice("B1", type: "service_bot", location: "SOL-3",
                               directives: ["service"], capacity: 10,
                               updatedAt: now.addingTimeInterval(-10_000),
                               repairingTarget: "D9")
        let ctx = StepContext(
            directive: repairDirective(
                step: "repairing", deviceCode: vesselCode, targets: [system],
                stepStartedAt: now.addingTimeInterval(-(BotPhase.repairDeadline + 1))
            ),
            world: repairWorld(devices: [vessel, bot]), step: "repairing"
        )
        #expect(phase(.awaitRepair).next(ctx) == .action(.stall(.repairUnfinished)))
    }

    @Test("await repair finishes once every bot is idle on a row read since the step began")
    func awaitRepairFinishesWhenIdle() {
        let bot = repairDevice("B1", type: "service_bot", location: "SOL-3",
                               directives: ["service"], capacity: 10, updatedAt: now)
        let ctx = StepContext(
            directive: repairDirective(
                step: "repairing", deviceCode: vesselCode, targets: [system],
                stepStartedAt: now.addingTimeInterval(-(BotPhase.probeDelay + 1))
            ),
            world: repairWorld(devices: [vessel, bot]), step: "repairing"
        )
        #expect(phase(.awaitRepair).next(ctx) == .finished)
    }

    /// A recalled bot carries `location: nil` for its whole cruise home, so a
    /// location query drops precisely the device the question is about.
    @Test("confirm recall counts a bot in transit as still out")
    func confirmRecallCountsABotInTransit() {
        let cruising = repairDevice("B1", type: "service_bot", location: nil,
                                    directives: ["service"], updatedAt: now)
        let world = repairWorld(
            devices: [vessel, cruising],
            openOperations: [
                "B1": STUCKOP_operation(entityCode: "B1", kind: "recall", completesAt: now.addingTimeInterval(120))
            ]
        )
        let ctx = StepContext(
            directive: repairDirective(
                step: "confirmingBotStow", deviceCode: vesselCode, targets: [system],
                stepStartedAt: now.addingTimeInterval(-(BotPhase.probeDelay + 1))
            ),
            world: world, step: "confirmingBotStow"
        )
        #expect(phase(.confirmRecall).next(ctx) != .finished)
    }
}
