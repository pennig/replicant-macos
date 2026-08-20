//
//  WorldCore.swift
//  Replicould — DirectiveEngine
//
//  The half of a world read that does not depend on which directive is asking:
//  13 fields, identical for all of them, and therefore read ONCE per tick
//  rather than once per directive. Splitting this out is what took the engine
//  from 22 whole-table reads every five seconds to one.
//

import Foundation
import GameModels
import SQLiteData
import UniverseModels

/// The directive-independent half of `WorldSnapshot` — every field a step
/// machine would otherwise re-fetch once per directive, read here once.
public struct WorldCore: Equatable, Sendable {
    public let devices: [String: Device]
    public let openOperations: [String: GameModels.Operation]
    public let queuedOperations: [String: [GameModels.Operation]]
    public let footprints: [String: LocationFootprint]
    public let starPositions: [String: Position]
    public let components: [String: String]
    public let blueprintBills: [String: ResourceCost]
    public let blueprintComponents: [String: [String: Int]]
    public let blueprintPrintTimes: [String: Int]
    public let theatres: [Theatre]
    public let locationEvents: [String: LocationEvent]
    public let replicantHostDevices: Set<String>
    public let peers: [Directive]

    public init(
        devices: [String: Device],
        openOperations: [String: GameModels.Operation],
        queuedOperations: [String: [GameModels.Operation]],
        footprints: [String: LocationFootprint],
        starPositions: [String: Position],
        components: [String: String],
        blueprintBills: [String: ResourceCost],
        blueprintComponents: [String: [String: Int]],
        blueprintPrintTimes: [String: Int],
        theatres: [Theatre],
        locationEvents: [String: LocationEvent],
        replicantHostDevices: Set<String>,
        peers: [Directive]
    ) {
        self.devices = devices
        self.openOperations = openOperations
        self.queuedOperations = queuedOperations.mapValues {
            $0.sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt }
        }
        self.footprints = footprints
        self.starPositions = starPositions
        self.components = components
        self.blueprintBills = blueprintBills
        self.blueprintComponents = blueprintComponents
        self.blueprintPrintTimes = blueprintPrintTimes
        self.theatres = theatres
        self.locationEvents = locationEvents
        self.replicantHostDevices = replicantHostDevices
        self.peers = peers
    }

    /// One consistent read of everything a world read needs regardless of
    /// which directive is asking. Call inside a `database.read { db in … }`
    /// block, same as `WorldView.read`.
    public static func read(from db: Database) throws -> WorldCore {
        let devices = try Device.all.fetchAll(db)
        let operations = try GameModels.Operation
            .where { $0.status.in(OperationStatus.openCases) }
            .fetchAll(db)

        // The in-force rows, this directive's own included — see `peers`.
        // Status-scoped by `DirectiveStatus.openCases`: a directive
        // still owning its carrier is still competing for stock; a finished
        // one is not.
        let peers = try Directive
            .where { $0.status.in(DirectiveStatus.openCases) }
            .fetchAll(db)

        // Whole table by design — see the property's doc comment. Read in
        // the SAME transaction as everything else so a mission never sees a
        // pile that a device row from a different instant contradicts.
        let footprintRows = try LocationFootprint.all.fetchAll(db)
        let footprints = Dictionary(
            footprintRows.map { ($0.location, $0) }, uniquingKeysWith: { _, last in last }
        )

        // Same geometry `WorldView.read` computes: a haul candidate must
        // sit in the delivering theatre's own mesh COMPONENT, not merely be meshed.
        // Four columns, never the whole row: this is a `[String: Position]`
        // and nothing here reads the rest. `Star` carries three `Date`
        // columns, and decoding a Date means an ISO-8601 parse per row —
        // at catalogue scale that parse cost dominated this whole read
        // while its result was discarded on the next line.
        let starRows = try Star.all
            .select { ($0.designation, $0.positionX, $0.positionY, $0.positionZ) }
            .fetchAll(db)
        let starPositions = Dictionary(
            starRows.map { ($0.0, Position(x: $0.1, y: $0.2, z: $0.3)) },
            uniquingKeysWith: { _, last in last }
        )
        let mesh = SalvageTargetPlanner.meshSystems(in: devices)
        let components = MeshGraph(positions: starPositions).components(of: mesh)

        let blueprintRows = try Blueprint.all
            .select { ($0.deviceType, $0.resources, $0.components, $0.printTime) }
            .fetchAll(db)
        let blueprintBills = Dictionary(
            blueprintRows.map { ($0.0, $0.1) }, uniquingKeysWith: { _, last in last }
        )
        let blueprintComponents = Dictionary(
            blueprintRows.map { ($0.0, $0.2) }, uniquingKeysWith: { _, last in last }
        )
        let blueprintPrintTimes = Dictionary(
            blueprintRows.map { ($0.0, $0.3) }, uniquingKeysWith: { _, last in last }
        )

        // Same `TheatreRegistry` call `WorldView.read` makes — two lists
        // of theatres in one process would be a real hazard.
        let pins = try TheatrePin.all.fetchAll(db)
        let theatres = TheatreRegistry.recognise(
            devices: devices, pins: pins,
            records: try TheatreRecord.order { $0.depot }.fetchAll(db), meshSystems: mesh,
            components: components, stockByLocation: footprints.mapValues(\.resources)
        )

        // Whole table, like `footprints` — a convoy must see the row it
        // is about to commit, in this same transaction.
        let eventRows = try LocationEvent.all.fetchAll(db)
        let locationEvents = Dictionary(
            eventRows.map { ($0.designation, $0) }, uniquingKeysWith: { _, last in last }
        )
        let replicantHostDevices = Set(
            try Replicant.all.fetchAll(db).compactMap(\.hostedDeviceCode)
        )

        return WorldCore(
            devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
            openOperations: Dictionary(
                operations.filter { $0.status == .active }.map { ($0.entityCode, $0) },
                uniquingKeysWith: { _, last in last }
            ),
            queuedOperations: Dictionary(grouping: operations, by: \.entityCode),
            footprints: footprints,
            starPositions: starPositions,
            components: components,
            blueprintBills: blueprintBills,
            blueprintComponents: blueprintComponents,
            blueprintPrintTimes: blueprintPrintTimes,
            theatres: theatres,
            locationEvents: locationEvents,
            replicantHostDevices: replicantHostDevices,
            peers: peers
        )
    }
}
