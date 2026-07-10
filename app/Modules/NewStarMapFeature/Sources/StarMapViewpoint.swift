import simd

/// A process-lived cache of the star map's imperative viewpoint — the camera pose
/// plus the orrery focus it's looking at.
///
/// The Metal view is torn down (and its `StarFieldRenderer` rebuilt) every time
/// you leave and return to the Stars tab, and again whenever a survey changes the
/// star terrain. Without this cache the camera would snap back to the overview and
/// any drilled-in system/planet would be lost on every such rebuild. TCA `State`
/// deliberately doesn't own this: the camera mutates every frame (eased framing,
/// auto-rotate), so persisting it there would churn the store on every tick — it
/// stays in the imperative render layer, matching the feature's camera-outside-TCA
/// design.
///
/// The live renderer reads this on creation — restoring exactly where you were, or
/// seeding the first-run dive when nothing is cached yet — and writes it each frame.
///
/// Left nonisolated to match the imperative render layer (renderer, camera, view
/// coordinator), which runs on the main thread by convention rather than by actor
/// isolation. `shared` is `nonisolated(unsafe)` for the same reason: every access
/// is a main-thread render/gesture callback, so there is no real data race.
final class StarMapViewpoint {
    /// The one instance shared across every renderer rebuild for the app's life.
    nonisolated(unsafe) static let shared = StarMapViewpoint()

    /// False until a renderer has captured this once. Distinguishes the very first
    /// appearance (seed the initial dive) from a later rebuild (restore what was
    /// here).
    private(set) var isSeeded = false

    // Camera pose (see `TurntableCamera`) + the drilled-level poses restored on
    // zoom-out.
    var camera = TurntableCamera()
    var cameraStack: [TurntableCamera] = []

    // Orrery focus, so a drilled-in system/planet is rebuilt exactly as it was.
    var systemProgress: Float = 0
    var systemFocused = false
    var orreryModel: SystemModel?
    var orreryCenter = SIMD3<Float>(repeating: 0)
    var orrerySunWorldPos = SIMD3<Float>(repeating: 0)
    var orreryScale: Float = 1
    var focusedStarIndex: Int?
    /// The picked star (drives the persistent label + relevance glow), so the
    /// selection highlight is restored alongside the camera, not just the dossier.
    var selectedStarIndex: Int?

    private init() {}

    func markSeeded() { isSeeded = true }
}
