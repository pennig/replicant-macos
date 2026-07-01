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

// MARK: - Round-trip decode

enum LocationDecoding {
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
    var atmosphere: String?
    var magneticField: Bool?
    var rings: Bool?
    var rotationPeriodHours: Double?
    var orbitalPeriodDays: Double?
    var orbitalDistanceAu: Double?
    var axialTiltDeg: Double?
    var inHabitableZone: Bool?
    var lifeStage: String?
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
    var resourcesRemainingPct: [String: Double]?
}

struct RawSalvage: Decodable {
    var designation: String?
    var name: String?
    var salvageType: String?
    var location: String?
    var resourcesAvailable: [String]?
    var depleted: Bool?
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
    var progress: Double?
    // requirements shape unconfirmed live; accept the documented per-type form.
    var requirements: [RawStructureRequirement]?
}

struct RawStructureRequirement: Decodable {
    var deviceType: String?
    var needed: Int?
    var contributed: Int?
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
    var domain: ResourceSite? {
        guard let designation else { return nil }
        return ResourceSite(
            designation: designation, name: name, siteIndex: siteIndex,
            remaining: resourcesRemainingPct ?? [:]
        )
    }
}

extension RawSalvage {
    var domain: SalvageSite? {
        guard let designation else { return nil }
        return SalvageSite(
            designation: designation, name: name, salvageType: salvageType,
            location: location, resourcesAvailable: resourcesAvailable ?? [],
            depleted: depleted ?? false
        )
    }
}

extension RawBodyPhysical {
    var physical: BodyPhysical {
        BodyPhysical(
            massEarth: massEarth, radiusEarth: radiusEarth, densityGcc: densityGcc,
            surfaceGravity: surfaceGravity, surfaceTempC: surfaceTempC, surfaceTempK: surfaceTempK,
            atmosphere: atmosphere, magneticField: magneticField, rings: rings,
            rotationPeriodHours: rotationPeriodHours, orbitalPeriodDays: orbitalPeriodDays,
            axialTiltDeg: axialTiltDeg, tags: tags ?? [], tidallyLocked: tidallyLocked,
            orbitalDistanceKm: orbitalDistanceKm, hasSubsurfaceOcean: hasSubsurfaceOcean,
            hasAtmosphere: hasAtmosphere
        )
    }
}

extension RawBelt {
    func domain(sites: [ResourceSite] = [], inventory: [InventoryItem] = []) -> Belt? {
        guard let designation else { return nil }
        return Belt(
            designation: designation, innerRadiusAu: innerRadiusAu, outerRadiusAu: outerRadiusAu,
            density: density, richness: resources ?? [:], sites: sites, inventory: inventory
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
            star: star.map {
                SystemStar(
                    designation: $0.designation ?? designation, name: $0.name,
                    stellarClass: $0.stellarClass, color: $0.color, ageMy: $0.ageMy,
                    miningBonusPct: $0.miningBonusPct, distanceFromSol: $0.distanceFromSol,
                    position: $0.position
                )
            },
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
        let sites = (resourceSites ?? []).compactMap(\.domain)
        let salvageSites = (salvage ?? []).compactMap(\.domain)
        let devs = (devices ?? []).compactMap(\.domain)
        let inv = (inventory ?? []).compactMap(\.domain)
        let events = ((locationEvent.map { [$0] } ?? []) + (activeLocationEvents ?? []))
            .compactMap(\.domain)

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
            let planetDomain = Planet(
                designation: designation, name: p.name, type: p.type, typeEstimated: false,
                orbitalDistanceAu: p.orbitalDistanceAu, inHabitableZone: p.inHabitableZone ?? false,
                lifeStage: p.lifeStage, recon: .scanned, moonCount: moonDomains.count,
                physical: p.physical, moons: moonDomains, sites: sites, salvage: salvageSites,
                devices: devs, inventory: inv, events: events
            )
            return .planet(planetDomain)

        case "moon":
            guard let m = moon, let designation = m.designation ?? location else { return nil }
            return .moon(Moon(
                designation: designation, name: m.name, type: m.type, recon: .scanned,
                physical: m.physical, sites: sites, salvage: salvageSites,
                devices: devs, inventory: inv
            ))

        case "belt":
            guard let b = belt?.domain(sites: sites, inventory: inv) else { return nil }
            return .belt(b)

        case "lagrange":
            guard let l = lagrange, let designation = l.designation ?? location else { return nil }
            return .special(SpecialSite(
                designation: designation, kind: .lagrange, label: l.lPoint,
                parentBody: l.parentPlanet, orbitalDistanceAu: l.orbitalDistanceAu
            ))

        case "megastructure":
            guard let designation = megastructure?.designation ?? location else { return nil }
            return .special(SpecialSite(
                designation: designation, kind: .megastructure, name: megastructure?.name,
                progress: megastructure?.progress,
                requirements: (megastructure?.requirements ?? []).compactMap { r in
                    r.deviceType.map {
                        StructureRequirement(deviceType: $0, needed: r.needed ?? 0, contributed: r.contributed ?? 0)
                    }
                }
            ))

        case "kuiper", "oort", "object":
            guard let designation = location else { return nil }
            let kind: SpecialSiteKind = SpecialSiteKind(rawValue: locationType ?? "object") ?? .object
            return .special(SpecialSite(designation: designation, kind: kind))

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
