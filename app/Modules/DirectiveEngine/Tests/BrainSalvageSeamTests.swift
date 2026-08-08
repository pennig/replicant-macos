//
//  BrainSalvageSeamTests.swift
//  Replicould — DirectiveEngine
//
//  The brain's salvage goal end to end: a real tick launches a real row, the
//  real engine drives the real machine, and the commands that reach the real
//  governor seam are asserted — including the two that must never appear.
//

import ConcurrencyExtras
import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

private let seamNow = Date(timeIntervalSince1970: 500_000)

private struct SeamDispatch: Equatable, Sendable, CustomStringConvertible {
    let verb: String
    let deviceCode: String
    var description: String { "\(verb) → \(deviceCode)" }
}

private func seamDevice(
    _ db: Database, code: String, type: String, location: String? = nil,
    tags: [String] = [], stowedIn: String? = nil, controllerDeviceCode: String? = nil,
    directives: [String] = [], features: [String] = [], availableCommands: [String] = [],
    status: String = "idle"
) throws {
    var detail: [String: JSONValue] = [:]
    if !directives.isEmpty {
        detail["available_directives"] = .array(directives.map(JSONValue.string))
    }
    try Device.insert {
        Device(
            deviceCode: code, deviceType: type, replicantCode: "R1", status: status,
            location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: stowedIn, controllerDeviceCode: controllerDeviceCode,
            attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: availableCommands, features: features, tags: tags,
            detail: .object(detail), updatedAt: seamNow, firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }.execute(db)
}

/// `SOL` meshed and holding the hub; `VEGA` meshed and holding the salvage. The
/// salvage fleet is staged aboard a tagged carrier standing at the hub.
private func seedSeamWorld(_ db: Database, salvageAt: String?) throws {
    try seedStar(db, designation: "SOL", x: 0, y: 0, z: 0)
    try seedStar(db, designation: "VEGA", x: 5, y: 0, z: 0)
    try seamDevice(db, code: "RLY1", type: "ftl_relay", location: "SOL-1", features: ["relay"], status: "relaying")
    try seamDevice(db, code: "RLY2", type: "ftl_relay", location: "VEGA-1", features: ["relay"], status: "relaying")
    try seamDevice(
        db, code: "HUB1", type: "autofactory", location: "SOL-3", availableCommands: ["enqueue_print"]
    )
    try seedHubStockpile(db, location: "SOL-3", resources: BrainCeiling.aggregateSpendFloor * 2)

    try seamDevice(
        db, code: "SALV1", type: Brain.carrierDeviceType, location: "SOL-3",
        tags: [Brain.salvageCarrierTag]
    )
    try seamDevice(
        db, code: "AMI1", type: "ami_mining_controller", tags: [Brain.salvageCarrierTag],
        stowedIn: "SALV1", directives: ["gather_salvage"]
    )
    try seamDevice(
        db, code: "DRONE1", type: "mining_drone", tags: [Brain.salvageCarrierTag],
        stowedIn: "SALV1", controllerDeviceCode: "AMI1"
    )

    if let salvageAt {
        try seedSalvageAssay(db, id: "SITE-\(salvageAt)", system: salvageAt, totals: ["structural": 900])
    }
}

/// One brain tick, then `evaluations` engine evaluations of whatever salvage row
/// it launched, recording every command that reaches the governor seam.
private func driveSeam(
    _ database: any DatabaseWriter, evaluations: Int
) async throws -> (row: Directive?, commands: [SeamDispatch], steps: [String]) {
    let dispatched = LockIsolated<[SeamDispatch]>([])
    var steps: [String] = []

    try await withDependencies {
        $0.defaultDatabase = database
        $0.date = .constant(seamNow)
        $0.uuid = .incrementing
        $0.deviceRefresher = confirmingRefresher(database)
        $0.commandGovernor.dispatch = { kind, deviceCode, _ in
            dispatched.withValue { $0.append(SeamDispatch(verb: kind.rawValue, deviceCode: deviceCode)) }
            return .dispatched(.accepted(operationID: nil))
        }
    } operation: {
        _ = await Brain(now: seamNow).evaluateOnce()

        guard let id = try await database.read({ db in
            try Directive.where { $0.kind.eq(DirectiveKind.salvageRun) }.fetchAll(db).first?.id
        }) else { return }

        let core = DirectiveEngineCore(machines: MissionRegistry.machines, tick: .seconds(5))
        for _ in 0..<evaluations {
            await core.evaluateOnce(directiveID: id)
            if let row = try await database.read({ db in
                try Directive.where { $0.id.eq(id) }.fetchOne(db)
            }) {
                steps.append(row.step)
            }
        }
    }

    let row = try await database.read { db in
        try Directive.where { $0.kind.eq(DirectiveKind.salvageRun) }.fetchAll(db).first
    }
    return (row, dispatched.value, steps)
}

@Suite("The brain's salvage goal, end to end")
struct BrainSalvageSeamTests {
    /// The headline. A tick launches a real row against a meshed salvage
    /// system, the engine drives it, and the vessel is commanded to travel
    /// there — with **no `deploy` and no `activate` anywhere in the command
    /// log**. That absence is the surgery's end-to-end proof: a unit test of
    /// the machine or the planner passes whether or not the engine calls it.
    @Test func aBrainLaunchedSalvageRunTravelsToAMeshedSystemAndPlantsNothing() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedSeamWorld(db, salvageAt: "VEGA") }

        let (row, commands, steps) = try await driveSeam(database, evaluations: 4)

        let launched = try #require(row, "the brain launched no salvage run")
        #expect(launched.deviceCode == "SALV1")
        #expect(launched.targets == ["VEGA"], "the salvage planner chose the target, not the survey one")
        #expect(steps.contains(SalvageRun.Step.travelling))

        #expect(commands.contains(SeamDispatch(verb: "travel", deviceCode: "SALV1")))
        #expect(
            !commands.contains { $0.verb == "deploy" || $0.verb == "activate" },
            "the run planted a relay: \(commands)"
        )
    }

    /// The negative twin. Without it the headline above would pass on a machine
    /// that dispatches nothing at all: no meshed salvage means no launch, so no
    /// row and no commands.
    @Test func noMeshedSalvageLaunchesNothingAndCommandsNothing() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedSeamWorld(db, salvageAt: nil) }

        let (row, commands, _) = try await driveSeam(database, evaluations: 4)

        #expect(row == nil, "nothing to salvage, so nothing to launch")
        #expect(commands.isEmpty)
    }

    /// Salvage in a system `tendMesh` has not reached is not this goal's to
    /// take — the coupling the whole surgery buys, asserted through the seam
    /// rather than at the planner.
    @Test func salvageInAnUnmeshedSystemIsNotLaunchedFor() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedSeamWorld(db, salvageAt: nil)
            // Rich, close, and unmeshed: no relay is seeded at ALTAIR.
            try seedStar(db, designation: "ALTAIR", x: 3, y: 0, z: 0)
            try seedSalvageAssay(db, id: "SITE-ALTAIR", system: "ALTAIR", totals: ["structural": 9_000])
        }

        let (row, commands, _) = try await driveSeam(database, evaluations: 4)

        #expect(row == nil)
        #expect(commands.isEmpty)
    }
}
