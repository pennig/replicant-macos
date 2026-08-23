//
//  LocationDTOs.swift
//  UniverseModels
//
//  The decode layer between the generated OpenAPI client and the catalog domain.
//
//  The generated client types every nested block of the location response as an
//  opaque freeform `*Payload` (just `additionalProperties`), so it gives no
//  usable typed access. Instead we re-encode the generated `Codable` body back
//  to JSON — which faithfully reproduces the server's original snake_case keys,
//  including drift the generator missed (e.g. `asteroid_belt` at star level vs
//  `belt` at belt level) — then decode that into these all-optional DTOs with
//  `.convertFromSnakeCase`. The DTOs then map into the `StarSystem` domain,
//  coalescing every optional. This keeps us tolerant of spec drift: unknown keys
//  are ignored, missing keys stay nil.
//

import Foundation
import Utils

// MARK: - Round-trip decode

public enum LocationDecoding {
    /// Decoder for the re-encoded location JSON. Snake→camel so DTO fields are
    /// idiomatic; resource-name dictionary keys are single words and unaffected.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static let encoder = JSONEncoder()

    /// Re-encode a generated `Codable` body to JSON, then decode into `T`.
    static func reinterpret<Body: Encodable, T: Decodable>(_ body: Body, as _: T.Type) throws -> T {
        let data = try encoder.encode(body)
        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - Public decode facade

// The `Raw*` wire DTOs below stay internal to this module; the service layer
// (`LocationsClient` in GameServices) decodes endpoint payloads only through
// these domain-typed entry points. Each takes any `Encodable` body — a
// generated OpenAPI schema or a `JSONValue` — and round-trips it through
// `reinterpret`.
extension LocationDecoding {
    /// `GET /v1/locations` — the per-location holdings overlay.
    public static func footprint(from body: some Encodable) throws -> [String: LocationCounts] {
        let raw = try reinterpret(body, as: RawFootprint.self)
        return (raw.locations ?? [:]).mapValues(\.domain)
    }

    /// `GET /v1/locations/{designation}` — polymorphic on `location_type`;
    /// read the result as a star system or a body detail.
    public static func location(from body: some Encodable) throws -> LocationPayload {
        LocationPayload(raw: try reinterpret(body, as: RawLocation.self))
    }

    /// `POST /v1/replicants/{code}/scan` — the full current-system scan.
    public static func scannedSystem(from body: some Encodable) throws -> StarSystem? {
        try reinterpret(body, as: RawScan.self).system()
    }

    /// A `scan.completed` event's `result` block — the scanned body, ready to
    /// merge into a cached `StarSystem`.
    public static func scanResultBody(from body: some Encodable) throws -> BodyDetail? {
        try reinterpret(body, as: RawScanEventResult.self).bodyDetail()
    }

    /// The absolute salvage amounts inside a `scan.completed` result. A second
    /// decode over the same payload rather than a field on `SalvageSite`: these
    /// are raw counts bound for `SiteAssay`, and the domain type deliberately
    /// carries percentages, not units.
    public static func salvageObservations(fromScanResult result: JSONValue) -> [SalvageObservation] {
        guard
            let data = try? JSONEncoder().encode(result),
            let raw = try? decoder.decode(RawScanResultSalvage.self, from: data)
        else { return [] }
        let blocks = [raw.planet?.salvage, raw.moon?.salvage, raw.salvage].compactMap { $0 }.flatMap { $0 }
        return blocks.compactMap(\.observation)
    }

    /// An `ami.survey.digest` payload's `report.scans[]` — every body the
    /// survey's drones scanned this tick, each paired with the absolute salvage
    /// amounts its block reported.
    public static func surveyScans(from body: some Encodable) throws -> SurveyScans {
        let entries = try reinterpret(body, as: RawSurveyDigestReport.self).report?.scans ?? []
        var reports: [SurveyScanReport] = []
        var unreadable: [String] = []
        for scan in entries {
            guard let observation = scan.observation() else {
                unreadable.append(scan.scanType ?? "(no scan_type)")
                continue
            }
            reports.append(SurveyScanReport(
                deviceCode: scan.deviceCode, body: observation,
                salvage: scan.salvageObservations()
            ))
        }
        return SurveyScans(reports: reports, unreadable: unreadable)
    }
}

/// The readable scans in one digest, plus the `scan_type` of each entry that
/// wasn't readable. The types are carried rather than discarded so a kind this
/// build doesn't handle (a belt or star scan, say) is *named* in the log
/// instead of vanishing into a silently-shorter array — a bare count would say
/// something was missed without saying what to implement.
public struct SurveyScans: Equatable, Sendable {
    public var reports: [SurveyScanReport]
    public var unreadable: [String]

    public init(reports: [SurveyScanReport] = [], unreadable: [String] = []) {
        self.reports = reports
        self.unreadable = unreadable
    }

    public var isEmpty: Bool { reports.isEmpty && unreadable.isEmpty }
}

/// Just enough of an `ami.survey.digest` payload to reach `report.scans[]`.
/// The rest of the digest (progress, busy/idle counts, the belt_search block)
/// is survey-queue telemetry, not location data, and is deliberately not read.
struct RawSurveyDigestReport: Decodable {
    struct Report: Decodable { var scans: [RawSurveyScan]? }
    var report: Report?
}

/// Just enough of a `scan.completed` result to reach its salvage blocks.
struct RawScanResultSalvage: Decodable {
    struct Body: Decodable { var salvage: [RawSalvage]? }
    var planet: Body?
    var moon: Body?
    var salvage: [RawSalvage]?
}

/// A decoded `GET /v1/locations/{designation}` response. The endpoint is
/// polymorphic on `location_type`, so the caller picks the reading: a star
/// yields a `StarSystem`, a planet/moon/belt a `BodyDetail`.
public struct LocationPayload {
    let raw: RawLocation
    public func starSystem() -> StarSystem? { raw.starSystem() }
    public func bodyDetail() -> BodyDetail? { raw.bodyDetail() }
}

// MARK: - Location response DTO (polymorphic on locationType)

struct RawLocation: Decodable {
    var location: String?
    var locationType: String?
    var scanned: Bool?
    var systemScanned: Bool?
    var entryPoint: String?
    // star level
    var star: RawStar?
    var planetsScanned: Int?
    var planetsTotal: Int?
    var moonsScanned: Int?
    var moonsTotal: Int?
    var moonsTotalEstimated: Bool?
    var planets: [RawPlanet]?
    var asteroidBelt: RawBeltContainer?
    // body level
    var planet: RawBodyPhysical?
    var moon: RawBodyPhysical?
    var belt: RawBelt?
    var moons: [RawMoon]?
    var lagrange: RawLagrange?
    var megastructure: RawMegastructure?
    // events / holdings (any level)
    var locationEvent: RawEvent?
    var activeLocationEvents: [RawEvent]?
    var inventory: [RawInventory]?
    var devices: [RawDevice]?
    var resourceSites: [RawResourceSite]?
    var salvage: [RawSalvage]?
}

struct RawStar: Decodable {
    var designation: String?
    var name: String?
    var stellarClass: String?
    var color: String?
    var ageMy: Double?
    var miningBonusPct: Double?
    var distanceFromSol: Double?
    var position: Position?
    // Scan-only (absent from the `locations` GET).
    var temperatureK: Double?
    var massSolar: Double?
    var luminositySolar: Double?
    var habitableZone: RawHabitableZone?
}

struct RawHabitableZone: Decodable {
    var innerAu: Double?
    var outerAu: Double?
}

extension RawStar {
    /// Map to the domain star. Shared by the `locations` GET and the scan mapping
    /// (the scan populates temperature/mass/luminosity/HZ; the GET leaves them nil).
    func systemStar(fallbackDesignation: String) -> SystemStar {
        SystemStar(
            designation: designation ?? fallbackDesignation, name: name,
            stellarClass: stellarClass, color: color, ageMy: ageMy,
            miningBonusPct: miningBonusPct, distanceFromSol: distanceFromSol,
            position: position, temperatureK: temperatureK, massSolar: massSolar,
            luminositySolar: luminositySolar,
            habitableZoneInnerAu: habitableZone?.innerAu,
            habitableZoneOuterAu: habitableZone?.outerAu
        )
    }
}

/// Star-level planet roster entry: known once the system is explored, with
/// `typeEstimated` true until the body is individually scanned.
struct RawPlanet: Decodable {
    var designation: String?
    var name: String?
    var type: String?
    var typeEstimated: Bool?
    var lifeStage: String?
    var orbitalDistanceAu: Double?
    var inHabitableZone: Bool?
    var moonCount: Int?
    var moonCountEstimated: Bool?
    var scanned: Bool?
    var inventory: [RawInventory]?
    var salvage: [RawSalvage]?
}

/// Planet-level moon roster entry (simpler than a planet).
struct RawMoon: Decodable {
    var designation: String?
    var name: String?
    var type: String?
    var scanned: Bool?
    var inventory: [RawInventory]?
    var salvage: [RawSalvage]?
}

/// `atmosphere` is a density LABEL in a scan's physical block ("thin", "crushing")
/// but a presence FLAG in `GET locations/{designation}` (`"atmosphere": false`) —
/// the same meaning a moon block spells `has_atmosphere`.
enum RawAtmosphere: Decodable {
    case label(String)
    case present(Bool)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let label = try? container.decode(String.self) {
            self = .label(label)
        } else {
            self = .present(try container.decode(Bool.self))
        }
    }

    var label: String? { if case .label(let l) = self { l } else { nil } }
    var present: Bool? { if case .present(let p) = self { p } else { nil } }
}

/// Physical block for a scanned planet or moon (`planet{}` / `moon{}`).
struct RawBodyPhysical: Decodable {
    var designation: String?
    var name: String?
    var type: String?
    var tags: [String]?
    var massEarth: Double?
    var radiusEarth: Double?
    var densityGcc: Double?
    var surfaceGravity: Double?
    var surfaceTempC: Double?
    var surfaceTempK: Double?
    var atmosphere: RawAtmosphere?
    var moonCount: Int?
    var moonCountEstimated: Bool?
    var magneticField: Bool?
    var rings: Bool?
    var rotationPeriodHours: Double?
    var orbitalPeriodDays: Double?
    var orbitalPeriodHours: Double?
    var orbitalDistanceAu: Double?
    var axialTiltDeg: Double?
    var inHabitableZone: Bool?
    var lifeStage: String?
    var speciesName: String?
    // moon extras
    var tidallyLocked: Bool?
    var orbitalDistanceKm: Double?
    var hasSubsurfaceOcean: Bool?
    var hasAtmosphere: Bool?
}

struct RawBeltContainer: Decodable {
    var present: Bool?
    var belts: [RawBelt]?
}

struct RawBelt: Decodable {
    var designation: String?
    var density: String?
    var innerRadiusAu: Double?
    var outerRadiusAu: Double?
    var resources: [String: String]?
}

struct RawResourceSite: Decodable {
    var designation: String?
    var name: String?
    var siteIndex: Int?
    var siteType: String?
    var resourcesRemainingPct: [String: Double]?
}

struct RawSalvage: Decodable {
    var designation: String?
    var name: String?
    var salvageType: String?
    var location: String?
    var resourcesAvailable: [String]?
    /// The scan.completed stream event keys salvage yield by `resources_remaining`
    /// (a quantity map) instead of `resources_available` (a name array); fall back
    /// to its keys so either shape produces `resourcesAvailable`.
    var resourcesRemaining: [String: Double]?
    var depleted: Bool?

    /// This entry's absolute remaining amounts, when it reports any. Nil when
    /// the block carries only names (the `salvage[]` roster shape), since a
    /// site with unknown units must never read as a site with zero.
    var observation: SalvageObservation? {
        guard let designation, let remaining = resourcesRemaining, !remaining.isEmpty else {
            return nil
        }
        return SalvageObservation(
            designation: designation,
            body: location ?? SalvageSite.bodyDesignation(ofSite: designation),
            resourcesRemaining: remaining
        )
    }
}

struct RawLagrange: Decodable {
    var designation: String?
    var parentPlanet: String?
    var parentPlanetName: String?
    var lPoint: String?
    var orbitalDistanceAu: Double?
}

struct RawMegastructure: Decodable {
    var designation: String?
    var name: String?
    var title: String?
    var objectType: String?
    var status: String?
    var stage: String?
    var progressPercentage: Double?
    var orbitalDistanceAu: Double?
    var deadline: String?
    /// `{device_type: {current, remaining, complete, required}}`.
    var requirements: [String: RawRequirement]?
}

/// One `requirements` entry (shared by the location detail + scan responses).
struct RawRequirement: Decodable {
    var current: Int?
    var remaining: Int?
    var complete: Bool?
    var required: Int?
}

extension Dictionary where Key == String, Value == RawRequirement {
    var domain: [StructureRequirement] {
        map { deviceType, r in
            StructureRequirement(
                deviceType: deviceType, required: r.required ?? 0,
                current: r.current ?? 0, remaining: r.remaining ?? 0, complete: r.complete ?? false
            )
        }
        .sorted { $0.deviceType < $1.deviceType }
    }
}

struct RawEvent: Decodable {
    var designation: String?
    var location: String?
    var locationName: String?
    var eventType: String?
    var title: String?
    var description: String?
    var broadcastMessage: String?
    var tier: Int?
    var status: String?
    var category: String?
}

struct RawInventory: Decodable {
    var resourceType: String?
    var quantity: Double?
}

struct RawDevice: Decodable {
    var deviceCode: String?
    var deviceType: String?
    var status: String?
}

// MARK: - Footprint response DTO (GET /v1/locations)

struct RawFootprint: Decodable {
    var locations: [String: RawCounts]?
}

struct RawCounts: Decodable {
    var locationEvents: Int?
    var devices: Int?
    var resourceSites: Int?
    var resources: Int?
    var replicants: Int?
}

// MARK: - Footprint domain

/// Per-location holdings from `GET /v1/locations` — an overlay for badges and a
/// pre-hydrate inventory hint, NOT a knowledge index (a scanned system with no
/// holdings is absent).
public struct LocationCounts: Equatable, Sendable, Codable {
    public var locationEvents: Int
    public var devices: Int
    public var resourceSites: Int
    public var resources: Int
    public var replicants: Int
    public init(
        locationEvents: Int = 0, devices: Int = 0, resourceSites: Int = 0,
        resources: Int = 0, replicants: Int = 0
    ) {
        self.locationEvents = locationEvents
        self.devices = devices
        self.resourceSites = resourceSites
        self.resources = resources
        self.replicants = replicants
    }
}

// MARK: - DTO → domain mapping

extension RawInventory {
    var domain: InventoryItem? {
        guard let resourceType else { return nil }
        return InventoryItem(resourceType: resourceType, quantity: quantity ?? 0)
    }
}

extension RawDevice {
    var domain: LocatedDevice? {
        guard let deviceCode else { return nil }
        return LocatedDevice(deviceCode: deviceCode, deviceType: deviceType ?? "", status: status)
    }
}

extension RawResourceSite {
    /// True when the server tags this `resource_sites` entry as salvage — the
    /// live API returns salvage wreckage inside `resource_sites` with
    /// `site_type == "salvage"` rather than in a separate `salvage` block.
    var isSalvage: Bool { siteType == "salvage" }

    var domain: ResourceSite? {
        guard let designation else { return nil }
        return ResourceSite(
            designation: designation, name: name, siteIndex: siteIndex,
            remaining: resourcesRemainingPct ?? [:]
        )
    }

    /// Reinterpret a salvage-typed resource site as a `SalvageSite`. Its
    /// `resources_remaining_pct` keys are the yieldable resources and its values
    /// are how much of each is left; all-zero (or empty) remaining means spent.
    var salvageDomain: SalvageSite? {
        guard let designation else { return nil }
        let remaining = resourcesRemainingPct ?? [:]
        return SalvageSite(
            designation: designation, name: name,
            resourcesAvailable: remaining.keys.sorted(),
            depleted: !remaining.isEmpty && remaining.values.allSatisfy { $0 <= 0 },
            remainingPct: remaining
        )
    }
}

extension RawSalvage {
    var domain: SalvageSite? {
        guard let designation else { return nil }
        let available = resourcesAvailable ?? resourcesRemaining.map { $0.keys.sorted() } ?? []
        return SalvageSite(
            designation: designation, name: name, salvageType: salvageType,
            location: location, resourcesAvailable: available,
            depleted: depleted ?? false
        )
    }
}

extension RawBodyPhysical {
    var physical: BodyPhysical {
        BodyPhysical(
            massEarth: massEarth, radiusEarth: radiusEarth, densityGcc: densityGcc,
            surfaceGravity: surfaceGravity, surfaceTempC: surfaceTempC, surfaceTempK: surfaceTempK,
            atmosphere: atmosphere?.label, magneticField: magneticField, rings: rings,
            rotationPeriodHours: rotationPeriodHours, orbitalPeriodDays: orbitalPeriodDays,
            orbitalPeriodHours: orbitalPeriodHours,
            axialTiltDeg: axialTiltDeg, tags: tags ?? [], speciesName: speciesName,
            tidallyLocked: tidallyLocked,
            orbitalDistanceKm: orbitalDistanceKm, hasSubsurfaceOcean: hasSubsurfaceOcean,
            hasAtmosphere: hasAtmosphere ?? atmosphere?.present
        )
    }
}

extension RawBelt {
    func domain(sites: [ResourceSite] = [], inventory: [InventoryItem] = [],
                devices: [LocatedDevice] = []) -> Belt? {
        guard let designation else { return nil }
        return Belt(
            designation: designation, innerRadiusAu: innerRadiusAu, outerRadiusAu: outerRadiusAu,
            density: density, richness: resources ?? [:], sites: sites, inventory: inventory,
            devices: devices
        )
    }
}

extension RawEvent {
    var domain: LocationEventInfo? {
        guard let designation else { return nil }
        return LocationEventInfo(
            designation: designation, location: location, locationName: locationName,
            eventType: eventType, title: title, eventDescription: description,
            broadcastMessage: broadcastMessage, tier: tier, status: status, category: category
        )
    }
}

extension RawPlanet {
    /// Roster-level planet: known bodies with estimated attributes until scanned.
    var domain: Planet? {
        guard let designation else { return nil }
        let isScanned = scanned ?? false
        return Planet(
            designation: designation, name: name, type: type,
            typeEstimated: typeEstimated ?? false, orbitalDistanceAu: orbitalDistanceAu,
            inHabitableZone: inHabitableZone ?? false, lifeStage: lifeStage,
            recon: isScanned ? .scanned : .visited, moonCount: moonCount,
            moonCountEstimated: moonCountEstimated ?? false,
            inventory: (inventory ?? []).compactMap(\.domain),
            events: []
        )
        // Nested detail (physical, moons, sites, salvage, devices) is merged in
        // by a subsequent body() hydrate — see LocationsClient.
    }

    var salvageSites: [SalvageSite] { (salvage ?? []).compactMap(\.domain) }
}

extension RawCounts {
    var domain: LocationCounts {
        LocationCounts(
            locationEvents: locationEvents ?? 0, devices: devices ?? 0,
            resourceSites: resourceSites ?? 0, resources: resources ?? 0,
            replicants: replicants ?? 0
        )
    }
}

// MARK: - System assembly

extension RawLocation {
    /// Build the star-level `StarSystem` from a `location_type == "star"`
    /// response. Recon: unexplored systems never reach here (they 403), so a
    /// system is at least `.visited`; `.scanned` once every planet is scanned.
    func starSystem() -> StarSystem? {
        guard let designation = star?.designation ?? location else { return nil }
        let planetDomains = (planets ?? []).compactMap { raw -> Planet? in
            guard var p = raw.domain else { return nil }
            p.salvage = raw.salvageSites
            return p
        }
        let scannedAll = (planetsScanned ?? 0) >= (planetsTotal ?? .max) && (planetsTotal ?? 0) > 0
        let recon: Recon = (systemScanned ?? false)
            ? (scannedAll ? .scanned : .visited)
            : .visited
        let events = ((locationEvent.map { [$0] } ?? []) + (activeLocationEvents ?? []))
            .compactMap(\.domain)
        return StarSystem(
            designation: designation,
            name: star?.name,
            star: star.map { $0.systemStar(fallbackDesignation: designation) },
            recon: recon,
            systemScanned: systemScanned ?? false,
            entryPoint: entryPoint,
            planetsScanned: planetsScanned, planetsTotal: planetsTotal,
            moonsScanned: moonsScanned, moonsTotal: moonsTotal,
            moonsTotalEstimated: moonsTotalEstimated ?? false,
            belts: (asteroidBelt?.belts ?? []).compactMap { $0.domain() },
            planets: planetDomains,
            events: events
        )
    }

    /// Build the scanned detail for a single body from a planet/moon/belt-level
    /// response, to be merged into the tree in place of its roster stub.
    func bodyDetail() -> BodyDetail? {
        // Salvage arrives inside `resource_sites` (site_type == "salvage"), so
        // split those out into the salvage roster and keep the rest as mining
        // sites — plus any that come in a dedicated `salvage` block (spec drift).
        let rawSites = resourceSites ?? []
        let sites = rawSites.filter { !$0.isSalvage }.compactMap(\.domain)
        let salvageSites = rawSites.filter(\.isSalvage).compactMap(\.salvageDomain)
            + (salvage ?? []).compactMap(\.domain)
        let devs = (devices ?? []).compactMap(\.domain)
        let inv = (inventory ?? []).compactMap(\.domain)
        let events = ((locationEvent.map { [$0] } ?? []) + (activeLocationEvents ?? []))
            .compactMap(\.domain)

        // The location endpoint is gated on *presence*, not scanning, so it returns
        // a body we're sitting in even when it's never been scanned. It signals an
        // unscanned body by sending `scanned: false` explicitly; an already-scanned
        // body OMITS the flag (and carries a full physical block). So "unscanned"
        // means `scanned == false` specifically — a missing flag reads as scanned.
        // (Marking every fetched body `.scanned` is what made unscanned bodies read
        // as "Scanned"; keying off `scanned ?? false` would then wrongly demote the
        // scanned bodies that omit the flag.)
        let isScanned = scanned != false
        let bodyRecon: Recon = isScanned ? .scanned : .visited
        switch locationType {
        case "planet":
            guard let p = planet, let designation = p.designation ?? location else { return nil }
            let moonDomains = (moons ?? []).compactMap { m -> Moon? in
                guard let d = m.designation else { return nil }
                return Moon(
                    designation: d, name: m.name, type: m.type,
                    recon: (m.scanned ?? false) ? .scanned : .visited,
                    salvage: (m.salvage ?? []).compactMap(\.domain),
                    inventory: (m.inventory ?? []).compactMap(\.domain)
                )
            }
            // An unscanned planet declares `moon_count` and sends no roster, so the
            // roster's length alone would erase a count the catalog already holds.
            let declaredMoons = p.moonCount.map { max($0, moonDomains.count) } ?? moonDomains.count
            let planetDomain = Planet(
                designation: designation, name: p.name, type: p.type, typeEstimated: !isScanned,
                orbitalDistanceAu: p.orbitalDistanceAu, inHabitableZone: p.inHabitableZone ?? false,
                lifeStage: p.lifeStage, recon: bodyRecon, moonCount: declaredMoons,
                moonCountEstimated: p.moonCountEstimated ?? false,
                physical: isScanned ? p.physical : nil, moons: moonDomains, sites: sites, salvage: salvageSites,
                devices: devs, inventory: inv, events: events
            )
            return .planet(planetDomain)

        case "moon":
            guard let m = moon, let designation = m.designation ?? location else { return nil }
            return .moon(Moon(
                designation: designation, name: m.name, type: m.type, lifeStage: m.lifeStage,
                recon: bodyRecon,
                physical: isScanned ? m.physical : nil, sites: sites, salvage: salvageSites,
                devices: devs, inventory: inv
            ))

        case "belt":
            guard let b = belt?.domain(sites: sites, inventory: inv, devices: devs) else { return nil }
            return .belt(b)

        case "lagrange":
            guard let l = lagrange, let designation = l.designation ?? location else { return nil }
            return .special(SpecialSite(
                designation: designation, kind: .lagrange, label: l.lPoint,
                parentBody: l.parentPlanet, orbitalDistanceAu: l.orbitalDistanceAu,
                inventory: inv, devices: devs
            ))

        case "megastructure":
            guard let designation = megastructure?.designation ?? location else { return nil }
            return .special(SpecialSite(
                designation: designation, kind: .megastructure, objectType: megastructure?.objectType,
                name: megastructure?.name, title: megastructure?.title,
                status: megastructure?.status, stage: megastructure?.stage,
                orbitalDistanceAu: megastructure?.orbitalDistanceAu,
                progressPercentage: megastructure?.progressPercentage, deadline: megastructure?.deadline,
                requirements: (megastructure?.requirements ?? [:]).domain, inventory: inv,
                devices: devs
            ))

        case "kuiper", "oort", "object":
            guard let designation = location else { return nil }
            let kind: SpecialSiteKind = SpecialSiteKind(rawValue: locationType ?? "object") ?? .object
            return .special(SpecialSite(designation: designation, kind: kind, inventory: inv, devices: devs))

        default:
            return nil
        }
    }
}

/// The scanned detail for one body, merged into the tree by the reducer.
public enum BodyDetail: Equatable, Sendable {
    case planet(Planet)
    case moon(Moon)
    case belt(Belt)
    case special(SpecialSite)
}

// MARK: - scan.completed stream event result

/// The `result` block of a `scan.completed` stream event. Unlike the locations
/// endpoint (which nests physical under `moon`/`planet`/`belt` and puts salvage/
/// sites at the response top level), the event folds a body's collections
/// *inside* the body object — so it needs its own decode path into `BodyDetail`.
struct RawScanEventResult: Decodable {
    var moon: RawScannedBody?
    var planet: RawScannedBody?
    var belt: RawScannedBody?

    /// The scanned body as a `BodyDetail` ready to merge into a `StarSystem`.
    func bodyDetail() -> BodyDetail? {
        if let m = moon, let designation = m.physical.designation {
            return .moon(Moon(
                designation: designation, name: m.physical.name, type: m.physical.type,
                lifeStage: m.physical.lifeStage,
                recon: .scanned, physical: m.physical.physical,
                sites: m.sites, salvage: m.salvageSites, devices: m.located, inventory: m.stored
            ))
        }
        if let p = planet, let designation = p.physical.designation {
            let moonDomains = (p.moons ?? []).compactMap { rm -> Moon? in
                guard let md = rm.designation else { return nil }
                return Moon(
                    designation: md, name: rm.name, type: rm.type,
                    recon: (rm.scanned ?? false) ? .scanned : .visited,
                    salvage: (rm.salvage ?? []).compactMap(\.domain),
                    inventory: (rm.inventory ?? []).compactMap(\.domain)
                )
            }
            return .planet(Planet(
                designation: designation, name: p.physical.name, type: p.physical.type,
                typeEstimated: false, orbitalDistanceAu: p.physical.orbitalDistanceAu,
                inHabitableZone: p.physical.inHabitableZone ?? false, lifeStage: p.physical.lifeStage,
                recon: .scanned, moonCount: moonDomains.count, physical: p.physical.physical,
                moons: moonDomains, sites: p.sites, salvage: p.salvageSites,
                devices: p.located, inventory: p.stored
            ))
        }
        if let b = belt, let designation = b.physical.designation {
            return .belt(Belt(designation: designation, sites: b.sites, inventory: b.stored))
        }
        return nil
    }
}

// MARK: - ami.survey.digest report.scans[]

/// One entry of an `ami.survey.digest` payload's `report.scans[]` (API v2.3.3).
///
/// This is the *only* channel through which an AMI-adopted survey drone's scan
/// intel reaches the client — those drones emit no per-device events at all
/// (see the `ami-drones-are-event-silent` note), so before this block existed a
/// survey that scanned nine bodies produced nothing but counts.
struct RawSurveyScan: Decodable {
    var deviceCode: String?
    var scanTarget: String?
    var scanType: String?
    var report: RawSurveyScanReport?
}

/// The body block inside one survey scan. Structurally *almost*
/// `RawScanEventResult`, with one difference that matters: the digest hangs
/// `moons` off the report as a sibling of `planet`, where a `scan.completed`
/// result nests it inside the planet object. Hence the separate type rather
/// than a reuse.
struct RawSurveyScanReport: Decodable {
    var planet: RawScannedBody?
    var moon: RawScannedBody?
    var moons: [RawMoon]?
}

extension RawSurveyScan {
    /// The scanned body as a partial observation, or nil for an entry we can't
    /// read — a missing report, a designation-less body, or a `scan_type` this
    /// build doesn't know (the caller logs those so a new kind surfaces).
    func observation() -> BodyObservation? {
        guard let report else { return nil }
        if let planet = report.planet, let designation = planet.physical.designation ?? scanTarget {
            // Roster stubs: designation, name, type and a `scanned` flag. A stub
            // is `.visited`, not `.scanned` — the survey saw that the moon is
            // there, not what it is made of.
            let moons = (report.moons ?? []).compactMap { raw -> Moon? in
                guard let moonDesignation = raw.designation else { return nil }
                return Moon(
                    designation: moonDesignation, name: raw.name, type: raw.type,
                    recon: (raw.scanned ?? false) ? .scanned : .visited,
                    salvage: (raw.salvage ?? []).compactMap(\.domain),
                    inventory: (raw.inventory ?? []).compactMap(\.domain)
                )
            }
            return BodyObservation(
                kind: .planet, designation: designation, name: planet.physical.name,
                type: planet.physical.type, lifeStage: planet.physical.lifeStage,
                inHabitableZone: planet.physical.inHabitableZone,
                orbitalDistanceAu: planet.physical.orbitalDistanceAu,
                physical: planet.physical.physical, salvage: planet.salvageSites, moons: moons
            )
        }
        if let moon = report.moon, let designation = moon.physical.designation ?? scanTarget {
            return BodyObservation(
                kind: .moon, designation: designation, name: moon.physical.name,
                type: moon.physical.type, lifeStage: moon.physical.lifeStage,
                physical: moon.physical.physical, salvage: moon.salvageSites
            )
        }
        return nil
    }

    /// Absolute salvage amounts reported inside this scan's body block — the
    /// only source of a site's unit totals, bound for `SiteAssay`.
    func salvageObservations() -> [SalvageObservation] {
        let blocks = [report?.planet?.salvage, report?.moon?.salvage].compactMap { $0 }.flatMap { $0 }
        return blocks.compactMap(\.observation)
    }
}

/// One scanned body from a scan-event `result`: its physical block (decoded from the
/// same object) plus the salvage/sites/devices/inventory (and moons, for a
/// planet) the event nests inside it.
struct RawScannedBody: Decodable {
    var physical: RawBodyPhysical
    var salvage: [RawSalvage]?
    var resourceSites: [RawResourceSite]?
    var devices: [RawDevice]?
    var inventory: [RawInventory]?
    var moons: [RawMoon]?

    private enum CodingKeys: String, CodingKey {
        case salvage, resourceSites, devices, inventory, moons
    }

    init(from decoder: Decoder) throws {
        // Physical attributes decode from the same object (unknown keys ignored).
        physical = try RawBodyPhysical(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        salvage = try c.decodeIfPresent([RawSalvage].self, forKey: .salvage)
        resourceSites = try c.decodeIfPresent([RawResourceSite].self, forKey: .resourceSites)
        devices = try c.decodeIfPresent([RawDevice].self, forKey: .devices)
        inventory = try c.decodeIfPresent([RawInventory].self, forKey: .inventory)
        moons = try c.decodeIfPresent([RawMoon].self, forKey: .moons)
    }

    /// Mining sites only — salvage-typed resource sites are pulled into salvage.
    var sites: [ResourceSite] { (resourceSites ?? []).filter { !$0.isSalvage }.compactMap(\.domain) }

    /// Salvage: the dedicated block plus any salvage-typed resource sites.
    var salvageSites: [SalvageSite] {
        (salvage ?? []).compactMap(\.domain)
            + (resourceSites ?? []).filter(\.isSalvage).compactMap(\.salvageDomain)
    }

    var located: [LocatedDevice] { (devices ?? []).compactMap(\.domain) }
    var stored: [InventoryItem] { (inventory ?? []).compactMap(\.domain) }
}
