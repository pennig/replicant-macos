//
//  WorldView.swift
//  Replicould — DirectiveEngine
//
//  The galaxy as the automation brain sees it: one consistent read of every
//  meshed system, every census star position, every non-depleted salvage
//  assay, every live location event, and the print hub — the single input
//  every later brain task (pathfinding, value ranking, prune analysis)
//  consumes.
//
//  A sibling to `WorldSnapshot`, but wider on purpose: `WorldSnapshot` scopes
//  systems to one directive's `wanted` set because decoding thousands of
//  `StarSystem` blobs per tick would be real cost; the brain instead needs
//  galaxy scope to rank ACROSS the whole census, so this reads only the cheap
//  tables — devices, `stars`, `siteAssays`, `locationEvents` — and touches no
//  blob.
//
//  `beltsBySystem` (Task 11): the one blob decode in this whole read. Every
//  other field above comes from a cheap table; belt richness only exists
//  inside the per-system `StarSystem` JSON blob (`SystemDetail.systemJSON`),
//  and decoding all ~14,000 census systems every 5-second tick would be the
//  most expensive thing the brain does. Bounded two ways before a single
//  blob is touched: SURVEYED — `SystemDetail.systemScanned` filters in SQL,
//  since belt richness is only known once a system has been through its full
//  system scan (see the field's doc below for why this is the right signal
//  over `recon == .scanned`) — and UNMESHED — a meshed system needs no
//  grow-scoring, so its blob is skipped in Swift before `.system()` is ever
//  called. A single malformed blob degrades to "no belt data for this
//  system" rather than failing the whole read (mirrors the same-shaped
//  decode-failure handling in the sibling `WorldSnapshot` read). If this
//  decode set ever grows past what's comfortable on a 5-second tick, the
//  documented escape hatch is a dedicated `belts` index table populated at
//  hydrate time — not built now, YAGNI until the count actually demands it.
//

import Foundation
import GameModels
import OSLog
import SQLiteData
import UniverseModels

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Brain")

public struct WorldView: Equatable, Sendable {
    /// The whole fleet, by device code — the brain ranks across every
    /// device, not a directive-scoped subset.
    public let devices: [String: Device]
    /// Census star position, by system designation.
    public let starPositions: [String: Position]
    /// Systems currently on the mesh: those holding a relay that is actually
    /// relaying. Derived from device rows via
    /// `SalvageTargetPlanner.meshSystems(in:)` — see that function's doc for
    /// why device rows are authoritative over the `ftlLinks` table.
    public let meshSystems: Set<String>
    /// System → summed non-depleted salvage assay units. A depleted site's
    /// totals are excluded even though `totals` only ever rises — `depleted`
    /// is the sole signal a site is spent (mirrors
    /// `SalvageTargetPlanner.nextTarget`'s ranking).
    public let salvageUnits: [String: Double]
    /// Systems holding at least one live (`LocationEvent.isActive`) location
    /// event.
    public let eventSystems: Set<String>
    /// The print hub's location, but only when its system is meshed — an
    /// off-mesh hub is a later concern (escalate/unsupported per the 06
    /// design), not something the brain can route a `deliver` toward yet.
    public let hubLocation: String?
    /// System → its belts, classified. Populated only for systems that are
    /// both surveyed (`SystemDetail.systemScanned`) and unmeshed — see the
    /// module doc above for why. A system with belts in its blob that all
    /// fail to classify (`BeltClass.classify` returns `nil`) is simply
    /// absent here, same as a system with no belts at all.
    public let beltsBySystem: [String: [BeltInfo]]
    /// The moment this snapshot was taken. Brain logic compares against this
    /// rather than `Date()`, keeping ranking passes pure and their tests
    /// deterministic.
    public let now: Date

    public init(
        devices: [String: Device],
        starPositions: [String: Position],
        meshSystems: Set<String>,
        salvageUnits: [String: Double],
        eventSystems: Set<String>,
        hubLocation: String?,
        beltsBySystem: [String: [BeltInfo]] = [:],
        now: Date
    ) {
        self.devices = devices
        self.starPositions = starPositions
        self.meshSystems = meshSystems
        self.salvageUnits = salvageUnits
        self.eventSystems = eventSystems
        self.hubLocation = hubLocation
        self.beltsBySystem = beltsBySystem
        self.now = now
    }

    /// One consistent, galaxy-wide read of everything the brain reasons over.
    /// Called from inside a `database.read { db in … }` block, mirroring how
    /// `DirectiveEngine`'s roam-context read composes several `@Table` reads
    /// in a single transaction.
    public static func read(from db: Database, now: Date) throws -> WorldView {
        let allDevices = try Device.all.fetchAll(db)
        let devicesByCode = Dictionary(
            allDevices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }
        )

        let mesh = SalvageTargetPlanner.meshSystems(in: allDevices)

        let stars = try Star.all.fetchAll(db)
        var positions: [String: Position] = [:]
        for star in stars { positions[star.designation] = star.position }

        // Sum non-depleted salvage assay units per system. A depleted site's
        // totals are excluded even though `totals` only ever rises —
        // `depleted` is the sole signal a site is spent.
        let assays = try SiteAssay.where { !$0.depleted && $0.siteType.eq("salvage") }.fetchAll(db)
        var salvage: [String: Double] = [:]
        for assay in assays {
            salvage[assay.system, default: 0] += assay.totals.values.reduce(0, +)
        }

        // `locationEvents` is a small quest ledger (tens of rows, not
        // thousands), so filtering through `isActive` in Swift after a
        // whole-table read is cheap and guarantees exact parity with that
        // property's case-insensitive semantics — a SQL `= 'active'` would
        // silently miss a differently-cased status.
        let events = try LocationEvent.all.fetchAll(db)
        let eventSystems = Set(
            events.filter(\.isActive).map { SiteAssay.system(of: $0.location) }
        )

        let hub = Self.hubLocation(in: allDevices, meshSystems: mesh)

        let belts = try Self.beltsBySystem(in: db, meshSystems: mesh)

        return WorldView(
            devices: devicesByCode,
            starPositions: positions,
            meshSystems: mesh,
            salvageUnits: salvage,
            eventSystems: eventSystems,
            hubLocation: hub,
            beltsBySystem: belts,
            now: now
        )
    }

    /// The bounded belt decode (see the module doc for why it must be
    /// bounded at all). SQL narrows to the surveyed subset before any row's
    /// `systemJSON` even leaves the database — the expensive direction to
    /// filter, since most of the census is never scanned. `meshSystems` is
    /// Swift-derived from device rows (`SalvageTargetPlanner.meshSystems`
    /// has no SQL-expressible equivalent to push down), so the unmeshed
    /// filter runs here, over that already-small surveyed set, and — this is
    /// the point — strictly BEFORE `.system()` decodes anything, so a meshed
    /// system's blob is never touched at all, not decoded-then-discarded.
    private static func beltsBySystem(
        in db: Database, meshSystems: Set<String>
    ) throws -> [String: [BeltInfo]] {
        let surveyed = try SystemDetail.where { $0.systemScanned }.fetchAll(db)
        let candidates = surveyed.filter { !meshSystems.contains($0.designation) }

        var belts: [String: [BeltInfo]] = [:]
        // Failures are tallied, not logged per-row: this loop runs every
        // 5-second tick, and a permanently-malformed row would otherwise
        // flood the log forever (once per read × however many bad rows).
        // `firstFailure` keeps one breadcrumb for diagnosability without
        // per-row volume.
        var failures = 0
        var firstFailure: String?
        for detail in candidates {
            let system: StarSystem
            do {
                system = try detail.system()
            } catch {
                // One bad row must not take the whole galaxy-wide read down —
                // degrade to "no belt data for this system" and keep going,
                // the same direction `WorldSnapshot`'s per-directive blob
                // read already degrades a failed decode.
                failures += 1
                if firstFailure == nil { firstFailure = detail.designation }
                continue
            }
            let classified = system.belts.compactMap { belt -> BeltInfo? in
                BeltClass.classify(density: belt.density, richness: belt.richness)
                    .map { BeltInfo(designation: belt.designation, beltClass: $0) }
            }
            if !classified.isEmpty {
                belts[detail.designation] = classified
            }
        }

        // One line per read, regardless of candidate count or failure count
        // — the performance guard the module doc promises.
        if let firstFailure {
            logger.debug(
                """
                belts: decoded \(candidates.count - failures, privacy: .public) surveyed/unmeshed \
                system blob(s), \(failures, privacy: .public) failed (first: \(firstFailure, privacy: .public))
                """
            )
        } else {
            logger.debug(
                "belts: decoded \(candidates.count, privacy: .public) surveyed/unmeshed system blob(s)"
            )
        }
        return belts
    }

    /// The single print hub this effort: the autofactory device's location,
    /// but only if that system is meshed (an off-mesh hub is out of the
    /// brain's reach until `tendMesh` brings it on — 06).
    static func hubLocation(in devices: [Device], meshSystems: Set<String>) -> String? {
        guard let hub = devices.first(where: { $0.isPrintHub })?.location else { return nil }
        return meshSystems.contains(SiteAssay.system(of: hub)) ? hub : nil
    }
}
