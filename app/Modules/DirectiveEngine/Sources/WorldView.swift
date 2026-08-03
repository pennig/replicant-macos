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
//  `beltsBySystem` (Task 9): belt yields are a blob-decode concern deferred
//  past this read — populated empty here since `read(from:now:)` touches no
//  blob (see the module doc above); Task 11 hydrates it from decoded `Belt`
//  data via `BeltClass.classify`, and Task 10 is its first consumer.
//

import Foundation
import GameModels
import SQLiteData
import UniverseModels

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
    /// System → its belts, classified. Always empty as of this task (Task
    /// 9) — the field exists so `BeltInfo` has a home on `WorldView`, but
    /// nothing populates it until Task 11 decodes belt data from the
    /// per-system blob.
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

        return WorldView(
            devices: devicesByCode,
            starPositions: positions,
            meshSystems: mesh,
            salvageUnits: salvage,
            eventSystems: eventSystems,
            hubLocation: hub,
            beltsBySystem: [:],  // Task 11 hydrates this from decoded belt data.
            now: now
        )
    }

    /// The single print hub this effort: the autofactory device's location,
    /// but only if that system is meshed (an off-mesh hub is out of the
    /// brain's reach until `tendMesh` brings it on — 06).
    static func hubLocation(in devices: [Device], meshSystems: Set<String>) -> String? {
        guard let hub = devices.first(where: { $0.isPrintHub })?.location else { return nil }
        return meshSystems.contains(SiteAssay.system(of: hub)) ? hub : nil
    }
}
