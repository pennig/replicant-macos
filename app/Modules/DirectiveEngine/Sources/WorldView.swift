//
//  WorldView.swift
//  Replicould — DirectiveEngine
//
//  The galaxy as the automation brain sees it: one consistent read of every
//  meshed system, every census star position, every non-depleted salvage assay,
//  every live location event, every location holding uncollected units, the
//  account's replicants and the print hub — the single input every brain pass
//  (pathfinding, value ranking, prune analysis) consumes.
//
//  A sibling to `WorldSnapshot`, but wider: `WorldSnapshot` scopes systems to
//  one directive's `wanted` set because decoding thousands of `StarSystem`
//  blobs per tick is real cost, while the brain must rank ACROSS the whole
//  census. So this reads the cheap tables — devices, `stars`, `siteAssays`,
//  `locationEvents`, `locationFootprints`, `replicants` — and touches exactly
//  one blob field.
//
//  That field is `beltsBySystem`. Belt richness exists only inside the
//  per-system `StarSystem` JSON (`SystemDetail.systemJSON`), and decoding all
//  ~14,000 census systems every 5-second tick would be the most expensive thing
//  the brain does. SURVEY is the SOLE bound holding that off —
//  `SystemDetail.systemScanned`, applied in SQL before any blob leaves the
//  database — so widen it only against a measurement. A single malformed blob
//  degrades to "no belt data for that system" rather than failing the read,
//  mirroring the sibling `WorldSnapshot` read.
//
//  Only projections of the replicant rows are carried (`replicantSystems`,
//  `replicantHostDevices`): nothing here reasons about a replicant's name or XP.
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
    /// The print hub's LOCATION (`SOL-3-1`, not the bare system `SOL`), present
    /// only when its system is meshed; an off-mesh hub is unsupported and
    /// escalates rather than being routed toward.
    ///
    /// **This is the one hub recognition rule, and anything needing the hub
    /// re-derives it from here** rather than reading a remembered
    /// `Directive.originDesignation`, which is `SiteAssay.system(of:)` of this —
    /// a bare system designation, and a bare designation travels to the
    /// system's ENTRY POINT, an L4 away from the printer, where an
    /// exact-location match refuses the carrier that lands there.
    public let hubLocation: String?
    /// System → its belts, classified. Populated for every SURVEYED
    /// (`SystemDetail.systemScanned`) system, meshed or not: prune needs the
    /// belts of systems already REACHED, since a perpetual mine belt is a
    /// live-value target forever and without its belts a reached mine's own
    /// relay reads as useless — the one direction prune must never err in. Grow
    /// subtracts meshed systems itself, in `ValueCatalog.build`.
    ///
    /// A system whose belts all fail to classify (`BeltClass.classify` returns
    /// `nil`) is absent here, exactly as a system with no belts at all is; read
    /// `surveyedSystems` to tell those apart from "never looked".
    public let beltsBySystem: [String: [BeltInfo]]
    /// Every system holding one of the account's replicants — **where command
    /// authority comes from.**
    ///
    /// Per `ftl-authority-rule` a command reaches a device either because a
    /// replicant is physically present or because the target shares a mesh
    /// subgraph with a STATIONARY one, so these systems are the roots the whole
    /// mesh hangs off and `PrunePredicate` must never offer up the relays that
    /// connect them.
    ///
    /// Read off `Replicant.currentStar` through `SiteAssay.system(of:)`, so a
    /// value arriving as a location (`SOL-3`) reduces to its system the way
    /// every other designation in this file does. A replicant mid-flight is NOT
    /// filtered out: whichever end of the trip `currentStar` names, treating it
    /// as authority-bearing only ever ADDS a pin, and over-pinning is the safe
    /// direction (the consumer, `PrunePredicate.servedSystems`, is monotone in
    /// its targets).
    public let replicantSystems: Set<String>
    /// The device codes that HOST a replicant (`Replicant.hostedDeviceCode`).
    ///
    /// A carrier absent from this set must never be chosen as a reclaim source:
    /// `RelayRun`'s reclaim path deactivates the source relay, taking its system
    /// off the mesh, so authority to then issue the `stow` comes only from
    /// `ftl-authority-rule` rule (1), a replicant physically present. Checking
    /// it at selection is what makes the shortfall a choice not taken rather
    /// than a stall discovered mid-run (`RelayRun.carrierRetainsAuthority`).
    public let replicantHostDevices: Set<String>
    /// System → summed units sitting at its locations: resources already
    /// extracted and waiting for a Haul Run to collect them.
    ///
    /// Distinct in kind from `salvageUnits` and `beltsBySystem`, which are
    /// value still IN THE GROUND: a pile is inventory the fleet already paid
    /// for, and `HaulTargetPlanner` can only issue the `ferry` that collects it
    /// while both ends sit on the mesh. Depletion is what produces a pile, so
    /// without this the two facts move in opposite directions at the same
    /// instant — the assay drops out of `salvageUnits` exactly as the units
    /// land on the ground.
    ///
    /// Summed ACROSS a system's locations, because both consumers ask about
    /// the system rather than the pile: prune keeps the road to the system,
    /// and grow ranks one relay per system.
    ///
    /// Read off `LocationFootprint`, bounded in SQL to rows holding units:
    /// most of that table is locations looked at once and found empty, and
    /// taking those too would pin every system the fleet has ever visited.
    public let stockpileUnits: [String: Int]
    /// Systems that have been through a full system scan
    /// (`SystemDetail.systemScanned`) — the very rows `beltsBySystem` decodes.
    ///
    /// Carried separately because `beltsBySystem` alone cannot tell "surveyed,
    /// and genuinely holds no belt" from "never looked": both are simply absent
    /// from it. Prune needs exactly that distinction — an unsurveyed system's
    /// value is UNKNOWN, and unknown reads as pinned, never as reclaimable.
    /// Grow has no use for it, an unsurveyed system yielding no `ValueTarget`
    /// either way.
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
                    .map { BeltInfo(designation: belt.designation, beltClass: $0) }
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

    /// The single print hub: a print-capable device's location among `devices`,
    /// kept only if its system is in `meshSystems` (an off-mesh hub is out of
    /// the brain's reach until `tendMesh` brings it on) **and `stockByLocation`
    /// shows that location actually holding resources.**
    ///
    /// **The stock clause is not an optimisation; without it the hub follows the
    /// carrier around.** `Device.isPrintHub` is a CAPABILITY predicate
    /// (`enqueue_print` in `availableCommands`) that every HEAVEN vessel
    /// satisfies too, so a carrier that flies off to plant a relay becomes its
    /// own "hub" and the whole brain relocates with it: grow launches there,
    /// prune anchors there, and the reserve rail reads that location's empty
    /// stockpile and stalls `printStockShort` while the real hub is full.
    ///
    /// **`> 0`, not "above the reserve floor", and the difference matters.**
    /// Recognition asks whether this is a stockpile at all; ADEQUACY is the
    /// rail's judgement (`RelayRun.printStockIsShort`). Folding the floor in
    /// here makes a hub that dips below it vanish entirely, turning the designed
    /// "printStockShort → idle until supply recovers" degradation into "there is
    /// no hub" — both wrong and unactionable.
    ///
    /// Richest location first, designation as tie-break: a TOTAL order, so a
    /// stateless brain re-deriving this every tick names the same hub every
    /// tick.
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
