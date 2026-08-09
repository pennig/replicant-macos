//
//  WorldView.swift
//  Replicould — DirectiveEngine
//
//  The galaxy as the automation brain sees it: one consistent read of the mesh,
//  census positions, live assays and events, uncollected units, the replicants and
//  the print hub — the single input every brain pass consumes. Wider than the
//  sibling `WorldSnapshot`, which scopes to one directive because decoding
//  thousands of `StarSystem` blobs per tick is real cost, so this reads the cheap
//  tables and touches exactly one blob field.
//
//  That field is `beltsBySystem`, and SURVEY is the SOLE bound holding its cost
//  off — `SystemDetail.systemScanned`, applied in SQL before any blob leaves the
//  database. Widen it only against a measurement. A malformed blob degrades to
//  "no belt data for that system" rather than failing the read.
//

import Foundation
import GameModels
import OSLog
import SQLiteData
import UniverseModels

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Brain")

/// One tick's galaxy-wide read, as `read(from:now:)` takes it. Inert and
/// value-typed: a brain pass ranks over this and writes nothing back, so every
/// pass in a tick sees the same instant.
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
    /// The print hub's LOCATION (`SOL-3-1`, not the bare system), non-nil only when
    /// its system is meshed. **The one hub recognition rule** — re-derive from here
    /// rather than from `Directive.originDesignation`, which is a bare system
    /// designation and travels to an entry point an L4 away from the printer.
    public let hubLocation: String?
    /// System → its belts, classified, for every SURVEYED system whether meshed or
    /// not: prune needs the belts of systems already REACHED, or a reached mine's
    /// own relay reads as useless. A system whose belts all fail to classify is
    /// absent here exactly as one with no belts is — read `surveyedSystems` to tell
    /// those from "never looked".
    public let beltsBySystem: [String: [BeltInfo]]
    /// Every system holding one of the account's replicants — **where command
    /// authority comes from**, so `PrunePredicate` must never offer up the relays
    /// connecting them. A replicant mid-flight is NOT filtered out: whichever end
    /// `currentStar` names, treating it as authority-bearing only ADDS a pin, and
    /// over-pinning is the safe direction.
    public let replicantSystems: Set<String>
    /// The device codes that HOST a replicant. A carrier absent from this set must
    /// never be a reclaim source: the reclaim path deactivates the source relay, so
    /// authority for the following `stow` comes only from a replicant present.
    public let replicantHostDevices: Set<String>
    /// System → summed units already extracted and awaiting a Haul Run. Distinct in
    /// kind from `salvageUnits`, which is value still IN THE GROUND — depletion is
    /// what produces a pile, so without this the two move in opposite directions at
    /// the same instant. Bounded in SQL to rows holding units, or it would pin every
    /// system the fleet has ever visited.
    public let stockpileUnits: [String: Int]
    /// Systems that have been through a full system scan. Carried separately because
    /// `beltsBySystem` cannot tell "surveyed, holds no belt" from "never looked" —
    /// both are simply absent — and prune needs that distinction, since unknown
    /// value reads as pinned.
    public let surveyedSystems: Set<String>
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
        surveyedSystems: Set<String> = [],
        replicantSystems: Set<String> = [],
        replicantHostDevices: Set<String> = [],
        stockpileUnits: [String: Int] = [:],
        now: Date
    ) {
        self.devices = devices
        self.starPositions = starPositions
        self.meshSystems = meshSystems
        self.salvageUnits = salvageUnits
        self.eventSystems = eventSystems
        self.hubLocation = hubLocation
        self.beltsBySystem = beltsBySystem
        self.surveyedSystems = surveyedSystems
        self.replicantSystems = replicantSystems
        self.replicantHostDevices = replicantHostDevices
        self.stockpileUnits = stockpileUnits
        self.now = now
    }

    /// One consistent, galaxy-wide read of everything the brain reasons over,
    /// taken from `db` and stamped `now`. Call it from inside a
    /// `database.read { db in … }` block: every table below must be read in ONE
    /// transaction, or the brain ranks a fleet from one instant against a census
    /// from another.
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

        // `locationEvents` is a small quest ledger, so filtering through
        // `isActive` in Swift after a whole-table read is cheap and keeps exact
        // parity with that property's case-insensitive semantics — a SQL
        // `= 'active'` silently misses a differently-cased status.
        let events = try LocationEvent.all.fetchAll(db)
        let eventSystems = Set(
            events.filter(\.isActive).map { SiteAssay.system(of: $0.location) }
        )

        // The census rows for the print-capable locations, and only those — a
        // handful of codes, never the whole table. Read in the SAME transaction
        // as the devices, so the hub can never be recognised from a stockpile
        // reading belonging to a different instant than the printer that
        // justifies it.
        let printLocations = Set(allDevices.filter(\.isPrintHub).compactMap(\.location))
        let hubStock: [String: Int] = printLocations.isEmpty ? [:] : try LocationFootprint
            .where { $0.location.in(Array(printLocations)) }
            .fetchAll(db)
            .reduce(into: [:]) { $0[$1.location] = $1.resources }
        let hub = Self.hubLocation(in: allDevices, meshSystems: mesh, stockByLocation: hubStock)

        // Bounded in SQL to rows actually holding units. The table carries a
        // row per location the fleet has ever looked at and most of them are
        // empty, so the predicate is what keeps this a handful of rows rather
        // than the whole census.
        let stockpiles = try LocationFootprint.where { $0.resources > 0 }.fetchAll(db)

        // One fetch, two fields: SURVEY is the sole bound on the blob decode,
        // so the rows that define `surveyedSystems` are exactly the rows
        // `beltsBySystem` decodes. Reading them once keeps the two from ever
        // disagreeing about what "surveyed" means.
        let surveyed = try SystemDetail.where { $0.systemScanned }.fetchAll(db)
        let belts = Self.beltsBySystem(in: surveyed)

        // The account's own roster — a handful of rows, so the whole-table read
        // is as cheap as the `locationEvents` one above and needs no scoping.
        let replicants = try Replicant.all.fetchAll(db)

        return WorldView(
            devices: devicesByCode,
            starPositions: positions,
            meshSystems: mesh,
            salvageUnits: salvage,
            eventSystems: eventSystems,
            hubLocation: hub,
            beltsBySystem: belts,
            surveyedSystems: Set(surveyed.map(\.designation)),
            replicantSystems: Set(
                replicants.compactMap { $0.currentStar.map { SiteAssay.system(of: $0) } }
            ),
            replicantHostDevices: Set(replicants.compactMap(\.hostedDeviceCode)),
            stockpileUnits: stockpiles.reduce(into: [:]) { totals, row in
                totals[SiteAssay.system(of: row.location), default: 0] += row.resources
            },
            now: now
        )
    }

    /// The bounded belt decode: `candidates`' `systemJSON` blobs, classified
    /// per system. Pass only rows the caller has already narrowed in SQL —
    /// SURVEY is the sole bound (see the module doc), and it must be applied
    /// before any blob leaves the database or the bound buys nothing. Both
    /// consumers narrow further on their own terms afterwards: grow drops
    /// meshed systems in `ValueCatalog.build`, prune keeps them.
    private static func beltsBySystem(in candidates: [SystemDetail]) -> [String: [BeltInfo]] {
        var belts: [String: [BeltInfo]] = [:]
        // Failures are tallied, not logged per-row: this loop runs every
        // 5-second tick, so a permanently-malformed row would flood the log
        // forever. `firstFailure` keeps one breadcrumb without per-row volume.
        var failures = 0
        var firstFailure: String?
        for detail in candidates {
            let system: StarSystem
            do {
                system = try detail.system()
            } catch {
                // One bad row must not take the whole galaxy-wide read down:
                // degrade to "no belt data for this system" and keep going, the
                // direction `WorldSnapshot`'s per-directive blob read degrades a
                // failed decode in.
                failures += 1
                if firstFailure == nil { firstFailure = detail.designation }
                continue
            }
            let classified = system.belts.compactMap { belt -> BeltInfo? in
                BeltClass.classify(density: belt.density, richness: belt.richness)
                    .map { BeltInfo(designation: belt.designation, beltClass: $0, richness: belt.richness) }
            }
            if !classified.isEmpty {
                belts[detail.designation] = classified
            }
        }

        // One line per read, whatever the candidate or failure count.
        if let firstFailure {
            logger.debug(
                """
                belts: decoded \(candidates.count - failures, privacy: .public) surveyed \
                system blob(s), \(failures, privacy: .public) failed (first: \(firstFailure, privacy: .public))
                """
            )
        } else {
            logger.debug(
                "belts: decoded \(candidates.count, privacy: .public) surveyed system blob(s)"
            )
        }
        return belts
    }

    /// The single print hub: a print-capable device's location whose system is
    /// meshed AND which `stockByLocation` shows holding resources. **The stock
    /// clause is not an optimisation — without it the hub follows the carrier
    /// around**, since `isPrintHub` is a capability predicate every HEAVEN vessel
    /// satisfies, so a carrier that flies off becomes its own hub and the brain
    /// relocates with it.
    ///
    /// **`> 0`, not "above the reserve floor".** Recognition asks whether this is a
    /// stockpile at all; adequacy is the rail's judgement. Folding the floor in
    /// makes a dipping hub vanish, turning "idle until supply recovers" into "there
    /// is no hub". Richest first, designation as tie-break — a TOTAL order, so a
    /// stateless brain names the same hub every tick.
    static func hubLocation(
        in devices: [Device], meshSystems: Set<String>, stockByLocation: [String: Int]
    ) -> String? {
        let candidates = Set(
            devices
                .filter(\.isPrintHub)
                .compactMap(\.location)
                .filter { meshSystems.contains(SiteAssay.system(of: $0)) }
                .filter { (stockByLocation[$0] ?? 0) > 0 }
        )
        return candidates.max {
            let (left, right) = (stockByLocation[$0] ?? 0, stockByLocation[$1] ?? 0)
            return left == right ? $0 > $1 : left < right
        }
    }
}
