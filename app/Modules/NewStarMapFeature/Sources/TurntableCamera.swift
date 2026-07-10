import simd

// A turntable, not a free arcball. Azimuth is free; elevation is clamped
// (symmetric ±80°) so up stays up and the player can never roll or tumble into
// disorientation. Dolly is logarithmic (radius-multiplying) to span the huge
// overview→single-star range without crawling or teleporting.
//
// Refocus is a RE-AIM: it holds the eye where it is and pivots to look at the new
// star, deriving the orbit from (fixed eye → new pivot). Selecting a nearby star
// therefore only changes the tilt. A max-radius cap adds a blend: refocusing on a
// DISTANT star also glides the eye inward along the viewing ray (a zoom-toward),
// since holding the eye fixed that far out would leave the star an unreadable dot.

struct TurntableCamera {
    var target: SIMD3<Float> = .zero      // the pivot everything orbits
    var azimuth: Float = 0.6              // radians, free
    var elevation: Float = 0.5            // radians, clamped ±80°
    var radius: Float = 180               // distance from pivot

    var fovy: Float = 60 * .pi / 180
    var near: Float = 0.05
    var far: Float = 4000

    /// Horizontal optical shift in NDC, folded into the projection so the pivot
    /// can sit centred in the region a translucent split-view sidebar leaves clear.
    /// It shifts the *image* only — the orbit centre and look-at are untouched, so
    /// the galaxy still spins about its true centre. Positive → content moves right.
    var lensShiftX: Float = 0

    // Symmetric elevation clamp: 10° shy of each pole to dodge the gimbal
    // singularity and top/bottom-down vertigo, while allowing views from below
    // (there's no privileged galactic plane — the terrain is a sphere).
    private let minElevation: Float = -80 * .pi / 180
    private let maxElevation: Float =  80 * .pi / 180
    private let minRadius: Float = 0.5
    private let maxRadius: Float = 500

    /// Refocus radius cap. A star closer than this is re-aimed with the eye held
    /// fixed (tilt-only); a star farther than this pulls the eye in to sit this
    /// far from it (zoom-toward). The knob that tunes the near/far blend.
    var maxFocusRadius: Float = 45

    // Orbit sensitivity falls off as the camera pulls back: full sensitivity at or
    // inside `orbitReferenceRadius`, then decreasing so the whole field doesn't
    // sweep past uncontrollably far out. Lets you place a labelled star precisely.
    var orbitReferenceRadius: Float = 40
    var orbitMinSensitivity: Float = 0.2

    /// Dolly floor while focused on a body: the renderer sets this to the distance
    /// at which the focused star fills its angular-size cap, so you can't zoom past
    /// the point where it stops growing (no dead zone). nil → the plain `minRadius`.
    var focusFloor: Float?

    // Duration-scaled ease-in-out for framing moves. Duration grows with the size
    // of the change and is clamped to [minDuration, maxDuration]; the eye-position
    // change is weighted so a reposition (zoom-toward / Home) always takes longer
    // than a same-magnitude pure re-aim.
    var framingMinDuration: Double = 0.30
    var framingMaxDuration: Double = 0.75
    /// Eye translation (ly) at which the duration saturates to the max.
    private let eyeMoveReference: Float = 45
    /// Look-direction swing (radians) at which the duration saturates to the max.
    private let lookSwingReference: Float = 70 * .pi / 180

    // In-flight eased move (nil = settled / under manual control). `step()`
    // advances it each frame; any manual gesture cancels it so the user wins. A
    // move is expressed as endpoints of BOTH the eye (position) and the pivot;
    // orientation is derived from them per frame. The max-radius cap is applied
    // once, when computing `goalEye` — never mid-flight — so a tilt-only re-aim
    // (start eye == goal eye) keeps the eye pinned throughout.
    private struct Framing {
        var startEye: SIMD3<Float>
        var goalEye: SIMD3<Float>
        var startTarget: SIMD3<Float>
        var goalTarget: SIMD3<Float>
        var startTime: Double
        var duration: Double
    }
    private var framing: Framing?

    /// Whether an eased framing move is in flight — the auto-rotate idle clock
    /// treats this as motion so the spin won't resume mid-move.
    var isFraming: Bool { framing != nil }

    /// How zoomed-in the camera is on the logarithmic dolly scale: 0 when fully
    /// zoomed out (`maxRadius`), 1 when fully zoomed in (`minRadius`). Used to gate
    /// zoom-dependent detail like label density.
    var zoomedInFraction: Float {
        let lo = log(minRadius), hi = log(maxRadius)
        return min(max((hi - log(radius)) / (hi - lo), 0), 1)
    }

    /// Camera eye derived from spherical coordinates around the pivot.
    var eye: SIMD3<Float> {
        let ce = cos(elevation), se = sin(elevation)
        let ca = cos(azimuth),   sa = sin(azimuth)
        let dir = SIMD3<Float>(ce * sa, se, ce * ca)   // pivot → eye
        return target + dir * radius
    }

    // MARK: Gestures

    mutating func orbit(dAzimuth: Float, dElevation: Float) {
        framing = nil
        let s = orbitSensitivity
        azimuth += dAzimuth * s
        elevation = min(max(elevation + dElevation * s, minElevation), maxElevation)
    }

    /// A slow, hands-off azimuth spin for the auto-rotate control. Unlike `orbit`
    /// it does NOT cancel an in-flight framing move — it simply yields while one is
    /// easing (the framing owns azimuth then) and resumes once the camera settles.
    mutating func autoOrbit(by radians: Float) {
        guard framing == nil else { return }
        azimuth += radians
    }

    /// Radians-per-input scale for orbiting: 1.0 at/inside `orbitReferenceRadius`,
    /// falling off (∝ 1/√radius) to `orbitMinSensitivity` far out.
    var orbitSensitivity: Float {
        min(max(sqrt(orbitReferenceRadius / radius), orbitMinSensitivity), 1)
    }

    /// Logarithmic dolly. `amount` > 0 zooms in. A pinch/scroll maps here.
    /// Manual dolly cancels any in-flight framing so the user always wins.
    mutating func dolly(_ amount: Float) {
        framing = nil
        let floor = max(minRadius, focusFloor ?? minRadius)
        radius = min(max(radius * exp(-amount), floor), maxRadius)
    }

    /// Pan the pivot in the screen plane. Speed scales with radius so panning
    /// feels the same at every zoom level (distance-relative movement).
    /// Manual pan cancels any in-flight framing.
    mutating func pan(dx: Float, dy: Float) {
        framing = nil
        let e = eye
        let forward = normalize(target - e)
        let right = normalize(cross(forward, SIMD3<Float>(0, 1, 0)))
        let up = cross(right, forward)
        let scale = radius * 0.0015
        target += (-right * dx + up * dy) * scale
    }

    // MARK: Eased framing

    /// Re-aim at `point`: pivot to look at the star, settling at a distance bounded
    /// by the star's dolly floor and the re-aim cap:
    ///   • inside the `focusFloor` (dollied in too close while unfocused) → pull the
    ///     eye back out to the floor, so a focused star can't over-fill the view;
    ///   • between the floor and `maxFocusRadius` → hold the eye exactly where it is
    ///     (tilt-only — an orientation change);
    ///   • beyond `maxFocusRadius` → glide the eye in along the viewing ray to sit
    ///     `maxFocusRadius` from it (zoom-toward).
    /// The bound is applied once here, to the goal eye. `now` is the current time
    /// (seconds, monotonic) — injected so the camera is a pure, testable value.
    mutating func focus(on point: SIMD3<Float>, now: Double) {
        let v = eye - point
        let dist = length(v)
        // Direction from the star back to the eye; fall back to the current orbit
        // direction if the eye is essentially on the star.
        let u: SIMD3<Float>
        if dist > 1e-4 {
            u = v / dist
        } else {
            let ce = cos(elevation), se = sin(elevation), ca = cos(azimuth), sa = sin(azimuth)
            u = SIMD3<Float>(ce * sa, se, ce * ca)
        }
        let floor = max(minRadius, focusFloor ?? minRadius)
        let goalDist = dist < floor ? floor
                     : (dist <= maxFocusRadius ? dist : maxFocusRadius)
        beginFraming(goalEye: point + u * goalDist, goalTarget: point, now: now)
    }

    /// Dive to a fixed distance: always reposition the eye to sit `diveRadius`
    /// from `point` along the current viewing ray, regardless of the present
    /// radius. Unlike `focus`, this always changes the pose (a double-click "get
    /// closer") — but keeps the same orientation. Same eased framing.
    /// `duration` overrides the auto-scaled framing time (used to sync the drill
    /// fly with the crossfade).
    mutating func dive(on point: SIMD3<Float>, radius diveRadius: Float, now: Double, duration: Double? = nil) {
        let v = eye - point
        let dist = length(v)
        // Direction from the star back to the eye; fall back to the current orbit
        // direction if the eye is essentially on the star.
        let ce = cos(elevation), se = sin(elevation)
        let ca = cos(azimuth),   sa = sin(azimuth)
        let u = dist > 1e-4 ? v / dist : SIMD3<Float>(ce * sa, se, ce * ca)
        let r = min(max(diveRadius, minRadius), maxRadius)
        beginFraming(goalEye: point + u * r, goalTarget: point, now: now, duration: duration)
    }

    /// Immediately settle at a dived pose on `point` (no eased framing), keeping
    /// the current orbit angles. Seeds the first-run viewpoint — a close frame on
    /// the current-location star rather than the far overview.
    mutating func settle(on point: SIMD3<Float>, radius r: Float) {
        framing = nil
        target = point
        radius = min(max(r, minRadius), maxRadius)
    }

    /// Cancel any in-flight eased move, holding the current pose. Used when a
    /// cached pose is restored so a fly that was mid-flight when the view went away
    /// doesn't resume from a stale start time.
    mutating func cancelFraming() { framing = nil }

    /// Ease to an overview: move the eye so it sits `radius` from `target`,
    /// recentring there. Used for Home — a deliberate pull-back, not a re-aim.
    mutating func overview(target newTarget: SIMD3<Float>, radius newRadius: Float, now: Double) {
        let goalRadius = min(max(newRadius, minRadius), maxRadius)
        let goalEye = eyePosition(target: newTarget, azimuth: azimuth,
                                  elevation: elevation, radius: goalRadius)
        beginFraming(goalEye: goalEye, goalTarget: newTarget, now: now)
    }

    /// Ease back to a previously-captured pose (used to restore the pre-drill
    /// camera on zoom-out). Interpolates to the saved eye + pivot; azimuth /
    /// elevation / radius are re-derived from them as the move settles.
    mutating func restore(_ saved: TurntableCamera, now: Double, duration: Double? = nil) {
        beginFraming(goalEye: saved.eye, goalTarget: saved.target, now: now, duration: duration)
    }

    private mutating func beginFraming(goalEye: SIMD3<Float>, goalTarget: SIMD3<Float>, now: Double, duration: Double? = nil) {
        let startEye = eye
        framing = Framing(
            startEye: startEye, goalEye: goalEye,
            startTarget: target, goalTarget: goalTarget,
            startTime: now,
            duration: duration ?? framingDuration(fromEye: startEye, toEye: goalEye,
                                                  fromPivot: target, toPivot: goalTarget))
    }

    /// Advance any in-flight framing move. Returns true while still animating so
    /// the view can keep redrawing, then settle. Time-based `smoothstep`
    /// (ease-in-out) over the move's computed duration — frame-rate independent.
    /// Interpolates eye AND pivot as endpoints, then derives orientation from
    /// them; because the cap is baked into `goalEye`, a tilt-only re-aim (start
    /// eye == goal eye) holds the eye exactly fixed for every frame.
    @discardableResult
    mutating func step(now: Double) -> Bool {
        guard let f = framing else { return false }

        let raw = f.duration <= 0 ? 1 : (now - f.startTime) / f.duration
        let t = Float(min(max(raw, 0), 1))
        let e = t * t * (3 - 2 * t)             // smoothstep: zero velocity at both ends
        let eyeNow   = f.startEye + (f.goalEye - f.startEye) * e
        let pivotNow = f.startTarget + (f.goalTarget - f.startTarget) * e
        setOrbit(fromEye: eyeNow, pivot: pivotNow)

        if t >= 1 { framing = nil; return false }
        return true
    }

    // MARK: Orbit derivation

    /// Set target + azimuth/elevation/radius so the camera sits at `e` looking at
    /// `p`. No cap here — that's already resolved into the interpolation endpoints.
    private mutating func setOrbit(fromEye e: SIMD3<Float>, pivot p: SIMD3<Float>) {
        target = p
        let v = e - p
        let dist = length(v)
        guard dist > 1e-4 else { return }
        let u = v / dist
        azimuth = atan2(u.x, u.z)
        elevation = min(max(asin(min(max(u.y, -1), 1)), minElevation), maxElevation)
        radius = min(max(dist, minRadius), maxRadius)
    }

    /// Eye position for an arbitrary orbit state (same formula as `eye`).
    private func eyePosition(target t: SIMD3<Float>, azimuth a: Float,
                             elevation el: Float, radius r: Float) -> SIMD3<Float> {
        let ce = cos(el), se = sin(el), ca = cos(a), sa = sin(a)
        return t + SIMD3<Float>(ce * sa, se, ce * ca) * r
    }

    /// Duration for a framing move, scaled by how big the change is: the eye
    /// translation (position) and the look-direction swing (orientation), each
    /// normalized and the larger taken. Position saturates on a shorter reference,
    /// so repositioning reads as heavier/slower than a same-size pure re-aim.
    private func framingDuration(fromEye e0: SIMD3<Float>, toEye e1: SIMD3<Float>,
                                 fromPivot p0: SIMD3<Float>, toPivot p1: SIMD3<Float>) -> Double {
        let posAmount = min(length(e1 - e0) / eyeMoveReference, 1)
        let look0 = normalizeOrZero(p0 - e0)
        let look1 = normalizeOrZero(p1 - e1)
        let cosang = min(max(dot(look0, look1), -1), 1)
        let rotAmount = acos(cosang) / lookSwingReference
        let amount = Double(min(max(max(posAmount, rotAmount), 0), 1))
        return framingMinDuration + amount * (framingMaxDuration - framingMinDuration)
    }

    private func normalizeOrZero(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let len = length(v)
        return len > 1e-5 ? v / len : SIMD3<Float>(0, 0, 1)
    }

    // MARK: Matrices

    func viewMatrix() -> simd_float4x4 {
        .lookAt(eye: eye, center: target, up: SIMD3<Float>(0, 1, 0))
    }

    func projectionMatrix(aspect: Float) -> simd_float4x4 {
        var p = simd_float4x4.perspective(fovyRadians: fovy, aspect: aspect, near: near, far: far)
        // ndc.x of the pivot (on the view axis) equals -columns.2.x, so a negative
        // term here pushes content right into the sidebar-cleared region.
        p.columns.2.x = -lensShiftX
        return p
    }
}
