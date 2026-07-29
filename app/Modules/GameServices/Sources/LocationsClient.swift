//
//  LocationsClient.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  Reads the stellar-locations catalog through the generated `ReplicantSpace`
//  client (inheriting bearer auth, rate limiting, and logging). Three calls:
//    - `footprint()`   → GET /v1/locations       (holdings overlay; see note)
//    - `system(_:)`    → GET /v1/locations/{star} (star-level roster + belts)
//    - `body(_:)`      → GET /v1/locations/{code} (scanned body detail to merge)
//
//  Location detail is gated on *presence*, not exploration: the endpoint returns
//  detail only while one of your replicants is in the system, and otherwise
//  responds 403 ("No replicant in system"), surfaced here as
//  `LocationsError.noReplicantInSystem` (not a failure — it just means "travel
//  there first"). All decoding goes through the JSON round-trip in
//  `LocationDTOs.swift`, since the generated client exposes the nested blocks
//  only as opaque freeform containers.
//

import API
import Dependencies
import Foundation
import GameModels
import GameSession
import OSLog
import SQLiteData
import UniverseModels
import Utils

private let logger = Logger(subsystem: "name.pennig.replicould", category: "LocationsClient")

public enum LocationsError: Error, Equatable, Sendable {
    /// No replicant is currently in the system, so live detail is unavailable
    /// (HTTP 403 "No replicant in system"). Presence-gated, *not* exploration —
    /// a previously-scanned system the replicant has left returns this too.
    case noReplicantInSystem
    case notFound
    case malformed
    case unexpected(Int)
}

public struct LocationsClient: Sendable {
    /// Per-location holdings (devices/resources/sites/events/presence), keyed by
    /// location code. An overlay for badges/inventory hints — NOT a knowledge
    /// index; a scanned system with no holdings is simply absent.
    public var footprint: @Sendable () async throws -> [String: LocationCounts]

    /// The star-level system: physical star, planet roster (types estimated
    /// until scanned), asteroid belts, counts, and system events. Throws
    /// `.noReplicantInSystem` if no replicant is currently in the system.
    public var system: @Sendable (_ designation: String) async throws -> StarSystem

    /// Scanned detail for a single body (planet/moon/belt/lagrange/…), merged
    /// into the tree in place of its roster stub.
    public var body: @Sendable (_ designation: String) async throws -> BodyDetail

    /// Full system scan of the replicant's current system — the only source of
    /// shops, megastructures/objects, and the outer system. Returns a
    /// `StarSystem` to merge (see `StarSystem.mergingScan`).
    public var scan: @Sendable (_ replicantCode: String) async throws -> StarSystem

    public init(
        footprint: @escaping @Sendable () async throws -> [String: LocationCounts],
        system: @escaping @Sendable (String) async throws -> StarSystem,
        body: @escaping @Sendable (String) async throws -> BodyDetail,
        scan: @escaping @Sendable (String) async throws -> StarSystem
    ) {
        self.footprint = footprint
        self.system = system
        self.body = body
        self.scan = scan
    }
}

extension BodyDetail {
    /// The stored resources at this body (planets, moons, belts carry inventory;
    /// a special site carries none).
    public var inventory: [InventoryItem] {
        switch self {
        case .planet(let p): return p.inventory
        case .moon(let m):   return m.inventory
        case .belt(let b):   return b.inventory
        case .special:       return []
        }
    }
}

extension LocationsClient {
    /// Fresh inventory at a location, fetched through `body(_:)`. Used by the
    /// print confirmation to check a blueprint's cost against what's on hand.
    public func inventory(at designation: String) async throws -> [InventoryItem] {
        try await body(designation).inventory
    }

    /// Resolve a print's resource requirements by refreshing the location's live
    /// inventory and filling in what's on hand for each required resource. A
    /// location we can't read (unexplored, offline, or no location at all) leaves
    /// the stock unknown rather than failing the preview.
    public func printRequirements(
        deviceType: String,
        location: String?,
        locationName: String?,
        required: [PrintResourceLine]
    ) async -> PrintRequirements {
        var available: [String: Double]?
        if let location, let items = try? await inventory(at: location) {
            available = Dictionary(
                items.map { ($0.resourceType.lowercased(), $0.quantity) },
                uniquingKeysWith: +
            )
        }
        return PrintRequirements.resolve(
            deviceType: deviceType,
            locationName: locationName,
            required: required,
            available: available
        )
    }
}

extension LocationsClient {
    /// Fetch the `GET /v1/locations` holdings overlay, persist it, and mark every
    /// system it names as explored.
    ///
    /// That second write is the point. `stars.explored` is otherwise only ever set
    /// by the star map survey's walk of the *distance-sorted* per-replicant census,
    /// so a system explored long ago sits as many pages deep as it is now far away
    /// — SOL landed on census page 13 for a probe that had moved 39.5 ly off. The
    /// Locations catalog gates both its "Explored" filter and its hydrate-on-select
    /// on that flag, so a missed row is a system you cannot open. Anything you hold
    /// at a location proves you reached its system, which repairs those rows from a
    /// single request.
    ///
    /// Strictly additive: it never clears `explored`, since the footprint is a
    /// holdings overlay rather than a knowledge index and a system you hold nothing
    /// in is simply absent from it.
    public func refreshFootprint() async throws {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date.now) var now
        let footprint = try await footprint()
        let rows = footprint.map { LocationFootprint(location: $0.key, counts: $0.value, fetchedAt: now) }
        let systems = LocationFootprint.systems(in: footprint.keys).sorted()
        try await database.write { db in
            try LocationFootprint.upsert { rows }.execute(db)
            guard !systems.isEmpty else { return }
            try Star.where { $0.designation.in(systems) }
                .update { $0.explored = #bind(true) }
                .execute(db)
        }
    }

    /// Scan the replicant's current system and persist the result, overlaying it
    /// onto any already-hydrated `SystemDetail` (preserving per-body scan detail).
    /// Shared by the explicit Scan action and the passive GameSync capture.
    public func scanAndPersist(replicantCode: String) async throws {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date.now) var now
        let scanned = try await scan(replicantCode)
        try await database.write { db in
            let existing = try SystemDetail
                .where { $0.designation.eq(scanned.designation) }.fetchOne(db)
            let merged = (try existing?.system())?.mergingScan(scanned) ?? scanned
            try SystemDetail.persist(system: merged, at: now, in: db)
        }
    }

    /// Fetch a single body's scanned detail and merge it into the persisted
    /// `SystemDetail` blob for its system, so callers reading `allSalvageSites`
    /// from the local catalog (e.g. the gather_salvage location picker) see that
    /// body's sites without opening the Locations feature. Best-effort: a system
    /// with no replicant present (403), an uncharted system, or an unreadable
    /// body simply leaves the catalog untouched rather than throwing.
    /// Re-read one star system and fold it into the cached blob.
    ///
    /// Best-effort by contract: `GET locations/{star}` is **exploration**-gated,
    /// not presence-gated — its 403 says "No replicant in system", which is a
    /// lie, and any *explored* system rehydrates from anywhere (see the
    /// location-endpoint-presence-gate note). So a caller away from the system is
    /// the normal case and succeeds; an unexplored system 403s and leaves the
    /// cache exactly as it was. Used by `DirectiveEngine`'s `refreshSystem`
    /// action to pull fresh scan counts after a survey completes, and by the
    /// `directive.completed` catalog route for the same reason.
    public func hydrateSystem(designation: String) async throws {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date.now) var now
        guard let fresh = try? await system(designation) else { return }
        // Read, merge, and persist inside ONE transaction: `persist` also stamps
        // the census row's `fullyScannedAt`, and splitting the read from the
        // write would let the two disagree about what the merge concluded.
        try await database.write { db in
            let cached = try? SystemDetail.where { $0.designation.eq(designation) }.fetchOne(db)
            let merged = (try? cached?.system()).flatMap { $0 }.map { $0.mergingSystemDetail(fresh) } ?? fresh
            try SystemDetail.persist(system: merged, at: now, in: db)
        }
    }

    public func hydrateBody(systemDesignation: String, bodyDesignation: String) async throws {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date.now) var now
        let cached = try await database.read { db in
            try SystemDetail.where { $0.designation.eq(systemDesignation) }.fetchOne(db)
        }
        // Attach the body onto whatever base roster we have — the cached blob, or
        // a fresh star-level fetch when the system isn't in the catalog yet.
        var base = try cached?.system()
        if base == nil { base = try? await system(systemDesignation) }
        guard var assembled = base, let detail = try? await body(bodyDesignation) else { return }
        assembled = assembled.applying(detail)
        let merged = assembled
        try await database.write { db in
            try SystemDetail.persist(system: merged, at: now, in: db)
        }
    }

    /// Fold a `scan.completed` stream event's `result` body into the local catalog,
    /// sparing a later `body(_:)` hydration call (the event already carries the
    /// scanned body's physical block, salvage, sites, and inventory). Merges onto
    /// the cached `SystemDetail` blob when present, else seeds a minimal system so
    /// the body — and its salvage — isn't lost before the system is hydrated.
    /// Best-effort and idempotent: an unrecognized or system-less payload is a
    /// no-op. Returns whether a body was persisted.
    @discardableResult
    public func ingestScanResult(payload: [String: JSONValue]) async throws -> Bool {
        guard
            let result = payload["result"],
            let detail = ((try? LocationDecoding.scanResultBody(from: result)) ?? nil)
        else { return false }
        let system = String(detail.designation.split(separator: "-").first ?? "")
        guard !system.isEmpty else { return false }
        let observations = LocationDecoding.salvageObservations(fromScanResult: result)

        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date.now) var now
        try await database.write { db in
            let cached = try SystemDetail.where { $0.designation.eq(system) }.fetchOne(db)
            let base = (try? cached?.system()) ?? StarSystem(designation: system, recon: .visited)

            // The percentages as they stood BEFORE this scan's merge. Needed
            // twice, and both times because `applying` replaces a body's
            // salvage wholesale from a payload that carries no
            // `resources_remaining_pct`: once to imply totals from the scan's
            // absolute amounts, and once to put the percentages back on the
            // merged tree so the scan doesn't destroy the data it just used.
            let knownPct = base.knownSalvageSites.reduce(into: [String: [String: Double]]()) {
                $0[$1.designation] = $1.remainingPct
            }
            let merged = base.seedingParent(of: detail).applying(detail)
                .restoringSalvagePercentages(knownPct)
            try SystemDetail.persist(system: merged, at: now, in: db)

            // The scan's absolute remaining is a second source of capacity.
            // With a known percentage it implies the original total; without
            // one it is at least a floor.
            for observation in observations {
                let stored = try SiteAssay.where { $0.id.eq(observation.designation) }.fetchOne(db)
                var observed: [String: Double] = [:]
                for (resource, remaining) in observation.resourcesRemaining {
                    if let pct = knownPct[observation.designation]?[resource],
                       let implied = SiteAssay.impliedTotal(remaining: remaining, percentRemaining: pct) {
                        observed[resource] = implied
                    } else {
                        observed[resource] = remaining
                    }
                }
                let assay = SiteAssay(
                    id: observation.designation,
                    body: observation.body,
                    system: SiteAssay.system(of: observation.designation),
                    siteType: "salvage",
                    totals: SiteAssay.raising(stored?.totals ?? [:], with: observed),
                    assayedAt: now
                )
                try SiteAssay.upsert { assay }.execute(db)
            }
        }
        return true
    }

    /// Fold an `ami.survey.digest`'s `report.scans[]` into the local catalog
    /// (API v2.3.3). Returns how many bodies were persisted.
    ///
    /// This is the **only** channel carrying a Survey Run's scan intel. An
    /// AMI-adopted survey drone emits no per-device events at all — every scan
    /// it performs is rolled into its controller's digest (see the
    /// `ami-drones-are-event-silent` note) — so without this, every body a
    /// survey scans stays a roster stub until someone opens it and pays a
    /// `GET locations/{designation}` per body.
    ///
    /// Grouped by system so a digest whose drones are spread across systems
    /// costs one transaction each rather than one per body. Best-effort and
    /// idempotent: replaying the same event writes the same rows.
    @discardableResult
    public func ingestSurveyScans(payload: [String: JSONValue]) async throws -> Int {
        let scans = (try? LocationDecoding.surveyScans(from: payload)) ?? SurveyScans()
        if !scans.unreadable.isEmpty {
            // Deliberately `.notice` — the level unhandled events use — so a new
            // `scan_type` the backend starts emitting is falsifiable from the
            // log rather than silently dropped, and named so it's actionable.
            logger.notice(
                "⚠️ ami.survey.digest: unreadable scan_type(s) \(scans.unreadable.joined(separator: ", "), privacy: .public) — no planet/moon block this build understands"
            )
        }
        guard !scans.reports.isEmpty else { return 0 }

        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date.now) var now

        let bySystem = Dictionary(grouping: scans.reports) { $0.body.systemDesignation }
        var persisted = 0
        for (system, reports) in bySystem where !system.isEmpty {
            try await database.write { db in
                let cached = try SystemDetail.where { $0.designation.eq(system) }.fetchOne(db)
                var merged = (try? cached?.system()) ?? StarSystem(designation: system, recon: .visited)

                // Percentages as they stood BEFORE the merge, for the same two
                // reasons `ingestScanResult` needs them: to imply a site's
                // original total from the scan's absolute remaining, and to put
                // the percentages back afterwards. `observing` already preserves
                // them per-site, but capturing here keeps the assay inference
                // reading pre-merge state either way.
                let knownPct = merged.knownSalvageSites.reduce(into: [String: [String: Double]]()) {
                    $0[$1.designation] = $1.remainingPct
                }

                for report in reports {
                    merged = merged.observing(report.body)
                }
                try SystemDetail.persist(system: merged, at: now, in: db)

                for observation in reports.flatMap(\.salvage) {
                    let stored = try SiteAssay.where { $0.id.eq(observation.designation) }.fetchOne(db)
                    var observed: [String: Double] = [:]
                    for (resource, remaining) in observation.resourcesRemaining {
                        if let pct = knownPct[observation.designation]?[resource],
                           let implied = SiteAssay.impliedTotal(remaining: remaining, percentRemaining: pct) {
                            observed[resource] = implied
                        } else {
                            observed[resource] = remaining
                        }
                    }
                    let assay = SiteAssay(
                        id: observation.designation,
                        body: observation.body,
                        system: SiteAssay.system(of: observation.designation),
                        siteType: "salvage",
                        totals: SiteAssay.raising(stored?.totals ?? [:], with: observed),
                        assayedAt: now
                    )
                    try SiteAssay.upsert { assay }.execute(db)
                }
            }
            persisted += reports.count
        }
        return persisted
    }

    /// Record a `salvage.discovered` event.
    ///
    /// Two writes in one transaction. The **assay** is the durable half: this
    /// event is the only place absolute resource counts appear, and the catalog
    /// payload never carries them. The **catalog fold-in** is convenience: the
    /// payload has everything `SalvageSite` needs, so a discovery is visible
    /// immediately instead of waiting for the next scan.
    ///
    /// `remainingPct` is deliberately left empty rather than synthesised as
    /// 100%. Live sites do read 100% right after discovery, but writing that in
    /// would present an inference as observed data; the site reads as discovered
    /// totals until a hydrate supplies real percentages.
    ///
    /// Best-effort and idempotent. Returns whether an assay was written.
    @discardableResult
    public func recordSalvageDiscovery(payload: [String: JSONValue]) async throws -> Bool {
        guard let discovery = SalvageEventPayload.discovery(from: payload) else { return false }
        let system = SiteAssay.system(of: discovery.designation)
        guard !system.isEmpty else { return false }

        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date.now) var now
        try await database.write { db in
            let stored = try SiteAssay.where { $0.id.eq(discovery.designation) }.fetchOne(db)
            let assay = SiteAssay(
                id: discovery.designation,
                body: discovery.body,
                system: system,
                siteType: "salvage",
                totals: SiteAssay.raising(stored?.totals ?? [:], with: discovery.resources),
                assayedAt: now
            )
            try SiteAssay.upsert { assay }.execute(db)

            let cached = try SystemDetail.where { $0.designation.eq(system) }.fetchOne(db)
            let base = (try? cached?.system()) ?? StarSystem(designation: system, recon: .visited)
            let site = SalvageSite(
                designation: discovery.designation,
                name: discovery.name,
                salvageType: discovery.salvageType,
                location: discovery.body,
                resourcesAvailable: discovery.resources.keys.sorted(),
                depleted: false
            )
            guard let merged = base.insertingSalvage(site) else { return }
            try SystemDetail.persist(system: merged, at: now, in: db)
        }
        return true
    }

    /// Mark ONE salvage site as fully spent (a `salvage.depleted` event). Keyed
    /// by site designation, not by body: a body can host several sites, and
    /// spending one must not spend its siblings. No-op if the system isn't
    /// cached or nothing matches. Returns whether a row changed.
    @discardableResult
    public func markSalvageDepleted(site: String) async throws -> Bool {
        try await mutateSalvage(atSite: site) {
            $0.depleted = true
            $0.resourcesAvailable = []
            $0.remainingPct = $0.remainingPct.mapValues { _ in 0 }
        }
    }

    /// Drop one depleted resource from a site (a resource-level depletion
    /// event). Full depletion arrives separately as `salvage.depleted`, so this
    /// only prunes that resource.
    @discardableResult
    public func markSalvageResourceDepleted(site: String, resource: String) async throws -> Bool {
        try await mutateSalvage(atSite: site) {
            $0.resourcesAvailable.removeAll { $0 == resource }
            $0.remainingPct[resource] = 0
        }
    }

    /// Shared body: load the cached system, apply the transform to the ONE site
    /// with this designation, and persist only if something actually changed.
    private func mutateSalvage(
        atSite site: String, _ transform: @Sendable (inout SalvageSite) -> Void
    ) async throws -> Bool {
        let system = SiteAssay.system(of: site)
        guard !system.isEmpty else { return false }
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date.now) var now
        return try await database.write { db in
            guard
                let cached = try SystemDetail.where({ $0.designation.eq(system) }).fetchOne(db),
                let starSystem = try? cached.system()
            else { return false }
            let body = SalvageEventPayload.body(ofSite: site)
            let updated = starSystem.updatingSalvage(at: body) { salvage in
                guard salvage.designation == site else { return }
                transform(&salvage)
            }
            guard updated != starSystem else { return false }
            try SystemDetail.persist(system: updated, at: now, in: db)
            return true
        }
    }
}

extension LocationsClient: DependencyKey {
    public static let liveValue = LocationsClient(
        footprint: {
            @Dependency(\.gameClient) var gameClient
            let client = gameClient.make()
            let output = try await client.getV1Locations()
            switch output {
            case .ok(let ok):
                return try LocationDecoding.footprint(from: try ok.body.json)
            case .default(let statusCode, _):
                throw LocationsError.unexpected(statusCode)
            }
        },
        system: { designation in
            let raw = try await fetchLocation(designation)
            guard let system = raw.starSystem() else { throw LocationsError.malformed }
            return system
        },
        body: { designation in
            let raw = try await fetchLocation(designation)
            guard let detail = raw.bodyDetail() else { throw LocationsError.malformed }
            return detail
        },
        scan: { replicantCode in
            @Dependency(\.gameClient) var gameClient
            let client = gameClient.make()
            let output = try await client.postV1ReplicantsReplicantCodeScan(
                path: .init(replicantCode: replicantCode)
            )
            switch output {
            case .ok(let ok):
                guard let system = try LocationDecoding.scannedSystem(from: ok.body.json)
                else { throw LocationsError.malformed }
                return system
            case .notFound:
                throw LocationsError.notFound
            case .badRequest:
                throw LocationsError.unexpected(400)
            case .default(let statusCode, _):
                throw LocationsError.unexpected(statusCode)
            }
        }
    )

    /// Shared GET /v1/locations/{designation} with the explored-gate mapping.
    private static func fetchLocation(_ designation: String) async throws -> LocationPayload {
        @Dependency(\.gameClient) var gameClient
        let client = gameClient.make()
        let output = try await client.getV1LocationsDesignation(path: .init(designation: designation))
        switch output {
        case .ok(let ok):
            return try LocationDecoding.location(from: try ok.body.json)
        case .forbidden:
            throw LocationsError.noReplicantInSystem
        case .notFound:
            throw LocationsError.notFound
        case .conflict:
            throw LocationsError.unexpected(409)
        case .badRequest:
            throw LocationsError.unexpected(400)
        case .unprocessableContent:
            throw LocationsError.unexpected(422)
        case .default(let statusCode, _):
            throw LocationsError.unexpected(statusCode)
        }
    }
}

extension LocationsClient: TestDependencyKey {
    /// Unimplemented by default so a test that reaches the network without
    /// stubbing it fails loudly (V3.6-T5).
    public static let testValue = LocationsClient(
        footprint: unimplemented("LocationsClient.footprint"),
        system: unimplemented("LocationsClient.system"),
        body: unimplemented("LocationsClient.body"),
        scan: unimplemented("LocationsClient.scan")
    )

    public static let previewValue = LocationsClient(
        footprint: {
            ["SOL-3": LocationCounts(locationEvents: 1, devices: 1, replicants: 1)]
        },
        system: { designation in
            StarSystem(
                designation: designation, name: designation,
                star: SystemStar(designation: designation, stellarClass: "G2", color: "yellow-white"),
                recon: .visited, systemScanned: true, entryPoint: "\(designation)-5-L4",
                planetsScanned: 1, planetsTotal: 2,
                planets: [
                    Planet(designation: "\(designation)-1", type: "Barren", orbitalDistanceAu: 0.39, recon: .visited),
                    Planet(
                        designation: "\(designation)-3", type: "Terrestrial", orbitalDistanceAu: 1,
                        inHabitableZone: true, recon: .scanned, moonCount: 1
                    ),
                ]
            )
        },
        body: { designation in
            .planet(Planet(designation: designation, type: "Terrestrial", recon: .scanned))
        },
        scan: { _ in
            StarSystem(
                designation: "SOL", star: SystemStar(designation: "SOL", stellarClass: "G2"),
                recon: .scanned, systemScanned: true,
                structures: [SpecialSite(designation: "EXODUS-ARK-001", kind: .megastructure,
                                         objectType: "megastructure", progressPercentage: 100)],
                shops: [Shop(controllerCode: "043CA0A9", shopName: "Riker's Lunar Supplies", location: "SOL-3-1")]
            )
        }
    )
}

extension DependencyValues {
    public var locationsClient: LocationsClient {
        get { self[LocationsClient.self] }
        set { self[LocationsClient.self] = newValue }
    }
}
