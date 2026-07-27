//
//  BodySpin.swift
//  NewStarMapFeature
//
//  How an orrery body turns: its obliquity, its rotation period, and whether it is
//  tidally locked to its parent. Built from the scan's `axial_tilt_deg` /
//  `rotation_period_hours` / `tidally_locked` (all nil until the body is scanned).
//  Pure + deterministic, so it is unit-tested rather than eyeballed on the GPU.
//

import Foundation
import simd

/// A body's rotation, as the renderer needs it: a pole direction and a signed rate.
///
/// The backend signals retrograde rotation TWO independent ways — a negative
/// `rotationHours` (SOL-2 = −5832.5, SOL-7 = −17.24) and an obliquity past 90°
/// (SOL-2 = 177.4°, SOL-7 = 97.77°), the standard astronomical convention.
///
/// Only the first needs code. The second is pure geometry: past 90° the pole tips
/// below the orbital plane, so a body spinning right-handed about it appears to turn
/// backwards from above. `sign` therefore deliberately IGNORES obliquity — flipping
/// it there too would double-count and cancel a retrograde world back to prograde.
struct BodySpin: Equatable, Sendable {
    /// Axial tilt in degrees, as reported. Nil until scanned.
    var tiltDeg: Double?
    /// Rotation period in hours, signed. Nil until scanned.
    var rotationHours: Double?
    /// Same face always toward the parent — true for essentially every scanned moon.
    var tidallyLocked: Bool = false

    /// An unscanned body: upright, default rate, free-rotating.
    static let unknown = BodySpin()

    /// Obliquity normalized into 0…180°. The backend already reports within that range
    /// (3.13 … 177.4 observed); the wrap is defensive, so a stray value can never aim
    /// the pole somewhere absurd.
    var obliquityDeg: Double {
        guard let t = tiltDeg, t.isFinite else { return 0 }
        let wrapped = t.truncatingRemainder(dividingBy: 360)
        let positive = wrapped < 0 ? wrapped + 360 : wrapped
        return positive > 180 ? 360 - positive : positive
    }

    /// Whether this body turns retrograde, by either signal — for the dossier's label.
    /// The RENDERER does not consult this: obliquity is handled by the pole geometry
    /// and the explicit sign by `sign`.
    var isRetrograde: Bool {
        obliquityDeg > 90 || (rotationHours ?? 0) < 0
    }

    /// −1 only when the rotation is *explicitly* called retrograde by a negative
    /// period, else +1. Obliquity deliberately does not flip this — see the type's
    /// note: past 90° the tilted pole already reverses the apparent spin, and
    /// flipping here as well would cancel it back to prograde.
    var sign: Float {
        (rotationHours ?? 0) < 0 ? -1 : 1
    }

    /// The body's north pole as a unit vector: +Y tilted by `obliquityDeg` about an
    /// azimuth taken from the body's stable appearance seed, so two worlds sharing a
    /// tilt don't lean the same way.
    func pole(seed: Float) -> SIMD3<Float> {
        let obl = Float(obliquityDeg) * .pi / 180
        let az = seed * 2 * .pi
        return SIMD3(sin(obl) * cos(az), cos(obl), sin(obl) * sin(az))
    }

    /// The reference rotation period (hours) every body's spin scales against — one
    /// Earth day. GLOBAL and constant, deliberately.
    ///
    /// This previously anchored on the fastest rotator in the *current layer*, which
    /// had two problems. A body's speed depended on which of its neighbours happened
    /// to be scanned, so surveying one fast world silently slowed every other planet
    /// in that system; and because only the single fastest body got `baseRate`, every
    /// other planet ended up slower than the flat rate they all span at before
    /// rotation periods were wired in — the whole orrery read sluggish. A fixed
    /// reference means a given planet always turns at the same rate, in any system,
    /// however much of it you have surveyed.
    static let referenceHours: Double = 24

    /// Perceptible-speed band (rad/s). Real periods span 9.92h…5832.5h — a 588× spread
    /// no single curve keeps legible at both ends — so the extremes clamp. Without the
    /// floor SOL-1 would take ~13 minutes per turn and SOL-2 ~27, both reading as
    /// frozen; without the ceiling a very fast rotator would strobe.
    static let minRate: Float = 0.022     // ≈ 286 s per rotation
    static let maxRate: Float = 0.16      // ≈ 39 s per rotation

    /// Signed spin rate (rad/s), scaled off the global `referenceHours` and compressed
    /// by `falloff`, then clamped into the perceptible band. A body with no reading
    /// keeps the historical fixed rate (identical to a 24-hour world).
    func spinRate(baseRate: Float = 0.06, falloff: Float = 0.5) -> Float {
        guard let h = rotationHours, h != 0, h.isFinite else { return baseRate }
        let ratio = Float(Self.referenceHours / abs(h))
        let rate = baseRate * pow(max(ratio, 1e-6), falloff)
        return sign * min(max(rate, Self.minRate), Self.maxRate)
    }

    /// The spin phase that keeps a tidally locked body's near face toward its parent,
    /// given its current orbit angle. Paired with `spinRate == 0`, since the orbital
    /// motion alone supplies the body's one rotation per orbit.
    ///
    /// It is the **negated** orbit angle, and the sign is not arbitrary — two
    /// conventions compose to require it:
    ///
    /// - `OrreryLayout` places a body at `(cos a, 0, sin a)` with `a` DECREASING over
    ///   time (orbits run counter-clockwise about the pole), so the body's position
    ///   advances as `−a`.
    /// - `orrery_body_fragment` rotates the texture LOOKUP direction by `spin`, so a
    ///   fixed surface feature appears to advance by `−spin`.
    ///
    /// For the same face to hold on the parent, the feature must advance exactly as
    /// the position does: `−spin == −a` … i.e. `spin == −a`. Feeding `a` unnegated
    /// turns the moon relative to its parent at twice the orbital rate, which reads as
    /// retrograde — see `tidallyLockedBodyKeepsOneFaceTowardItsParent`.
    static func lockedSpinPhase(orbitAngle: Float) -> Float { -orbitAngle }

    /// The body's orthonormal texturing frame as (x, pole, z) columns — the frame the
    /// surface shader transforms into so every latitude feature tilts with the body.
    ///
    /// SYNC POINT: `orrery_body_fragment` builds this exact basis on the GPU. It MUST
    /// be right-handed (determinant +1): building `z` as `cross(pole, x)` instead of
    /// `cross(x, pole)` yields a reflection, which mirrors the sphere and makes every
    /// planet appear to spin backwards. That shipped once; `bodyFrameIsRightHanded`
    /// exists so it cannot ship again unnoticed.
    func frame(seed: Float) -> (x: SIMD3<Float>, pole: SIMD3<Float>, z: SIMD3<Float>) {
        let p = pole(seed: seed)
        let ref: SIMD3<Float> = abs(p.y) > 0.99 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let x = simd_normalize(simd_cross(ref, p))
        return (x, p, simd_cross(x, p))
    }
}
