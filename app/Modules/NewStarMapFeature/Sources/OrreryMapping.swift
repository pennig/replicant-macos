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

    /// Display radius (scene units) — from real `radius_earth` when scanned, else a
    /// type default. Gentle compression so gas giants don't dwarf the terrestrials.
    static func displayRadius(planet: Planet) -> Double {
        if let re = planet.physical?.radiusEarth, re > 0 {
            return 0.5 + 0.35 * re.squareRoot()
        }
        let t = (planet.type ?? "").lowercased()
        if t.contains("giant") { return 1.6 }
        if t.contains("super earth") { return 0.95 }
        return 0.75
    }

    // MARK: - Build

    static func systemModel(from s: StarSystem) -> SystemModel {
        let star = s.star

        let planets = s.planets.map { p -> OrreryPlanet in
            let au = p.orbitalDistanceAu ?? 0.1
            var indicators: BodyIndicators = []
            if !p.devices.isEmpty { indicators.insert(.device) }
            if p.salvage.contains(where: { !$0.depleted }) { indicators.insert(.salvage) }
            if !p.sites.isEmpty { indicators.insert(.miningSite) }
            if !p.inventory.isEmpty { indicators.insert(.inventory) }
            if let ls = p.lifeStage, ls != "none", !ls.isEmpty { indicators.insert(.life) }

            let interestingMoon = p.moons.contains { moonIsInteresting($0) }
                || (p.moons.isEmpty && (p.moonCount ?? 0) > 0)   // hint before hydration

            return OrreryPlanet(
                designation: p.designation, name: p.name, type: p.type,
                orbitalDistanceAu: au, inHabitableZone: p.inHabitableZone,
                scanned: p.recon == .scanned, moonCount: p.moonCount ?? p.moons.count,
                lifeStage: p.lifeStage, inventory: p.inventory,
                semiMajorScene: sceneRadius(au: au),
                periodDays: p.physical?.orbitalPeriodDays ?? fallbackPeriodDays(au: au),
                phase0Deg: phaseDeg(p.designation),
                displayRadius: displayRadius(planet: p),
                colorHex: planetColor(type: p.type),
                hasRing: p.physical?.rings ?? false,
                indicators: indicators, hasInterestingMoon: interestingMoon, moons: [])
        }

        let belts = s.belts.map { b in
            BeltModel(
                designation: b.designation,
                innerScene: sceneRadius(au: b.innerRadiusAu ?? 0),
                outerScene: sceneRadius(au: b.outerRadiusAu ?? 0),
                density: b.density, richness: b.richness, hasSites: !b.sites.isEmpty)
        }

        let kuiper = s.structures.first { $0.kind == .kuiper }?.orbitalDistanceAu.map(sceneRadius(au:))

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

        let maxOrbit = (planets.map(\.semiMajorScene) + belts.map(\.outerScene)).max() ?? 0
        let frame = maxOrbit > 0 ? maxOrbit * 1.12 : (kuiper ?? 20)
        let deviceCount = s.planets.reduce(0) { $0 + $1.devices.count }

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
            hzInnerScene: star?.habitableZoneInnerAu.map(sceneRadius(au:)),
            hzOuterScene: star?.habitableZoneOuterAu.map(sceneRadius(au:)),
            planets: planets, belts: belts, hazards: hazards,
            kuiperScene: kuiper, frameScene: frame,
            deviceCount: deviceCount, vesselCount: 0)
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

    // MARK: - Helpers

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
