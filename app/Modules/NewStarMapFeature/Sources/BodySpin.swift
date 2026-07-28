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

    /// Cap (degrees) on how much of a body's obliquity the RENDERED plane expresses —
    /// the plane its rings, its surface frame, and its moon orbits all share.
    ///
    /// A cap is needed because `TurntableCamera` frames at ~29° elevation and clamps at
    /// ±80°: against SOL-7's 97.77° the shared plane sits near-perpendicular to the
    /// orbital plane and every orbit collapses toward a line. Compressing the range is
    /// the same move `spinRate` already makes for a 588× rotation-period spread.
    ///
    /// `90` disables compression (fully physical); `0` flattens every plane into the
    /// orbital plane. Only extremes are affected at the default — Saturn's 26.73° is
    /// untouched.
    var tiltCapDeg: Double = 38

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

    /// The obliquity the RENDERER uses — `obliquityDeg` with its plane tilt compressed
    /// toward `tiltCapDeg`. Every visual consumer reads this (via `pole`), which is what
    /// makes it structurally impossible for the ring plane, the surface bands, and the
    /// moon orbits to disagree about where this body's equator is.
    ///
    /// `obliquityDeg` itself is left alone: `isRetrograde` and the dossier report what
    /// the scan actually said.
    var renderObliquityDeg: Double {
        let theta = obliquityDeg
        let planeTilt = min(theta, 180 - theta)          // a plane has no normal sign
        let compressed = Self.compress(planeTilt, capDeg: tiltCapDeg)
        // Preserve the HEMISPHERE. Mapping a past-90° obliquity down below 90 would put
        // the pole back above the orbital plane and cancel the body's retrograde spin —
        // the double-count `sign`'s doc comment warns about. This branch is why the
        // compression can never introduce that bug.
        return theta <= 90 ? compressed : 180 - compressed
    }

    /// Identity below a knee, then asymptotic to `capDeg`. `capDeg >= 90` is the
    /// identity (nothing to compress); `capDeg == 0` flattens.
    static func compress(_ planeTilt: Double, capDeg: Double) -> Double {
        guard capDeg < 90 else { return planeTilt }
        guard capDeg > 0 else { return 0 }
        let knee = min(capDeg * 0.8, 30)
        guard planeTilt > knee else { return planeTilt }
        let room = capDeg - knee
        guard room > 0 else { return capDeg }
        return knee + room * (1 - exp(-(planeTilt - knee) / room))
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

    /// The body's north pole as a unit vector: +Y tilted by `renderObliquityDeg` about
    /// an azimuth taken from the body's stable appearance seed, so two worlds sharing a
    /// tilt don't lean the same way. Reads the COMPRESSED obliquity — this is the single
    /// pole the rings, the surface frame, and the moon orbits are all built from.
    func pole(seed: Float) -> SIMD3<Float> {
        let obl = Float(renderObliquityDeg) * .pi / 180
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

    /// A stable, non-axis-aligned tumble axis for a body with no reported pole.
    ///
    /// Irregular satellites are largely non-principal-axis rotators, and captured
    /// asteroids report no `axial_tilt_deg` at all — so routing them through `pole` gives
    /// every one of them an upright axis and they read as tiny planets. Spreading the
    /// axis over the sphere is what makes them read as tumbling rock.
    static func tumbleAxis(seed: Float) -> SIMD3<Float> {
        // Two decorrelated angles from one seed: a full azimuth and a polar angle
        // covering the sphere (not clustered at the poles).
        let az = seed * 2 * .pi
        let polar = acos(1 - 2 * fmod(seed * 7.331 + 0.137, 1))
        return SIMD3(sin(polar) * cos(az), cos(polar), sin(polar) * sin(az))
    }

    /// The spin axis a placed body should actually render with: `tumbleAxis(seed:)` for
    /// an irregular, freely-tumbling body, or its own reported `pole` otherwise —
    /// including for an irregular body that is ALSO tidally locked.
    ///
    /// That exception matters: a tidally locked body is by definition no longer a
    /// chaotic non-principal-axis rotator, AND `lockedSpinPhase` assumes the spin axis
    /// tracks the orbital normal (the pole) to keep one face toward the parent —
    /// substituting an unrelated tumble axis there would visibly break the lock. This
    /// combination is not a corner case: `tidallyLocked` (see the type's doc comment,
    /// "true for essentially every scanned moon") is read from the scan independently
    /// of `type`, and captured asteroids are ~18% of the live moon census.
    ///
    /// Factored out of the renderer's placement loop so this exact selection rule is
    /// unit-testable without a live `StarFieldRenderer`/Metal device.
    static func renderSpinAxis(irregularity: Float, locked: Bool, pole: SIMD3<Float>,
                               tumbleSeed: Float) -> SIMD3<Float> {
        irregularity > 0 && !locked ? tumbleAxis(seed: tumbleSeed) : pole
    }

    /// The orthonormal basis around a pole, as (x, normal, z) columns.
    ///
    /// SYNC POINT: `orrery_body_fragment` and `orrery_ring_vertex` build this exact
    /// basis on the GPU. It MUST be right-handed (determinant +1): building `z` as
    /// `cross(pole, x)` instead of `cross(x, pole)` yields a reflection, which mirrors
    /// the sphere and makes every planet appear to spin backwards. That shipped once;
    /// `planeBasisIsRightHanded` and `bodyFrameIsRightHanded` exist so it cannot ship
    /// again unnoticed.
    static func planeBasis(pole: SIMD3<Float>) -> (x: SIMD3<Float>, normal: SIMD3<Float>, z: SIMD3<Float>) {
        let p = simd_normalize(pole)
        let ref: SIMD3<Float> = abs(p.y) > 0.99 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let x = simd_normalize(simd_cross(ref, p))
        return (x, p, simd_cross(x, p))
    }

    /// The body's orthonormal texturing frame as (x, pole, z) columns — the frame the
    /// surface shader transforms into so every latitude feature tilts with the body.
    /// Delegates to `planeBasis` so the moon orbit plane and the ring plane are built
    /// from the identical construction.
    func frame(seed: Float) -> (x: SIMD3<Float>, pole: SIMD3<Float>, z: SIMD3<Float>) {
        let b = Self.planeBasis(pole: pole(seed: seed))
        return (b.x, b.normal, b.z)
    }
}
