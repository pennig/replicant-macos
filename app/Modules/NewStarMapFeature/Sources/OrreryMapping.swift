//
//  OrreryMapping.swift
//  NewStarMapFeature
//
//  Maps the real `UniverseModels.StarSystem` (decoded from the scan / locations
//  endpoints and persisted per system) to the orrery's render `SystemModel`.
//  Orbits come from real AU via a compressed radial map so the whole system reads
//  well at a glance; scan-only star facts pass through (nil until scanned). Pure +
//  deterministic (per-designation phases) → identical every launch, unit-testable.
//

import Foundation
import UniverseModels

enum OrreryMapping {

    // MARK: - Radial / temporal maps

    /// Compressed AU → scene units. Real orbits span ~0.05–30+ AU; the sqrt map
    /// keeps inner planets legible while the outer system still fits the frame.
    static func sceneRadius(au: Double) -> Double {
        7.0 * (max(au, 0) as Double).squareRoot()
    }

    /// Kepler-ish fallback orbital period (days) from AU, for bodies not yet
    /// scanned (period ∝ a^1.5), tuned so inner planets sweep visibly.
    static func fallbackPeriodDays(au: Double) -> Double {
        max(6, 40 * pow(max(au, 0.03), 1.5))
    }

    /// A stable 0…360° orbit phase from a designation (FNV-1a), so the layout is
    /// deterministic across launches.
    static func phaseDeg(_ designation: String) -> Double {
        var h: UInt64 = 14695981039346656037
        for b in designation.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Double(h % 360)
    }

    /// A stable per-body appearance seed in [0, 1), hashed (FNV-1a) from the body's
    /// designation and rotation period. Fed to the surface shader so each planet has
    /// its own band count / swirliness / feature placement — identical every time it's
    /// viewed. Rotation period is folded in when known (nil until scanned) for extra
    /// variety; the designation alone keeps it stable before that.
    static func appearanceSeed(designation: String, rotationPeriodHours: Double?) -> Float {
        var h: UInt64 = 14695981039346656037
        for b in designation.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let rp = rotationPeriodHours ?? 0
        let bits = rp.isFinite ? UInt64(bitPattern: Int64((rp * 10).rounded())) : 0
        h = (h ^ bits) &* 1099511628211
        return Float(h % 100_000) / 100_000
    }

    // MARK: - Appearance

    /// Planet-type → schematic color hex. (The sun keeps its temperature-real color;
    /// this is only for the small orbiting bodies.)
    static func planetColor(type: String?) -> String {
        let t = (type ?? "").lowercased()
        if t.contains("ocean") { return "#3f7fd0" }
        if t.contains("desert") || t.contains("arid") { return "#c98b5a" }
        if t.contains("super earth") || t.contains("terran") || t.contains("terrestrial") { return "#5fb07a" }
        if t.contains("ice giant") { return "#9fd0e0" }
        if t.contains("gas giant") { return "#caa06a" }
        if t.contains("frozen") || t.contains("icy") { return "#cdd6e6" }
        if t.contains("lava") || t.contains("molten") { return "#d8613a" }
        if t.contains("barren") { return "#8f857a" }
        return "#a89a86"
    }

    /// The system star renders at the renderer's fixed angular size (`maxAngularSize`);
    /// expressed in orrery scene units that is this fraction of `frameScene`. Anchoring
    /// planet sizes and the inner-orbit floor to it keeps every body proportional to
    /// the sun no matter how compact or spread the real system is.
    /// Derived from the renderer: maxAngularSize / (tan(fovy/2) · fitInset)
    /// = 0.05 / (tan 30° · 0.9) ≈ 0.096.
    static let sunSceneFraction = 0.096

    /// Planet display radius as a *fraction of the sun's* rendered radius. Real ratios
    /// are tiny (Jupiter ≈ 0.10 R☉, Earth ≈ 0.009 R☉); we exaggerate for legibility but
    /// keep every planet clearly sub-sun. From real `radius_earth` when scanned, else a
    /// type default. The scene radius is `sunScene · sizeFraction` at the call site.
    static func sizeFraction(planet: Planet) -> Double {
        if let re = planet.physical?.radiusEarth, re > 0 {
            return min(0.42, 0.11 + 0.075 * re.squareRoot())
        }
        let t = (planet.type ?? "").lowercased()
        if t.contains("gas giant") { return 0.38 }
        if t.contains("giant") { return 0.30 }          // ice giant
        if t.contains("super earth") { return 0.20 }
        return 0.16
    }

    // MARK: - Build

    static func systemModel(from s: StarSystem) -> SystemModel {
        let star = s.star

        // Frame the system from the raw (AU-mapped) orbits first, so we can derive the
        // sun's scene footprint before sizing bodies and flooring inner orbits to it.
        let rawScenes = s.planets.map { sceneRadius(au: $0.orbitalDistanceAu ?? 0.1) }
        let beltOuters = s.belts.map { sceneRadius(au: $0.outerRadiusAu ?? 0) }
        let rawMax = (rawScenes + beltOuters).max() ?? 0
        let kuiper = s.structures.first { $0.kind == .kuiper }?.orbitalDistanceAu.map(sceneRadius(au:))
        let frame = rawMax > 0 ? rawMax * 1.12 : (kuiper ?? 20)
        let sunScene = sunSceneFraction * frame

        // Body radii (scene units, proportional to the sun), then non-overlapping orbit
        // radii: each planet keeps its AU-mapped radius when it has room, but crowded
        // inner bodies (which the sqrt map stacks together and inside the large sun) get
        // pushed outward just enough to clear the previous body — so no two orbits (or a
        // planet and the star) ever intersect.
        let radii = s.planets.map { sunScene * sizeFraction(planet: $0) }
        let rawBeltInner = s.belts.map { sceneRadius(au: $0.innerRadiusAu ?? 0) }
        let rawBeltOuter = s.belts.map { sceneRadius(au: $0.outerRadiusAu ?? 0) }
        // Interleave planets and belts and space them all outward from the star, so no
        // planet orbit ever falls inside an asteroid belt's band (and no two planets, or
        // a planet and the star, ever intersect).
        let layout = spacedLayout(
            planetOrbits: rawScenes, planetRadii: radii,
            beltInner: rawBeltInner, beltOuter: rawBeltOuter, sunScene: sunScene)
        let orbits = layout.orbits

        let planets = s.planets.indices.map { i -> OrreryPlanet in
            let p = s.planets[i]
            let au = p.orbitalDistanceAu ?? 0.1
            var indicators: BodyIndicators = []
            if !p.devices.isEmpty { indicators.insert(.device) }
            if p.salvage.contains(where: { !$0.depleted }) { indicators.insert(.salvage) }
            if !p.sites.isEmpty { indicators.insert(.miningSite) }
            if !p.inventory.isEmpty { indicators.insert(.inventory) }
            if let ls = p.lifeStage, ls != "none", !ls.isEmpty { indicators.insert(.life) }

            let interestingMoon = p.moons.contains { moonIsInteresting($0) }
                || (p.moons.isEmpty && (p.moonCount ?? 0) > 0)   // hint before hydration

            // Every planet has its 5 Lagrange points — shown and selectable device or not.
            // Their designations are deterministic (`SYSTEM-n-L[1-5]`) and positions come
            // from `OrreryLayout` (parent planet + star), so no per-location hydration of
            // `planet.lagrange` is needed to render or pick them.
            let lagrange = (1...5).map { LagrangePoint(designation: "\(p.designation)-L\($0)", point: $0) }

            return OrreryPlanet(
                designation: p.designation, name: p.name, type: p.type,
                planetType: PlanetType(apiType: p.type), estimated: p.typeEstimated,
                tags: p.physical?.tags ?? [],
                surfaceTempC: p.physical?.surfaceTempC,
                atmosphere: Atmosphere(apiValue: p.physical?.atmosphere),
                appearanceSeed: appearanceSeed(designation: p.designation,
                                               rotationPeriodHours: p.physical?.rotationPeriodHours),
                orbitalDistanceAu: au, inHabitableZone: p.inHabitableZone,
                scanned: p.recon == .scanned, moonCount: p.moonCount ?? p.moons.count,
                lifeStage: p.lifeStage, inventory: p.inventory,
                semiMajorScene: orbits[i],
                periodDays: p.physical?.orbitalPeriodDays ?? fallbackPeriodDays(au: au),
                phase0Deg: phaseDeg(p.designation),
                displayRadius: radii[i],
                colorHex: planetColor(type: p.type),
                hasRing: p.physical?.rings ?? false,
                indicators: indicators, hasInterestingMoon: interestingMoon, moons: [],
                lagrange: lagrange)
        }

        let belts = s.belts.indices.map { i -> BeltModel in
            let b = s.belts[i]
            let band = layout.belts[i]   // spaced clear of the sun and its neighbouring orbits
            return BeltModel(
                designation: b.designation,
                innerScene: band.inner, outerScene: band.outer,
                density: b.density, richness: b.richness, hasSites: !b.sites.isEmpty)
        }

        let hazards = s.structures.compactMap { st -> OrreryHazard? in
            guard st.objectType == "incoming_asteroid"
                    || (st.kind == .object && st.orbitalDistanceAu != nil) else { return nil }
            return OrreryHazard(
                designation: st.designation, objectType: st.objectType ?? "object",
                title: st.title ?? st.name,
                orbitScene: sceneRadius(au: st.orbitalDistanceAu ?? 0),
                targetScene: nil, progressPct: st.progressPercentage,
                deadline: st.deadline.flatMap(parseDate))
        }

        // Positioned system objects (megastructures, objects, outer-system regions) for
        // device/pip/picking anchors. Only those with a known orbital distance.
        let structures = s.structures.compactMap { st -> OrreryStructure? in
            guard let au = st.orbitalDistanceAu else { return nil }
            return OrreryStructure(designation: st.designation,
                                   kind: st.objectType ?? st.kind.rawValue,
                                   orbitScene: sceneRadius(au: au))
        }

        let deviceCount = s.planets.reduce(0) { $0 + $1.devices.count }

        // The spacing pass can push a very crowded inner system — or a wide belt — past
        // the raw outer edge; frame to whichever body/belt now sits farthest out.
        let outerMost = (orbits + layout.belts.map(\.outer)).max() ?? 0

        let hz: HabitableZone? = zip2(star?.habitableZoneInnerAu, star?.habitableZoneOuterAu)
            .map { HabitableZone(innerAu: $0, outerAu: $1) }

        return SystemModel(
            star: StarDetail(
                designation: s.designation, name: star?.name ?? s.name,
                spectralType: star?.stellarClass, color: star?.color,
                position: star?.position ?? Position(x: 0, y: 0, z: 0),
                temperatureK: star?.temperatureK, massSolar: star?.massSolar,
                luminositySolar: star?.luminositySolar, ageMy: star?.ageMy,
                habitableZone: hz, miningBonusPct: star?.miningBonusPct),
            // Map the HZ edges through the SAME spacing the planets got, so the drawn band
            // stays faithful: a planet whose AU falls in the zone renders inside the band,
            // and one outside renders outside — even after spacing nudges orbits outward.
            hzInnerScene: star?.habitableZoneInnerAu
                .map { remapToSpaced(sceneRadius(au: $0), rawScenes: rawScenes, orbits: orbits) },
            hzOuterScene: star?.habitableZoneOuterAu
                .map { remapToSpaced(sceneRadius(au: $0), rawScenes: rawScenes, orbits: orbits) },
            planets: planets, belts: belts, hazards: hazards,
            structures: structures,
            kuiperScene: kuiper,
            // Widen the frame so nothing spills outside the view.
            frameScene: max(frame, outerMost * 1.12),
            deviceCount: deviceCount, vesselCount: 0)
    }

    /// Non-overlapping orbit radii AND asteroid-belt bands (scene units). Planets and
    /// belts are interleaved by their raw inner edge and walked from the star outward;
    /// each is pushed out just enough that its inner edge clears the previous occupant's
    /// outer edge plus a gap. So when the sqrt-compressed inner system would stack bodies
    /// on top of one another — or a planet's orbit would fall inside a belt's band — the
    /// crowded one is nudged outward. The sun is the innermost "body" (radius `sunScene`),
    /// so the first occupant also clears the star. Order-preserving; occupants with room
    /// keep their true positions. Returns planet orbits and belt bands in input order.
    static func spacedLayout(
        planetOrbits: [Double], planetRadii: [Double],
        beltInner: [Double], beltOuter: [Double], sunScene: Double
    ) -> (orbits: [Double], belts: [(inner: Double, outer: Double)]) {
        let pad = max(0.6, sunScene * 0.15)          // clear gap between adjacent occupants

        enum Occupant { case planet(Int), belt(Int) }
        // Sort by raw radial centre (a planet's orbit; a belt's midpoint). Centre order
        // preserves the planets' true radial order (a nearer planet never renders farther
        // out than a farther one), which keeps the spaced orbits monotonic in raw radius —
        // relied on by `remapToSpaced` for a faithful habitable-zone band.
        var order: [(Occupant, key: Double)] = []
        for i in planetOrbits.indices { order.append((.planet(i), planetOrbits[i])) }
        for i in beltInner.indices { order.append((.belt(i), (beltInner[i] + beltOuter[i]) / 2)) }
        order.sort { $0.key < $1.key }

        var orbits = planetOrbits
        var belts = Array(zip(beltInner, beltOuter)).map { (inner: $0.0, outer: $0.1) }
        var prevOuter = sunScene                      // the star occupies the centre

        for (occupant, _) in order {
            switch occupant {
            case let .planet(i):
                let orbit = max(planetOrbits[i], prevOuter + pad + planetRadii[i])
                orbits[i] = orbit
                prevOuter = orbit + planetRadii[i]
            case let .belt(i):
                let width = max(beltOuter[i] - beltInner[i], 0)
                let inner = max(beltInner[i], prevOuter + pad)
                belts[i] = (inner, inner + width)
                prevOuter = inner + width
            }
        }
        return (orbits, belts)
    }

    /// Map a raw (AU→scene) radius into the *spaced* layout, so a continuous feature —
    /// the habitable-zone band — lands consistently with the planets whose orbits the
    /// spacing pass nudged outward. Piecewise-linear through the planet anchors
    /// (`rawScenes[i]` → `orbits[i]`), pinned at the star centre (0 → 0) and extrapolated
    /// beyond the outermost planet with that last segment's slope. Because the spaced
    /// orbits are monotonic in raw radius (see `spacedLayout`), this map is monotonic:
    /// a radius inside the raw HZ maps inside the mapped band, one outside stays outside.
    static func remapToSpaced(_ rawRadius: Double, rawScenes: [Double], orbits: [Double]) -> Double {
        // Anchors sorted by raw radius, prefixed with the star centre.
        let sorted = rawScenes.indices.sorted { rawScenes[$0] < rawScenes[$1] }
        var xs: [Double] = [0], ys: [Double] = [0]
        for i in sorted { xs.append(rawScenes[i]); ys.append(orbits[i]) }
        guard xs.count > 1 else { return rawRadius }        // no planets → identity

        if rawRadius <= xs[0] { return rawRadius }
        for k in 1..<xs.count where rawRadius <= xs[k] {
            let t = (rawRadius - xs[k - 1]) / max(xs[k] - xs[k - 1], 1e-9)
            return ys[k - 1] + t * (ys[k] - ys[k - 1])
        }
        // Beyond the outermost planet: extend along the last segment's slope.
        let n = xs.count
        let slope = (ys[n - 1] - ys[n - 2]) / max(xs[n - 1] - xs[n - 2], 1e-9)
        return ys[n - 1] + slope * (rawRadius - xs[n - 1])
    }

    /// A star-only model (no planets/belts) for a system we haven't hydrated yet —
    /// so the sun shows immediately on drill-in while the roster loads.
    static func minimal(designation: String, position: Position,
                        spectralType: String?, color: String?, name: String?) -> SystemModel {
        SystemModel(
            star: StarDetail(
                designation: designation, name: name, spectralType: spectralType,
                color: color, position: position, temperatureK: nil, massSolar: nil,
                luminositySolar: nil, ageMy: nil, habitableZone: nil, miningBonusPct: nil),
            hzInnerScene: nil, hzOuterScene: nil, planets: [], belts: [], hazards: [],
            kuiperScene: nil, frameScene: 20, deviceCount: 0, vesselCount: 0)
    }

    /// A moon worth flagging: has your device, a live salvage site, a mining site,
    /// or stored inventory.
    static func moonIsInteresting(_ m: Moon) -> Bool {
        !m.devices.isEmpty || m.salvage.contains(where: { !$0.depleted })
            || !m.sites.isEmpty || !m.inventory.isEmpty
    }

    // MARK: - Body level (a planet + its moons)

    /// Moon display radius as a *fraction of the central planet's* rendered radius —
    /// from real `radiusEarth` when scanned, else a small default. Moons read clearly
    /// smaller than the planet they orbit. The scene radius is `centralScene · fraction`.
    static func moonSizeFraction(_ m: Moon) -> Double {
        if let re = m.physical?.radiusEarth, re > 0 { return min(0.30, 0.10 + 0.08 * re.squareRoot()) }
        return 0.14
    }

    /// Moon schematic colour by type — icy/rocky/lava/ocean, else a neutral grey.
    static func moonColor(type: String?) -> String {
        let t = (type ?? "").lowercased()
        if t.contains("ice") || t.contains("frozen") { return "#cdd6e6" }
        if t.contains("lava") || t.contains("volcanic") { return "#d8613a" }
        if t.contains("ocean") { return "#5f8fc0" }
        if t.contains("rock") || t.contains("barren") { return "#9a9086" }
        return "#b8b0a4"
    }

    /// A body-level orrery `SystemModel`: the drilled planet as the lit `centralBody`
    /// with its moons as the orbiting `planets`. Moons ring outward from the planet
    /// (interesting moons + nearest first, capped for the 60+-moon systems); orbits
    /// are index-stepped (real `orbitalDistanceKm` only orders them) so the roster
    /// stays legible. Empty moons → just the central planet (shown before the
    /// `hydrateBody` roster lands, like the star-only system fallback).
    static func bodyModel(planet: Planet, maxMoons: Int = 24) -> SystemModel {
        // The drilled planet is the body-level "sun": a consistent, prominent centre
        // (like the field star at system level), with its moons proportional to it.
        let centralScene = 2.6
        let central = CentralBody(
            displayRadius: centralScene,
            colorHex: planetColor(type: planet.type),
            hasRing: planet.physical?.rings ?? false,
            planetType: PlanetType(apiType: planet.type),
            lifeStage: planet.lifeStage, estimated: planet.typeEstimated,
            tags: planet.physical?.tags ?? [],
            inHabitableZone: planet.inHabitableZone,
            surfaceTempC: planet.physical?.surfaceTempC,
            atmosphere: Atmosphere(apiValue: planet.physical?.atmosphere),
            appearanceSeed: appearanceSeed(designation: planet.designation,
                                           rotationPeriodHours: planet.physical?.rotationPeriodHours))

        let ordered = planet.moons.sorted { a, b in
            let ai = moonIsInteresting(a), bi = moonIsInteresting(b)
            if ai != bi { return ai }
            let ad = a.physical?.orbitalDistanceKm ?? .greatestFiniteMagnitude
            let bd = b.physical?.orbitalDistanceKm ?? .greatestFiniteMagnitude
            if ad != bd { return ad < bd }
            return a.designation < b.designation
        }
        // Force-include EVERY interesting moon (hosts a device / site / salvage /
        // inventory) even past the cap — a device must never lack an anchor. The cap only
        // trims boring moons for legibility; a huge interesting roster is shown in full.
        let interesting = ordered.filter(moonIsInteresting)
        let boring = ordered.filter { !moonIsInteresting($0) }
        let shown = interesting + boring.prefix(max(0, maxMoons - interesting.count))
        let base = centralScene * 1.7          // first moon clears the planet + a gap
        let step = centralScene * 0.5
        let moons: [OrreryPlanet] = shown.enumerated().map { i, m in
            var indicators: BodyIndicators = []
            if !m.devices.isEmpty { indicators.insert(.device) }
            if m.salvage.contains(where: { !$0.depleted }) { indicators.insert(.salvage) }
            if !m.sites.isEmpty { indicators.insert(.miningSite) }
            if !m.inventory.isEmpty { indicators.insert(.inventory) }
            return OrreryPlanet(
                designation: m.designation, name: m.name, type: m.type,
                planetType: PlanetType(apiType: m.type), estimated: m.recon != .scanned,
                tags: m.physical?.tags ?? [],
                surfaceTempC: m.physical?.surfaceTempC,
                atmosphere: Atmosphere(apiValue: m.physical?.atmosphere),
                appearanceSeed: appearanceSeed(designation: m.designation,
                                               rotationPeriodHours: m.physical?.rotationPeriodHours),
                orbitalDistanceAu: 0, inHabitableZone: false,
                scanned: m.recon == .scanned, moonCount: 0, lifeStage: nil,
                inventory: m.inventory,
                semiMajorScene: base + Double(i) * step,
                periodDays: m.physical?.orbitalPeriodDays ?? (8 + Double(i) * 3),
                phase0Deg: phaseDeg(m.designation),
                displayRadius: centralScene * moonSizeFraction(m),
                colorHex: moonColor(type: m.type),
                hasRing: false, indicators: indicators,
                hasInterestingMoon: false, moons: [])
        }
        let frame = (moons.map(\.semiMajorScene).max() ?? (centralScene + 2)) * 1.12
        let deviceCount = planet.devices.count + planet.moons.reduce(0) { $0 + $1.devices.count }

        return SystemModel(
            star: StarDetail(
                designation: planet.designation, name: planet.name,
                spectralType: planet.type, color: nil,
                position: Position(x: 0, y: 0, z: 0),
                temperatureK: nil, massSolar: nil, luminositySolar: nil, ageMy: nil,
                habitableZone: nil, miningBonusPct: nil),
            centralBody: central, hzInnerScene: nil, hzOuterScene: nil,
            planets: moons, belts: [], hazards: [], kuiperScene: nil,
            frameScene: frame, deviceCount: deviceCount, vesselCount: 0)
    }

    // MARK: - Helpers

    /// The L-number (1…5) of a Lagrange designation whose last segment is `L[1-5]`
    /// (`SOL-5-L4` → 4). Nil if the tail isn't a recognized Lagrange marker.
    static func lPointNumber(_ designation: String) -> Int? {
        guard let last = designation.split(separator: "-").last,
              last.first == "L", let n = Int(last.dropFirst()), (1...5).contains(n)
        else { return nil }
        return n
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Both-or-nothing pair (avoids nested optional maps).
    private static func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
        guard let a, let b else { return nil }
        return (a, b)
    }
}
