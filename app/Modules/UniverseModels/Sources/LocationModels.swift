//
//  LocationModels.swift
//  UniverseModels
//
//  The canonical "what we know" domain for the stellar-locations catalog. These
//  are pure value types shared by the catalog feature and (eventually) anything
//  else that needs charted-universe data. They are deliberately decoupled from
//  the star-map orrery's presentation models (which carry renderer scene units) —
//  see `NewStarMapFeature`.
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
import GameModels

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

/// A body (belt, planet, moon, or object) that holds stored inventory, paired
/// with its holdings — the unit the system inspector lists under "Inventory".
public struct InventoryHolding: Identifiable, Equatable, Sendable {
    public var designation: String
    public var name: String?
    public var inventory: [InventoryItem]
    public var id: String { designation }
    public var displayName: String { name ?? designation }
    public init(designation: String, name: String? = nil, inventory: [InventoryItem]) {
        self.designation = designation
        self.name = name
        self.inventory = inventory
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
/// yield (`resourcesAvailable`) and whether it is spent (`depleted`). Sites
/// sourced from `resource_sites[]` (`site_type: "salvage"`) also carry
/// per-resource percentages in `remainingPct`; sites sourced from the
/// `salvage[]` roster block carry only names, so `remainingPct` is empty there.
/// `salvageType` is a flavor tag (e.g. "research_station").
public struct SalvageSite: Identifiable, Equatable, Sendable, Codable {
    public var designation: String
    public var name: String?
    public var salvageType: String?
    public var location: String?
    public var resourcesAvailable: [String]
    public var depleted: Bool
    /// Resource name → percent still present (0…100), from
    /// `resources_remaining_pct`. Empty when the site came from the `salvage[]`
    /// roster block, which carries names but no percentages. Combine with a
    /// `SiteAssay`'s totals via `SiteAmounts.amounts` for absolute units.
    public var remainingPct: [String: Double]
    public var id: String { designation }

    public init(
        designation: String, name: String? = nil, salvageType: String? = nil,
        location: String? = nil, resourcesAvailable: [String] = [], depleted: Bool = false,
        remainingPct: [String: Double] = [:]
    ) {
        self.designation = designation
        self.name = name
        self.salvageType = salvageType
        self.location = location
        self.resourcesAvailable = resourcesAvailable
        self.depleted = depleted
        self.remainingPct = remainingPct
    }

    /// Hand-written so a `StarSystem` blob persisted before `remainingPct`
    /// existed still decodes. Synthesized `Decodable` ignores stored-property
    /// defaults and throws `keyNotFound` for an absent key, which would make
    /// every pre-existing `systemDetails` row unreadable.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        designation = try c.decode(String.self, forKey: .designation)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        salvageType = try c.decodeIfPresent(String.self, forKey: .salvageType)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        resourcesAvailable = try c.decodeIfPresent([String].self, forKey: .resourcesAvailable) ?? []
        depleted = try c.decodeIfPresent(Bool.self, forKey: .depleted) ?? false
        remainingPct = try c.decodeIfPresent([String: Double].self, forKey: .remainingPct) ?? [:]
    }

    /// The body that hosts this salvage — its `location` when known, else derived
    /// by dropping the trailing `-SAL-N` from the designation
    /// (`SHERATANON-7-4-SAL-1` → `SHERATANON-7-4`). This is what the
    /// `gather_salvage` directive targets (a body, not the site itself).
    public var bodyDesignation: String {
        if let location, !location.isEmpty { return location }
        return Self.bodyDesignation(ofSite: designation)
    }

    /// The body a site designation implies, by dropping its trailing `-SAL-N`
    /// (`SHERATANON-7-4-SAL-1` → `SHERATANON-7-4`). The one place the `-SAL-N`
    /// convention is encoded — callers with only a designation (no `SalvageSite`
    /// value, e.g. a `salvage.discovered`/`salvage.depleted` event payload) use
    /// this directly; `bodyDesignation` above delegates to it as its fallback.
    public static func bodyDesignation(ofSite designation: String) -> String {
        var parts = designation.split(separator: "-")
        if let i = parts.lastIndex(of: "SAL") { parts = Array(parts[..<i]) }
        return parts.joined(separator: "-")
    }
}

/// A salvage site's absolute remaining amounts as one payload reported them.
/// Distinct from `SalvageSite` (which is catalog state) because these are raw
/// unit counts destined for a `SiteAssay`, not for the tree.
public struct SalvageObservation: Equatable, Sendable {
    public var designation: String
    public var body: String
    /// Resource name → absolute units still present.
    public var resourcesRemaining: [String: Double]

    public init(designation: String, body: String, resourcesRemaining: [String: Double]) {
        self.designation = designation
        self.body = body
        self.resourcesRemaining = resourcesRemaining
    }
}

/// A body (planet or moon) that hosts one or more salvage sites — the unit the
/// `gather_salvage` directive targets. Dispatching to the body works every
/// salvage site on it, so the picker offers bodies rather than sites.
public struct SalvageBody: Identifiable, Equatable, Sendable {
    public var designation: String
    public var name: String?
    /// How many live salvage sites the body holds.
    public var siteCount: Int
    /// Total units still present across the body's live sites, when assayed.
    /// Nil when no site on the body has a stored total — unknown, not zero.
    public var unitsRemaining: Double?
    /// Total units *discovered* across the body's live sites whose live
    /// percentage isn't known yet — the assayed-but-unhydrated case, which is
    /// the common one until the user opens the body. A historical figure, not a
    /// live one, so it is kept apart from `unitsRemaining` rather than summed
    /// into it. Nil when nothing on the body is in that state.
    public var discoveredTotal: Double?
    public var id: String { designation }
    /// Body name when the server provides one, else its designation.
    public var displayName: String { name ?? designation }

    public init(
        designation: String, name: String? = nil, siteCount: Int = 1,
        unitsRemaining: Double? = nil, discoveredTotal: Double? = nil
    ) {
        self.designation = designation
        self.name = name
        self.siteCount = siteCount
        self.unitsRemaining = unitsRemaining
        self.discoveredTotal = discoveredTotal
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
    /// Moon orbital period. Moons never report `orbitalPeriodDays` the way planets do —
    /// the backend gives them hours instead (SOL-3-1 = 655.7, SOL-5-1 = 42.46) — so this
    /// is the only real orbit speed a moon has. Nil until the moon is scanned.
    public var orbitalPeriodHours: Double?
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
        rotationPeriodHours: Double? = nil, orbitalPeriodDays: Double? = nil,
        orbitalPeriodHours: Double? = nil, axialTiltDeg: Double? = nil,
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
        self.orbitalPeriodHours = orbitalPeriodHours
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

/// A per-device-type contribution requirement for a megastructure. Mirrors the
/// scan's `requirements` dict entries: `{current, remaining, complete, required}`.
public struct StructureRequirement: Identifiable, Equatable, Sendable, Codable {
    public var deviceType: String
    public var required: Int
    public var current: Int
    public var remaining: Int
    public var complete: Bool
    public var id: String { deviceType }
    public init(deviceType: String, required: Int, current: Int = 0, remaining: Int = 0, complete: Bool = false) {
        self.deviceType = deviceType
        self.required = required
        self.current = current
        self.remaining = remaining
        self.complete = complete
    }
}

/// A location that isn't a planet/moon/belt: a lagrange point, megastructure,
/// outer-system region (Kuiper/Oort), or system object. `parentBody` names the
/// planet a lagrange point leads. For megastructures, `progressPercentage`
/// (0…100) and `requirements` track galaxy-wide construction. `objectType` is
/// the scan's raw discriminator ("megastructure", "incoming_asteroid", …) and
/// `deadline` marks time-bound objects (e.g. an inbound impactor).
public struct SpecialSite: Identifiable, Equatable, Sendable, Codable {
    public var designation: String
    public var kind: SpecialSiteKind
    public var objectType: String?
    public var name: String?
    public var title: String?
    public var siteDescription: String?
    public var label: String?
    public var status: String?
    public var stage: String?
    public var parentBody: String?
    public var orbitalDistanceAu: Double?
    public var progressPercentage: Double?
    public var deadline: String?
    public var requirements: [StructureRequirement]
    /// Resources stored at this object (megastructures/outer-system objects can
    /// accumulate holdings just like bodies). Empty for most objects.
    public var inventory: [InventoryItem]
    /// Devices stationed at this location (Lagrange points and objects can host devices),
    /// from its per-location detail. Empty until hydrated.
    public var devices: [LocatedDevice]
    public var id: String { designation }

    public init(
        designation: String, kind: SpecialSiteKind, objectType: String? = nil, name: String? = nil,
        title: String? = nil, siteDescription: String? = nil, label: String? = nil,
        status: String? = nil, stage: String? = nil, parentBody: String? = nil,
        orbitalDistanceAu: Double? = nil, progressPercentage: Double? = nil, deadline: String? = nil,
        requirements: [StructureRequirement] = [], inventory: [InventoryItem] = [],
        devices: [LocatedDevice] = []
    ) {
        self.designation = designation
        self.kind = kind
        self.objectType = objectType
        self.name = name
        self.title = title
        self.siteDescription = siteDescription
        self.label = label
        self.status = status
        self.stage = stage
        self.parentBody = parentBody
        self.orbitalDistanceAu = orbitalDistanceAu
        self.progressPercentage = progressPercentage
        self.deadline = deadline
        self.requirements = requirements
        self.inventory = inventory
        self.devices = devices
    }

    // Custom decoding so blobs persisted before `inventory` / `requirements` / `devices`
    // existed still decode — a missing key defaults to empty rather than throwing
    // and dropping the whole cached system. Encoding stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case designation, kind, objectType, name, title, siteDescription, label
        case status, stage, parentBody, orbitalDistanceAu, progressPercentage
        case deadline, requirements, inventory, devices
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        designation = try c.decode(String.self, forKey: .designation)
        kind = try c.decode(SpecialSiteKind.self, forKey: .kind)
        objectType = try c.decodeIfPresent(String.self, forKey: .objectType)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        siteDescription = try c.decodeIfPresent(String.self, forKey: .siteDescription)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        stage = try c.decodeIfPresent(String.self, forKey: .stage)
        parentBody = try c.decodeIfPresent(String.self, forKey: .parentBody)
        orbitalDistanceAu = try c.decodeIfPresent(Double.self, forKey: .orbitalDistanceAu)
        progressPercentage = try c.decodeIfPresent(Double.self, forKey: .progressPercentage)
        deadline = try c.decodeIfPresent(String.self, forKey: .deadline)
        requirements = try c.decodeIfPresent([StructureRequirement].self, forKey: .requirements) ?? []
        inventory = try c.decodeIfPresent([InventoryItem].self, forKey: .inventory) ?? []
        devices = try c.decodeIfPresent([LocatedDevice].self, forKey: .devices) ?? []
    }
}

// MARK: - Shops (system-scoped; each references a body)

public struct ShopTrade: Identifiable, Equatable, Sendable, Codable {
    public var tradeCode: String
    public var name: String
    public var currentStock: Int?
    /// What the trade costs: resource name → quantity.
    public var criteria: [String: Double]
    /// What the trade yields: device type → count.
    public var rewards: [String: Int]
    public var id: String { tradeCode }
    public init(
        tradeCode: String, name: String, currentStock: Int? = nil,
        criteria: [String: Double] = [:], rewards: [String: Int] = [:]
    ) {
        self.tradeCode = tradeCode
        self.name = name
        self.currentStock = currentStock
        self.criteria = criteria
        self.rewards = rewards
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
    /// Devices stationed at the belt, from its per-location detail (belts aren't in the
    /// system-scan blob's device rosters). Empty until the location is hydrated.
    public var devices: [LocatedDevice]
    public var id: String { designation }

    public init(
        designation: String, innerRadiusAu: Double? = nil, outerRadiusAu: Double? = nil,
        density: String? = nil, richness: [String: String] = [:], sites: [ResourceSite] = [],
        inventory: [InventoryItem] = [], devices: [LocatedDevice] = []
    ) {
        self.designation = designation
        self.innerRadiusAu = innerRadiusAu
        self.outerRadiusAu = outerRadiusAu
        self.density = density
        self.richness = richness
        self.sites = sites
        self.inventory = inventory
        self.devices = devices
    }

    // Custom decoding so blobs persisted before `devices` still decode — a missing key
    // defaults to empty rather than throwing and dropping the whole cached system.
    private enum CodingKeys: String, CodingKey {
        case designation, innerRadiusAu, outerRadiusAu, density, richness, sites, inventory, devices
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        designation = try c.decode(String.self, forKey: .designation)
        innerRadiusAu = try c.decodeIfPresent(Double.self, forKey: .innerRadiusAu)
        outerRadiusAu = try c.decodeIfPresent(Double.self, forKey: .outerRadiusAu)
        density = try c.decodeIfPresent(String.self, forKey: .density)
        richness = try c.decodeIfPresent([String: String].self, forKey: .richness) ?? [:]
        sites = try c.decodeIfPresent([ResourceSite].self, forKey: .sites) ?? []
        inventory = try c.decodeIfPresent([InventoryItem].self, forKey: .inventory) ?? []
        devices = try c.decodeIfPresent([LocatedDevice].self, forKey: .devices) ?? []
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
///
/// `temperatureK`/`massSolar`/`luminositySolar` and the habitable-zone bounds are
/// only reported by the full system scan (`POST .../scan`), not the `locations`
/// GET — so they stay nil for systems we've explored but not scanned.
public struct SystemStar: Equatable, Sendable, Codable {
    public var designation: String
    public var name: String?
    public var stellarClass: String?
    public var color: String?
    public var ageMy: Double?
    public var miningBonusPct: Double?
    public var distanceFromSol: Double?
    public var position: Position?
    public var temperatureK: Double?
    public var massSolar: Double?
    public var luminositySolar: Double?
    public var habitableZoneInnerAu: Double?
    public var habitableZoneOuterAu: Double?

    public init(
        designation: String, name: String? = nil, stellarClass: String? = nil, color: String? = nil,
        ageMy: Double? = nil, miningBonusPct: Double? = nil, distanceFromSol: Double? = nil,
        position: Position? = nil, temperatureK: Double? = nil, massSolar: Double? = nil,
        luminositySolar: Double? = nil, habitableZoneInnerAu: Double? = nil,
        habitableZoneOuterAu: Double? = nil
    ) {
        self.designation = designation
        self.name = name
        self.stellarClass = stellarClass
        self.color = color
        self.ageMy = ageMy
        self.miningBonusPct = miningBonusPct
        self.distanceFromSol = distanceFromSol
        self.position = position
        self.temperatureK = temperatureK
        self.massSolar = massSolar
        self.luminositySolar = luminositySolar
        self.habitableZoneInnerAu = habitableZoneInnerAu
        self.habitableZoneOuterAu = habitableZoneOuterAu
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

    /// Salvage sites known in the system, tolerant of how the server (and older
    /// catalog blobs) surface them: unions the dedicated salvage roster with any
    /// resource-site rows whose designation marks them as salvage (`…-SAL-N`) —
    /// the live API returns salvage inside `resource_sites`, and blobs persisted
    /// before that was split out still carry them there. Deduped by designation.
    public var knownSalvageSites: [SalvageSite] {
        var byDesignation: [String: SalvageSite] = [:]
        for site in allSalvageSites { byDesignation[site.designation] = site }
        for site in allResourceSites where site.designation.contains("-SAL-") {
            if byDesignation[site.designation] == nil {
                byDesignation[site.designation] = SalvageSite(designation: site.designation, name: site.name)
            }
        }
        return byDesignation.values.sorted { $0.designation < $1.designation }
    }

    /// Bodies holding at least one live (non-depleted) salvage site, each with
    /// its site count — the targets the `gather_salvage` directive picker
    /// offers. Pass stored `SiteAssay` totals (site designation → totals) to
    /// have each body report the units still on it — or, for a site whose live
    /// percentages haven't been fetched yet, the units discovered on it.
    public func salvageBodies(totals: [String: [String: Double]] = [:]) -> [SalvageBody] {
        var counts: [String: Int] = [:]
        var units: [String: Double] = [:]
        var discovered: [String: Double] = [:]
        for site in knownSalvageSites where !site.depleted {
            let body = site.bodyDesignation
            guard !body.isEmpty else { continue }
            counts[body, default: 0] += 1
            let amounts = SiteAmounts.amounts(for: site, totals: totals[site.designation])
            // A site with percentages reports live units; one without still
            // reports what was discovered on it, so a body the user hasn't
            // opened isn't silently worthless in the picker.
            if let siteUnits = SiteAmounts.totalRemaining(amounts) {
                units[body, default: 0] += siteUnits
            }
            if let siteDiscovered = SiteAmounts.totalDiscovered(amounts) {
                discovered[body, default: 0] += siteDiscovered
            }
        }
        return counts.keys.sorted().map {
            SalvageBody(
                designation: $0, name: bodyName(for: $0),
                siteCount: counts[$0]!, unitsRemaining: units[$0],
                discoveredTotal: discovered[$0]
            )
        }
    }

    /// Salvage-bearing bodies with no assay data joined in.
    public var salvageBodies: [SalvageBody] { salvageBodies() }

    /// The display name of a planet or moon by designation, if the tree holds it.
    private func bodyName(for designation: String) -> String? {
        for planet in planets {
            if planet.designation == designation { return planet.name }
            for moon in planet.moons where moon.designation == designation { return moon.name }
        }
        return nil
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

    /// Every body (belt, planet, moon, or object) that holds stored inventory,
    /// each paired with its holdings — what the system inspector lists so the
    /// interesting stock is visible without drilling into each body.
    public var inventoryHoldings: [InventoryHolding] {
        var out: [InventoryHolding] = []
        for belt in belts where !belt.inventory.isEmpty {
            out.append(InventoryHolding(designation: belt.designation, inventory: belt.inventory))
        }
        for planet in planets {
            if !planet.inventory.isEmpty {
                out.append(InventoryHolding(designation: planet.designation, name: planet.name, inventory: planet.inventory))
            }
            for moon in planet.moons where !moon.inventory.isEmpty {
                out.append(InventoryHolding(designation: moon.designation, name: moon.name, inventory: moon.inventory))
            }
        }
        for object in structures where !object.inventory.isEmpty {
            out.append(InventoryHolding(designation: object.designation, name: object.title ?? object.name, inventory: object.inventory))
        }
        return out
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

    /// The planet and any of its moons that hold stored inventory, each paired
    /// with its holdings — what the planet inspector lists so a moon's stock rolls
    /// up to the planet view.
    public var inventoryHoldings: [InventoryHolding] {
        var out: [InventoryHolding] = []
        if !inventory.isEmpty {
            out.append(InventoryHolding(designation: designation, name: name, inventory: inventory))
        }
        for moon in moons where !moon.inventory.isEmpty {
            out.append(InventoryHolding(designation: moon.designation, name: moon.name, inventory: moon.inventory))
        }
        return out
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
            // Lagrange points attach to their parent planet. Prefer the payload's
            // `parentBody`, falling back to the designation (SOL-5-L4 → SOL-5) so
            // they still land on the planet when the API omits `parent_planet`.
            let lagrangeParent = s.kind == .lagrange
                ? (s.parentBody ?? s.designation.split(separator: "-").dropLast().joined(separator: "-"))
                : nil
            if let parent = lagrangeParent,
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

    /// Update every salvage site at (or under) a body designation, in place.
    /// Matches by designation prefix (`SHERATANON-7-4` → `SHERATANON-7-4-SAL-1`),
    /// so it works whether the site sits on a planet or a moon, and by the site's
    /// own `location` as a fallback. Returns the modified copy — a system with no
    /// matching salvage comes back unchanged (`==` to the original).
    public func updatingSalvage(
        at location: String, _ transform: (inout SalvageSite) -> Void
    ) -> StarSystem {
        let prefix = location + "-"
        func matches(_ s: SalvageSite) -> Bool { s.location == location || s.designation.hasPrefix(prefix) }
        var copy = self
        for pi in copy.planets.indices {
            for si in copy.planets[pi].salvage.indices where matches(copy.planets[pi].salvage[si]) {
                transform(&copy.planets[pi].salvage[si])
            }
            for mi in copy.planets[pi].moons.indices {
                for si in copy.planets[pi].moons[mi].salvage.indices where matches(copy.planets[pi].moons[mi].salvage[si]) {
                    transform(&copy.planets[pi].moons[mi].salvage[si])
                }
            }
        }
        return copy
    }

    /// Attach a discovered salvage site to the tree, seeding its host body if
    /// the roster doesn't know it yet (a discovery can arrive long before the
    /// body is scanned). Matches the host by designation, planet then moon.
    /// Returns nil when the site is already present unchanged, so callers can
    /// skip a pointless blob rewrite.
    public func insertingSalvage(_ site: SalvageSite) -> StarSystem? {
        let body = site.bodyDesignation
        guard !body.isEmpty else { return nil }
        var copy = self

        func upsert(into salvage: inout [SalvageSite]) -> Bool {
            if let i = salvage.firstIndex(where: { $0.designation == site.designation }) {
                // Preserve observed percentages; the discovery carries none.
                var merged = site
                merged.remainingPct = salvage[i].remainingPct
                merged.depleted = salvage[i].depleted
                guard salvage[i] != merged else { return false }
                salvage[i] = merged
                return true
            }
            salvage.append(site)
            return true
        }

        for pi in copy.planets.indices {
            if copy.planets[pi].designation == body {
                return upsert(into: &copy.planets[pi].salvage) ? copy : nil
            }
            for mi in copy.planets[pi].moons.indices where copy.planets[pi].moons[mi].designation == body {
                return upsert(into: &copy.planets[pi].moons[mi].salvage) ? copy : nil
            }
        }

        // Unknown body: seed a minimal planet so the site isn't lost for now.
        // This stub is provisional, not durable: `mergingScan` rebuilds
        // `planets` from the fresh scan roster, so a stub the roster doesn't
        // name is discarded along with the site on it (and a moon stubbed as a
        // planet never matches the roster). The site returns with the next scan
        // or hydrate of its real body; the assay in `SiteAssay` — the half the
        // catalog can never re-derive — survives either way.
        copy.planets.append(Planet(designation: body, salvage: [site]))
        return copy
    }

    /// Re-apply salvage percentages that a merge dropped.
    ///
    /// `applying(_:)` replaces a body's salvage wholesale from the payload it
    /// was handed, and the `scan.completed` payload carries absolute
    /// `resources_remaining` but no `resources_remaining_pct` — so folding a
    /// scan in would otherwise wipe the percentages a `body(_:)` hydrate had
    /// established, dropping the inspector back to a bare name list and
    /// degrading the next scan's implied-total calculation to a raw floor.
    ///
    /// Same idiom as `mergingMoons`: keep the richer of the two. Fresher data
    /// wins — a merged site that *does* carry percentages is left alone, and
    /// only an empty `remainingPct` is filled from `percentages` (site
    /// designation → resource → 0…100).
    ///
    /// A site the scan reports as `depleted` is skipped: its remembered
    /// percentages describe a site that no longer holds anything, so restoring
    /// them would make the inspector read "Depleted · ~339 units" — live
    /// tonnage claimed at a spent site. A depleted site keeps its empty map and
    /// falls back to the honest name list.
    public func restoringSalvagePercentages(_ percentages: [String: [String: Double]]) -> StarSystem {
        guard !percentages.isEmpty else { return self }
        func restore(_ salvage: inout [SalvageSite]) {
            for i in salvage.indices where salvage[i].remainingPct.isEmpty && !salvage[i].depleted {
                guard let pct = percentages[salvage[i].designation], !pct.isEmpty else { continue }
                salvage[i].remainingPct = pct
            }
        }
        var copy = self
        for pi in copy.planets.indices {
            restore(&copy.planets[pi].salvage)
            for mi in copy.planets[pi].moons.indices {
                restore(&copy.planets[pi].moons[mi].salvage)
            }
        }
        return copy
    }

    /// Ensure the container a body attaches to exists before `applying`, so a
    /// body from a stream-event scan isn't dropped for lack of a roster: a moon needs its
    /// parent planet; planets, belts, and specials self-attach. Used when folding
    /// a `scan.completed` result into a system we may not have hydrated yet.
    public func seedingParent(of detail: BodyDetail) -> StarSystem {
        guard case .moon(let m) = detail else { return self }
        let parentID = m.designation.split(separator: "-").dropLast().joined(separator: "-")
        guard !parentID.isEmpty, !planets.contains(where: { $0.designation == parentID }) else { return self }
        var copy = self
        copy.planets.append(Planet(designation: parentID, recon: .aware))
        return copy
    }

    private mutating func upsertPlanet(_ p: Planet) {
        if let idx = planets.firstIndex(where: { $0.designation == p.designation }) {
            // Preserve already-known salvage/lagrange from the roster if the
            // detail response didn't repeat them.
            var merged = p
            if merged.salvage.isEmpty { merged.salvage = planets[idx].salvage }
            if merged.lagrange.isEmpty { merged.lagrange = planets[idx].lagrange }
            // A planet-level fetch lists its moons as bare stubs (no salvage,
            // sites, or physical) — merging them in verbatim would wipe the richer
            // detail a prior per-moon `body(_:)` fetch established. Keep the richer
            // moon where we have one.
            merged.moons = Self.mergingMoons(fresh: p.moons, into: planets[idx].moons)
            planets[idx] = merged
        } else {
            planets.append(p)
        }
    }

    /// Merge a fresh moon roster over existing moons, keeping whichever copy of
    /// each moon carries more detail (physical / sites / salvage) so a per-moon
    /// scan isn't clobbered by a later planet-level fetch's stub. Existing moons
    /// absent from the fresh roster are retained.
    private static func mergingMoons(fresh: [Moon], into existing: [Moon]) -> [Moon] {
        guard !existing.isEmpty else { return fresh }
        let existingByID = Dictionary(existing.map { ($0.designation, $0) }, uniquingKeysWith: { first, _ in first })
        var result = fresh.map { f -> Moon in
            guard let e = existingByID[f.designation] else { return f }
            let existingIsRicher = e.physical != nil || !e.sites.isEmpty || !e.salvage.isEmpty
            var kept = existingIsRicher ? e : f
            if kept.salvage.isEmpty { kept.salvage = f.salvage }
            if kept.inventory.isEmpty { kept.inventory = f.inventory }
            return kept
        }
        let freshIDs = Set(fresh.map(\.designation))
        result += existing.filter { !freshIDs.contains($0.designation) }
        return result
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

extension BodyDetail {
    /// The scanned body's designation, whichever kind it is.
    public var designation: String {
        switch self {
        case .planet(let p): p.designation
        case .moon(let m): m.designation
        case .belt(let b): b.designation
        case .special(let s): s.designation
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
