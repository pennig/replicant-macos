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
        self.queuedOperations = queuedOperations.mapValues {
            $0.sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt }
        }
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
        // Assays are scoped to every target — one small row each, and a roam
        // planner ranks across the whole tour.
        let baseWanted = Set(directive.targets)
            .union(directive.originDesignation.map { [$0] } ?? [])
        // Blobs are scoped to the CURRENT target only. Every reader of
        // `systems` asks about `directive.currentTarget`, never a later one,
        // and a roaming run's target list grows without bound — at a few
        // hundred targets, decoding one blob each dominated the whole read.
        let baseDecoded = Set(directive.currentTarget.map { [$0] } ?? [])
            .union(directive.originDesignation.map { [$0] } ?? [])
        let directiveID = directive.id
        let vesselCode = directive.deviceCode

        return try await database.read { db in
            let core = try WorldCore.read(from: db)

            // Newest `logWindow` first, then restored to ascending order — the
            // order every caller (`.reversed()` walks included) already expects.
            let log = try Array(DirectiveLogEntry
                .where { $0.directiveID.eq(directiveID) }
                .order { $0.occurredAt.desc() }
                .limit(Self.logWindow)
                .fetchAll(db)
                .reversed())

            // Matched in SQL, not Swift — see
            // `app/.claude/memory/dispatched-operations-two-set-union.md`.
            let auditLog = try DirectiveLogEntry
                .where { entry in
                    entry.directiveID.eq(directiveID)
                        && entry.kind.eq(DirectiveLogKind.commandDispatched)
                        && entry.operationID.isNot(nil)
                        && (entry.operationID ?? "").notIn(
                            DirectiveLogEntry
                                .where {
                                    $0.directiveID.eq(directiveID)
                                        && $0.kind.eq(DirectiveLogKind.opCompleted)
                                        && $0.operationID.isNot(nil)
                                }
                                .select { $0.operationID ?? "" }
                        )
                }
                .order { $0.occurredAt }
                .fetchAll(db)

            // Ids this directive dispatched — one query, never a
            // host-parameter list in Swift.
            let dispatchedIDs = DirectiveLogEntry
                .where {
                    $0.directiveID.eq(directiveID)
                        && $0.kind.eq(DirectiveLogKind.commandDispatched)
                        && $0.operationID.isNot(nil)
                }
                .select { $0.operationID ?? "" }

            // Mission half: kinds a machine reads. Owner column is truth; log
            // is the fallback for rows written before it existed.
            let missionOps = try GameModels.Operation
                .where { operation in
                    (operation.directiveID.eq(directiveID) || operation.id.in(dispatchedIDs))
                        && operation.kind.in(Self.dispatchedKinds)
                }
                .fetchAll(db)

            // Audit half, kept kind-agnostic on purpose. See
            // `app/.claude/memory/dispatched-operations-two-set-union.md`.
            let auditOperationIDs = auditLog.compactMap(\.operationID)
            let auditOps = auditOperationIDs.isEmpty
                ? []
                : try GameModels.Operation.where { $0.id.in(auditOperationIDs) }.fetchAll(db)

            let dispatched = Dictionary(
                (missionOps + auditOps).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            var wanted = baseWanted
            var decoded = baseDecoded
            if let vessel = core.devices[vesselCode],
               let location = vessel.location {
                // The arrival check reads the system the vessel is in now.
                wanted.insert(SiteAssay.system(of: location))
                decoded.insert(SiteAssay.system(of: location))
            }
            let details = try SystemDetail
                .where { $0.designation.in(Array(decoded)) }
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

            return WorldSnapshot(
                devices: core.devices,
                openOperations: core.openOperations,
                queuedOperations: core.queuedOperations,
                log: log,
                auditLog: auditLog,
                dispatchedOperations: dispatched,
                systems: systems,
                siteAssays: siteAssays,
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
}
