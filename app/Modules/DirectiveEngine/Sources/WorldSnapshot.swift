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
    /// The active operation per device, by device code — the job actually on
    /// the platen. A queued job is not here; ask `queuedOperations` for those.
    public let openOperations: [String: GameModels.Operation]
    /// Every OPEN operation per device (`optimistic` included), oldest first —
    /// `(startedAt, id)` tie-broken, since two ops in one transaction can share
    /// a `startedAt`. Several entries when a bench has jobs queued behind the active one.
    public let queuedOperations: [String: [GameModels.Operation]]
    /// This directive's newest `logWindow` timeline entries, ascending.
    /// Completion detection reads the `directive.completed` ROW here rather
    /// than the event, which is what keeps missions replay-immune.
    public let log: [DirectiveLogEntry]
    /// The audit pass's live worklist — unmatched `.commandDispatched` entries,
    /// matched in SQL, never windowed by count. See
    /// `app/.claude/memory/dispatched-operations-two-set-union.md`.
    public let auditLog: [DirectiveLogEntry]
    /// This directive's dispatched operations, by id — including closed ones;
    /// union of a kind-filtered mission set and an audit set, never folded into
    /// `openOperations`. See `app/.claude/memory/dispatched-operations-two-set-union.md`.
    public let dispatchedOperations: [String: GameModels.Operation]
    /// Cached `StarSystem` blobs, by star designation. Only the CURRENT target,
    /// the origin and the vessel's own system are decoded — never the rest of
    /// the tour, whose blobs no reader asks for and whose count is unbounded.
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
    /// The other in-force directives, INCLUDING this one — read in the SAME
    /// transaction as the devices, and the basis of `RelayRun.isNextInLine`.
    /// See `app/.claude/memory/world-snapshot-peers-fifo.md`.
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

    /// Kinds `dispatchedOperations`'s mission half carries; widen only
    /// alongside a new consumer. See
    /// `app/.claude/memory/dispatched-operations-two-set-union.md`.
    static let dispatchedKinds = [OperationKind.print.rawValue, OperationKind.travel.rawValue]

    public init(
        devices: [String: Device],
        openOperations: [String: GameModels.Operation],
        queuedOperations: [String: [GameModels.Operation]] = [:],
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
        self.queuedOperations = queuedOperationsSorted(queuedOperations)
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
    /// The active operation for the device `code` names, if it has one.
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
        try await database.read { db in
            let core = try WorldCore.read(from: db)
            let slice = try DirectiveSlice.read(from: db, core: core, directive: directive)
            return WorldSnapshot(core: core, slice: slice, now: now)
        }
    }

    /// Composes the two halves of a world read into the public shape — the
    /// point where `WorldCore` and `DirectiveSlice` become indistinguishable
    /// from a direct `read`.
    init(core: WorldCore, slice: DirectiveSlice, now: Date) {
        self.init(
            devices: core.devices,
            openOperations: core.openOperations,
            queuedOperations: core.queuedOperations,
            log: slice.log,
            auditLog: slice.auditLog,
            dispatchedOperations: slice.dispatchedOperations,
            systems: slice.systems,
            siteAssays: slice.siteAssays,
            footprints: core.footprints,
            starPositions: core.starPositions,
            components: core.components,
            blueprintBills: core.blueprintBills,
            blueprintComponents: core.blueprintComponents,
            blueprintPrintTimes: core.blueprintPrintTimes,
            theatres: core.theatres,
            locationEvents: core.locationEvents,
            replicantHostDevices: core.replicantHostDevices,
            peers: core.peers,
            now: now
        )
    }
}
