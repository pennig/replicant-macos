import simd

/// The system layer's recession from a drilled planet: a uniform scale about that
/// planet's live world position, ramped by the system↔body cross-fade.
///
/// Drilling from a system into one of its planets is not a real dive. `enterSystem`
/// frames the star at `maxAngularSize`, leaving the camera ~17 star-radii out;
/// `enterBody` rescales so the planet renders star-sized and frames its moons,
/// leaving the camera ~19 planet-radii out. The camera therefore *translates* from
/// star to planet without meaningfully changing its distance-to-target — the whole
/// sense of zoom comes from `bodyCentralStartRadius` growing the central body. So
/// the rest of the system, left at its true world positions and at depths
/// comparable to the arriving moon system, can only slide sideways and fade.
///
/// Scaling that system out from the drilled planet is what turns the move into a
/// fly-in: orbit radii AND their spacing grow together (the rings visibly spread),
/// and the sun and siblings — which sit *closer* to the planet than the camera does
/// — are flung past the camera and shrink to points. It is the counterpart of the
/// galaxy drill's `systemPush`, one level down.
///
/// The drilled planet is already the one body a SYSTEM layer excludes (it is drawn
/// once as the continuous central body, never blended against a second copy), so it
/// is the exact fixed point here, with nothing to reconcile between the two layers.
///
/// Two algebraic properties carry the whole render path, and are pinned by
/// `OrreryPushTests`:
///   - the pivot is an exact fixed point, at any progress;
///   - the scale composes into a layer's `(centre, scale, reveal)`, because an
///     `OrreryLayout` is an affine map of scene coordinates and the scaffold
///     shaders already compute `orreryCenter + local · orreryReveal`. That is why
///     the rings need no shader change and no buffer rebuild.
struct OrreryPush {
    /// The drilled planet's live world position — the one point that does not move.
    var pivot: SIMD3<Float>
    /// Distance multiplier. 1 = no push.
    var factor: Float

    /// No push at all — galaxy and system levels, and every layer that IS the
    /// drilled body (that layer is the pivot).
    static let identity = OrreryPush(pivot: .zero, factor: 1)

    private init(pivot: SIMD3<Float>, factor: Float) {
        self.pivot = pivot
        self.factor = factor
    }

    /// `strength` is the extra distance factor at full drill (0 = none), ramped by
    /// the eased cross-fade `progress` — mirroring how the galaxy field's
    /// `systemPush` is ramped by the eased `orreryReveal`, so the rush peaks with
    /// the fade rather than fighting it. Reversing `progress` unwinds it for free,
    /// which is the whole zoom-out.
    init(pivot: SIMD3<Float>, progress: Float, strength: Float) {
        self.init(pivot: pivot, factor: 1 + strength * progress)
    }

    var isIdentity: Bool { factor == 1 }

    func callAsFunction(_ p: SIMD3<Float>) -> SIMD3<Float> {
        pivot + (p - pivot) * factor
    }
}
