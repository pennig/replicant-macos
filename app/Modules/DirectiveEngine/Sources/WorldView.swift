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
//  most expensive thing the brain does. Bounded by SURVEYED —
//  `SystemDetail.systemScanned` filters in SQL, since belt richness is only
//  known once a system has been through its full system scan (see the field's
//  doc below for why this is the right signal over `recon == .scanned`).
//  A single malformed blob degrades to "no belt data for this
//  system" rather than failing the whole read (mirrors the same-shaped
//  decode-failure handling in the sibling `WorldSnapshot` read). If this
//  decode set ever grows past what's comfortable on a 5-second tick, the
//  documented escape hatch is a dedicated `belts` index table populated at
//  hydrate time — not built now, YAGNI until the count actually demands it.
//
//  Task 21 widened that decode set by exactly one bound: it used to skip
//  MESHED systems too ("a meshed system needs no grow-scoring"), which was
//  true while grow was the only consumer. Prune is the other reading, and it
//  needs the belts of systems already REACHED — a perpetual mine belt is a
//  live-value target forever, and the relay standing in it must never fall
//  off the path-union. Without those belts a reached mine's own relay reads
//  as useless, which is the one direction prune must never err in. The cost
//  is negligible: the meshed set is tens of systems against a surveyed set
//  in the hundreds, and SURVEYED — the bound that actually keeps ~14,000
//  blobs out of the loop — is untouched. Grow is unaffected:
//  `ValueCatalog.build` subtracts meshed systems itself.
//
//  Task 23 added the `replicants` read, and it closes a hole rather than
//  widening a feature: authority in this game comes from a replicant (see the
//  ftl-authority-rule note), and until now the brain's whole model of the world
//  contained none — prune anchored on the print HUB as a proxy and the reclaim
//  path's carrier precondition was unexpressible. Two projections come out of
//  it (`replicantSystems`, `replicantHostDevices`); the rows themselves stay
//  out, since nothing here reasons about a replicant's name or XP.
//
//  SURVEY IS THEREFORE NOW THE SOLE BOUND on the decode set, and the only
//  observable proof of it left is `unsurveyedSystemExcluded` — the widening
//  retired the other one. That same bound is also published as
//  `surveyedSystems` (below) rather than left implicit, because "we have
//  never looked at this system" and "we looked and found nothing" are
//  different facts to prune and identical in `beltsBySystem`.
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
    /// System → its belts, classified. Populated for every SURVEYED
    /// (`SystemDetail.systemScanned`) system, meshed or not — see the module
    /// doc above for why survey is the bound and why mesh status no longer
    /// is. A system with belts in its blob that all fail to classify
    /// (`BeltClass.classify` returns `nil`) is simply absent here, same as a
    /// system with no belts at all.
    public let beltsBySystem: [String: [BeltInfo]]
    /// Every system holding one of the account's replicants.
    ///
    /// **This is where command authority comes from**, and until Task 23 the
    /// brain could not see it at all (a review confirmed `WorldView` carried no
    /// replicant anywhere). Per `ftl-authority-rule`, a command reaches a
    /// device either because a replicant is physically present or because the
    /// target shares a mesh subgraph with a STATIONARY one — so the systems
    /// listed here are the roots the whole mesh hangs off, and `PrunePredicate`
    /// must never offer up the relays that connect them.
    ///
    /// Read off `Replicant.currentStar` and passed through
    /// `SiteAssay.system(of:)` so a value that arrives as a location
    /// (`SOL-3`) reduces to its system the same way every other designation in
    /// this file does. A replicant mid-flight is NOT filtered out: whichever
    /// end of the trip `currentStar` names, treating it as authority-bearing
    /// only ever ADDS a pin, and over-pinning is the safe direction (the
    /// consumer, `PrunePredicate.servedSystems`, is monotone in its targets).
    public let replicantSystems: Set<String>
    /// The device codes that HOST a replicant (`Replicant.hostedDeviceCode`).
    ///
    /// The brain's answer to a question the executor can only ask the server
    /// afterwards: `RelayRun`'s reclaim path deactivates the source relay,
    /// which takes its system off the mesh, so authority to then issue the
    /// `stow` comes only from `ftl-authority-rule` rule (1) — a replicant
    /// physically present. That makes "does this carrier host a replicant?" a
    /// precondition on choosing a reclaim source at all, and this is the field
    /// that lets `Brain` check it before committing rather than discovering it
    /// as a stall (`RelayRun.carrierRetainsAuthority`).
    public let replicantHostDevices: Set<String>
    /// Systems that have been through a full system scan
    /// (`SystemDetail.systemScanned`) — the very rows `beltsBySystem` decodes.
    ///
    /// Carried separately because `beltsBySystem` alone cannot tell "surveyed,
    /// and genuinely holds no belt" from "never looked": both are simply
    /// absent from it. Prune needs exactly that distinction — an unsurveyed
    /// system's value is UNKNOWN, and unknown must read as pinned, never as
    /// reclaimable. Grow has no use for it (an unsurveyed system yields no
    /// `ValueTarget` either way).
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

        // One fetch, two fields: SURVEY is the sole bound on the blob decode,
        // so the rows that define `surveyedSystems` are exactly the rows
        // `beltsBySystem` decodes. Reading them once keeps the two from ever
        // disagreeing about what "surveyed" means.
        let surveyed = try SystemDetail.where { $0.systemScanned }.fetchAll(db)
        let belts = Self.beltsBySystem(in: surveyed)

        // The account's own roster — four rows on the live account, so the
        // whole-table read is as cheap as the `locationEvents` one above and
        // needs no scoping. Two fields come out of it, projected here rather
        // than carried whole: the brain reasons about WHERE authority is and
        // WHICH hull carries it, never about a replicant's XP or name.
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
            now: now
        )
    }

    /// The bounded belt decode (see the module doc for why it must be
    /// bounded at all). SURVEY is now the SOLE bound, applied in SQL by the
    /// caller before any row's `systemJSON` leaves the database — the
    /// expensive direction to filter, and the only one that matters, since
    /// most of the census is never scanned. Both consumers then narrow
    /// further on their own terms: grow drops meshed systems in
    /// `ValueCatalog.build`, prune keeps them.
    private static func beltsBySystem(in candidates: [SystemDetail]) -> [String: [BeltInfo]] {
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

    /// The single print hub this effort: the autofactory device's location,
    /// but only if that system is meshed (an off-mesh hub is out of the
    /// brain's reach until `tendMesh` brings it on — 06).
    static func hubLocation(in devices: [Device], meshSystems: Set<String>) -> String? {
        guard let hub = devices.first(where: { $0.isPrintHub })?.location else { return nil }
        return meshSystems.contains(SiteAssay.system(of: hub)) ? hub : nil
    }
}
