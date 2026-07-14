//
//  OrreryLayout.swift
//  NewStarMapFeature
//
//  The single source of truth for "where does a body / location sit, in world space,
//  in the orrery, at this instant?" Built per rendered layer from its (model, centre,
//  scale, reveal, orbit time) and consulted by body placement, annotation pips, device
//  clusters, ship endpoints, and picking — so the orbit math lives in exactly one place
//  and every overlay tracks a body's true position.
//
//  Pure + deterministic (no clock/GPU) → unit-testable. Scene units map through `scale`
//  to the map's light-year world, positioned around `center` (the focused star at system
//  level, or the drilled planet at body level).
//

import simd

/// The knobs that turn a body's real orbital period into its on-screen period. Kept a
/// value so the renderer owns the tuning and the layout stays pure. Mirrors the constants
/// the renderer used inline (`orreryMinPeriod` / `orreryPeriodFalloff`).
struct OrbitTiming: Equatable, Sendable {
    /// Seconds for the system's *fastest* orbit (the anchor every period scales off).
    var minPeriodSeconds: Float = 75
    /// Compression of the period spread (1 = true ratio, 0 = every body at one speed).
    var periodFalloff: Float = 0.55

    static let `default` = OrbitTiming()

    /// The on-screen orbital period (seconds) for a body, scaled off the system fastest.
    func periodSeconds(periodDays: Double, minPeriodDays: Double) -> Float {
        let ratio = minPeriodDays > 0 ? Float(periodDays / minPeriodDays) : 1
        return max(minPeriodSeconds * pow(ratio, periodFalloff), 0.001)
    }

    /// A body's orbit angle (radians) at `time`. Subtracted so bodies orbit
    /// counter-clockwise about the sun's north pole (matching the sun spin + belt).
    func angle(phase0Deg: Double, periodDays: Double, minPeriodDays: Double, time: Float) -> Float {
        let period = periodSeconds(periodDays: periodDays, minPeriodDays: minPeriodDays)
        return Float(phase0Deg) * .pi / 180 - (time / period) * 2 * .pi
    }
}

/// Resolves orrery locations to world positions for one rendered layer at one instant.
struct OrreryLayout {
    let model: SystemModel
    /// World centre of this layer (the focused star, or a drilled planet at body level).
    let center: SIMD3<Float>
    /// Scene-unit → world (light-year) scale around `center`.
    let scale: Float
    /// Orbit-radius / emerge scale (0 = collapsed to the centre, 1 = full orbits). Applied
    /// to every anchor so devices/ships/pips emerge from the centre exactly as bodies do.
    let reveal: Float
    /// Orbit clock (seconds) — frozen at body level, matching the renderer.
    let time: Float
    let timing: OrbitTiming

    init(model: SystemModel, center: SIMD3<Float>, scale: Float, reveal: Float,
         time: Float, timing: OrbitTiming = .default) {
        self.model = model
        self.center = center
        self.scale = scale
        self.reveal = reveal
        self.time = time
        self.timing = timing
    }

    /// The shortest orbital period (days) among this layer's orbiters — the "fastest"
    /// orbit the on-screen timing is anchored to. 1 for an empty model.
    var minPeriodDays: Double { model.planets.map(\.periodDays).min() ?? 1 }

    // MARK: Orbiters (planets at system level, moons at body level)

    /// A layer orbiter's orbit angle (radians) at the layer's `time`.
    func orbiterAngle(_ p: OrreryPlanet) -> Float {
        timing.angle(phase0Deg: p.phase0Deg, periodDays: p.periodDays,
                     minPeriodDays: minPeriodDays, time: time)
    }

    /// A layer orbiter's world position at the layer's `time`, with `reveal` applied.
    func orbiterPosition(_ p: OrreryPlanet) -> SIMD3<Float> {
        radial(orbiterAngle(p), Float(p.semiMajorScene) * scale * reveal)
    }

    /// The world position of the orbiter with `id` in this layer, if present.
    func orbiterPosition(id: String) -> SIMD3<Float>? {
        model.planets.first { $0.id == id }.map(orbiterPosition)
    }

    // MARK: Lagrange points

    /// The world position of a Lagrange point (`SYSTEM-n-L[1-5]`), relative to its parent
    /// planet's live orbit position and the star at `center`. L1/L2 sit just inside/outside
    /// the planet on its radial, L3 opposite the star, L4/L5 lead/trail by 60° on the orbit.
    /// Schematic (not physically exact) but stable and legible. Nil if the parent planet
    /// isn't an orbiter of this layer (e.g. a body-level layer, where it collapses upstream).
    func lagrangePosition(_ code: String) -> SIMD3<Float>? {
        guard let n = OrreryMapping.lPointNumber(code) else { return nil }
        let parentID = Self.parent(of: code)
        guard let planet = model.planets.first(where: { $0.id == parentID }) else { return nil }
        let a = orbiterAngle(planet)
        let r = Float(planet.semiMajorScene) * scale * reveal
        // Radial offset for the collinear points: a fraction of the orbit, floored to a
        // few planet radii so L1/L2 clear the planet's disc at any zoom.
        let bodyR = Float(planet.displayRadius) * scale
        let off = max(r * 0.10, bodyR * 3)
        let lead: Float = 60 * .pi / 180
        switch n {
        case 1: return radial(a, r - off)           // sunward
        case 2: return radial(a, r + off)           // anti-sunward
        case 3: return radial(a + .pi, r)           // opposite the star
        case 4: return radial(a + lead, r)          // leading
        case 5: return radial(a - lead, r)          // trailing
        default: return nil
        }
    }

    // MARK: Belts

    /// A deterministic anchor point on a belt's ring (`SYSTEM-BELT-k`, or a `…-SITE-N`
    /// under it) — the mid-radius at a stable per-belt angle, so a device "at the belt"
    /// has one fixed spot rather than floating in the ring.
    func beltAnchor(_ code: String) -> SIMD3<Float>? {
        let beltID = Self.beltDesignation(in: code) ?? code
        guard let belt = model.belts.first(where: { $0.id == beltID }) else { return nil }
        let mid = (belt.innerScene + belt.outerScene) / 2
        let a = Float(OrreryMapping.phaseDeg(beltID)) * .pi / 180
        return radial(a, Float(mid) * scale * reveal)
    }

    // MARK: Structures / system objects

    /// The world position of a positioned system object (megastructure / object /
    /// kuiper / oort), at a stable per-designation angle and its scene orbit radius.
    func structurePosition(_ code: String) -> SIMD3<Float>? {
        guard let s = model.structures.first(where: { $0.id == code }), s.orbitScene > 0 else { return nil }
        let a = Float(OrreryMapping.phaseDeg(code)) * .pi / 180
        return radial(a, Float(s.orbitScene) * scale * reveal)
    }

    // MARK: Top-level dispatch

    /// Resolve ANY location code to a world position in this layer, level-aware: a code
    /// this layer knows directly (its orbiter, a Lagrange point, a belt, a structure)
    /// resolves exactly; anything deeper (a moon at system level, a site) collapses to the
    /// nearest ancestor the layer knows; the system/central body resolves to `center`.
    /// Nil only when nothing — not even an ancestor — is known.
    func position(ofLocation raw: String) -> SIMD3<Float>? {
        let code = Self.hostBody(of: raw)     // strip a trailing -SITE-N / -SAL-N
        if let p = resolveExact(code) { return p }
        // Collapse upward: a moon → its planet, a Lagrange/site of an unknown body → the
        // body, etc. Walk ancestors until one resolves.
        var parts = code.split(separator: "-").map(String.init)
        while parts.count > 1 {
            parts.removeLast()
            if let p = resolveExact(parts.joined(separator: "-")) { return p }
        }
        return nil
    }

    /// Exact (non-collapsing) resolution of a single code against this layer.
    private func resolveExact(_ code: String) -> SIMD3<Float>? {
        if code == model.star.designation { return center }   // star (system) or drilled planet (body)
        if OrreryMapping.lPointNumber(code) != nil, let p = lagrangePosition(code) { return p }
        if let p = orbiterPosition(id: code) { return p }
        if code.contains("-BELT-") || code.hasSuffix("-BELT"), let p = beltAnchor(code) { return p }
        if let p = structurePosition(code) { return p }
        return nil
    }

    // MARK: Helpers

    private func radial(_ angle: Float, _ radius: Float) -> SIMD3<Float> {
        center + SIMD3<Float>(cos(angle) * radius, 0, sin(angle) * radius)
    }

    /// The parent of a code — its designation minus the last segment (`SOL-5-L4` → `SOL-5`).
    static func parent(of code: String) -> String {
        code.split(separator: "-").dropLast().joined(separator: "-")
    }

    /// The host body/belt of a site code: strip a trailing `-SITE-N` or `-SAL-N`
    /// (`SOL-BELT-1-SITE-0` → `SOL-BELT-1`, `SOL-3-SAL-1` → `SOL-3`). Other codes pass through.
    static func hostBody(of code: String) -> String {
        var parts = code.split(separator: "-").map(String.init)
        for marker in ["SITE", "SAL"] {
            if let i = parts.lastIndex(of: marker) { parts = Array(parts[..<i]); break }
        }
        return parts.joined(separator: "-")
    }

    /// The `SYSTEM-BELT-k` designation embedded in a code, if any (`SOL-BELT-1-SITE-0`
    /// → `SOL-BELT-1`, `SOL-BELT-1` → `SOL-BELT-1`).
    static func beltDesignation(in code: String) -> String? {
        let parts = code.split(separator: "-").map(String.init)
        guard let i = parts.firstIndex(of: "BELT"), i + 1 < parts.count else { return nil }
        return parts[...(i + 1)].joined(separator: "-")
    }
}
