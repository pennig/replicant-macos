//
//  LocationModels.swift
//  UniverseModels
//
//  The canonical "what we know" domain for the stellar-locations catalog. These
//  are pure value types shared by the catalog feature and (eventually) anything
//  else that needs charted-universe data. They are deliberately decoupled from
//  the StarMap orrery's presentation models (which carry SceneKit scene units) —
//  see `StarMapFeature/SystemModels.swift`.
//
//  The designation hierarchy *is* the tree:
//    SOL · SOL-3 · SOL-3-1 · SOL-BELT-1 · SOL-BELT-1-SITE-0 · SOL-5-L4
//
//  Knowledge is graded (see `Recon`) and orthogonal per level: a system can be
//  `explored` (its body roster known, with *estimated* types) while individual
//  bodies remain unscanned. The backend surfaces this as `system_scanned` +
//  per-body `scanned`/`*_estimated` flags, which the mapping layer folds into
//  `Recon` and the `…Estimated` fields below.
//
//  These types are `Codable` so a whole `StarSystem` can be persisted as one
//  JSON blob per explored system (mirroring the `Device.detail` convention) and
//  the tree/roll-ups reconstructed in memory. API decoding is a separate DTO
//  layer — see `LocationDTOs.swift`.
//

import Foundation

// MARK: - Shared leaf values

/// A stored resource quantity at a location. Mirrors
/// `app_schemas_scanning_InventoryItemSchema`. (Moved here from StarMap so the
/// orrery and the catalog share one definition.)
public struct InventoryItem: Equatable, Sendable, Codable {
    public var resourceType: String
    public var quantity: Double
    public init(resourceType: String, quantity: Double) {
        self.resourceType = resourceType
        self.quantity = quantity
    }
}

/// A device stationed at a body/belt, as location detail reports it.
public struct LocatedDevice: Identifiable, Equatable, Sendable, Codable {
    public var deviceCode: String
    public var deviceType: String
    public var status: String?
    public var id: String { deviceCode }
    public init(deviceCode: String, deviceType: String, status: String? = nil) {
        self.deviceCode = deviceCode
        self.deviceType = deviceType
        self.status = status
    }
}

/// A mineable site at a belt, planet, or moon (designation `…-SITE-N`).
/// `remaining` maps a resource name → percent remaining (0…100), straight from
/// `resources_remaining_pct`. Not a valid travel destination — a mining target.
public struct ResourceSite: Identifiable, Equatable, Sendable, Codable {
    public var designation: String
    public var name: String?
    public var siteIndex: Int?
    public var remaining: [String: Double]
    public var id: String { designation }

    public init(
        designation: String, name: String? = nil, siteIndex: Int? = nil,
        remaining: [String: Double] = [:]
    ) {
        self.designation = designation
        self.name = name
        self.siteIndex = siteIndex
        self.remaining = remaining
    }
}

/// Discoverable wreckage/debris at a planet or moon (designation `…-SAL-N`).
/// Distinct from a mining `ResourceSite`: salvage lists *which* resources it can
/// yield (`resourcesAvailable`) and whether it is spent (`depleted`), with no
/// per-resource percentages. `salvageType` is a flavor tag (e.g.
/// "research_station").
public struct SalvageSite: Identifiable, Equatable, Sendable, Codable {
    public var designation: String
    public var name: String?
    public var salvageType: String?
    public var location: String?
    public var resourcesAvailable: [String]
    public var depleted: Bool
    public var id: String { designation }

    public init(
        designation: String, name: String? = nil, salvageType: String? = nil,
        location: String? = nil, resourcesAvailable: [String] = [], depleted: Bool = false
    ) {
        self.designation = designation
        self.name = name
        self.salvageType = salvageType
        self.location = location
        self.resourcesAvailable = resourcesAvailable
        self.depleted = depleted
    }
}

/// Physical attributes of a planet or moon — populated only once the body is
/// scanned. Every field is optional so the same struct serves both.
public struct BodyPhysical: Equatable, Sendable, Codable {
    public var massEarth: Double?
    public var radiusEarth: Double?
    public var densityGcc: Double?
    public var surfaceGravity: Double?
    public var surfaceTempC: Double?
    public var surfaceTempK: Double?
    public var atmosphere: String?
    public var magneticField: Bool?
    public var rings: Bool?
    public var rotationPeriodHours: Double?
    public var orbitalPeriodDays: Double?
    public var axialTiltDeg: Double?
    public var tags: [String]
    // Moon-specific
    public var tidallyLocked: Bool?
    public var orbitalDistanceKm: Double?
    public var hasSubsurfaceOcean: Bool?
    public var hasAtmosphere: Bool?

    public init(
        massEarth: Double? = nil, radiusEarth: Double? = nil, densityGcc: Double? = nil,
        surfaceGravity: Double? = nil, surfaceTempC: Double? = nil, surfaceTempK: Double? = nil,
        atmosphere: String? = nil, magneticField: Bool? = nil, rings: Bool? = nil,
        rotationPeriodHours: Double? = nil, orbitalPeriodDays: Double? = nil, axialTiltDeg: Double? = nil,
        tags: [String] = [], tidallyLocked: Bool? = nil, orbitalDistanceKm: Double? = nil,
        hasSubsurfaceOcean: Bool? = nil, hasAtmosphere: Bool? = nil
    ) {
        self.massEarth = massEarth
        self.radiusEarth = radiusEarth
        self.densityGcc = densityGcc
        self.surfaceGravity = surfaceGravity
        self.surfaceTempC = surfaceTempC
        self.surfaceTempK = surfaceTempK
        self.atmosphere = atmosphere
        self.magneticField = magneticField
        self.rings = rings
        self.rotationPeriodHours = rotationPeriodHours
        self.orbitalPeriodDays = orbitalPeriodDays
        self.axialTiltDeg = axialTiltDeg
        self.tags = tags
        self.tidallyLocked = tidallyLocked
        self.orbitalDistanceKm = orbitalDistanceKm
        self.hasSubsurfaceOcean = hasSubsurfaceOcean
        self.hasAtmosphere = hasAtmosphere
    }
}

// MARK: - Special / outer-system sites

public enum SpecialSiteKind: String, Equatable, Sendable, Codable, CaseIterable {
    case lagrange, megastructure, object, kuiper, oort

    public var label: String {
        switch self {
        case .lagrange:      "Lagrange Point"
        case .megastructure: "Megastructure"
        case .object:        "Object"
        case .kuiper:        "Kuiper Belt"
        case .oort:          "Oort Cloud"
        }
    }
}

/// A per-device-type contribution requirement for a megastructure.
public struct StructureRequirement: Identifiable, Equatable, Sendable, Codable {
    public var deviceType: String
    public var needed: Int
    public var contributed: Int
    public var id: String { deviceType }
    public init(deviceType: String, needed: Int, contributed: Int = 0) {
        self.deviceType = deviceType
        self.needed = needed
        self.contributed = contributed
    }
}

/// A location that isn't a planet/moon/belt: a lagrange point, megastructure,
/// or outer-system region (Kuiper/Oort/system object). `parentBody` names the
/// planet a lagrange point leads. For megastructures, `progress` (0…1) and
/// `requirements` track galaxy-wide construction.
public struct SpecialSite: Identifiable, Equatable, Sendable, Codable {
    public var designation: String
    public var kind: SpecialSiteKind
    public var name: String?
    public var label: String?
    public var parentBody: String?
    public var orbitalDistanceAu: Double?
    public var progress: Double?
    public var requirements: [StructureRequirement]
    public var id: String { designation }

    public init(
        designation: String, kind: SpecialSiteKind, name: String? = nil, label: String? = nil,
        parentBody: String? = nil, orbitalDistanceAu: Double? = nil, progress: Double? = nil,
        requirements: [StructureRequirement] = []
    ) {
        self.designation = designation
        self.kind = kind
        self.name = name
        self.label = label
        self.parentBody = parentBody
        self.orbitalDistanceAu = orbitalDistanceAu
        self.progress = progress
        self.requirements = requirements
    }
}

// MARK: - Shops (system-scoped; each references a body)

public struct ShopTrade: Identifiable, Equatable, Sendable, Codable {
    public var tradeCode: String
    public var name: String
    public var currentStock: Int?
    public var id: String { tradeCode }
    public init(tradeCode: String, name: String, currentStock: Int? = nil) {
        self.tradeCode = tradeCode
        self.name = name
        self.currentStock = currentStock
    }
}

/// A trade controller sited on some body (`location`). Shops arrive with the
/// system scan, not the location endpoint, so they are held at the system level
/// and bubbled to a body via `location`.
public struct Shop: Identifiable, Equatable, Sendable, Codable {
    public var controllerCode: String
    public var shopName: String
    public var shopDescription: String?
    public var location: String
    public var locationName: String?
    public var ownerReplicantCode: String?
    public var ownerName: String?
    public var trades: [ShopTrade]
    public var id: String { controllerCode }

    public init(
        controllerCode: String, shopName: String, shopDescription: String? = nil,
        location: String, locationName: String? = nil, ownerReplicantCode: String? = nil,
        ownerName: String? = nil, trades: [ShopTrade] = []
    ) {
        self.controllerCode = controllerCode
        self.shopName = shopName
        self.shopDescription = shopDescription
        self.location = location
        self.locationName = locationName
        self.ownerReplicantCode = ownerReplicantCode
        self.ownerName = ownerName
        self.trades = trades
    }
}

// MARK: - Location events

/// A time-limited or community event sited at a location. Summary fields only;
/// the deep criteria/progress payload is intentionally omitted here.
public struct LocationEventInfo: Identifiable, Equatable, Sendable, Codable {
    public var designation: String
    public var location: String?
    public var locationName: String?
    public var eventType: String?
    public var title: String?
    public var eventDescription: String?
    public var broadcastMessage: String?
    public var tier: Int?
    public var status: String?
    public var category: String?
    public var id: String { designation }

    public init(
        designation: String, location: String? = nil, locationName: String? = nil,
        eventType: String? = nil, title: String? = nil, eventDescription: String? = nil,
        broadcastMessage: String? = nil, tier: Int? = nil, status: String? = nil,
        category: String? = nil
    ) {
        self.designation = designation
        self.location = location
        self.locationName = locationName
        self.eventType = eventType
        self.title = title
        self.eventDescription = eventDescription
        self.broadcastMessage = broadcastMessage
        self.tier = tier
        self.status = status
        self.category = category
    }
}

// MARK: - Bodies

public struct Moon: Identifiable, Equatable, Sendable, Codable {
    public var designation: String
    public var name: String?
    public var type: String?
    public var recon: Recon
    public var physical: BodyPhysical?
    public var sites: [ResourceSite]
    public var salvage: [SalvageSite]
    public var devices: [LocatedDevice]
    public var inventory: [InventoryItem]
    public var id: String { designation }

    public init(
        designation: String, name: String? = nil, type: String? = nil, recon: Recon = .aware,
        physical: BodyPhysical? = nil, sites: [ResourceSite] = [], salvage: [SalvageSite] = [],
        devices: [LocatedDevice] = [], inventory: [InventoryItem] = []
    ) {
        self.designation = designation
        self.name = name
        self.type = type
        self.recon = recon
        self.physical = physical
        self.sites = sites
        self.salvage = salvage
        self.devices = devices
        self.inventory = inventory
    }
}

public struct Belt: Identifiable, Equatable, Sendable, Codable {
    public var designation: String
    public var innerRadiusAu: Double?
    public var outerRadiusAu: Double?
    public var density: String?
    /// Resource name → richness qualifier ("low"/"moderate"/"high"/"abundant").
    public var richness: [String: String]
    public var sites: [ResourceSite]
    /// Accumulated stock held at the belt (distinct from `sites`, which are the
    /// discovered deposits). Drives the belt's contribution to the Inventory sort.
    public var inventory: [InventoryItem]
    public var id: String { designation }

    public init(
        designation: String, innerRadiusAu: Double? = nil, outerRadiusAu: Double? = nil,
        density: String? = nil, richness: [String: String] = [:], sites: [ResourceSite] = [],
        inventory: [InventoryItem] = []
    ) {
        self.designation = designation
        self.innerRadiusAu = innerRadiusAu
        self.outerRadiusAu = outerRadiusAu
        self.density = density
        self.richness = richness
        self.sites = sites
        self.inventory = inventory
    }
}

public struct Planet: Identifiable, Equatable, Sendable, Codable {
    public var designation: String
    public var name: String?
    public var type: String?
    public var typeEstimated: Bool
    public var orbitalDistanceAu: Double?
    public var inHabitableZone: Bool
    public var lifeStage: String?
    public var recon: Recon
    public var moonCount: Int?
    public var moonCountEstimated: Bool
    public var physical: BodyPhysical?
    public var moons: [Moon]
    public var sites: [ResourceSite]
    public var salvage: [SalvageSite]
    public var devices: [LocatedDevice]
    public var inventory: [InventoryItem]
    public var lagrange: [SpecialSite]
    public var events: [LocationEventInfo]
    public var id: String { designation }

    public init(
        designation: String, name: String? = nil, type: String? = nil, typeEstimated: Bool = false,
        orbitalDistanceAu: Double? = nil, inHabitableZone: Bool = false, lifeStage: String? = nil,
        recon: Recon = .aware, moonCount: Int? = nil, moonCountEstimated: Bool = false,
        physical: BodyPhysical? = nil, moons: [Moon] = [], sites: [ResourceSite] = [],
        salvage: [SalvageSite] = [], devices: [LocatedDevice] = [], inventory: [InventoryItem] = [],
        lagrange: [SpecialSite] = [], events: [LocationEventInfo] = []
    ) {
        self.designation = designation
        self.name = name
        self.type = type
        self.typeEstimated = typeEstimated
        self.orbitalDistanceAu = orbitalDistanceAu
        self.inHabitableZone = inHabitableZone
        self.lifeStage = lifeStage
        self.recon = recon
        self.moonCount = moonCount
        self.moonCountEstimated = moonCountEstimated
        self.physical = physical
        self.moons = moons
        self.sites = sites
        self.salvage = salvage
        self.devices = devices
        self.inventory = inventory
        self.lagrange = lagrange
        self.events = events
    }
}

/// Physical attributes of the system's star.
public struct SystemStar: Equatable, Sendable, Codable {
    public var designation: String
    public var name: String?
    public var stellarClass: String?
    public var color: String?
    public var ageMy: Double?
    public var miningBonusPct: Double?
    public var distanceFromSol: Double?
    public var position: Position?

    public init(
        designation: String, name: String? = nil, stellarClass: String? = nil, color: String? = nil,
        ageMy: Double? = nil, miningBonusPct: Double? = nil, distanceFromSol: Double? = nil,
        position: Position? = nil
    ) {
        self.designation = designation
        self.name = name
        self.stellarClass = stellarClass
        self.color = color
        self.ageMy = ageMy
        self.miningBonusPct = miningBonusPct
        self.distanceFromSol = distanceFromSol
        self.position = position
    }
}

// MARK: - System aggregate

/// Everything we know about one star system: the root of the catalog tree.
/// Persisted as a single JSON blob per explored system.
public struct StarSystem: Identifiable, Equatable, Sendable, Codable {
    public var designation: String
    public var name: String?
    public var star: SystemStar?
    public var recon: Recon
    public var systemScanned: Bool
    public var entryPoint: String?
    public var planetsScanned: Int?
    public var planetsTotal: Int?
    public var moonsScanned: Int?
    public var moonsTotal: Int?
    public var moonsTotalEstimated: Bool
    public var belts: [Belt]
    public var planets: [Planet]
    public var structures: [SpecialSite]
    public var shops: [Shop]
    public var events: [LocationEventInfo]
    public var id: String { designation }

    public init(
        designation: String, name: String? = nil, star: SystemStar? = nil, recon: Recon = .aware,
        systemScanned: Bool = false, entryPoint: String? = nil, planetsScanned: Int? = nil,
        planetsTotal: Int? = nil, moonsScanned: Int? = nil, moonsTotal: Int? = nil,
        moonsTotalEstimated: Bool = false, belts: [Belt] = [], planets: [Planet] = [],
        structures: [SpecialSite] = [], shops: [Shop] = [], events: [LocationEventInfo] = []
    ) {
        self.designation = designation
        self.name = name
        self.star = star
        self.recon = recon
        self.systemScanned = systemScanned
        self.entryPoint = entryPoint
        self.planetsScanned = planetsScanned
        self.planetsTotal = planetsTotal
        self.moonsScanned = moonsScanned
        self.moonsTotal = moonsTotal
        self.moonsTotalEstimated = moonsTotalEstimated
        self.belts = belts
        self.planets = planets
        self.structures = structures
        self.shops = shops
        self.events = events
    }
}

// MARK: - Roll-ups ("interesting information bubbles up")

extension StarSystem {
    /// Every mining site (belts, planets, moons) anywhere in the system.
    public var allResourceSites: [ResourceSite] {
        belts.flatMap(\.sites)
            + planets.flatMap { $0.sites + $0.moons.flatMap(\.sites) }
    }

    /// Every salvage site (planets and moons) anywhere in the system.
    public var allSalvageSites: [SalvageSite] {
        planets.flatMap { $0.salvage + $0.moons.flatMap(\.salvage) }
    }

    /// Every device stationed anywhere in the system.
    public var allDevices: [LocatedDevice] {
        planets.flatMap { $0.devices + $0.moons.flatMap(\.devices) }
    }

    /// Every stored inventory item anywhere in the system.
    public var allInventory: [InventoryItem] {
        belts.flatMap(\.inventory)
            + planets.flatMap { $0.inventory + $0.moons.flatMap(\.inventory) }
    }

    /// Total stored resource quantity — the "Inventory" sort key.
    public var totalInventoryQuantity: Double {
        allInventory.reduce(0) { $0 + $1.quantity }
    }

    /// Every event anywhere in the system (system-level + per-planet).
    public var allEvents: [LocationEventInfo] {
        events + planets.flatMap(\.events)
    }

    /// Shops sited on a specific body designation (bubbling up to any ancestor).
    public func shops(onOrUnder designation: String) -> [Shop] {
        shops.filter { $0.location == designation || $0.location.hasPrefix(designation + "-") }
    }
}

extension Planet {
    /// Mining sites on this planet and its moons.
    public var allResourceSites: [ResourceSite] {
        sites + moons.flatMap(\.sites)
    }

    /// Salvage sites on this planet and its moons.
    public var allSalvageSites: [SalvageSite] {
        salvage + moons.flatMap(\.salvage)
    }
}

// MARK: - Merging hydrated body detail into the tree

extension StarSystem {
    /// Fold a freshly-scanned body's detail into the tree, replacing its roster
    /// stub in place (preserving order). Moons attach under their parent planet
    /// by designation prefix; lagrange points attach to their parent planet when
    /// present, otherwise to `structures`.
    public func applying(_ detail: BodyDetail) -> StarSystem {
        var copy = self
        switch detail {
        case .planet(let p):
            copy.upsertPlanet(p)
        case .moon(let m):
            // Parent planet = designation minus the trailing "-N": SOL-3-1 → SOL-3.
            let parentID = m.designation.split(separator: "-").dropLast().joined(separator: "-")
            if let idx = copy.planets.firstIndex(where: { $0.designation == parentID }) {
                copy.planets[idx].upsertMoon(m)
            }
        case .belt(let b):
            if let idx = copy.belts.firstIndex(where: { $0.designation == b.designation }) {
                copy.belts[idx] = b
            } else {
                copy.belts.append(b)
            }
        case .special(let s):
            if s.kind == .lagrange, let parent = s.parentBody,
               let idx = copy.planets.firstIndex(where: { $0.designation == parent }) {
                if let li = copy.planets[idx].lagrange.firstIndex(where: { $0.designation == s.designation }) {
                    copy.planets[idx].lagrange[li] = s
                } else {
                    copy.planets[idx].lagrange.append(s)
                }
            } else if let idx = copy.structures.firstIndex(where: { $0.designation == s.designation }) {
                copy.structures[idx] = s
            } else {
                copy.structures.append(s)
            }
        }
        return copy
    }

    private mutating func upsertPlanet(_ p: Planet) {
        if let idx = planets.firstIndex(where: { $0.designation == p.designation }) {
            // Preserve already-known salvage/lagrange from the roster if the
            // detail response didn't repeat them.
            var merged = p
            if merged.salvage.isEmpty { merged.salvage = planets[idx].salvage }
            if merged.lagrange.isEmpty { merged.lagrange = planets[idx].lagrange }
            planets[idx] = merged
        } else {
            planets.append(p)
        }
    }
}

extension Planet {
    fileprivate mutating func upsertMoon(_ m: Moon) {
        if let idx = moons.firstIndex(where: { $0.designation == m.designation }) {
            moons[idx] = m
        } else {
            moons.append(m)
        }
    }
}

// MARK: - Recon ordering (for filter/sort)

extension Recon {
    /// Higher = more thoroughly reconnoitered. Drives sort and threshold filters.
    public var rank: Int {
        switch self {
        case .aware:   0
        case .visited: 1
        case .scanned: 2
        }
    }
}
