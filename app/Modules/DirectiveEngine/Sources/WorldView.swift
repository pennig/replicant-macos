//
//  WorldView.swift
//  Replicould — DirectiveEngine
//
//  The galaxy as the automation brain sees it: one consistent read of the mesh,
//  census positions, live assays and events, uncollected units, the replicants and
//  the print hub — the single input every brain pass consumes. Wider than the
//  sibling `WorldSnapshot`, which scopes to one directive because decoding
//  thousands of `StarSystem` blobs per tick is real cost. No blob reaches Swift
//  here: `beltsBySystem` is projected out of the JSON by SQLite, bounded by
//  SURVEY (`SystemDetail.systemScanned`). A malformed blob degrades to "no belt
//  data for that system" rather than failing the read.
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
    /// Every recognised theatre this tick, ordered by depot — `TheatreRegistry`'s
    /// one rule for what counts as a hub.
    public let theatres: [Theatre]
    /// The persisted depot per system that made `theatres` sticky, so the brain
    /// can tell a newly recognised depot from one it has already written.
    public let theatreRecords: [TheatreRecord]
    /// System → mesh-component label, from `MeshGraph.components(of:)`.
    public let components: [String: String]
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
    /// Per-type stock summed over the operational theatres' depots. Empty when
    /// no depot has a per-type reading — absence is unknown, never zero.
    public let theatreStock: [String: Double]
    /// The OLDEST `fetchedAt` among the depot rows read, so a depot with a
    /// stale reading ages the aggregate. A depot with NO rows contributes and
    /// ages nothing — its absence is unknown, not stale.
    public let theatreStockFreshness: Date?
    /// Systems that have been through a full system scan. Carried separately because
    /// `beltsBySystem` cannot tell "surveyed, holds no belt" from "never looked" —
    /// both are simply absent — and prune needs that distinction, since unknown
    /// value reads as pinned.
    public let surveyedSystems: Set<String>
    /// The whole location-event ledger, unfiltered: `ResourceDemand.compute`
    /// applies `isActive` itself, and reading demand out of the same
    /// transaction as the stock above is what keeps the two comparable.
    public let locationEvents: [LocationEvent]
    /// Device type → its blueprint's build cost, the bill an event's device
    /// requirement is priced through. Empty until the catalog is fetched;
    /// `ResourceDemand` drops an unbilled device rather than guessing.
    public let blueprintBills: [String: ResourceCost]
    /// Device type → the other printed devices its blueprint consumes. Empty
    /// until the catalog is fetched, which makes every device read as a leaf.
    public let blueprintComponents: [String: [String: Int]]
    /// The one theatre rule, over this tick's geometry — `WorldSnapshot` holds
    /// the identical value, so the brain and a mission cannot disagree.
    public let theatreResolver: TheatreResolver

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
        theatres: [Theatre] = [],
        theatreRecords: [TheatreRecord] = [],
        components: [String: String] = [:],
        beltsBySystem: [String: [BeltInfo]] = [:],
        surveyedSystems: Set<String> = [],
        replicantSystems: Set<String> = [],
        replicantHostDevices: Set<String> = [],
        stockpileUnits: [String: Int] = [:],
        theatreStock: [String: Double] = [:],
        theatreStockFreshness: Date? = nil,
        locationEvents: [LocationEvent] = [],
        blueprintBills: [String: ResourceCost] = [:],
        blueprintComponents: [String: [String: Int]] = [:],
        now: Date
    ) {
        self.devices = devices
        self.starPositions = starPositions
        self.meshSystems = meshSystems
        self.salvageUnits = salvageUnits
        self.eventSystems = eventSystems
        self.theatres = theatres
        self.theatreRecords = theatreRecords
        self.components = components
        self.beltsBySystem = beltsBySystem
        self.surveyedSystems = surveyedSystems
        self.replicantSystems = replicantSystems
        self.replicantHostDevices = replicantHostDevices
        self.stockpileUnits = stockpileUnits
        self.theatreStock = theatreStock
        self.theatreStockFreshness = theatreStockFreshness
        self.locationEvents = locationEvents
        self.blueprintBills = blueprintBills
        self.blueprintComponents = blueprintComponents
        self.now = now
        self.theatreResolver = TheatreResolver(
            theatres: theatres, starPositions: starPositions, components: components
        )
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

        // The three columns the brain needs, not the description strings and
        // other JSON arrays every row also carries.
        let billRows = try Blueprint.all
            .select { ($0.deviceType, $0.resources, $0.components) }
            .fetchAll(db)
        let bills = Dictionary(
            billRows.map { ($0.0, $0.1) }, uniquingKeysWith: { _, last in last }
        )
        let blueprintComponents = Dictionary(
            billRows.map { ($0.0, $0.2) }, uniquingKeysWith: { _, last in last }
        )

        // Candidate depot locations: print-capable, pinned, and system_hub
        // device locations, read in the same transaction as the devices.
        let printLocations = Set(allDevices.filter(\.isPrintHub).compactMap(\.location))
        let pins = try TheatrePin.all.fetchAll(db)
        let hubDeviceLocations = Set(allDevices.filter { $0.deviceType == "system_hub" }.compactMap(\.location))
        let stockLocations = printLocations.union(pins.map(\.location)).union(hubDeviceLocations)
        let hubStock: [String: Int] = stockLocations.isEmpty ? [:] : try LocationFootprint
            .where { $0.location.in(Array(stockLocations)) }
            .fetchAll(db)
            .reduce(into: [:]) { $0[$1.location] = $1.resources }

        let componentLabels = MeshGraph(positions: positions).components(of: mesh)
        let theatreRecords = try TheatreRecord.all.fetchAll(db)
        let theatres = TheatreRegistry.recognise(
            devices: allDevices, pins: pins, records: theatreRecords, meshSystems: mesh,
            components: componentLabels, stockByLocation: hubStock
        )

        let operationalDepots = Set(theatres.filter(\.isOperational).map(\.depot))
        let inventoryRows = operationalDepots.isEmpty ? [] : try LocationInventory
            .where { $0.location.in(Array(operationalDepots)) }
            .fetchAll(db)
        let stock = Self.aggregateStock(rows: inventoryRows, depots: operationalDepots)

        // Bounded in SQL to rows actually holding units. The table carries a
        // row per location the fleet has ever looked at and most of them are
        // empty, so the predicate is what keeps this a handful of rows rather
        // than the whole census.
        let stockpiles = try LocationFootprint.where { $0.resources > 0 }.fetchAll(db)

        // Two reads, one predicate: `systemScanned` is the sole bound and both
        // queries apply it, inside one transaction, so they cannot disagree
        // about what "surveyed" means. Neither pulls a blob into memory — the
        // designations are a column select and the belts are projected by
        // SQLite out of the JSON.
        let surveyed = try SystemDetail
            .where { $0.systemScanned }
            .select { $0.designation }
            .fetchAll(db)
        let belts = try Self.beltsBySystem(in: db)

        // The account's own roster — a handful of rows, so the whole-table read
        // is as cheap as the `locationEvents` one above and needs no scoping.
        let replicants = try Replicant.all.fetchAll(db)

        return WorldView(
            devices: devicesByCode,
            starPositions: positions,
            meshSystems: mesh,
            salvageUnits: salvage,
            eventSystems: eventSystems,
            theatres: theatres,
            theatreRecords: theatreRecords,
            components: componentLabels,
            beltsBySystem: belts,
            surveyedSystems: Set(surveyed),
            replicantSystems: Set(
                replicants.compactMap { $0.currentStar.map { SiteAssay.system(of: $0) } }
            ),
            replicantHostDevices: Set(replicants.compactMap(\.hostedDeviceCode)),
            stockpileUnits: stockpiles.reduce(into: [:]) { totals, row in
                totals[SiteAssay.system(of: row.location), default: 0] += row.resources
            },
            theatreStock: stock.quantities,
            theatreStockFreshness: stock.freshness,
            locationEvents: events,
            blueprintBills: bills,
            blueprintComponents: blueprintComponents,
            now: now
        )
    }

    /// The per-type sum over `depots` and the oldest read behind it.
    static func aggregateStock(
        rows: [LocationInventory], depots: Set<String>
    ) -> (quantities: [String: Double], freshness: Date?) {
        let relevant = rows.filter { depots.contains($0.location) }
        var quantities: [String: Double] = [:]
        for row in relevant { quantities[row.resourceType, default: 0] += row.quantity }
        return (quantities, relevant.map(\.fetchedAt).min())
    }

    /// Inward: same mesh component, then nearest. Operational only.
    public func theatre(servicing system: String) -> Theatre? {
        theatreResolver.theatre(servicing: system)
    }

    /// Outward: nearest by straight-line distance, no component filter. Operational only.
    public func theatre(nearest system: String) -> Theatre? {
        theatreResolver.theatre(nearest: system)
    }

    /// `device`'s theatre. A `goal` lets its scoped tag outrank where it
    /// stands; nil asks the location question alone.
    public func owningTheatre(of device: Device, goal: FleetTag.Goal?) -> Theatre? {
        theatreResolver.owningTheatre(of: device, goal: goal)
    }

    /// `system`'s theatre — the rule `owningTheatre(of:)` applies to a
    /// device's location, for a caller reasoning about a SYSTEM (a belt
    /// candidate) rather than a device.
    public func owningTheatre(ofSystem system: String) -> Theatre? {
        theatreResolver.owningTheatre(ofSystem: system)
    }

    /// One belt as SQLite projects it out of the blob: the three fields
    /// `BeltClass.classify` ranks on, and nothing else. `richnessJSON` arrives as
    /// the JSON text of the object, so it still needs a Swift decode — a tiny one.
    @Selection
    struct BeltProjection {
        let system: String
        let designation: String
        let density: String?
        let richnessJSON: String?
    }

    /// `beltsBySystem` computed by SQLite instead of by decoding whole blobs:
    /// `json_each` walks `$.belts` and projects the three ranked fields, so the
    /// read scales with the belt count rather than with every surveyed system's
    /// whole object graph. Same survey bound, applied in the same place.
    static func beltsBySystem(in db: Database) throws -> [String: [BeltInfo]] {
        // `json_each` is a table-valued function over a TEXT column, which the
        // query builder cannot type today — `jsonEach()` requires the column to
        // already carry a JSON representation.
        //
        // The `CASE` is what keeps one malformed blob from failing the whole
        // read: `json_each` raises on invalid JSON, and it must never see any.
        // A `WHERE json_valid(...)` would depend on the planner filtering before
        // the join; sanitizing the argument does not.
        let rows = try #sql(
            """
            SELECT \(SystemDetail.designation), \
            json_extract("belt"."value", '$."designation"'), \
            json_extract("belt"."value", '$."density"'), \
            json_extract("belt"."value", '$."richness"') \
            FROM \(SystemDetail.self), \
            json_each( \
            CASE WHEN json_valid(\(SystemDetail.systemJSON)) \
            THEN \(SystemDetail.systemJSON) ELSE '{}' END, \
            '$."belts"') AS "belt" \
            WHERE \(SystemDetail.systemScanned)
            """,
            as: BeltProjection.self
        )
        .fetchAll(db)

        var belts: [String: [BeltInfo]] = [:]
        for row in rows {
            let richness = row.richnessJSON
                .flatMap { try? Self.richnessDecoder.decode([String: String].self, from: Data($0.utf8)) }
                ?? [:]
            guard let beltClass = BeltClass.classify(density: row.density, richness: richness) else { continue }
            belts[row.system, default: []].append(
                BeltInfo(designation: row.designation, beltClass: beltClass, richness: richness)
            )
        }
        // One line per read. A blob SQLite rejected as invalid is absent from
        // `rows` and so uncounted here — the projection cannot tell it from a
        // system with no belts.
        logger.debug(
            """
            belts: projected \(rows.count, privacy: .public) belt(s) \
            over \(belts.count, privacy: .public) system(s)
            """
        )
        return belts
    }

    private static let richnessDecoder = JSONDecoder()
}
