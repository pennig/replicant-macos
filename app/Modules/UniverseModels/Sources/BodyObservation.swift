//
//  BodyObservation.swift
//  UniverseModels
//
//  A *partial* look at one body, and the rule for folding it into a cached
//  `StarSystem`. This is deliberately not a `BodyDetail`.
//
//  `BodyDetail` means "everything the server knows about this body", and
//  `StarSystem.applying(_:)` merges it by *replacing* the roster entry — it
//  preserves only salvage, lagrange, and the moon roster, taking sites,
//  devices, and inventory from the incoming value. That is correct for a
//  `GET locations/{designation}` response or a `scan.completed` result, both of
//  which carry those collections.
//
//  A survey digest's `report.scans[]` does not. It carries physics (and, for a
//  moon, salvage) and nothing else — so routing it through `applying` would
//  silently erase every device, mining site, and stored item we knew about the
//  body, on every scan. A separate type makes that asymmetry unrepresentable
//  rather than a comment somebody has to remember.
//
//  See `docs/superpowers/specs/2026-07-27-survey-digest-scan-hydration-design.md`.
//

import Foundation

/// One body as a single scan reported it. Every field is optional-or-empty
/// because a scan is an observation, not a full record: `observing(_:)` writes
/// only what the payload actually carried and leaves the rest of the cached
/// body alone.
public struct BodyObservation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case planet
        case moon
    }

    public var kind: Kind
    public var designation: String
    public var name: String?
    public var type: String?
    public var lifeStage: String?
    public var inHabitableZone: Bool?
    public var orbitalDistanceAu: Double?
    public var physical: BodyPhysical
    public var salvage: [SalvageSite]
    /// The moon roster a *planet* scan reported alongside the planet: stubs
    /// carrying designation, name, type, and a `scanned` flag. Empty for a moon
    /// observation.
    public var moons: [Moon]

    public init(
        kind: Kind, designation: String, name: String? = nil, type: String? = nil,
        lifeStage: String? = nil, inHabitableZone: Bool? = nil,
        orbitalDistanceAu: Double? = nil, physical: BodyPhysical = BodyPhysical(),
        salvage: [SalvageSite] = [], moons: [Moon] = []
    ) {
        self.kind = kind
        self.designation = designation
        self.name = name
        self.type = type
        self.lifeStage = lifeStage
        self.inHabitableZone = inHabitableZone
        self.orbitalDistanceAu = orbitalDistanceAu
        self.physical = physical
        self.salvage = salvage
        self.moons = moons
    }

    /// The system this body belongs to — its designation's first segment
    /// (`UDKUDUA-7-1` → `UDKUDUA`). Empty for a malformed designation.
    public var systemDesignation: String {
        String(designation.split(separator: "-").first ?? "")
    }
}

/// One entry of an `ami.survey.digest` payload's `report.scans[]`: the body a
/// survey drone scanned, plus the absolute salvage amounts the same block
/// reported.
///
/// The two travel together because one decode produces both. The
/// `scan.completed` path decodes twice (`scanResultBody` then
/// `salvageObservations(fromScanResult:)`) to keep unit counts off
/// `SalvageSite`, which carries percentages — `SalvageObservation` is already a
/// separate type, so pairing them here honours that rule without a second pass.
public struct SurveyScanReport: Equatable, Sendable {
    /// The drone that performed the scan. Provenance for the log, not persisted.
    public var deviceCode: String?
    public var body: BodyObservation
    public var salvage: [SalvageObservation]

    public init(
        deviceCode: String? = nil, body: BodyObservation, salvage: [SalvageObservation] = []
    ) {
        self.deviceCode = deviceCode
        self.body = body
        self.salvage = salvage
    }
}

// MARK: - Folding an observation into the tree

extension StarSystem {
    /// Fold a scan's partial view of one body into the tree, writing only what
    /// the scan actually saw. Seeds the body (and, for a moon, its parent
    /// planet) when the roster doesn't know it yet, so an observation is never
    /// dropped for lack of a container.
    ///
    /// Never touches the body's `sites`, `devices`, or `inventory` — a scan
    /// carries none of those, and absence is not evidence of emptiness.
    public func observing(_ observation: BodyObservation) -> StarSystem {
        switch observation.kind {
        case .planet: observingPlanet(observation)
        case .moon: observingMoon(observation)
        }
    }

    private func observingPlanet(_ observation: BodyObservation) -> StarSystem {
        guard !observation.designation.isEmpty else { return self }
        var copy = self
        let index = copy.index(ofPlanet: observation.designation)
        var planet = copy.planets[index]

        if let name = observation.name { planet.name = name }
        if let type = observation.type {
            planet.type = type
            planet.typeEstimated = false
        }
        if let lifeStage = observation.lifeStage { planet.lifeStage = lifeStage }
        if let inHabitableZone = observation.inHabitableZone { planet.inHabitableZone = inHabitableZone }
        if let orbitalDistanceAu = observation.orbitalDistanceAu {
            planet.orbitalDistanceAu = orbitalDistanceAu
        }
        planet.physical = observation.physical
        planet.recon = .scanned
        planet.salvage = Self.mergingSalvage(
            fresh: observation.salvage, into: planet.salvage, clearingDepleted: true
        )

        // The scan's moon roster is authoritative about *which* moons exist, but
        // its entries are stubs — `mergingMoons` keeps any richer moon a prior
        // per-moon scan established rather than flattening it back to a stub.
        if !observation.moons.isEmpty {
            planet.moons = Self.mergingMoons(fresh: observation.moons, into: planet.moons)
            planet.moonCount = planet.moons.count
            planet.moonCountEstimated = false
        }

        copy.planets[index] = planet
        return copy
    }

    private func observingMoon(_ observation: BodyObservation) -> StarSystem {
        // Parent planet = designation minus the trailing "-N": SOL-3-1 → SOL-3.
        let parentID = observation.designation.split(separator: "-").dropLast().joined(separator: "-")
        guard !parentID.isEmpty, !observation.designation.isEmpty else { return self }
        var copy = self
        let planetIndex = copy.index(ofPlanet: parentID)

        let moonIndex = copy.planets[planetIndex].moons
            .firstIndex { $0.designation == observation.designation }
        var moon = moonIndex.map { copy.planets[planetIndex].moons[$0] }
            ?? Moon(designation: observation.designation)

        if let name = observation.name { moon.name = name }
        if let type = observation.type { moon.type = type }
        if let lifeStage = observation.lifeStage { moon.lifeStage = lifeStage }
        moon.physical = observation.physical
        moon.recon = .scanned
        moon.salvage = Self.mergingSalvage(
            fresh: observation.salvage, into: moon.salvage, clearingDepleted: true
        )

        if let moonIndex {
            copy.planets[planetIndex].moons[moonIndex] = moon
        } else {
            copy.planets[planetIndex].moons.append(moon)
        }

        // A moon we hadn't listed raises the parent's count to what we now know
        // of — a floor, never a reduction, and never a claim the roster is
        // complete (`moonCountEstimated` is left as it stands).
        let known = copy.planets[planetIndex].moons.count
        if known > (copy.planets[planetIndex].moonCount ?? 0) {
            copy.planets[planetIndex].moonCount = known
        }
        return copy
    }

    /// The index of a planet in the roster, appending a bare entry when the
    /// roster doesn't know it. A survey can scan a body in a system we've only
    /// ever seen from a distance.
    private mutating func index(ofPlanet designation: String) -> Int {
        if let index = planets.firstIndex(where: { $0.designation == designation }) { return index }
        planets.append(Planet(designation: designation, recon: .aware))
        return planets.count - 1
    }

    /// Merge a scan's salvage roster over what we already know, keeping each
    /// existing site's observed `remainingPct`. A scan carries no percentages,
    /// so taking its entries verbatim would discard the only live figures we
    /// have — the same reason `ingestScanResult` restores them after `applying`.
    ///
    /// Pass `clearingDepleted` only for a scan — a fresh observation of the site
    /// itself, and so the one path that may *clear* a stale local flag. A body
    /// roster may lag a `salvage.depleted` event, so it raises the flag and never
    /// lowers it.
    static func mergingSalvage(
        fresh: [SalvageSite], into existing: [SalvageSite], clearingDepleted: Bool
    ) -> [SalvageSite] {
        guard !fresh.isEmpty else { return existing }
        var result = existing
        for site in fresh {
            guard let index = result.firstIndex(where: { $0.designation == site.designation }) else {
                result.append(site)
                continue
            }
            var merged = site
            if merged.remainingPct.isEmpty { merged.remainingPct = result[index].remainingPct }
            if !clearingDepleted { merged.depleted = merged.depleted || result[index].depleted }
            result[index] = merged
        }
        return result
    }
}
