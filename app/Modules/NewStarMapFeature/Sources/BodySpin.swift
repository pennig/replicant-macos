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

    /// Signed spin rate (rad/s), anchored so the FASTEST rotator in the layer turns at
    /// `baseRate` and the spread is compressed by `falloff`. Real periods run
    /// 9.92h…5832.5h — a 588× spread that a linear map either blurs at one end or
    /// freezes at the other. A body with no reading keeps the historical fixed rate.
    func spinRate(fastestHours: Double, baseRate: Float = 0.06, falloff: Float = 0.5) -> Float {
        guard let h = rotationHours, h != 0, h.isFinite, fastestHours > 0 else { return baseRate }
        let ratio = Float(fastestHours / abs(h))
        return sign * baseRate * pow(max(ratio, 1e-6), falloff)
    }
}
