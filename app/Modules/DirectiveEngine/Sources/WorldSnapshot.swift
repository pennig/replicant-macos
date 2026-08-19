//
//  WorldSnapshot.swift
//  Replicould — DirectiveEngine
//
//  The world as a step machine sees it: one consistent read of reconciled
//  SQLite state, keyed for lookup. Missions are pure functions over this — they
//  perform no I/O and never see a raw event, so they stay testable as fixtures
//  and immune to replay.
//

import Foundation
import GameModels
import SQLiteData
import UniverseModels

// `GameModels.Operation` is qualified throughout rather than aliased: a
// file-private typealias cannot appear in this type's public API, and
// `Foundation.Operation` would otherwise win the name.

/// One directive-scoped read, as `read(from:now:directive:)` takes it. Inert and
/// value-typed: a step machine evaluates against this and writes nothing back,
/// so every step in an evaluation sees the same instant.
public struct WorldSnapshot: Equatable, Sendable {
    /// The fleet, by device code.
    public let devices: [String: Device]
    /// The single OPEN operation per device, by device code. Closed ops are
    /// excluded: a step machine asks "is this device busy?", and a completed op
    /// is not busy.
    public let openOperations: [String: GameModels.Operation]
    /// This directive's newest `logWindow` timeline entries, ascending.
    /// Completion detection reads the `directive.completed` ROW here rather
    /// than the event, which is what keeps missions replay-immune.
    public let log: [DirectiveLogEntry]
    /// This directive's FULL `.commandDispatched`/`.opCompleted` history —
    /// unlike `log`, never windowed, so an op dispatched long before `log`'s
    /// cutoff can still be resolved by `DirectiveExecutor`'s audit pass.
    public let auditLog: [DirectiveLogEntry]
    /// The operations this directive dispatched, by operation id — **including
    /// closed ones**, so the audit pass can notice a dispatched op reaching a
    /// terminal state and write its `.opCompleted` entry. Scoped to the ids
    /// named by this directive's own `.commandDispatched` log entries, so it
    /// stays a handful of rows rather than the whole table.
    ///
    /// Never fold these into `openOperations`: a mission asking "is this device
    /// busy?" reads that lookup, and a closed op inside it reads as in-flight.
    public let dispatchedOperations: [String: GameModels.Operation]
    /// Cached `StarSystem` blobs for the systems this directive cares about, by
    /// star designation. Only the directive's own targets (plus its origin and
    /// the vessel's current system) are decoded: decoding the whole catalogue
    /// costs real time at thousands of bodies.
    public let systems: [String: StarSystem]
    /// Stored assay totals for the salvage sites in this directive's systems,
    /// keyed by SITE designation (`TOSLIT-3-2-SAL-1`) — the shape
    /// `StarSystem.salvageBodies(totals:)` expects.
    ///
    /// Read from `SiteAssay` rather than derived from the system blob: a site's
    /// ORIGINAL unit total arrives once, on `salvage.discovered`, and the
    /// catalogue payload never carries it, so every re-scan's blob rewrite
    /// clobbers it. Without this table a mission sees only percentages, and a
    /// roster-sourced site's percentages are empty.
    public let siteAssays: [String: [String: Double]]
    /// Every known location's holdings summary, by location designation — the
    /// stockpile census the Haul Run ranks over.
    ///
    /// Read WHOLE, unlike `systems`/`siteAssays`, which are scoped to `wanted`
    /// because decoding body blobs is expensive: this table holds one tiny row
    /// per known location and the planner's whole job is to compare all of
    /// them. Scoping it to the directive's targets hides exactly the piles the
    /// run exists to find.
    ///
    /// Kept as the whole row rather than the unit count alone because the
    /// machine needs `fetchedAt` too: `surveying` gates its refresh on how
    /// stale the census is, which a bare `[String: Int]` cannot answer.
    public let footprints: [String: LocationFootprint]
    /// Census star position, by system designation — the geometry the Haul
    /// Run's round-trip ranking reads. Whole-table, like `footprints`.
    public let starPositions: [String: Position]
    /// System → mesh-component label (`MeshGraph.components(of:)`), so a haul
    /// candidate is filtered to the delivering theatre's own component.
    public let components: [String: String]
    /// Device type → its blueprint's build cost, mirroring `WorldView`. Distinct
    /// from `components` above, which is the FTL mesh.
    public let blueprintBills: [String: ResourceCost]
    /// Device type → the printed devices its blueprint consumes.
    public let blueprintComponents: [String: [String: Int]]
    /// Device type → how many seconds one unit takes to print. Absent means the
    /// catalogue has never been read for that type, never "instant".
    public let blueprintPrintTimes: [String: Int]
    /// Every recognised theatre, mirroring `WorldView.theatres` — the same
    /// `TheatreRegistry` call, so the two views cannot disagree.
    public let theatres: [Theatre]
    /// The whole location-event ledger by designation, mirroring
    /// `WorldView.locationEvents`. Read whole like `footprints`: it is one
    /// small row per known event, and a convoy must see the row it commits.
    public let locationEvents: [String: LocationEvent]
    /// The devices the replicant roster is hosted in, mirroring
    /// `WorldView.replicantHostDevices`. Hosting is a roster fact, never a
    /// device column — `Device.replicantCode` records ownership instead.
    public let replicantHostDevices: Set<String>
    /// The other in-force directives, INCLUDING this one — the rows a mission
    /// needs to see to know what its siblings already own.
    ///
    /// **Every other field here answers "what is the world like?"; this one
    /// answers "who else is competing for it?"** Most steps need neither — the
    /// directive row is the lease ledger and `Brain.reservedDevices` does the
    /// allocating, so a mission never arbitrates for a leased device.
    ///
    /// The exception is claiming shared stock no lease covers. Idle relays
    /// standing at a print hub belong to nobody: they are unstowed, no
    /// directive names them, and the brain cannot pre-assign them because it
    /// allocates at LAUNCH while a run claims one much later, once a print
    /// completes. Two Relay Runs are independent `Task`s on independent
    /// five-second clocks (`DirectiveEngine.makeExecutor`), so "whoever asks
    /// first" is a real race with no serialising authority above it; peers let
    /// a run settle it itself by asking whether it is the oldest waiting run at
    /// this hub (`RelayRun.isNextInLine`), which is what makes the claim
    /// race-free and FIFO.
    ///
    /// Read in the SAME transaction as the devices, so a run can never see a
    /// peer's row from one instant against a fleet from another.
    public let peers: [Directive]
    /// The moment this snapshot was taken. Every time comparison in a mission
    /// uses this rather than `Date()`, so step machines stay pure and their
    /// tests deterministic.
    public let now: Date

    /// The one theatre rule, over this snapshot's own geometry — `WorldView`
    /// holds the identical value, so a mission and the brain cannot disagree.
    public let theatreResolver: TheatreResolver

    /// Newest entries kept for `log`. HaulRun's `dispatchAttemptCount` — the
    /// deepest `world.log` walk-back — stays under a few hundred entries even
    /// with many interleaved controllers; 500 leaves headroom.
    public static let logWindow = 500

    public init(
        devices: [String: Device],
        openOperations: [String: GameModels.Operation],
        log: [DirectiveLogEntry] = [],
        auditLog: [DirectiveLogEntry] = [],
        dispatchedOperations: [String: GameModels.Operation] = [:],
        systems: [String: StarSystem] = [:],
        siteAssays: [String: [String: Double]] = [:],
        footprints: [String: LocationFootprint] = [:],
        starPositions: [String: Position] = [:],
        components: [String: String] = [:],
        blueprintBills: [String: ResourceCost] = [:],
        blueprintComponents: [String: [String: Int]] = [:],
        blueprintPrintTimes: [String: Int] = [:],
        theatres: [Theatre] = [],
        locationEvents: [String: LocationEvent] = [:],
        replicantHostDevices: Set<String> = [],
        peers: [Directive] = [],
        now: Date
    ) {
        self.devices = devices
        self.openOperations = openOperations
        self.log = log
        self.auditLog = auditLog
        self.dispatchedOperations = dispatchedOperations
        self.systems = systems
        self.siteAssays = siteAssays
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
        self.now = now
        self.theatreResolver = TheatreResolver(
            theatres: theatres, starPositions: starPositions, components: components
        )
    }

    /// The row for the device `code` names, or nil when the fleet read has none.
    public func device(_ code: String) -> Device? { devices[code] }
    /// The single OPEN operation for the device `code` names, if it has one.
    public func openOperation(for code: String) -> GameModels.Operation? { openOperations[code] }
    /// The device's live op only when it belongs to `owner`; a nil `owner`
    /// keeps `openOperation(for:)`'s meaning, and an op with no owner of its
    /// own is never filtered out either way.
    public func openOperation(for code: String, owner directiveID: String?) -> GameModels.Operation? {
        guard let op = openOperations[code], let directiveID, let opOwner = op.directiveID else {
            return openOperations[code]
        }
        return opOwner == directiveID ? op : nil
    }
    /// `device.updatedAt >= watermark`. The one freshness predicate missions
    /// use from now on.
    public func isFresh(_ device: Device, since watermark: Date) -> Bool {
        device.updatedAt >= watermark
    }
    /// The decoded blob for the system `designation` names, or nil when it was
    /// out of `wanted` scope or failed to decode — the two are indistinguishable
    /// here, and both mean "this mission cannot prove anything about it".
    public func system(_ designation: String) -> StarSystem? { systems[designation] }
    /// The row for the event `designation` names, or nil when the ledger has none.
    public func event(_ designation: String) -> LocationEvent? { locationEvents[designation] }

    /// The depot of the theatre `directive` serves, resolved off its own row —
    /// nil when the row is unstamped or names a non-operational depot. Never
    /// falls back to another theatre.
    public func theatreDepot(for directive: Directive) -> String? {
        guard let depot = directive.theatreDepot else { return nil }
        return theatres.first { $0.depot == depot && $0.isOperational }?.depot
    }

    /// Whether `directive` is stamped to a theatre that has gone `.claimed`
    /// while another theatre stands `.operational` — the state a mission must
    /// idle through rather than paper over with a stand-in designation.
    public func theatreWentClaimed(for directive: Directive) -> Bool {
        guard let depot = directive.theatreDepot, theatreDepot(for: directive) == nil else { return false }
        return theatres.contains { $0.depot != depot && $0.isOperational }
    }

    /// One consistent read of everything a mission reasons over, taken from
    /// `database` at the instant `now` and scoped to `directive` — its targets,
    /// its origin, its log and the operations it dispatched.
    public static func read(
        from database: any DatabaseReader,
        now: Date,
        directive: Directive
    ) async throws -> WorldSnapshot {
        // The systems worth decoding: every target, the origin, and whatever
        // system the vessel is in right now (the arrival check needs it).
        let baseWanted = Set(directive.targets)
            .union(directive.originDesignation.map { [$0] } ?? [])
        let directiveID = directive.id
        let vesselCode = directive.deviceCode

        return try await database.read { db in
            let devices = try Device.all.fetchAll(db)
            let operations = try GameModels.Operation
                .where { $0.status.in(OperationStatus.openCases) }
                .fetchAll(db)
            // Newest `logWindow` first, then restored to ascending order — the
            // order every caller (`.reversed()` walks included) already expects.
            let log = try Array(DirectiveLogEntry
                .where { $0.directiveID.eq(directiveID) }
                .order { $0.occurredAt.desc() }
                .limit(Self.logWindow)
                .fetchAll(db)
                .reversed())

            // Unbounded and kind-scoped, unlike `log`: an old-enough dispatch
            // must stay resolvable after `log`'s window rolls past it.
            let auditLog = try DirectiveLogEntry
                .where { $0.directiveID.eq(directiveID) && $0.kind.in([DirectiveLogKind.commandDispatched, .opCompleted]) }
                .order { $0.occurredAt }
                .fetchAll(db)
            let dispatchedIDs = Array(Set(auditLog.compactMap { entry in
                entry.kind == .commandDispatched ? entry.operationID : nil
            }))
            // The owner column is the source of truth; the log join is a
            // fallback for rows written before it existed.
            let ownedDispatched = try GameModels.Operation
                .where { $0.directiveID.eq(directiveID) }
                .fetchAll(db)
            let legacyDispatched = dispatchedIDs.isEmpty ? [] : try GameModels.Operation
                .where { $0.id.in(dispatchedIDs) }
                .fetchAll(db)
            let dispatched = Dictionary(
                (ownedDispatched + legacyDispatched).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            // The in-force rows, this directive's own included — see `peers`.
            // Status-scoped by `DirectiveStatus.openCases`: a directive
            // still owning its carrier is still competing for stock; a finished
            // one is not.
            let peers = try Directive
                .where { $0.status.in(DirectiveStatus.openCases) }
                .fetchAll(db)

            var wanted = baseWanted
            if let vessel = devices.first(where: { $0.deviceCode == vesselCode }),
               let location = vessel.location {
                wanted.insert(SiteAssay.system(of: location))
            }
            let details = try SystemDetail
                .where { $0.designation.in(Array(wanted)) }
                .fetchAll(db)
            let systems = details.reduce(into: [String: StarSystem]()) { systems, detail in
                // A blob that fails to decode is treated as absent: the mission
                // then can't prove the target is scanned and surveys it again,
                // which is the safe direction to be wrong in.
                if let system = try? detail.system() { systems[detail.designation] = system }
            }

            // Same `wanted` scope as the system blobs above — never the whole
            // table. `SiteAssay.system` is exactly the leading-segment
            // designation `wanted` is built from (`SiteAssay.system(of:)`).
            let assays = try SiteAssay
                .where { $0.system.in(Array(wanted)) }
                .fetchAll(db)
            let siteAssays = Dictionary(assays.map { ($0.id, $0.totals) }, uniquingKeysWith: { _, last in last })

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

            return WorldSnapshot(
                devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
                openOperations: Dictionary(operations.map { ($0.entityCode, $0) }, uniquingKeysWith: { _, last in last }),
                log: log,
                auditLog: auditLog,
                dispatchedOperations: dispatched,
                systems: systems,
                siteAssays: siteAssays,
                footprints: footprints,
                starPositions: starPositions,
                components: components,
                blueprintBills: blueprintBills,
                blueprintComponents: blueprintComponents,
                blueprintPrintTimes: blueprintPrintTimes,
                theatres: theatres,
                locationEvents: locationEvents,
                replicantHostDevices: replicantHostDevices,
                peers: peers,
                now: now
            )
        }
    }
}
