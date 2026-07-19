import CStarMapShaderTypes
import MetalKit
import simd
import QuartzCore   // CACurrentMediaTime — the clock we feed the camera's easing

final class StarFieldRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let queue: MTLCommandQueue

    /// Process-lived cache of the camera pose + orrery focus, so this renderer
    /// (rebuilt on every tab switch / survey) restores where the player was rather
    /// than snapping back to the overview.
    private let viewpoint: StarMapViewpoint

    private let starPipeline: MTLRenderPipelineState        // additive glow field (no depth)
    private let bodyPipeline: MTLRenderPipelineState        // opaque resolved discs (write depth)
    private let tonemapPipeline: MTLRenderPipelineState
    private let meshPipeline: MTLRenderPipelineState
    private let shipLinePipeline: MTLRenderPipelineState
    private let stateMarkerPipeline: MTLRenderPipelineState
    private let labelPipeline: MTLRenderPipelineState
    private let ambientPipeline: MTLRenderPipelineState     // interstellar medium (additive, no depth)
    private let orreryBodyPipeline: MTLRenderPipelineState  // lit sun/planets (over-blend, depth-write)
    private let orreryLinePipeline: MTLRenderPipelineState  // orbit rings / HZ / kuiper (additive)
    private let orreryPointPipeline: MTLRenderPipelineState // asteroid belt (additive points)
    private let orreryPipPipeline: MTLRenderPipelineState   // body indicator + hazard pips (additive)
    private let orreryAtmoPipeline: MTLRenderPipelineState  // terrestrial atmosphere halos (additive, depth-read)

    // Depth: only the resolved bodies write it; the dense additive field never
    // does (Invariant 8). Overlays test against it to occlude behind bodies.
    private let bodyDepthState: MTLDepthStencilState        // test .less, write
    private let readDepthState: MTLDepthStencilState        // test .less, no write
    private let noDepthState: MTLDepthStencilState          // always, no write
    private var depthTexture: MTLTexture?
    private let depthFormat: MTLPixelFormat = .depth32Float
    /// Relevance at/above which a disc is drawn as a depth-writing opaque body;
    /// below it, the disc is drawn transparent (opacity ∝ relevance) without
    /// writing depth, so a de-emphasized star never hard-occludes a lit one.
    private let bodyOpaqueThreshold: Float = 0.9
    private let startTime = CACurrentMediaTime()   // base for surface animation (keeps Float precise)

    // Terrain: the star instance buffer, the domain array, and the relevance field
    // are swapped in place by `updateTerrain` (surveyed stars stream in) so the
    // renderer — and thus the live camera / framing / selection — is never torn
    // down. Rebuilding per survey page is what left the viewport black on first load.
    private var starBuffer: MTLBuffer
    private var stars: [Star]
    private(set) var relevance: RelevanceField

    // The interstellar medium behind the charted field: one additive point buffer.
    private let ambientBuffer: MTLBuffer?
    private let ambientVertexCount: Int

    // Volumetric nebulae: additive world-space billboard puffs (NebulaField), diffused
    // around the surveyed stars. The buffer is rebuilt in place when the tuning config
    // changes (from the HUD panel) or the terrain changes; the render knobs are a
    // per-frame uniform, so they cost nothing to tweak. Drawn in the pre-pass with the
    // ambient dust, faded/receded with the galaxy on drill-in.
    private var nebulaBuffer: MTLBuffer?
    private var nebulaCount = 0
    private var nebulaParams = NebulaRenderParams.live
    private let nebulaConfig = NebulaConfig()
    private let nebulaPipeline: MTLRenderPipelineState

    // System-focus (orrery). Bodies are billboard sphere-impostors (no mesh);
    // scaffold/belt buffers are rebuilt per drill-in. The orrery is scaled to the
    // focused star's angular framing so drilling reads as a zoom IN, and the sun
    // uses the star field's angular clamp so it matches the star it grew from.
    private var systemFocused = false
    private var orreryModel: SystemModel?
    private var orreryCenter = SIMD3<Float>(repeating: 0)   // world centre of the orrery (star, or a planet at body level)
    private var orrerySunWorldPos = SIMD3<Float>(repeating: 0)  // light source (the system star), for lit bodies
    private var orreryScale: Float = 1          // scene-unit → world (ly) around the centre
    private var focusedStarIndex: Int?          // the system star = the orrery sun (uncapped, unfaded); kept at body level too
    private var cameraStack: [TurntableCamera] = []   // pose per drilled level, restored on zoom-out
    private var orreryLineBuffer: MTLBuffer?
    private var orreryLineVertexCount = 0
    private var orreryHZBuffer: MTLBuffer?          // habitable-zone filled band (triangles)
    private var orreryHZVertexCount = 0
    private var orreryBeltBuffer: MTLBuffer?
    private var orreryBeltCount = 0
    // One time-based transition progress (0 = galaxy, 1 = system focus). The
    // crossfade, orrery reveal + emerge, and camera fly are ALL driven from this
    // over ONE shared duration, so they start and land together in both directions.
    private var systemProgress: Float = 0
    private var transitionFrom: Float = 0
    private var transitionTarget: Float = 0
    private var transitionStart: Double = 0
    private var transitionDuration: Double = 0.0001
    private var fieldDim: Float { 1 - systemProgress * (1 - fieldFloor) }   // terrain fade to a faint backdrop
    private var orreryReveal: Float { systemProgress }   // orrery reveal + emerge scale
    /// Galaxy-overlay opacity (FTL mesh, ships, player/relay markers). Direction-aware
    /// off the active `transitionTarget` (1 = drilling into a system, 0 = zooming back
    /// to the galaxy): fades OUT fast over the first half of a drill in (reveal 0→0.5),
    /// then fades back IN gently over the WHOLE zoom out (reveal 1→0). Full-span on the
    /// way out matters because the transition's smoothstep is fastest at the midpoint —
    /// starting the fade there (as a symmetric curve would) coincides with peak camera
    /// velocity and reads as a pop; spreading it across the pull-back keeps it gradual.
    /// At the settled ends both branches agree (reveal 0 → 1, reveal 1 → 0), so
    /// direction only matters mid-flight. Body-level moves hold reveal at 1 → hidden.
    private var overlayDim: Float {
        transitionTarget >= 0.5
            ? max(0, 1 - orreryReveal * 2)   // drilling in: gone by reveal 0.5
            : 1 - orreryReveal               // zooming out: fade in across the whole pull-back
    }
    /// Drill/zoom durations (seconds); match the reducer's transition lock.
    private let drillDurationBase = 1.15
    private let zoomDurationBase = 0.95

    /// Whether the active orrery is body-level (a planet + its moons) rather than
    /// system-level (the focused star + its planets). Drives the `bodyProgress` fade
    /// direction for each cross-fading layer.
    private var orreryIsBody = false
    /// System↔body cross-fade (0 = system view, 1 = drilled into a planet), on its
    /// own eased clock (like `systemProgress`). While a drill/zoom between the two
    /// levels is in flight, `departing` holds the layer being left behind so both
    /// render in one frame — the sibling planets + sun fade out while the drilled
    /// planet + its moons fade in (and vice-versa on the way back).
    private var bodyProgress: Float = 0
    private var bodyFrom: Float = 0
    private var bodyTarget: Float = 0
    private var bodyStart: Double = 0
    private var bodyDuration: Double = 0.0001
    /// The orrery layer being transitioned away from — the system when drilling into
    /// a planet, the planet when zooming back out. Carries its own centre / sun /
    /// scale / scaffold buffers so it renders exactly where it sits, independent of
    /// the arriving layer, and is dropped once the cross-fade settles.
    private var departing: DepartingOrrery?

    /// An orrery model update (e.g. a body hydrate landing) that arrived while a
    /// drill/zoom was in flight. Rebuilding the orrery does CPU geometry generation
    /// plus buffer allocation on the render thread; doing that mid-fly drops a frame
    /// or two. So it's stashed here and applied in `draw` once the transition settles,
    /// where a one-frame rebuild on a static camera is imperceptible.
    private var pendingOrreryModel: SystemModel?

    private struct DepartingOrrery {
        var model: SystemModel
        var center: SIMD3<Float>
        var sunWorldPos: SIMD3<Float>
        var scale: Float
        var isBody: Bool
        var lineBuffer: MTLBuffer?
        var lineCount: Int
        var hzBuffer: MTLBuffer?
        var hzCount: Int
        var beltBuffer: MTLBuffer?
        var beltCount: Int
    }

    /// Orbit-animation clock (seconds). Advances with real time EXCEPT while focused
    /// on / transitioning to a body, when it FREEZES — so a drilled planet (and its
    /// siblings) hold their positions rather than orbiting out from under the camera,
    /// and resume exactly where they paused on the way back (an accumulator, so
    /// freezing/unfreezing never jumps). Surface spin/flares use `time` (never frozen).
    private var orbitClock: Float = 0
    /// The drilled planet's rendered radius in the SYSTEM view (world units). The
    /// body-level central body grows from this to its full body radius across
    /// `bodyProgress`, so the planet is continuous with its system self at the start
    /// of the drill (no size pop) yet ends up comfortably sun-sized. 0 = not drilling.
    private var bodyCentralStartRadius: Float = 0
    /// Designation of the drilled planet, so a SYSTEM layer can SKIP it (it's drawn
    /// once as the continuous central body, never blended against a second copy).
    /// Set on `enterBody`, cleared once fully back at system level.
    private var bodyPlanetID: String?

    /// The distant lighting-sun position for a body centred at `planet`, along the
    /// true direction to the system star (see `enterBody`).
    private func bodySunPosition(planet: SIMD3<Float>, starIndex: Int?, distance: Float) -> SIMD3<Float> {
        let starPos = starIndex.map { stars[$0].position } ?? (planet + SIMD3<Float>(1, 0, 0))
        let toStar = starPos - planet
        let dir = simd_length(toStar) > 1e-6 ? simd_normalize(toStar) : SIMD3<Float>(1, 0, 0)
        return planet + dir * distance
    }

    /// A cross-fading orrery layer's opacity at the current `bodyProgress`: a
    /// body-level layer fades IN with it (0→1); a system-level layer fades OUT
    /// (1→0). At the settled ends one layer is fully shown and the other is gone.
    private func layerOpacity(isBody: Bool) -> Float {
        isBody ? bodyProgress : 1 - bodyProgress
    }

    /// Start the eased system↔body cross-fade toward `target` (0 = system, 1 = body).
    private func beginBodyTransition(to target: Float, duration: Double, now: Double) {
        bodyFrom = bodyProgress
        bodyTarget = target
        bodyStart = now
        bodyDuration = max(duration, 0.0001)
    }

    /// Pin `bodyProgress` to a settled value with no in-flight fade — used when the
    /// active orrery is a system (galaxy↔system moves never cross the body level).
    private func settleBodyProgress(_ v: Float) {
        bodyProgress = v; bodyFrom = v; bodyTarget = v
        bodyStart = 0; bodyDuration = 0.0001
    }

    /// True while either eased clock (the shared galaxy↔system transition or the
    /// system↔body cross-fade) is still animating — used to defer main-thread orrery
    /// rebuilds off the fly. A settled clock has its end time in the past, so this
    /// reads false at rest.
    private func transitionInFlight(now: Double) -> Bool {
        now < transitionStart + transitionDuration || now < bodyStart + bodyDuration
    }

    /// Snapshot the active orrery (model + centre/sun/scale + scaffold buffers) into
    /// a departing layer, so it keeps rendering — where it truly sits — while the
    /// next level fades in over it. Captured BEFORE `setOrreryModel` swaps in the new
    /// roster (which reassigns the instance buffers; the snapshot retains the old).
    private func snapshotActiveOrrery(isBody: Bool) -> DepartingOrrery? {
        guard let model = orreryModel else { return nil }
        return DepartingOrrery(
            model: model, center: orreryCenter, sunWorldPos: orrerySunWorldPos,
            scale: orreryScale, isBody: isBody,
            lineBuffer: orreryLineBuffer, lineCount: orreryLineVertexCount,
            hzBuffer: orreryHZBuffer, hzCount: orreryHZVertexCount,
            beltBuffer: orreryBeltBuffer, beltCount: orreryBeltCount)
    }

    // Labels: the curated annotation layer. Rasterized-text cache + which star is
    // selected (always labelled), plus how many context labels to show.
    private let labelCache: LabelTextureCache
    private var selectedStarIndex: Int?
    private(set) var showSymbols = true      // status-symbol row under each label
    private var maxContextLabels = 20
    private let labelRingFloor: Float = 8    // min reticle radius the label clears (px)
    private let labelGap: Float = 5          // extra gap below the ring (px)
    private var labelOpacity: [Int: Float] = [:]   // per-star eased fade (starIndex → 0…1)
    private var lastLabelTime: Double = 0
    private let labelFadeTau: Double = 0.06        // fade time constant (quick)
    // Labels belong to the galaxy overview. They fade to nothing as the camera
    // drills into a system — decoupled from `fieldDim` (which now floors at a
    // faint backdrop) so they reach true 0 and stay silent while orbiting the
    // orrery. Gain > 1 clears them within the first fraction of the drill, so the
    // whole layout/projection pass can be skipped for the rest of the transition.
    private let labelFadeGain: Float = 2         // 0 at systemProgress = 1/gain
    private var labelDim: Float { max(0, 1 - systemProgress * labelFadeGain) }

    // FTL mesh overlay: precomputed once (links as quad-ribbon vertices, relay
    // marker positions, and the per-star relevance contribution), toggled at runtime.
    // Overlay geometry/relevance are rebuilt in place by `applyOverlays` (from
    // `init`, and again when the live FTL mesh / ships change) so an overlay
    // refresh never tears down the renderer — the live camera + interaction survive.
    private var meshLineBuffer: MTLBuffer?
    private var meshLineVertexCount = 0
    private var relayMarkerBuffer: MTLBuffer?     // one ring StateMarker per relay
    private var relayMarkerCount = 0
    private var meshContribution: [Float] = []
    private(set) var meshActive = false
    private var activeFilter: DataFilter?   // active data-filter overlay, if any
    private var meshLineHalfWidth: Float = 0.6   // link half-thickness in pixels

    // State overlay: the player and their ships. Always drawn, never dimmed.
    private var playerStarIndex = 0
    private var ships: [Ship] = []
    private var shipLineBuffer: MTLBuffer?        // 6 ribbon vertices per polyline segment
    /// Per polyline-segment metadata for the ship ribbons: the 6-vertex start offset in
    /// `shipLineBuffer`, the segment's endpoint stars, and which ship it belongs to. A ship
    /// spanning N distinct systems contributes N−1 segments (the common trip has one).
    private var shipSegments: [(vertexStart: Int, aStar: Int, bStar: Int, shipIndex: Int)] = []
    private var shipLineHalfWidth: Float = 1.6    // trajectory thickness in pixels
    // Trajectory dash cadence. Each visible dash aims for `shipDashWorldLength` in
    // world units, but is clamped to a screen-space pixel band so dashes never
    // balloon on zoom-in or vanish on zoom-out (see `encodeStateOverlay`).
    private var shipDashWorldLength: Float = 0.25   // target visible-dash length (world units / ly)
    private var shipDashMinPixels: Float = 4        // clamp: shortest visible dash on screen
    private var shipDashMaxPixels: Float = 40       // clamp: longest visible dash on screen
    private var playerMarkerRadius: Float = 14    // player reticle radius in pixels (clears the relay ring's 8px floor)
    private var shipHeadRadius: Float = 6         // ship comet-head radius in pixels
    // The inbound/outbound transit riser height, as a fraction of the framed system
    // radius (`SystemModel.frameScene`) so it stays proportional at system and body level.
    private var transitRiserFraction: Float = 0.32
    private let playerColor = SIMD3<Float>(1.0, 0.82, 0.35)   // gold
    private let shipColor   = SIMD3<Float>(0.55, 0.95, 1.0)   // bright cyan-white

    /// Pushed each frame with the ships' projected screen points (view points,
    /// top-left) so the SwiftUI overlay can float a tappable device icon over each
    /// pip. Set by `MetalStarView`; nil until then. Invoked on the main thread (the
    /// MTKView draws there), so the closure may hop to the main-actor overlay model.
    var onShipsProjected: (([ProjectedShip]) -> Void)?

    /// Pushed each frame with the device clusters' projected screen points (view points,
    /// top-left) while focused into a system, so the SwiftUI overlay floats one tappable
    /// badge over each occupied location. nil until set by `MetalStarView`. Empty in the
    /// galaxy (clusters are a system-focus overlay).
    var onClustersProjected: (([ProjectedCluster]) -> Void)?

    /// Pushed each frame with the inbound/outbound transit callouts' projected screen points
    /// (the top of each dotted riser) while focused into a system, so the SwiftUI overlay
    /// floats a "Traveling from/to …" card at each boundary crossing. nil until set by
    /// `MetalStarView`. Empty in the galaxy and for routes that don't touch the view.
    var onTransitsProjected: (([ProjectedTransit]) -> Void)?
    /// Device-presence clusters, grouped by the anchor the focused level draws (built by
    /// the view from the live roster + scan blob). Projected each frame in `draw`.
    private var deviceClusters: [DeviceCluster] = []
    /// The location the player has picked (mirrored from the reducer). A planet's Lagrange
    /// points are only drawn/pickable when that planet (or the point itself) is selected —
    /// otherwise only occupied points show, so an idle system isn't cluttered with ticks.
    var selectedLocationCode: String?

    /// Whether a planet's Lagrange point should be shown + pickable: a device sits on it,
    /// or the current selection belongs to this planet (the planet itself or any of its
    /// Lagrange points) — so all 5 stay visible while cycling among them.
    private func lagrangeVisible(_ lp: LagrangePoint, planet: OrreryPlanet) -> Bool {
        if deviceClusters.contains(where: { $0.anchorCode == lp.designation }) { return true }
        guard let sel = selectedLocationCode else { return false }
        return sel == planet.id || OrreryLayout.parent(of: sel) == planet.id
    }

    private var hdrTexture: MTLTexture?
    private var aspect: Float = 1

    var camera = TurntableCamera()

    /// Hands-off azimuth spin, enabled from the HUD's Auto-rotate control. The
    /// spin only begins after a calm period (no viewport input, no eased camera
    /// move) and eases in/out via `spinEnvelope`; advanced per-frame in `draw`.
    var autoRotate = false
    private let autoRotateRate: Float = -0.12       // radians / second at full spin
    private var lastFrameTime = CACurrentMediaTime()
    private var lastInteractionTime = CACurrentMediaTime()
    private var spinEnvelope: Float = 0            // eased 0…1 rate scale
    private let autoRotateIdleDelay: Double = 3    // seconds of calm before it spins
    private let spinEaseInTau: Float = 1.6         // gentle ramp up
    private let spinEaseOutTau: Float = 0.28       // quick, smooth stop on input

    // Tunables (all the knobs the design discussion surfaced, in one place).
    private var minAngularSize: Float = 0.0015   // floor: distant stars stay visible
    private var maxAngularSize: Float = 0.05     // ceiling: near stars can't fill the view
    // Orbit timing (dialed-in constants). Rather than a flat multiplier on period-days —
    // which let a short-period inner planet whip around too fast to click — every planet's
    // on-screen period scales off the system's *fastest* so that quickest orbit lands at
    // `orreryMinPeriod` seconds, and `orreryPeriodFalloff` (0…1) compresses the spread so
    // outer planets still drift rather than going inert. See `orbitPeriodSeconds`.
    private let orreryMinPeriod: Float = 75
    private let orreryPeriodFalloff: Float = 0.55
    private var atmoNear: Float = 40             // depth dimming band
    private var atmoFar: Float = 420
    private var atmoFloor: Float = 0.35          // atmospheric floor (≠ semantic floor)
    private var exposure: Float = 1.3            // global tone-map exposure
    private var lodStart: Float = 0.004          // angular size where the disc begins to appear
    private var lodFull: Float = 0.018           // angular size where it's a full luminous disc
    private var overviewRadius: Float = 180      // home / overview pull-back distance
    private var diveRadius: Float = 6           // double-click close-focus distance
    // Orrery elevation policy: while focused on an orrery (system or planet) the
    // camera is held to an oblique band — never edge-on or fully top-down — and
    // drilling into a system tilts onto the orbital plane at a fixed entry angle
    // (keeping the current azimuth). Galaxy view keeps the camera's default
    // symmetric range, restored on zoom-out from the saved pre-drill pose.
    private let orreryMinElevation: Float = 5 * .pi / 180
    private let orreryMaxElevation: Float = 85 * .pi / 180
    private let orreryEntryElevation: Float = 25 * .pi / 180
    // System-focus recession (see ShaderTypes.Uniforms): how far the background
    // field is pushed away from the focused star and how far it shrinks at full
    // drill-in, plus the residual field brightness kept as a backdrop (so the
    // galaxy recedes to faint dust behind the orrery instead of fading to black).
    private var systemPush: Float = 2.0
    private var fieldShrink: Float = 0.4
    private var fieldFloor: Float = 0.15

    /// Builds the renderer for a fixed terrain of `stars` plus the live `overlays`
    /// (FTL mesh links + ships in transit). The domain `[Star]` is the source of
    /// truth (supplied by the caller from the live `Star` table rather than
    /// `Galaxy.generate()`); the GPU buffer is its render projection. Returns nil
    /// for an empty terrain — the view shows a placeholder until the galaxy has
    /// been surveyed.
    init?(mtkView: MTKView, stars: [Star], overlays: StarMapOverlays, viewpoint: StarMapViewpoint) {
        guard !stars.isEmpty,
              let device = mtkView.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: .module)
        else { return nil }

        self.device = device
        self.queue = queue
        self.viewpoint = viewpoint

        // Static terrain geometry — uploaded once.
        let instances = stars.map(\.renderInstance)
        guard let starBuffer = device.makeBuffer(
            bytes: instances,
            length: instances.count * MemoryLayout<StarInstance>.stride,
            options: .storageModeShared),
              let relevance = RelevanceField(device: device, positions: stars.map(\.position))
        else { return nil }
        self.stars = stars
        self.starBuffer = starBuffer
        self.relevance = relevance

        labelCache = LabelTextureCache(device: device)

        // Ambient interstellar medium: one additive point-sprite buffer, generated
        // once and drawn behind the terrain.
        let ambientMotes = AmbientField.generate()
        ambientVertexCount = ambientMotes.count
        ambientBuffer = ambientMotes.isEmpty ? nil : device.makeBuffer(
            bytes: ambientMotes,
            length: ambientMotes.count * MemoryLayout<AmbientVertex>.stride,
            options: .storageModeShared)

        // Volumetric nebulae, diffused around the actual surveyed stars.
        let puffs = NebulaField.generate(config: nebulaConfig, stars: stars.map(\.position))
        nebulaCount = puffs.count
        nebulaBuffer = puffs.isEmpty ? nil : device.makeBuffer(
            bytes: puffs,
            length: puffs.count * MemoryLayout<NebulaPuff>.stride,
            options: .storageModeShared)

        // Every pipeline drawing into the HDR pass must declare its depth format
        // (the pass now has a depth attachment for the resolved-body occlusion).
        let depthPF: MTLPixelFormat = .depth32Float

        // Pass 1a: additive glow field into the HDR target. Base layer, no depth.
        let starDesc = MTLRenderPipelineDescriptor()
        starDesc.vertexFunction = library.makeFunction(name: "star_vertex")
        starDesc.fragmentFunction = library.makeFunction(name: "star_fragment")
        Self.configureAdditiveHDR(starDesc.colorAttachments[0]!)
        starDesc.depthAttachmentPixelFormat = depthPF

        // Pass 1b: opaque resolved discs. Straight "over" blend so they cover the
        // glow behind them; they write depth (via the body depth-stencil state).
        let bodyDesc = MTLRenderPipelineDescriptor()
        bodyDesc.vertexFunction = library.makeFunction(name: "star_vertex")
        bodyDesc.fragmentFunction = library.makeFunction(name: "star_body_fragment")
        let bca = bodyDesc.colorAttachments[0]!
        bca.pixelFormat = .rgba16Float
        bca.isBlendingEnabled = true
        bca.rgbBlendOperation = .add
        bca.alphaBlendOperation = .add
        bca.sourceRGBBlendFactor = .sourceAlpha               // "over" (not premultiplied)
        bca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        bca.sourceAlphaBlendFactor = .one
        bca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        bodyDesc.depthAttachmentPixelFormat = depthPF

        // Ambient field points (additive, no depth — drawn behind the terrain).
        let ambientDesc = MTLRenderPipelineDescriptor()
        ambientDesc.vertexFunction = library.makeFunction(name: "ambient_vertex")
        ambientDesc.fragmentFunction = library.makeFunction(name: "ambient_fragment")
        Self.configureAdditiveHDR(ambientDesc.colorAttachments[0]!)
        ambientDesc.depthAttachmentPixelFormat = depthPF

        // Nebula billboards (additive HDR, no depth — the volumetric clouds).
        let nebulaDesc = MTLRenderPipelineDescriptor()
        nebulaDesc.vertexFunction = library.makeFunction(name: "nebula_vertex")
        nebulaDesc.fragmentFunction = library.makeFunction(name: "nebula_fragment")
        Self.configureAdditiveHDR(nebulaDesc.colorAttachments[0]!)
        nebulaDesc.depthAttachmentPixelFormat = depthPF

        // Orrery bodies: lit sun/planets, over-blend + depth write so they occlude.
        let orreryBodyDesc = MTLRenderPipelineDescriptor()
        orreryBodyDesc.vertexFunction = library.makeFunction(name: "orrery_body_vertex")
        orreryBodyDesc.fragmentFunction = library.makeFunction(name: "orrery_body_fragment")
        let oba = orreryBodyDesc.colorAttachments[0]!
        oba.pixelFormat = .rgba16Float
        oba.isBlendingEnabled = true
        oba.rgbBlendOperation = .add
        oba.alphaBlendOperation = .add
        oba.sourceRGBBlendFactor = .sourceAlpha
        oba.destinationRGBBlendFactor = .oneMinusSourceAlpha
        oba.sourceAlphaBlendFactor = .one
        oba.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        orreryBodyDesc.depthAttachmentPixelFormat = depthPF

        // Orrery scaffold lines + belt points: additive HDR, depth-read only.
        let orreryLineDesc = MTLRenderPipelineDescriptor()
        orreryLineDesc.vertexFunction = library.makeFunction(name: "orrery_line_vertex")
        orreryLineDesc.fragmentFunction = library.makeFunction(name: "orrery_line_fragment")
        Self.configureAdditiveHDR(orreryLineDesc.colorAttachments[0]!)
        orreryLineDesc.depthAttachmentPixelFormat = depthPF

        let orreryPointDesc = MTLRenderPipelineDescriptor()
        orreryPointDesc.vertexFunction = library.makeFunction(name: "orrery_point_vertex")
        orreryPointDesc.fragmentFunction = library.makeFunction(name: "orrery_point_fragment")
        Self.configureAdditiveHDR(orreryPointDesc.colorAttachments[0]!)
        orreryPointDesc.depthAttachmentPixelFormat = depthPF

        // Orrery pips: small billboard indicator dots + hazard markers, additive.
        let orreryPipDesc = MTLRenderPipelineDescriptor()
        orreryPipDesc.vertexFunction = library.makeFunction(name: "orrery_pip_vertex")
        orreryPipDesc.fragmentFunction = library.makeFunction(name: "orrery_pip_fragment")
        Self.configureAdditiveHDR(orreryPipDesc.colorAttachments[0]!)
        orreryPipDesc.depthAttachmentPixelFormat = depthPF

        // Orrery atmosphere halos: soft glow shells beyond terrestrial limbs. Additive
        // HDR, depth-READ (occluded by a nearer body, never writes depth) — drawn after
        // the opaque bodies so a halo composites over the background and the sun.
        let orreryAtmoDesc = MTLRenderPipelineDescriptor()
        orreryAtmoDesc.vertexFunction = library.makeFunction(name: "orrery_atmosphere_vertex")
        orreryAtmoDesc.fragmentFunction = library.makeFunction(name: "orrery_atmosphere_fragment")
        Self.configureAdditiveHDR(orreryAtmoDesc.colorAttachments[0]!)
        orreryAtmoDesc.depthAttachmentPixelFormat = depthPF

        // Mesh links (additive, depth-tested so a body in front occludes them).
        let meshDesc = MTLRenderPipelineDescriptor()
        meshDesc.vertexFunction = library.makeFunction(name: "mesh_vertex")
        meshDesc.fragmentFunction = library.makeFunction(name: "mesh_fragment")
        Self.configureAdditiveHDR(meshDesc.colorAttachments[0]!)
        meshDesc.depthAttachmentPixelFormat = depthPF

        // Overlay pipelines: ship trajectory ribbons, and the shared marker
        // pipeline for rings (player, relays) and glows (ship heads).
        let shipLineDesc = MTLRenderPipelineDescriptor()
        shipLineDesc.vertexFunction = library.makeFunction(name: "ship_line_vertex")
        shipLineDesc.fragmentFunction = library.makeFunction(name: "ship_line_fragment")
        Self.configureAdditiveHDR(shipLineDesc.colorAttachments[0]!)
        shipLineDesc.depthAttachmentPixelFormat = depthPF

        let stateMarkerDesc = MTLRenderPipelineDescriptor()
        stateMarkerDesc.vertexFunction = library.makeFunction(name: "state_marker_vertex")
        stateMarkerDesc.fragmentFunction = library.makeFunction(name: "state_marker_fragment")
        Self.configureAdditiveHDR(stateMarkerDesc.colorAttachments[0]!)
        stateMarkerDesc.depthAttachmentPixelFormat = depthPF

        // Pass 2 pipeline: fullscreen tone-map to the drawable.
        let tmDesc = MTLRenderPipelineDescriptor()
        tmDesc.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
        tmDesc.fragmentFunction = library.makeFunction(name: "tonemap_fragment")
        tmDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat

        // Label pipeline: textured text quads composited over the drawable
        // (premultiplied-alpha "over", not additive — text sits on the image).
        let labelDesc = MTLRenderPipelineDescriptor()
        labelDesc.vertexFunction = library.makeFunction(name: "label_vertex")
        labelDesc.fragmentFunction = library.makeFunction(name: "label_fragment")
        let lca = labelDesc.colorAttachments[0]!
        lca.pixelFormat = mtkView.colorPixelFormat
        lca.isBlendingEnabled = true
        lca.rgbBlendOperation = .add
        lca.alphaBlendOperation = .add
        lca.sourceRGBBlendFactor = .one                       // texture is premultiplied
        lca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        lca.sourceAlphaBlendFactor = .one
        lca.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            starPipeline = try device.makeRenderPipelineState(descriptor: starDesc)
            bodyPipeline = try device.makeRenderPipelineState(descriptor: bodyDesc)
            meshPipeline = try device.makeRenderPipelineState(descriptor: meshDesc)
            shipLinePipeline = try device.makeRenderPipelineState(descriptor: shipLineDesc)
            stateMarkerPipeline = try device.makeRenderPipelineState(descriptor: stateMarkerDesc)
            tonemapPipeline = try device.makeRenderPipelineState(descriptor: tmDesc)
            labelPipeline = try device.makeRenderPipelineState(descriptor: labelDesc)
            ambientPipeline = try device.makeRenderPipelineState(descriptor: ambientDesc)
            nebulaPipeline = try device.makeRenderPipelineState(descriptor: nebulaDesc)
            orreryBodyPipeline = try device.makeRenderPipelineState(descriptor: orreryBodyDesc)
            orreryLinePipeline = try device.makeRenderPipelineState(descriptor: orreryLineDesc)
            orreryPointPipeline = try device.makeRenderPipelineState(descriptor: orreryPointDesc)
            orreryPipPipeline = try device.makeRenderPipelineState(descriptor: orreryPipDesc)
            orreryAtmoPipeline = try device.makeRenderPipelineState(descriptor: orreryAtmoDesc)
        } catch {
            assertionFailure("Pipeline creation failed: \(error)")
            return nil
        }

        // Depth-stencil states: bodies write depth; overlays read it (occluded by a
        // nearer body); ship head markers ignore it (always on top).
        let bd = MTLDepthStencilDescriptor()
        bd.depthCompareFunction = .less; bd.isDepthWriteEnabled = true
        let rd = MTLDepthStencilDescriptor()
        rd.depthCompareFunction = .less; rd.isDepthWriteEnabled = false
        let nd = MTLDepthStencilDescriptor()
        nd.depthCompareFunction = .always; nd.isDepthWriteEnabled = false
        guard let bodyDepth = device.makeDepthStencilState(descriptor: bd),
              let readDepth = device.makeDepthStencilState(descriptor: rd),
              let noDepth = device.makeDepthStencilState(descriptor: nd)
        else { return nil }
        bodyDepthState = bodyDepth
        readDepthState = readDepth
        noDepthState = noDepth

        super.init()

        // Extend the far plane to contain the ambient backdrop + star shell + the
        // distant nebula shell (pushed out further by the nebula `scale`), all of
        // which sit far beyond the charted bubble.
        camera.far = 12000

        // Bake the initial overlays (FTL mesh + ships) into their buffers/relevance.
        // Later overlay changes route through `updateOverlays` (in place), so the
        // renderer is never torn down while the player is interacting with it.
        applyOverlays(overlays)

        // Restore where the player last was (survives tab switches + surveys), or
        // seed the first-run dive on the current-location star.
        if viewpoint.isSeeded {
            restoreViewpoint()
        } else {
            frameInitialDive()
            viewpoint.markSeeded()
            persistViewpoint()
        }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        aspect = size.height > 0 ? Float(size.width / size.height) : 1
        makeHDRTexture(size: size)
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastFrameTime, 0), 0.1))   // clamp long stalls
        lastFrameTime = now
        advanceAutoRotate(now: now, dt: dt)
        relevance.step()                     // advance eased relevance transitions
        // Freeze orbital motion while focused on / transitioning to a body, so the
        // drilled planet holds still (no camera-follow needed) and its siblings stay
        // put; it resumes seamlessly from the same phase on the way back out.
        if !(orreryIsBody || departing != nil) { orbitClock += dt }
        camera.step(now: now)                // advance eased camera framing

        // Advance the shared transition progress (time-based smoothstep — a real
        // start and end), then drop the orrery only once fully back to the galaxy,
        let raw = Float(min(max((now - transitionStart) / transitionDuration, 0), 1))
        let eased = raw * raw * (3 - 2 * raw)
        systemProgress = transitionFrom + (transitionTarget - transitionFrom) * eased
        // The system↔body cross-fade runs on its own eased clock. Once it settles,
        // drop the layer we transitioned away from (its buffers are then free).
        let bRaw = Float(min(max((now - bodyStart) / bodyDuration, 0), 1))
        let bEased = bRaw * bRaw * (3 - 2 * bRaw)
        bodyProgress = bodyFrom + (bodyTarget - bodyFrom) * bEased
        if bRaw >= 1 {
            departing = nil
            if !orreryIsBody { bodyCentralStartRadius = 0; bodyPlanetID = nil }   // back at system level
        }
        // Apply an orrery update that arrived mid-fly now that both clocks have settled
        // and the camera is static — the rebuild's one-frame cost isn't perceptible here
        // (deferred in `updateOrrery` precisely to keep it off the fly).
        if let pending = pendingOrreryModel, raw >= 1, bRaw >= 1 {
            pendingOrreryModel = nil
            applyOrreryUpdate(pending)
        }
        // `focusedStarIndex` is intentionally NOT cleared on zoom-out: the star that
        // was drilled stays "focused" (it's the sun throughout, so no snap-flicker,
        // and it remains the focused star back in the galaxy).

        // Capture the live viewpoint each frame so the next renderer rebuild (tab
        // switch / survey) lands exactly here. Cheap: value types + COW model arrays.
        persistViewpoint()

        guard let hdr = hdrTexture,
              let drawable = view.currentDrawable,
              let screenPass = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer()
        else { return }

        var uniforms = makeUniforms()

        // --- Pass 1: stars → HDR ---
        let hdrPass = MTLRenderPassDescriptor()
        hdrPass.colorAttachments[0].texture = hdr
        hdrPass.colorAttachments[0].loadAction = .clear
        hdrPass.colorAttachments[0].storeAction = .store
        hdrPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        hdrPass.depthAttachment.texture = depthTexture
        hdrPass.depthAttachment.loadAction = .clear
        hdrPass.depthAttachment.clearDepth = 1.0
        hdrPass.depthAttachment.storeAction = .dontCare   // never read back → free on TBDR

        if let enc = cmd.makeRenderCommandEncoder(descriptor: hdrPass) {
            // 1(pre) — the interstellar medium behind everything (additive, no depth):
            // the ambient dust/protostar/shell points first, then the volumetric nebulae
            // over them.
            if let ambientBuffer, ambientVertexCount > 0 {
                enc.setRenderPipelineState(ambientPipeline)
                enc.setDepthStencilState(noDepthState)
                enc.setVertexBuffer(ambientBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: ambientVertexCount)
            }
            if let nebulaBuffer, nebulaCount > 0 {
                enc.setRenderPipelineState(nebulaPipeline)
                enc.setDepthStencilState(noDepthState)
                enc.setVertexBuffer(nebulaBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.setVertexBytes(&nebulaParams, length: MemoryLayout<NebulaRenderParams>.stride, index: 2)
                enc.setFragmentBytes(&nebulaParams, length: MemoryLayout<NebulaRenderParams>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                   instanceCount: nebulaCount)
            }

            // 1a — additive glow field (base layer, no depth).
            enc.setRenderPipelineState(starPipeline)
            enc.setDepthStencilState(noDepthState)
            enc.setVertexBuffer(starBuffer, offset: 0, index: 0)
            enc.setVertexBuffer(relevance.buffer, offset: 0, index: 1)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)  // time, for animated flares
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: stars.count)

            // 1b — resolved discs. Opacity ∝ relevance (dimming is pure transparency,
            // separate from LOD). Two slices over the same instanced geometry:
            //   opaque slice (relevance ≥ threshold) — over-blend + WRITE depth,
            //     covering the glow behind and occluding other bodies/overlays;
            //   dim slice (relevance < threshold) — drawn after, transparent,
            //     depth-tested but NOT writing, so a receded star never hard-occludes
            //     a lit one behind it (you see the lit star through the ghost).
            // Always drawn: in system focus the non-focused stars fade to zero and
            // DISCARD (writing no depth, so the orrery shows through), while the
            // focused star stays — it IS the sun, growing seamlessly.
            enc.setRenderPipelineState(bodyPipeline)
            enc.setVertexBuffer(starBuffer, offset: 0, index: 0)
            enc.setVertexBuffer(relevance.buffer, offset: 0, index: 1)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)  // view/time

            var opaqueRange = SIMD2<Float>(bodyOpaqueThreshold, 2)
            enc.setDepthStencilState(bodyDepthState)
            enc.setFragmentBytes(&opaqueRange, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: stars.count)

            var dimRange = SIMD2<Float>(0, bodyOpaqueThreshold)
            enc.setDepthStencilState(readDepthState)
            enc.setFragmentBytes(&dimRange, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: stars.count)

            // Overlays into the same HDR target. Screen-space sizing needs the
            // drawable dimensions.
            let size = view.drawableSize
            var params = MeshParams(
                viewportPixels: SIMD2<Float>(Float(size.width), Float(size.height)),
                halfWidthPixels: meshLineHalfWidth,
                nodeRadiusPixels: 0)

            // Galaxy overlays (mesh + state) — encoded whenever they carry any opacity;
            // the shader fades them via `overlayDim` (out fast on drill-in, in gently
            // across the whole zoom-out). Skipped entirely once fully faded.
            if overlayDim > 0.001 {
                // FTL mesh (reference overlay, toggled), depth-tested so a body in
                // front occludes it: link ribbons, then relay rings on top.
                if meshActive {
                    enc.setDepthStencilState(readDepthState)
                    if let meshLineBuffer, meshLineVertexCount > 0 {
                        enc.setRenderPipelineState(meshPipeline)
                        enc.setVertexBuffer(meshLineBuffer, offset: 0, index: 0)
                        enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                        enc.setVertexBytes(&params, length: MemoryLayout<MeshParams>.stride, index: 2)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: meshLineVertexCount)
                    }
                    if let relayMarkerBuffer, relayMarkerCount > 0 {
                        enc.setRenderPipelineState(stateMarkerPipeline)
                        enc.setVertexBuffer(relayMarkerBuffer, offset: 0, index: 0)
                        enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                        enc.setVertexBytes(&params, length: MemoryLayout<MeshParams>.stride, index: 2)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                           instanceCount: relayMarkerCount)
                    }
                }

                // State overlay (always on, top of the hierarchy, never dimmed).
                encodeStateOverlay(enc, uniforms: &uniforms, params: &params,
                                   now: CACurrentMediaTime())
            }

            // --- Orrery (system/body focus): scaffold rings + belt (additive), then
            // the lit sun/planets (over-blend, depth-write) so bodies occlude
            // correctly. During a system↔body drill/zoom two layers render in one
            // frame: the DEPARTING layer (behind, no depth write) and the ARRIVING/
            // active layer on top. Orbits use the frozen `orbitClock`, not wall time.
            if orreryReveal > 0.001 {
                let t = orbitClock
                let viewportPx = SIMD2<Float>(Float(size.width), Float(size.height))
                if let dep = departing {
                    // A body layer's orbits emerge/recede with `bodyProgress`; a system
                    // layer's with `orreryReveal` (systemProgress). Fade = the layer's
                    // opacity. A SYSTEM layer skips the drilled planet (drawn as the
                    // continuous central body); a body layer draws it as its central.
                    encodeOrreryLayer(
                        enc, model: dep.model, center: dep.center, sun: dep.sunWorldPos,
                        scale: dep.scale, emergeReveal: dep.isBody ? bodyProgress : orreryReveal,
                        alphaReveal: orreryReveal * layerOpacity(isBody: dep.isBody),
                        writesDepth: false, excludeID: dep.isBody ? nil : bodyPlanetID,
                        lineBuffer: dep.lineBuffer, lineCount: dep.lineCount,
                        hzBuffer: dep.hzBuffer, hzCount: dep.hzCount,
                        beltBuffer: dep.beltBuffer, beltCount: dep.beltCount,
                        baseUniforms: uniforms, time: t, viewportPx: viewportPx)
                }
                if let model = orreryModel {
                    encodeOrreryLayer(
                        enc, model: model, center: orreryCenter, sun: orrerySunWorldPos,
                        scale: orreryScale, emergeReveal: orreryIsBody ? bodyProgress : orreryReveal,
                        alphaReveal: orreryReveal * layerOpacity(isBody: orreryIsBody),
                        writesDepth: true, excludeID: orreryIsBody ? nil : bodyPlanetID,
                        lineBuffer: orreryLineBuffer, lineCount: orreryLineVertexCount,
                        hzBuffer: orreryHZBuffer, hzCount: orreryHZVertexCount,
                        beltBuffer: orreryBeltBuffer, beltCount: orreryBeltCount,
                        baseUniforms: uniforms, time: t, viewportPx: viewportPx)
                }

                // Ship comet heads for ships on an intra-system leg — the in-orrery
                // counterpart of the galaxy heads (which fade out on drill-in). Always on
                // top, matching the SwiftUI icon that tracks them.
                var shipParams = MeshParams(viewportPixels: viewportPx, halfWidthPixels: 0, nodeRadiusPixels: 0)
                encodeOrreryShipHeads(enc, uniforms: &uniforms, params: &shipParams, now: CACurrentMediaTime())

                // Inbound/outbound transit affordance: dotted risers + connectors for
                // ships whose route crosses the boundary of this view (drawn under the
                // SwiftUI callout cards `emitTransitProjection` positions).
                var transitParams = MeshParams(viewportPixels: viewportPx, halfWidthPixels: 0, nodeRadiusPixels: 0)
                encodeOrreryTransit(enc, uniforms: uniforms, params: &transitParams, now: CACurrentMediaTime())
            }
            enc.endEncoding()
        }

        // --- Pass 2: tone-map → drawable, then labels over the top ---
        if let enc = cmd.makeRenderCommandEncoder(descriptor: screenPass) {
            enc.setRenderPipelineState(tonemapPipeline)
            enc.setFragmentTexture(hdr, index: 0)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            let size = view.drawableSize
            encodeLabels(enc, viewportPx: SIMD2<Float>(Float(size.width), Float(size.height)))
            enc.endEncoding()
        }

        cmd.present(drawable)
        cmd.commit()

        // Publish the ships' screen positions for the SwiftUI icon overlay, using
        // the same camera pose just rendered so the icons are frame-locked to the pips.
        emitShipProjection(view: view, now: now)
        // And the device-presence cluster badges (system focus only).
        emitClusterProjection(view: view)
        // And the inbound/outbound transit callouts (system focus only), anchored to the
        // top of each riser the orrery pass drew.
        emitTransitProjection(view: view, now: now)
    }

    /// Project each in-transit ship's comet head to view points (top-left origin,
    /// mirroring `pickStar`) and push them to the SwiftUI overlay via
    /// `onShipsProjected`. Emits an empty set while drilled into a system — the pips
    /// fade out via `overlayDim`, so the icons vanish with them (same gate as the
    /// pip encode at `overlayDim > 0.001`). Uses `bounds.size` (POINTS), not
    /// `drawableSize` (pixels), so the points land in SwiftUI's local space.
    private func emitShipProjection(view: MTKView, now: Double) {
        guard let emit = onShipsProjected else { return }
        guard !ships.isEmpty else { emit([]); return }
        let viewM = camera.viewMatrix()
        let proj = camera.projectionMatrix(aspect: aspect)
        let size = view.bounds.size
        let w = Float(size.width), h = Float(size.height)
        guard w > 0, h > 0 else { emit([]); return }

        // In-orrery resolver: a ship whose active leg is wholly within the focused system
        // stays visible + placed on its intra-system cruise leg (opacity ramps with the
        // reveal). A ship not in this system — or when in the galaxy — falls back to the
        // galaxy straight-line placement, fading with `overlayDim` on drill-in.
        let shipLayout: OrreryLayout? = {
            guard systemFocused, orreryReveal > 0.001, let model = orreryModel else { return nil }
            let reveal = orreryIsBody ? bodyProgress : orreryReveal
            return orreryLayout(model: model, center: orreryCenter, scale: orreryScale,
                                reveal: reveal, time: orbitClock)
        }()
        let dim = overlayDim

        var projected: [ProjectedShip] = []
        projected.reserveCapacity(ships.count)
        for ship in ships {
            var world: SIMD3<Float>?
            var opacity = 0.0
            if let layout = shipLayout,
               let op = ship.orreryPosition(at: now, resolve: { layout.position(ofLocation: $0) }) {
                world = op
                opacity = Double(orreryReveal)
            } else if dim > 0.001 {
                world = ship.position(at: now, stars: stars)
                opacity = Double(dim)
            }
            guard let world, opacity > 0.001,
                  let point = projectViewPoint(world, view: viewM, proj: proj, width: w, height: h)
            else { continue }
            projected.append(ProjectedShip(deviceCode: ship.deviceCode, point: point, opacity: opacity))
        }
        emit(projected)
    }

    /// Replace the device-presence clusters (the view rebuilds these off the live roster
    /// + scan blob whenever either changes). Projected each frame while focused.
    func updateDeviceClusters(_ clusters: [DeviceCluster]) { deviceClusters = clusters }

    /// Project each device cluster's anchor to view points (top-left, mirroring
    /// `emitShipProjection`) and push them to the SwiftUI overlay. Clusters are a
    /// system-focus overlay: empty in the galaxy (fades with `orreryReveal`), placed via
    /// the active layer's `OrreryLayout` so a badge tracks its body as it orbits. Uses
    /// `bounds.size` (POINTS), not `drawableSize` (pixels), for SwiftUI's local space.
    private func emitClusterProjection(view: MTKView) {
        guard let emit = onClustersProjected else { return }
        guard systemFocused, orreryReveal > 0.001, !deviceClusters.isEmpty, let model = orreryModel
        else { emit([]); return }
        let reveal = orreryIsBody ? bodyProgress : orreryReveal
        let layout = orreryLayout(model: model, center: orreryCenter, scale: orreryScale,
                                  reveal: reveal, time: orbitClock)
        let viewM = camera.viewMatrix()
        let proj = camera.projectionMatrix(aspect: aspect)
        let size = view.bounds.size
        let w = Float(size.width), h = Float(size.height)
        guard w > 0, h > 0 else { emit([]); return }
        let op = Double(orreryReveal)

        var out: [ProjectedCluster] = []
        out.reserveCapacity(deviceClusters.count)
        for cluster in deviceClusters {
            guard let world = layout.position(ofLocation: cluster.anchorCode),
                  let center = projectViewPoint(world, view: viewM, proj: proj, width: w, height: h)
            else { continue }
            // Float the badge just above the body's top edge so it never covers it:
            // measure the body's on-screen radius via a view-space offset along view-x.
            var screenR: CGFloat = 0
            let r = anchorWorldRadius(cluster.anchorCode, model: model)
            if r > 0 {
                var edge = proj * (viewM * SIMD4<Float>(world, 1) + SIMD4<Float>(r, 0, 0, 0))
                if edge.w > 0 {
                    edge /= edge.w
                    screenR = abs(CGFloat((edge.x * 0.5 + 0.5) * w) - center.x)
                }
            }
            let point = CGPoint(x: center.x, y: center.y - screenR - 16)   // 16 ≈ badge half-height + margin
            out.append(ProjectedCluster(
                anchorCode: cluster.anchorCode, point: point,
                count: cluster.count, primaryType: cluster.primaryType,
                hasOwn: cluster.hasOwn, opacity: op))
        }
        emit(out)
    }

    /// The world radius of a cluster's anchor body (0 for a point anchor like a Lagrange
    /// point or belt) — so the badge can be floated clear of the body's on-screen disc.
    private func anchorWorldRadius(_ code: String, model: SystemModel) -> Float {
        if code == model.star.designation {
            if orreryIsBody, let cb = model.centralBody { return Float(cb.displayRadius) * orreryScale }
            if let fi = focusedStarIndex, stars.indices.contains(fi) { return stars[fi].worldRadius }
            return 0
        }
        if let p = model.planets.first(where: { $0.id == code }) { return Float(p.displayRadius) * orreryScale }
        return 0
    }

    // MARK: Picking

    /// The star under a point in the view's coordinate space (origin top-left,
    /// points). 10k projected on the CPU is trivial.
    ///
    /// Clicking anywhere on a star's on-screen disc selects THAT star, and when
    /// several discs overlap the click the frontmost (nearest camera) wins — so
    /// clicking a big foreground star never activates something behind it. Only
    /// when the click lands on no disc do we fall back to the nearest center
    /// within `pixelRadius` (for far stars whose disc is sub-pixel).
    func pickStar(atViewPoint p: CGPoint, viewSize: CGSize, pixelRadius: CGFloat = 14) -> Int? {
        guard !systemFocused else { return nil }   // orrery isn't selectable yet
        let view = camera.viewMatrix()
        let proj = camera.projectionMatrix(aspect: aspect)
        let w = Float(viewSize.width), h = Float(viewSize.height)
        let px = Float(p.x), py = Float(p.y)

        // Project a view-space point to view pixels (top-left origin); nil if behind.
        func project(_ vpos: SIMD4<Float>) -> SIMD2<Float>? {
            var clip = proj * vpos
            if clip.w <= 0 { return nil }
            clip /= clip.w
            return SIMD2<Float>((clip.x * 0.5 + 0.5) * w, (1 - (clip.y * 0.5 + 0.5)) * h)
        }

        var bestDisc = -1
        var bestDiscDepth = Float.greatestFiniteMagnitude   // nearest camera wins on overlap
        var bestNear = -1
        var bestNearD = Float(pixelRadius * pixelRadius)     // sub-pixel fallback

        for i in 0..<stars.count {
            let viewPos = view * SIMD4<Float>(stars[i].position, 1)
            let dist = length(viewPos.xyz)
            guard let center = project(viewPos) else { continue }

            // The star's on-screen radius: the same view-space half-extent the
            // vertex shader billboards (worldRadius, clamped to the angular band),
            // measured in pixels by projecting a point offset along view-x.
            let radiusView = min(max(stars[i].worldRadius, dist * minAngularSize),
                                 dist * maxAngularSize)
            let discR = project(viewPos + SIMD4<Float>(radiusView, 0, 0, 0))
                .map { length($0 - center) } ?? 0

            let d2 = length_squared(center - SIMD2<Float>(px, py))
            if d2 <= discR * discR {
                if dist < bestDiscDepth { bestDiscDepth = dist; bestDisc = i }
            } else if d2 < bestNearD {
                bestNearD = d2; bestNear = i
            }
        }
        return bestDisc >= 0 ? bestDisc : (bestNear >= 0 ? bestNear : nil)
    }

    /// The domain star at a pick index — for surfacing selection data to the UI.
    func star(at index: Int) -> Star { stars[index] }

    /// The orrery location designation under a view point (top-left, points), or nil —
    /// the system-focus counterpart of `pickStar`. Candidates are every anchor the active
    /// layer's `OrreryLayout` resolves: the sun/central body, each orbiter, and (at system
    /// level) each planet's Lagrange points, belts, and structures. Clicking a body's
    /// on-screen disc selects it (frontmost wins on overlap); point anchors use a
    /// pixel-radius fallback so a small Lagrange tick is still easy to hit. Nil unless
    /// focused into an orrery.
    func pickLocation(atViewPoint p: CGPoint, viewSize: CGSize, pixelRadius: CGFloat = 16) -> String? {
        guard systemFocused, let model = orreryModel else { return nil }
        let reveal = orreryIsBody ? bodyProgress : orreryReveal
        let layout = orreryLayout(model: model, center: orreryCenter, scale: orreryScale,
                                  reveal: reveal, time: orbitClock)
        let view = camera.viewMatrix()
        let proj = camera.projectionMatrix(aspect: aspect)
        let w = Float(viewSize.width), h = Float(viewSize.height)
        let px = Float(p.x), py = Float(p.y)

        // (designation, world position, world radius — 0 for a point anchor).
        var candidates: [(id: String, pos: SIMD3<Float>, radius: Float)] = []
        if orreryIsBody, let cb = model.centralBody {
            candidates.append((model.star.designation, orreryCenter, Float(cb.displayRadius) * orreryScale))
        } else if let fi = focusedStarIndex, stars.indices.contains(fi) {
            candidates.append((model.star.designation, orreryCenter, stars[fi].worldRadius))
        }
        for planet in model.planets {
            candidates.append((planet.id, layout.orbiterPosition(planet), Float(planet.displayRadius) * orreryScale))
        }
        if !orreryIsBody {
            for planet in model.planets {
                for lp in planet.lagrange where lagrangeVisible(lp, planet: planet) {
                    if let pos = layout.lagrangePosition(lp.designation) { candidates.append((lp.designation, pos, 0)) }
                }
            }
            for belt in model.belts {
                if let pos = layout.beltAnchor(belt.designation) { candidates.append((belt.designation, pos, 0)) }
            }
            for st in model.structures {
                if let pos = layout.structurePosition(st.designation) { candidates.append((st.designation, pos, 0)) }
            }
        }

        // Project a view-space point to view pixels (top-left); nil if behind.
        func projClip(_ vpos: SIMD4<Float>) -> SIMD2<Float>? {
            var clip = proj * vpos
            if clip.w <= 0 { return nil }
            clip /= clip.w
            return SIMD2<Float>((clip.x * 0.5 + 0.5) * w, (1 - (clip.y * 0.5 + 0.5)) * h)
        }

        var bestDisc = -1
        var bestDiscDepth = Float.greatestFiniteMagnitude
        var bestNear = -1
        var bestNearD = Float(pixelRadius * pixelRadius)
        for (i, c) in candidates.enumerated() {
            let vpos = view * SIMD4<Float>(c.pos, 1)
            guard let center = projClip(vpos) else { continue }
            let dist = length(vpos.xyz)
            let discR = c.radius > 0
                ? (projClip(vpos + SIMD4<Float>(c.radius, 0, 0, 0)).map { length($0 - center) } ?? 0)
                : 0
            let d2 = length_squared(center - SIMD2<Float>(px, py))
            if d2 <= discR * discR {
                if dist < bestDiscDepth { bestDiscDepth = dist; bestDisc = i }
            } else if d2 < bestNearD {
                bestNearD = d2; bestNear = i
            }
        }
        if bestDisc >= 0 { return candidates[bestDisc].id }
        if bestNear >= 0 { return candidates[bestNear].id }
        return nil
    }

    /// Whether `code` is a planet the current SYSTEM view can drill into (double-click
    /// → body view). False at body level (moons don't drill) and for non-planet anchors.
    func isDrillablePlanet(_ code: String) -> Bool {
        guard systemFocused, !orreryIsBody, let model = orreryModel else { return false }
        return model.planets.contains { $0.id == code }
    }

    // MARK: Focus

    /// Focus a star: highlight it in the relevance field and ease the camera to
    /// frame it (pivot + dolly tween, not a snap). Returns the star for the UI.
    @discardableResult
    func focus(onStarAt index: Int) -> Star {
        selectedStarIndex = index
        relevance.focus(on: index)
        camera.focusFloor = dollyFloor(for: index)
        camera.focus(on: stars[index].position, now: CACurrentMediaTime())   // re-aim
        return stars[index]
    }

    /// Dive into a star: highlight it and ease the camera to a fixed close
    /// distance (`diveRadius`), always repositioning. For double-click.
    @discardableResult
    func dive(onStarAt index: Int) -> Star {
        selectedStarIndex = index
        relevance.focus(on: index)
        camera.focusFloor = dollyFloor(for: index)
        // Never push the eye farther out than it already is — dive only gets
        // closer (or holds), clamping to the current distance to the star.
        let currentRadius = length(camera.eye - stars[index].position)
        camera.dive(on: stars[index].position, radius: min(diveRadius, currentRadius), now: CACurrentMediaTime())
        return stars[index]
    }

    /// Distance at which a star fills its angular-size cap — the closest the dolly
    /// should go, so you can't zoom past where it stops growing.
    private func dollyFloor(for index: Int) -> Float {
        stars[index].worldRadius / maxAngularSize
    }

    /// Clear the current selection and its highlight (esc).
    func clearFocus() {
        selectedStarIndex = nil
        camera.focusFloor = nil
        relevance.clearFocus()
    }

    /// Home / overview: clear the highlight and ease back out, recentring on Sol
    /// (the origin). Orientation is preserved — a pull-back, not a reorient.
    func home() {
        selectedStarIndex = nil
        camera.focusFloor = nil
        relevance.clearFocus()
        camera.overview(target: .zero, radius: overviewRadius, now: CACurrentMediaTime())
    }

    /// Recenter on the player's current-location system — the gold reticle. Clears
    /// any focus and eases to an overview centred on that system (not Sol), so the
    /// "recenter" control brings you home to where you actually are.
    func recenterOnPlayer() {
        selectedStarIndex = nil
        // Centred on a star → keep that star's dolly floor, so you can't then pinch
        // in past its angular-size limit (which would break a later enterSystem).
        camera.focusFloor = dollyFloor(for: playerStarIndex)
        relevance.clearFocus()
        camera.overview(target: stars[playerStarIndex].position,
                        radius: overviewRadius, now: CACurrentMediaTime())
    }

    // MARK: Viewpoint persistence

    /// Seed the very first viewpoint: a close dive on the current-location star (the
    /// gold player reticle) rather than the far galaxy overview. Mirrors the
    /// end-state of a double-click dive, and sets the star's dolly floor so you
    /// can't push past where it stops growing.
    private func frameInitialDive() {
        let floor = dollyFloor(for: playerStarIndex)
        camera.focusFloor = floor
        camera.settle(on: stars[playerStarIndex].position, radius: max(diveRadius, floor))
    }

    /// Restore the imperative viewpoint captured before the last teardown, so
    /// returning to the map lands exactly where you were — same pose, same
    /// drilled-in system/planet. The orrery scaffold/belt buffers are rebuilt at the
    /// restored centre + scale.
    private func restoreViewpoint() {
        camera = viewpoint.camera
        camera.cancelFraming()            // don't resume a fly that was mid-flight at teardown
        cameraStack = viewpoint.cameraStack
        systemProgress = viewpoint.systemProgress
        transitionFrom = systemProgress   // pin the transition so `draw` doesn't animate it
        transitionTarget = systemProgress
        systemFocused = viewpoint.systemFocused
        orreryCenter = viewpoint.orreryCenter
        orrerySunWorldPos = viewpoint.orrerySunWorldPos
        orreryScale = viewpoint.orreryScale
        // Land the body cross-fade settled (no departing layer, no replay of the fly).
        // The restored body view holds at its saved centre/scale (bodyProgress pinned
        // at 1 so the central body is at its full radius).
        orreryIsBody = viewpoint.orreryIsBody
        departing = nil
        bodyPlanetID = viewpoint.bodyPlanetID
        bodyCentralStartRadius = viewpoint.bodyCentralStartRadius
        settleBodyProgress(orreryIsBody ? 1 : 0)
        focusedStarIndex = viewpoint.focusedStarIndex
        selectedStarIndex = viewpoint.selectedStarIndex
        if let model = viewpoint.orreryModel {
            setOrreryModel(model)         // rebuilds scaffold/belt buffers at the restored centre+scale
        }
        // Re-light the relevance field the fresh GPU state lost: the pre-drill focus
        // in a system, else the picked star in the galaxy.
        if systemFocused, let focused = focusedStarIndex {
            relevance.focus(on: focused)
        } else if let selected = selectedStarIndex {
            relevance.focus(on: selected)
        }
    }

    /// Snapshot the live viewpoint into the shared cache so it survives the next
    /// teardown (tab switch / survey rebuild).
    private func persistViewpoint() {
        viewpoint.camera = camera
        viewpoint.cameraStack = cameraStack
        viewpoint.systemProgress = systemProgress
        viewpoint.systemFocused = systemFocused
        viewpoint.orreryModel = orreryModel
        viewpoint.orreryCenter = orreryCenter
        viewpoint.orrerySunWorldPos = orrerySunWorldPos
        viewpoint.orreryScale = orreryScale
        viewpoint.orreryIsBody = orreryIsBody
        viewpoint.bodyPlanetID = bodyPlanetID
        viewpoint.bodyCentralStartRadius = bodyCentralStartRadius
        viewpoint.focusedStarIndex = focusedStarIndex
        viewpoint.selectedStarIndex = selectedStarIndex
    }

    // MARK: System focus (orrery)

    /// Drill from the galaxy into a system: build its orrery around the star and
    /// ease the camera in to frame it. The field fades and the orrery reveals via
    /// `fieldDim`/`orreryReveal` (systemProgress 0→1, advanced in `draw`).
    func enterSystem(starIndex: Int, model: SystemModel) {
        guard stars.indices.contains(starIndex) else { return }
        focusedStarIndex = starIndex             // the star IS the orrery sun (unfaded, uncapped)
        orreryCenter = stars[starIndex].position
        orrerySunWorldPos = orreryCenter         // the sun sits at the centre
        // Frame the orrery in the star's own angular terms: dive until the star
        // fills `maxAngularSize` (dFinal) — the sun takes over at the same size, so
        // drilling reads as a zoom IN — and scale the orrery to fit the view there.
        let dFinal = stars[starIndex].worldRadius / maxAngularSize
        orreryScale = orreryScaleToFit(frameScene: model.frameScene, atDistance: dFinal)
        setOrreryModel(model)

        // Keep the existing relevance focus: the other stars are already dimmed
        // around the selection, so they just fade out with `fieldDim` — resetting
        // to full here would snap them bright right before fading them away.
        cameraStack.append(camera)               // restore this galaxy pose + clamp on zoom-out
        systemFocused = true
        orreryIsBody = false                     // system level — no body cross-fade in flight
        departing = nil
        bodyCentralStartRadius = 0
        bodyPlanetID = nil
        settleBodyProgress(0)
        camera.focusFloor = dFinal * 0.6         // limit how far you can zoom in
        // Narrow the interactive elevation to the oblique orrery band and tilt onto
        // the orbital plane at the fixed entry angle (keeping the current azimuth).
        camera.minElevation = orreryMinElevation
        camera.maxElevation = orreryMaxElevation
        let now = CACurrentMediaTime()
        beginTransition(to: 1, duration: drillDurationBase, now: now)
        camera.frame(on: orreryCenter, azimuth: camera.azimuth, elevation: orreryEntryElevation,
                     radius: dFinal, now: now, duration: transitionDuration)
    }

    /// Manual-dolly bounds for the current body-level orrery, at the live `orreryScale`.
    /// Zoom-IN floor is keyed to the planet's own radius (`centralScene * orreryScale`)
    /// so you can pull up to a full-frame close-up; zoom-OUT ceiling is a margin past the
    /// moon-system framing distance so the whole system fits with room to spare. Kept in
    /// one place because the moon roster hydrates AFTER drill-in — `updateOrrery` re-runs
    /// this so the ceiling widens to the real (larger) system instead of staying pinned
    /// at the pre-hydrate frame.
    private func bodyDollyBounds(model: SystemModel) -> (floor: Float, ceiling: Float) {
        let centralScene = Float(model.centralBody?.displayRadius ?? 2.6)
        let planetWorldRadius = centralScene * orreryScale
        let frameWorldRadius = Float(model.frameScene) * orreryScale
        let dFinal = frameWorldRadius / (tan(camera.fovy * 0.5) * 0.9)
        return (floor: planetWorldRadius * 2.0, ceiling: dFinal * 1.5)
    }

    /// Drill from a system into one of its planets — the same seamless move as
    /// galaxy→system, one level deeper. The clicked planet IS the body-view centre,
    /// at the SAME world position it orbited; the orrery freezes (`orbitClock` holds)
    /// so the planet sits still and the camera dives straight in — no per-frame
    /// tracking. The central body starts at its system rendered size and GROWS to a
    /// comfortable, sun-sized body radius across the drill (so it's continuous at the
    /// start yet legible at the end, and world units never get clipping-small). Moons
    /// emerge from it (orbit × `bodyProgress`) as planets do from the star; siblings +
    /// sun fade out.
    func enterBody(starIndex: Int, planetID: String, model: SystemModel) {
        guard stars.indices.contains(starIndex) else { return }
        // The planet's frozen position + its rendered radius in the system we're leaving.
        let systemPlanet = orreryModel?.planets.first(where: { $0.id == planetID })
        let planetCenter = currentOrbiterWorldPosition(id: planetID) ?? orreryCenter
        let systemPlanetRadius = systemPlanet.map { Float($0.displayRadius) * orreryScale }
            ?? (stars[starIndex].worldRadius * 0.3)

        // Snapshot the system we're leaving so its siblings + sun keep drawing (and
        // fading) over the fly-in. Orbits are frozen, so its focused planet stays put
        // and registered with the arriving body centre.
        departing = snapshotActiveOrrery(isBody: orreryIsBody)
        focusedStarIndex = starIndex             // the system star stays the light source
        orreryCenter = planetCenter
        orreryIsBody = true
        bodyPlanetID = planetID                       // the SYSTEM layer skips this planet
        bodyCentralStartRadius = systemPlanetRadius   // the body central grows FROM this

        // Scale the body orrery so the central planet ends up as big as the system
        // star (≥ the sun's angular width) — keeping world units comfortable, well
        // clear of the near plane — with the moons sized proportionally around it.
        let centralScene = Float(model.centralBody?.displayRadius ?? 2.6)
        orreryScale = stars[starIndex].worldRadius / centralScene
        // Frame it like a sun: dive until the moon system fits the view.
        let frameWorldRadius = Float(model.frameScene) * orreryScale
        let dFinal = frameWorldRadius / (tan(camera.fovy * 0.5) * 0.9)

        // Light from a DISTANT sun along the true star direction (kept far outside the
        // frame so it never falls inside the planet — which would unlight it and light
        // its moons as if the planet were the sun). Frozen with the orrery.
        orrerySunWorldPos = bodySunPosition(planet: planetCenter, starIndex: starIndex,
                                            distance: frameWorldRadius * 40)
        setOrreryModel(model)

        cameraStack.append(camera)               // restore this system pose (incl. near) on zoom-out
        systemFocused = true
        // Dolly bounds keyed to the planet's own radius (zoom-in) and the moon-system
        // frame (zoom-out) — recomputed on hydrate (see `bodyDollyBounds` / `updateOrrery`).
        let bounds = bodyDollyBounds(model: model)
        camera.focusFloor = bounds.floor
        camera.focusCeiling = bounds.ceiling
        let planetWorldRadius = centralScene * orreryScale
        // Pull the near plane in so nothing clips when dollied to the floor: below the
        // moon frame (dFinal · 0.02) AND below the gap between the zoom-in floor and the
        // planet surface (0.35 radius), whichever is tighter — the latter guards a large
        // moon system where dFinal · 0.02 could exceed that gap. Restored in exitToSystem.
        camera.near = min(camera.near, min(dFinal * 0.02, planetWorldRadius * 0.1))
        let now = CACurrentMediaTime()
        beginTransition(to: 1, duration: drillDurationBase, now: now)
        beginBodyTransition(to: 1, duration: drillDurationBase, now: now)   // moons emerge, siblings + sun fade
        camera.dive(on: planetCenter, radius: dFinal, now: now, duration: transitionDuration)
    }

    /// Zoom out from a body back to its system: restore the system pose, put the
    /// star back at the centre as the sun, and rebuild the system orrery. The
    /// galaxy stays receded (systemProgress holds at 1).
    func exitToSystem(starIndex: Int, model: SystemModel) {
        guard stars.indices.contains(starIndex) else { return }
        // Snapshot the planet we're leaving so it (and its moons) keep drawing while
        // the system's siblings + sun fade back IN over the pull-back.
        departing = snapshotActiveOrrery(isBody: orreryIsBody)
        focusedStarIndex = starIndex
        orreryCenter = stars[starIndex].position
        orrerySunWorldPos = orreryCenter
        orreryIsBody = false
        let dFinal = stars[starIndex].worldRadius / maxAngularSize
        orreryScale = orreryScaleToFit(frameScene: model.frameScene, atDistance: dFinal)
        setOrreryModel(model)

        let now = CACurrentMediaTime()
        beginTransition(to: 1, duration: zoomDurationBase, now: now)
        beginBodyTransition(to: 0, duration: zoomDurationBase, now: now)   // siblings + sun fade back in
        if let saved = cameraStack.popLast() {
            camera.focusFloor = saved.focusFloor
            camera.focusCeiling = saved.focusCeiling    // drop the body zoom-out cap
            camera.near = saved.near                    // restore the system near plane
            camera.minElevation = saved.minElevation   // still orrery-focused; carry its clamp
            camera.maxElevation = saved.maxElevation
            camera.restore(saved, now: now, duration: transitionDuration)
        }
    }

    /// Scale (scene-unit → world) that fits an orrery of outer radius `frameScene`
    /// into the view at camera distance `d`.
    private func orreryScaleToFit(frameScene: Double, atDistance d: Float) -> Float {
        let visibleRadius = d * tan(camera.fovy * 0.5) * 0.9
        return visibleRadius / Float(max(frameScene, 1))
    }

    /// Set the orrery roster and rebuild its scaffold/belt buffers at the current
    /// centre + scale (set by the enter methods; untouched here). Used on drill-in
    /// and again when the hydrate lands with the real roster — no camera change.
    private func setOrreryModel(_ model: SystemModel) {
        orreryModel = model
        let lines = OrreryGeometry.scaffoldLines(model: model, center: orreryCenter, scale: orreryScale)
        orreryLineVertexCount = lines.count
        orreryLineBuffer = lines.isEmpty ? nil : device.makeBuffer(
            bytes: lines, length: lines.count * MemoryLayout<OrreryLineVertex>.stride,
            options: .storageModeShared)

        let hz = OrreryGeometry.habitableZoneFill(model: model, center: orreryCenter, scale: orreryScale)
        orreryHZVertexCount = hz.count
        orreryHZBuffer = hz.isEmpty ? nil : device.makeBuffer(
            bytes: hz, length: hz.count * MemoryLayout<OrreryLineVertex>.stride,
            options: .storageModeShared)

        let belt = OrreryGeometry.beltPoints(model: model, center: orreryCenter, scale: orreryScale)
        orreryBeltCount = belt.count
        orreryBeltBuffer = belt.isEmpty ? nil : device.makeBuffer(
            bytes: belt, length: belt.count * MemoryLayout<AmbientVertex>.stride,
            options: .storageModeShared)
    }

    /// Refresh the orrery in place when the persisted detail updates while focused
    /// (planets/moons/belts pop in without restarting the transition or re-framing).
    func updateOrrery(model: SystemModel) {
        guard systemFocused else { return }
        // Defer the rebuild if a drill/zoom is still flying: the geometry generation +
        // buffer allocation stalls the render thread and drops a frame or two mid-fly.
        // `draw` applies the stashed model the moment both eased clocks settle, so the
        // one-frame cost lands on a static camera instead (see `pendingOrreryModel`).
        if transitionInFlight(now: CACurrentMediaTime()) {
            pendingOrreryModel = model
            return
        }
        applyOrreryUpdate(model)
    }

    /// Rebuild the orrery for an updated roster and re-fit the body zoom-out cap.
    /// Split out of `updateOrrery` so the same work can run either immediately (at
    /// rest) or deferred from `draw` (once a fly settles).
    private func applyOrreryUpdate(_ model: SystemModel) {
        setOrreryModel(model)
        // A body hydrate can grow the moon roster (and thus `frameScene`), so re-widen
        // the zoom-out cap to the real system — otherwise it stays pinned at the frame
        // computed from the sparse pre-hydrate roster and you can't pull back to see all
        // the moons. Only at body level; system-level zoom-out stays uncapped.
        if orreryIsBody {
            let bounds = bodyDollyBounds(model: model)
            camera.focusFloor = bounds.floor
            camera.focusCeiling = bounds.ceiling
        }
    }

    /// Zoom back out to the galaxy: ease the camera back to the exact pre-drill
    /// pose. The orrery reveal fades out in `draw`; its buffers drop on next drill.
    func exitSystem() {
        systemFocused = false
        orreryIsBody = false        // back to the galaxy — no body layer in play
        departing = nil
        bodyCentralStartRadius = 0
        bodyPlanetID = nil
        settleBodyProgress(0)
        let now = CACurrentMediaTime()
        beginTransition(to: 0, duration: zoomDurationBase, now: now)
        if let saved = cameraStack.popLast() {
            camera.focusFloor = saved.focusFloor
            camera.focusCeiling = saved.focusCeiling    // drop the body zoom-out cap
            camera.near = saved.near                    // restore the galaxy near plane
            camera.minElevation = saved.minElevation   // restore the galaxy's wider clamp
            camera.maxElevation = saved.maxElevation
            camera.restore(saved, now: now, duration: transitionDuration)
        }
    }

    /// Start the shared galaxy↔system transition (crossfade + orrery + camera fly
    /// all read `systemProgress` over `transitionDuration`, so they land together).
    private func beginTransition(to target: Float, duration: Double, now: Double) {
        transitionFrom = systemProgress
        transitionTarget = target
        transitionStart = now
        transitionDuration = max(duration, 0.0001)
        // A pending update from a prior level is superseded by the model this new
        // transition renders (set directly by the enter/exit caller); drop it so it
        // can't apply on top of the arriving level.
        pendingOrreryModel = nil
    }

    /// The orbit-timing knobs, packaged for `OrreryLayout` — the one place the orbit math
    /// now lives (bodies, pips, device clusters, ship endpoints, picking all read it).
    private var orbitTiming: OrbitTiming {
        OrbitTiming(minPeriodSeconds: orreryMinPeriod, periodFalloff: orreryPeriodFalloff)
    }

    /// Build the location resolver for one rendered layer at the given orbit `time`.
    private func orreryLayout(model: SystemModel, center: SIMD3<Float>, scale: Float,
                              reveal: Float, time: Float) -> OrreryLayout {
        OrreryLayout(model: model, center: center, scale: scale, reveal: reveal,
                     time: time, timing: orbitTiming)
    }

    /// Encode one orrery layer into the HDR pass: HZ band + orbit rings + belt
    /// (additive, depth-read), the lit bodies (over-blend), atmosphere halos, and
    /// annotation pips — all faded by `alphaReveal` (fed to the shaders as
    /// `orreryAlpha`) and centred on `center`. The scaffold shaders grow geometry
    /// out of `center` by `orreryReveal`, so the per-layer `center` is written into
    /// the uniform copy. `writesDepth` gates whether the bodies write depth: the
    /// active layer does (bodies occlude one another); a departing layer only reads,
    /// so its near-transparent bodies never punch depth holes. `emergeReveal` scales
    /// orbit radii + scaffold grow-out (0 = collapsed to the centre, 1 = full orbits)
    /// so moons emerge from / recede into the planet exactly as planets do the star.
    /// `excludeID` drops the drilled planet from a SYSTEM layer (it's drawn once as the
    /// continuous central body, not blended against a second copy).
    private func encodeOrreryLayer(_ enc: MTLRenderCommandEncoder,
                                   model: SystemModel, center: SIMD3<Float>, sun: SIMD3<Float>,
                                   scale: Float, emergeReveal: Float, alphaReveal: Float,
                                   writesDepth: Bool, excludeID: String?,
                                   lineBuffer: MTLBuffer?, lineCount: Int,
                                   hzBuffer: MTLBuffer?, hzCount: Int,
                                   beltBuffer: MTLBuffer?, beltCount: Int,
                                   baseUniforms: Uniforms, time: Float, viewportPx: SIMD2<Float>) {
        // Skip a fully-faded layer — UNLESS it carries the drilled planet (central),
        // which draws at full opacity independent of `alphaReveal`. Otherwise, in the
        // last sliver of a zoom-out (alphaReveal→0 but not yet settled), the opaque
        // central would be skipped while the system layer still excludes that planet
        // → it vanishes for one frame right before landing.
        guard alphaReveal > 0.001 || model.centralBody != nil else { return }
        var u = baseUniforms
        u.orreryCenter = SIMD4(center, 0)     // the scaffold grows out of THIS layer's centre
        u.orreryReveal = emergeReveal         // orbits/scaffold emerge from the centre by this
        u.orreryAlpha = alphaReveal           // fade this layer independently of the grow-out

        // Habitable-zone band (filled), orbit rings, then the belt point ring.
        if let hzBuf = hzBuffer, hzCount > 0 {
            enc.setRenderPipelineState(orreryLinePipeline)
            enc.setDepthStencilState(readDepthState)
            enc.setVertexBuffer(hzBuf, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: hzCount)
        }
        if let lineBuf = lineBuffer, lineCount > 0 {
            enc.setRenderPipelineState(orreryLinePipeline)
            enc.setDepthStencilState(readDepthState)
            enc.setVertexBuffer(lineBuf, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lineCount)
        }
        if let beltBuf = beltBuffer, beltCount > 0 {
            enc.setRenderPipelineState(orreryPointPipeline)
            enc.setDepthStencilState(readDepthState)
            enc.setVertexBuffer(beltBuf, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: beltCount)
        }

        // Bodies: billboard sphere-impostors, depth-tested so they occlude one another
        // (active layer writes depth; a departing layer reads only). The drilled planet
        // (central) stays FULLY OPAQUE and only changes size — it's one continuous body
        // across system↔body, never cross-faded — while its moons fade with the layer.
        var uCentral = u
        uCentral.orreryAlpha = orreryReveal
        let placed = placedOrreryBodies(model: model, center: center, scale: scale, sun: sun,
                                        reveal: emergeReveal, time: time, excludeID: excludeID)
        enc.setRenderPipelineState(orreryBodyPipeline)
        for placedBody in placed {
            var pu = placedBody.isCentral ? uCentral : u
            // The opaque central ALWAYS writes depth (even on a departing layer), so
            // the other layer's additive rings / HZ band can't composite THROUGH the
            // planet; the fading moons follow the layer policy (no holes when transparent).
            enc.setDepthStencilState((placedBody.isCentral || writesDepth) ? bodyDepthState : readDepthState)
            var body = bodyUniform(placedBody)
            enc.setVertexBytes(&pu, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&pu, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setVertexBytes(&body, length: MemoryLayout<OrreryBodyUniform>.stride, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        // Atmosphere halos: additive glow shells beyond the limb, depth-read (a nearer
        // body occludes them without their writing depth). The central's halo tracks
        // its full opacity; the moons' fade with the layer.
        let hasAtmo = placed.contains { atmosphereUniform($0) != nil }
        if hasAtmo {
            enc.setRenderPipelineState(orreryAtmoPipeline)
            enc.setDepthStencilState(readDepthState)
            for placedBody in placed {
                guard var a = atmosphereUniform(placedBody) else { continue }
                var pu = placedBody.isCentral ? uCentral : u
                enc.setVertexBytes(&pu, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.setFragmentBytes(&pu, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.setVertexBytes(&a, length: MemoryLayout<OrreryAtmosphereUniform>.stride, index: 2)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }

        // Annotation pips: indicator dots + hazard markers, depth-read (occluded
        // behind a body), additive.
        let pips = orreryPips(model: model, center: center, scale: scale, reveal: emergeReveal,
                              time: time, viewportPx: viewportPx, excludeID: excludeID)
        if !pips.isEmpty {
            var pipParams = MeshParams(viewportPixels: viewportPx, halfWidthPixels: 0, nodeRadiusPixels: 0)
            enc.setRenderPipelineState(orreryPipPipeline)
            enc.setDepthStencilState(readDepthState)
            pips.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setVertexBytes(&pipParams, length: MemoryLayout<MeshParams>.stride, index: 2)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: pips.count)
        }
    }

    /// A body positioned for this frame — the shared placement (world center + scene
    /// radius, plus the light source) and the material inputs, so the opaque body pass
    /// and the atmosphere-halo pass draw at exactly the same spot without recomputing
    /// the orbit math twice.
    private struct PlacedBody {
        var isCentral: Bool           // the drilled planet (opaque + size-morphing), not a moon/planet
        var center: SIMD3<Float>
        var radius: Float
        var sun: SIMD3<Float>         // light source (world), so both draws share it
        var type: PlanetType
        var lifeStage: String?
        var estimated: Bool
        var tags: [String]
        var inHabitableZone: Bool
        var surfaceTempC: Double?
        var atmosphere: Atmosphere
        var appearanceSeed: Float
        var seedDeg: Double
    }

    /// Place every body of one orrery layer for this frame: the drilled central body
    /// (body level) and each orbiting planet/moon at its animated angle. Explicitly
    /// parameterized by the layer's centre / scale / sun / reveal so the SAME code
    /// places the active orrery AND a departing one during the body cross-fade.
    /// `reveal` scales orbit radii (planets/moons emerge from the centre on drill-in,
    /// recede into it on zoom-out). `excludeID` drops one planet — used to skip the
    /// drilled planet in the SYSTEM layer, since it's drawn as the single continuous
    /// central body instead of cross-faded against a second copy. One pass, consumed
    /// by the body + halo draws.
    private func placedOrreryBodies(model: SystemModel, center: SIMD3<Float>, scale: Float,
                                    sun: SIMD3<Float>, reveal: Float,
                                    time: Float, excludeID: String? = nil) -> [PlacedBody] {
        let layout = orreryLayout(model: model, center: center, scale: scale, reveal: reveal, time: time)
        var placed: [PlacedBody] = []
        placed.reserveCapacity(model.planets.count + 1)

        // Body level: the drilled planet as a lit impostor at the centre (no orbit),
        // lit — like the moons — by the (distant) sun position. Its radius grows from
        // the size it had in the system view up to its full body radius across
        // `bodyProgress`, so the planet is ONE continuous body (opaque, size-morphing)
        // rather than a cross-fade — see the central handling in `encodeOrreryLayer`.
        if let central = model.centralBody {
            let fullRadius = Float(central.displayRadius) * scale
            let radius = bodyCentralStartRadius > 0
                ? bodyCentralStartRadius + (fullRadius - bodyCentralStartRadius) * bodyProgress
                : fullRadius
            placed.append(PlacedBody(
                isCentral: true, center: center, radius: radius,
                sun: sun, type: central.planetType, lifeStage: central.lifeStage,
                estimated: central.estimated, tags: central.tags,
                inHabitableZone: central.inHabitableZone,
                surfaceTempC: central.surfaceTempC, atmosphere: central.atmosphere,
                appearanceSeed: central.appearanceSeed,
                seedDeg: OrreryMapping.phaseDeg(model.star.designation)))
        }

        for planet in model.planets where planet.id != excludeID {
            let pos = layout.orbiterPosition(planet)   // emerge from the centre (reveal applied)
            placed.append(PlacedBody(
                isCentral: false, center: pos, radius: Float(planet.displayRadius) * scale,
                sun: sun, type: planet.planetType, lifeStage: planet.lifeStage,
                estimated: planet.estimated, tags: planet.tags,
                inHabitableZone: planet.inHabitableZone,
                surfaceTempC: planet.surfaceTempC, atmosphere: planet.atmosphere,
                appearanceSeed: planet.appearanceSeed,
                seedDeg: planet.phase0Deg))
        }
        return placed
    }

    /// Pack a placed body's resolved `PlanetMaterial` surface into the GPU uniform — base +
    /// terrain albedos, the procedural style index, biosphere strength, and the
    /// estimated flag — plus a deterministic per-body spin seed so each planet's
    /// texture is rotated differently (and stably across launches).
    private func bodyUniform(_ p: PlacedBody) -> OrreryBodyUniform {
        let s = PlanetMaterial.surface(for: p.type, lifeStage: p.lifeStage, estimated: p.estimated,
                                       tags: p.tags, surfaceTempC: p.surfaceTempC,
                                       atmosphere: p.atmosphere,
                                       inHabitableZone: p.inHabitableZone)
        let spin = Float(p.seedDeg) * .pi / 180
        return OrreryBodyUniform(
            centerRadius: SIMD4(p.center, p.radius),
            color: SIMD4(s.base, s.polarIce),
            sunEmissive: SIMD4(p.sun, s.greenVibrancy),
            detailColor: SIMD4(s.detail, Float(s.style.rawValue)),
            surfaceParams: SIMD4(s.estimated ? 1 : 0, s.life, spin, p.appearanceSeed),
            surfaceMods: SIMD4(s.mods.craters, s.mods.atmosphere, s.mods.lava, s.mods.frost))
    }

    /// The atmosphere-halo uniform for a placed body, or `nil` if it gets no shell (a
    /// giant, or an airless/unscanned reading). Same center/radius as the body draw so
    /// the halo registers exactly with the limb; lit by the same orrery sun.
    private func atmosphereUniform(_ p: PlacedBody) -> OrreryAtmosphereUniform? {
        guard let shell = PlanetMaterial.atmosphereShell(for: p.type, atmosphere: p.atmosphere,
                                                         tags: p.tags) else { return nil }
        return OrreryAtmosphereUniform(
            centerRadius: SIMD4(p.center, p.radius),
            sunExtent: SIMD4(p.sun, shell.extent),
            tintDensity: SIMD4(shell.tint, shell.density))
    }

    /// The per-frame annotation pips: a centred row of indicator dots above each
    /// body that carries notable features, plus a pulsing marker on each incoming
    /// hazard. Positions mirror `placedOrreryBodies` (same orbit math, same reveal
    /// scale) so the pips track their bodies as they orbit and emerge on drill-in.
    private func orreryPips(model: SystemModel, center: SIMD3<Float>, scale: Float,
                            reveal: Float, time: Float, viewportPx: SIMD2<Float>,
                            excludeID: String? = nil) -> [OrreryPip] {
        let layout = orreryLayout(model: model, center: center, scale: scale, reveal: reveal, time: time)
        let pipRadius: Float = 3
        let gap: Float = 4               // px between the planet rim and the pip row
        let minSpacing: Float = 8
        var pips: [OrreryPip] = []

        // Project a view-space point to view pixels (mirrors `pickStar`), so the pip
        // row can be anchored to each planet's on-screen radius rather than a fixed
        // pixel distance — the cluster then hugs the rim at every zoom instead of
        // floating off into a detached speck when the planet shrinks.
        let view = camera.viewMatrix()
        let proj = camera.projectionMatrix(aspect: aspect)
        let w = viewportPx.x, h = viewportPx.y
        func project(_ vpos: SIMD4<Float>) -> SIMD2<Float>? {
            var clip = proj * vpos
            if clip.w <= 0 { return nil }
            clip /= clip.w
            return SIMD2<Float>((clip.x * 0.5 + 0.5) * w, (1 - (clip.y * 0.5 + 0.5)) * h)
        }

        for planet in model.planets where planet.id != excludeID {
            let entries = OrreryGeometry.pipEntries(planet.indicators)
            guard !entries.isEmpty else { continue }
            let pos = layout.orbiterPosition(planet)

            // The planet's on-screen radius: project a point offset by its world
            // radius along view-x and measure the pixel span (same trick as the
            // star disc in `pickStar`). Scale the row's offset + spacing to it.
            let worldRadius = Float(planet.displayRadius) * scale
            let viewPos = view * SIMD4<Float>(pos, 1)
            let screenR = project(viewPos).flatMap { c in
                project(viewPos + SIMD4<Float>(worldRadius, 0, 0, 0)).map { length($0 - c) }
            } ?? 0

            let clusterY = -(screenR + gap + pipRadius)     // just above the rim (screen y grows downward)
            let spacing = max(minSpacing, screenR * 0.7)
            let n = Float(entries.count)
            for (i, entry) in entries.enumerated() {
                let x = (Float(i) - (n - 1) / 2) * spacing
                pips.append(OrreryPip(
                    worldPosRadius: SIMD4(pos, pipRadius),
                    color: SIMD4(entry.color, 0),                       // steady (no pulse)
                    pixelOffset: SIMD2(x, clusterY), _pad: .zero))
            }
        }

        // Lagrange points: a faint fixed-size tick at each L-point so the (now
        // pickable) points read as scaffold. Steady + dim; Phase 3 brightens an
        // occupied point. Only planets carry Lagrange (moons at body level don't).
        for planet in model.planets where planet.id != excludeID {
            for lp in planet.lagrange where lagrangeVisible(lp, planet: planet) {
                guard let pos = layout.lagrangePosition(lp.designation) else { continue }
                // An occupied point brightens to the device tint (and grows a touch) so it
                // reads as active under its cluster badge; an empty one stays faint scaffold.
                let occupied = deviceClusters.contains { $0.anchorCode == lp.designation }
                pips.append(OrreryPip(
                    worldPosRadius: SIMD4(pos, occupied ? 3.5 : 3),
                    color: SIMD4(occupied ? OrreryGeometry.deviceColor : OrreryGeometry.lagrangeColor, 0),
                    pixelOffset: .zero, _pad: .zero))
            }
        }

        // Belt features: a small pip row at the belt's ring anchor (mining site / stored
        // inventory), so a belt reads its notable contents like a planet does.
        for belt in model.belts {
            let entries = OrreryGeometry.pipEntries(belt.indicators)
            guard !entries.isEmpty, let pos = layout.beltAnchor(belt.designation) else { continue }
            let n = Float(entries.count)
            for (i, entry) in entries.enumerated() {
                let x = (Float(i) - (n - 1) / 2) * 9
                pips.append(OrreryPip(
                    worldPosRadius: SIMD4(pos, 3),
                    color: SIMD4(entry.color, 0),
                    pixelOffset: SIMD2(x, -10), _pad: .zero))
            }
        }

        // Incoming hazards: one pulsing red marker at the asteroid's position; the
        // pulse quickens as its progress climbs toward impact.
        for hazard in model.hazards where hazard.orbitScene > 0 {
            let pos = center + OrreryGeometry.hazardOffset(hazard) * scale * reveal
            let progress = Float(min(max((hazard.progressPct ?? 0) / 100, 0), 1))
            let pulseSpeed = 2.5 + 5 * progress
            pips.append(OrreryPip(
                worldPosRadius: SIMD4(pos, 5),
                color: SIMD4(OrreryGeometry.hazardColor, pulseSpeed),
                pixelOffset: .zero, _pad: .zero))
        }
        return pips
    }

    /// The current world position of an orbiter (planet) in the loaded orrery, at
    /// this instant's orbit angle — same math as `placedOrreryBodies`. Used to capture a
    /// planet's live position when drilling from the system into it.
    private func currentOrbiterWorldPosition(id: String) -> SIMD3<Float>? {
        guard let model = orreryModel else { return nil }
        // Use the (possibly frozen) orbit clock so the captured position matches what
        // the system layer is actually rendering this frame.
        return orreryLayout(model: model, center: orreryCenter, scale: orreryScale,
                            reveal: orreryReveal, time: orbitClock).orbiterPosition(id: id)
    }

    /// Marks live viewport input (scroll / pinch / click) so the auto-rotate idle
    /// clock resets — the spin eases out and won't resume until things are calm
    /// again for `autoRotateIdleDelay`.
    func registerInteraction() {
        lastInteractionTime = CACurrentMediaTime()
    }

    /// Idle-gated auto-rotate. The spin eases in only after `autoRotateIdleDelay`
    /// seconds with no viewport input and no eased camera move; any interaction
    /// (or an in-flight framing move) resets the idle clock and eases it back out.
    /// `spinEnvelope` (0…1) is the eased rate scale, using a slow ease-in and a
    /// quicker ease-out time constant.
    private func advanceAutoRotate(now: Double, dt: Float) {
        // An in-flight framing move counts as motion — hold the idle clock at now.
        if camera.isFraming { lastInteractionTime = now }
        let idle = now - lastInteractionTime
        let target: Float = (autoRotate && !systemFocused && idle >= autoRotateIdleDelay) ? 1 : 0
        let tau = target > spinEnvelope ? spinEaseInTau : spinEaseOutTau
        spinEnvelope += (target - spinEnvelope) * (1 - exp(-dt / max(tau, 1e-3)))
        if spinEnvelope > 0.001 {
            camera.autoOrbit(by: autoRotateRate * spinEnvelope * dt)
        }
    }

    // MARK: Terrain

    /// Swap the terrain to `newStars` (plus its `overlays`) IN PLACE — without
    /// tearing the renderer down — so a survey's stars stream in incrementally and
    /// the live camera / framing / selection all survive. The star table only ever
    /// appends (ordered by `createdAt`), so existing indices — the selection, the
    /// drilled star, ship endpoints — stay valid across the update.
    ///
    /// Rebuilds the instance buffer + relevance field for the new star set, then
    /// re-applies the overlays and re-lights the active focus/filter the fresh
    /// relevance field would otherwise have lost. A no-op for an empty set (keeps
    /// the last terrain rather than blanking to black).
    func updateTerrain(_ newStars: [Star], overlays: StarMapOverlays) {
        guard !newStars.isEmpty else { return }
        let instances = newStars.map(\.renderInstance)
        guard let buffer = device.makeBuffer(
            bytes: instances,
            length: instances.count * MemoryLayout<StarInstance>.stride,
            options: .storageModeShared),
              let field = RelevanceField(device: device, positions: newStars.map(\.position))
        else { return }
        stars = newStars
        starBuffer = buffer
        relevance = field

        // Rebuild overlays against the new indices (also re-sets the state clamp and
        // republishes the mesh contribution if the mesh overlay is on).
        applyOverlays(overlays)

        // Re-light the focus/filter the fresh relevance field started neutral.
        if let filter = activeFilter {
            relevance.write(.filter, filter.relevance(for: stars, floor: relevance.floor))
        }
        if systemFocused, let focused = focusedStarIndex, focused < stars.count {
            relevance.focus(on: focused)
        } else if let selected = selectedStarIndex, selected < stars.count {
            relevance.focus(on: selected)
        }

        // Re-diffuse the nebulae against the new star set (deterministic — same seed,
        // only the star-avoidance changes as systems stream in).
        regenerateNebula()
    }

    // MARK: Nebulae

    /// Rebuild the nebula puff buffer against the current star set — the diffusion tracks
    /// the surveyed stars, so a survey streaming systems in re-diffuses the field.
    private func regenerateNebula() {
        let puffs = NebulaField.generate(config: nebulaConfig, stars: stars.map(\.position))
        nebulaCount = puffs.count
        nebulaBuffer = puffs.isEmpty ? nil : device.makeBuffer(
            bytes: puffs,
            length: puffs.count * MemoryLayout<NebulaPuff>.stride,
            options: .storageModeShared)
    }

    // MARK: Overlays

    /// Refresh the live overlays (FTL mesh + ships) in place — WITHOUT rebuilding
    /// the renderer — so the camera and any in-flight interaction survive an
    /// overlay change (the async FTL links landing, a trip starting or ending).
    func updateOverlays(_ overlays: StarMapOverlays) {
        applyOverlays(overlays)
    }

    /// (Re)build the overlay geometry + relevance for `overlays`: the FTL mesh
    /// links/relay rings, the player reticle index, and the ships-in-transit
    /// ribbons, plus the state-tier relevance clamp so those systems never dim.
    /// Called from `init` (initial bake) and `updateOverlays` (live refresh).
    private func applyOverlays(_ overlays: StarMapOverlays) {
        // FTL mesh: build the graph, its link/marker geometry, and its relevance
        // contribution. `meshFalloff` sets how far off-mesh the lighting reaches
        // before receding to the field's floor.
        let mesh = FTLMesh.build(stars: stars, links: overlays.ftlLinks)
        let meshFalloff: Float = 15
        let lineVerts = mesh.lineVertices(for: stars)
        meshLineVertexCount = lineVerts.count
        meshLineBuffer = lineVerts.isEmpty ? nil : device.makeBuffer(
            bytes: lineVerts,
            length: lineVerts.count * MemoryLayout<MeshLineVertex>.stride,
            options: .storageModeShared)

        // Relay rings: one per relay system, sized to encircle its star (its
        // `worldRadius`) with a pixel floor so they stay visible at overview.
        let relayRingColor = SIMD3<Float>(0.30, 0.68, 1.0)
        let relayMarkers = mesh.nodes.map { i in
            StateMarker(position: stars[i].position, color: relayRingColor,
                        radiusPixels: 8, style: 0, worldRadius: stars[i].worldRadius)
        }
        relayMarkerCount = relayMarkers.count
        relayMarkerBuffer = relayMarkers.isEmpty ? nil : device.makeBuffer(
            bytes: relayMarkers,
            length: relayMarkers.count * MemoryLayout<StateMarker>.stride,
            options: .storageModeShared)
        meshContribution = mesh.relevance(for: stars, floor: relevance.floor, falloffRadius: meshFalloff)
        // If the mesh overlay is currently on, re-publish its (recomputed) relevance.
        if meshActive { relevance.write(.mesh, meshContribution) }

        // State overlay: the player reticle sits on the replicant's current-location
        // system (flagged on the terrain), falling back to the system nearest Sol
        // when no current location is known yet (e.g. before the account loads).
        let player = stars.firstIndex(where: \.isCurrentLocation)
            ?? stars.indices.min {
                simd_length_squared(stars[$0].position) < simd_length_squared(stars[$1].position)
            } ?? 0
        playerStarIndex = player

        // Ships in transit: resolve each real route's endpoint systems to star
        // indices and convert its wall-clock trip window into the renderer's
        // media-time domain (captured now), so `draw` places each ship along its
        // trajectory with a cheap linear map. Routes whose endpoints aren't in the
        // charted terrain are skipped.
        let indexByName = Dictionary(
            stars.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { first, _ in first })
        let buildMedia = CACurrentMediaTime()
        let buildDate = Date()
        func media(_ date: Date) -> Double { buildMedia + date.timeIntervalSince(buildDate) }
        func systemName(_ code: String) -> String { String(code.split(separator: "-").first ?? "") }
        let fleet: [Ship] = overlays.ships.compactMap { route in
            guard let from = indexByName[route.from], let to = indexByName[route.to], from != to
            else { return nil }
            let departed = media(route.departedAt)
            let arrives = media(route.arrivesAt)
            // Resolve legs to system-star endpoints + media windows, anchored so the LAST
            // leg ends at arrival (the live `travel` block lists only the remaining legs).
            // Needs every leg to carry a duration; otherwise a single straight segment.
            var shipLegs: [Ship.Leg] = []
            if !route.legs.isEmpty, route.legs.allSatisfy({ $0.seconds != nil }) {
                var end = arrives
                for leg in route.legs.reversed() {
                    let start = end - (leg.seconds ?? 0)
                    let fs = indexByName[systemName(leg.from)] ?? from
                    let ts = indexByName[systemName(leg.to)] ?? to
                    shipLegs.append(Ship.Leg(fromStar: fs, toStar: ts,
                                             fromCode: leg.from, toCode: leg.to,
                                             startMedia: start, endMedia: end))
                    end = start
                }
                shipLegs.reverse()
            }
            return Ship(deviceCode: route.deviceCode, fromStar: from, toStar: to,
                        departedMedia: departed, arrivesMedia: arrives,
                        arrivesAt: route.arrivesAt, legs: shipLegs)
        }
        ships = fleet
        // Ribbon as a polyline through each ship's distinct system nodes (one segment for
        // the common two-system trip). Record where each segment's 6 vertices start so the
        // encoder can draw + progress them individually.
        var shipVerts: [MeshLineVertex] = []
        var segments: [(vertexStart: Int, aStar: Int, bStar: Int, shipIndex: Int)] = []
        for (si, ship) in fleet.enumerated() {
            let nodes = ship.nodeStars
            for (a, b) in zip(nodes, nodes.dropFirst()) where a != b {
                segments.append((vertexStart: shipVerts.count, aStar: a, bStar: b, shipIndex: si))
                shipVerts.append(contentsOf: MeshLineVertex.ribbon(stars[a].position, stars[b].position))
            }
        }
        shipSegments = segments
        shipLineBuffer = shipVerts.isEmpty ? nil : device.makeBuffer(
            bytes: shipVerts,
            length: shipVerts.count * MemoryLayout<MeshLineVertex>.stride,
            options: .storageModeShared)

        // State-tier clamp: the player and every ship endpoint can never dim,
        // whatever the reference overlays want (Invariant 2).
        var clamp: Set<Int> = [player]
        for s in fleet { clamp.insert(s.fromStar); clamp.insert(s.toStar) }
        relevance.setStateClamp(clamp)
    }

    /// Toggle the FTL mesh: draw its links, and write (or clear) its relevance
    /// contribution — max-combined with any active focus so on-mesh systems stay
    /// lit while the rest of the field recedes.
    func toggleMesh() {
        meshActive.toggle()
        relevance.write(.mesh, meshActive ? meshContribution : nil)
    }

    /// Toggle the status-symbol row (exploration/life/resources/inventory) shown
    /// under each label.
    func toggleSymbols() {
        showSymbols.toggle()
    }

    /// Advance the data filter: off → life → minerals → gas → rare → unexplored →
    /// off. The active filter writes a relevance contribution (matching systems
    /// stay lit), max-combined with the mesh/focus. Returns the new filter's label.
    @discardableResult
    func cycleDataFilter() -> String? {
        let all = DataFilter.allCases
        if let current = activeFilter, let i = all.firstIndex(of: current) {
            activeFilter = i + 1 < all.count ? all[i + 1] : nil
        } else {
            activeFilter = all.first
        }
        relevance.write(.filter, activeFilter?.relevance(for: stars, floor: relevance.floor))
        return activeFilter?.label
    }

    // MARK: Private

    /// Encode the state overlay into the HDR pass: ship trajectories (comet tail +
    /// dashed remainder), then the player reticle and ship comet heads on top.
    /// Always drawn and never relevance-dimmed — it's game state, not terrain.
    private func encodeStateOverlay(_ enc: MTLRenderCommandEncoder,
                                    uniforms: inout Uniforms,
                                    params: inout MeshParams,
                                    now: Double) {
        // Ship trajectory ribbons — depth-tested (a body in front occludes them).
        if let shipLineBuffer {
            enc.setRenderPipelineState(shipLinePipeline)
            enc.setDepthStencilState(readDepthState)
            enc.setVertexBuffer(shipLineBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setVertexBytes(&params, length: MemoryLayout<MeshParams>.stride, index: 2)
            // Each polyline segment: the traveled/remaining split is the head's fraction
            // ALONG that segment, so the comet tail flows continuously across a multi-system
            // route (a segment before the head fills fully; the one after stays empty).
            for seg in shipSegments {
                let ship = ships[seg.shipIndex]
                let a = stars[seg.aStar].position, b = stars[seg.bStar].position
                let head = ship.position(at: now, stars: stars)
                var sp = ShipParams(color: shipColor,
                                    progress: segmentProgress(head: head, a: a, b: b),
                                    halfWidthPixels: shipLineHalfWidth,
                                    tailLength: 0.35,
                                    dashCyclePixels: shipDashCyclePixels(a: a, b: b, uniforms: uniforms, params: params))
                enc.setVertexBytes(&sp, length: MemoryLayout<ShipParams>.stride, index: 3)
                enc.setFragmentBytes(&sp, length: MemoryLayout<ShipParams>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: seg.vertexStart, vertexCount: 6)
            }
        }

        enc.setRenderPipelineState(stateMarkerPipeline)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setVertexBytes(&params, length: MemoryLayout<MeshParams>.stride, index: 2)

        // Player reticle — a ring on its star, depth-tested so a nearer body
        // occludes it (reads with the bodies, not through them). Style 2 = the bold
        // current-location reticle: a thicker ring at a wider clearance than a relay
        // ring (style 0), so it stays obvious on a star that is both.
        var playerMarker = StateMarker(
            position: stars[playerStarIndex].position, color: playerColor,
            radiusPixels: playerMarkerRadius, style: 2,
            worldRadius: stars[playerStarIndex].worldRadius)
        enc.setDepthStencilState(readDepthState)
        enc.setVertexBytes(&playerMarker, length: MemoryLayout<StateMarker>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)

        // Ship comet heads — the ONE exception: always on top, never occluded
        // (never lose a ship behind a star). Rebuilt each frame as the heads move.
        let heads = ships.map { ship in
            StateMarker(position: ship.position(at: now, stars: stars),
                        color: shipColor, radiusPixels: shipHeadRadius,
                        style: 1, worldRadius: 0)
        }
        if !heads.isEmpty {
            enc.setDepthStencilState(noDepthState)
            heads.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: heads.count)
        }
    }

    /// Draw a comet head for every ship on an intra-system leg within the focused system,
    /// placed via the active layer's `OrreryLayout` (the same resolve the SwiftUI icon
    /// uses). Additive glow, always on top — the in-orrery counterpart of the galaxy heads.
    private func encodeOrreryShipHeads(_ enc: MTLRenderCommandEncoder,
                                       uniforms: inout Uniforms, params: inout MeshParams, now: Double) {
        guard systemFocused, !ships.isEmpty, let model = orreryModel else { return }
        let reveal = orreryIsBody ? bodyProgress : orreryReveal
        let layout = orreryLayout(model: model, center: orreryCenter, scale: orreryScale,
                                  reveal: reveal, time: orbitClock)
        let heads: [StateMarker] = ships.compactMap { ship in
            guard let pos = ship.orreryPosition(at: now, resolve: { layout.position(ofLocation: $0) })
            else { return nil }
            return StateMarker(position: pos, color: shipColor,
                               radiusPixels: shipHeadRadius, style: 1, worldRadius: 0)
        }
        guard !heads.isEmpty else { return }
        // These heads sit at true orrery positions (like the bodies + the SwiftUI icon that
        // tracks them), so disable `overlayPushed` for this draw — otherwise the shader's
        // galaxy recession (`1 + systemPush·orreryReveal`, ≈3×) flings the head out from its
        // icon mid-drill. Zeroing `orreryReveal` makes the push an identity; head markers
        // have `worldRadius == 0`, so the reveal-driven star-size collapse doesn't apply.
        var u = uniforms
        u.orreryReveal = 0
        enc.setRenderPipelineState(stateMarkerPipeline)
        enc.setDepthStencilState(noDepthState)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setVertexBytes(&params, length: MemoryLayout<MeshParams>.stride, index: 2)
        heads.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: heads.count)
    }

    // MARK: Inbound / outbound transit affordance

    /// The active orrery layer's resolver for transit placement (system focus only), or nil
    /// in the galaxy. Mirrors `encodeOrreryShipHeads` / `emitClusterProjection`.
    private func orreryTransitLayout() -> OrreryLayout? {
        guard systemFocused, orreryReveal > 0.001, let model = orreryModel else { return nil }
        let reveal = orreryIsBody ? bodyProgress : orreryReveal
        return orreryLayout(model: model, center: orreryCenter, scale: orreryScale,
                            reveal: reveal, time: orbitClock)
    }

    /// The world height of a transit riser — a fraction of the framed system radius, so it
    /// stays proportional at system and body level and emerges with the orrery `reveal`.
    private func transitRiserWorldHeight(reveal: Float) -> Float {
        guard let model = orreryModel else { return 0 }
        return Float(model.frameScene) * transitRiserFraction * orreryScale * reveal
    }

    /// Draw the dotted risers + in-view connectors for every ship whose route crosses the
    /// boundary of the focused view (see `SystemTransit`). Reuses the ship-trajectory
    /// pipeline as a PURE dashed line (`progress: 0` ⇒ no traveled tail), depth-read so a
    /// nearer body occludes it like the ship ribbons. The SwiftUI callout cards float over
    /// the top of each riser (`emitTransitProjection`).
    private func encodeOrreryTransit(_ enc: MTLRenderCommandEncoder, uniforms: Uniforms,
                                     params: inout MeshParams, now: Double) {
        guard !ships.isEmpty, let layout = orreryTransitLayout() else { return }
        let reveal = orreryIsBody ? bodyProgress : orreryReveal
        let height = transitRiserWorldHeight(reveal: reveal)
        let resolves: (String) -> Bool = { layout.position(ofLocation: $0) != nil }

        var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
        for ship in ships {
            let result = SystemTransit.resolve(orderedCodes: ship.orderedCodes,
                                               deviceCode: ship.deviceCode, resolves: resolves)
            guard !result.boundaries.isEmpty else { continue }
            // Connector: trace consecutive in-view anchors (the in-system route path).
            let pts = result.connectorCodes.compactMap { layout.position(ofLocation: $0) }
            if pts.count > 1 {
                for i in 0..<(pts.count - 1) { segments.append((pts[i], pts[i + 1])) }
            }
            // Risers: straight up out of the orbital plane at each boundary anchor.
            for boundary in result.boundaries {
                guard let base = layout.position(ofLocation: boundary.anchorCode) else { continue }
                segments.append((base, base + SIMD3<Float>(0, height, 0)))
            }
        }
        guard !segments.isEmpty else { return }

        // Two shader overrides, both because `ship_line` is a GALAXY overlay by default:
        // 1. `overlayDim` drives its fade to 0 on drill-in — override it with the reveal so
        //    the transit lines are visible in-orrery (this is where they belong).
        // 2. `overlayPushed` (in the vertex shader) pushes points radially from the focused
        //    star by `1 + systemPush·orreryReveal` (≈3× here) to clear the galaxy field on
        //    a drill. Orrery bodies/pips and the CPU-projected callout are NOT pushed, so a
        //    pushed line lands far outside the orbits. Zero `orreryReveal` in this copy to
        //    make `overlayPushed` an identity, so the line tracks the true body positions.
        var u = uniforms
        u.overlayDim = orreryReveal
        u.orreryReveal = 0
        enc.setRenderPipelineState(shipLinePipeline)
        enc.setDepthStencilState(readDepthState)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setVertexBytes(&params, length: MemoryLayout<MeshParams>.stride, index: 2)
        for (a, b) in segments {
            let verts = MeshLineVertex.ribbon(a, b)
            var sp = ShipParams(color: shipColor, progress: 0, halfWidthPixels: shipLineHalfWidth,
                                tailLength: 0,
                                dashCyclePixels: shipDashCyclePixels(a: a, b: b, uniforms: u, params: params))
            verts.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            enc.setVertexBytes(&sp, length: MemoryLayout<ShipParams>.stride, index: 3)
            enc.setFragmentBytes(&sp, length: MemoryLayout<ShipParams>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    /// Project the top of each transit riser to view points and push the callouts to the
    /// SwiftUI overlay via `onTransitsProjected`. Empty in the galaxy / for routes that
    /// don't touch this view. Uses `bounds.size` (POINTS) for SwiftUI's local space.
    private func emitTransitProjection(view: MTKView, now: Double) {
        guard let emit = onTransitsProjected else { return }
        guard !ships.isEmpty, let layout = orreryTransitLayout() else { emit([]); return }
        let reveal = orreryIsBody ? bodyProgress : orreryReveal
        let height = transitRiserWorldHeight(reveal: reveal)
        let resolves: (String) -> Bool = { layout.position(ofLocation: $0) != nil }
        let viewM = camera.viewMatrix()
        let proj = camera.projectionMatrix(aspect: aspect)
        let size = view.bounds.size
        let w = Float(size.width), h = Float(size.height)
        guard w > 0, h > 0 else { emit([]); return }
        let op = Double(orreryReveal)

        var out: [ProjectedTransit] = []
        for ship in ships {
            let result = SystemTransit.resolve(orderedCodes: ship.orderedCodes,
                                               deviceCode: ship.deviceCode, resolves: resolves)
            for boundary in result.boundaries {
                guard let base = layout.position(ofLocation: boundary.anchorCode) else { continue }
                let top = base + SIMD3<Float>(0, height, 0)
                guard let point = projectViewPoint(top, view: viewM, proj: proj, width: w, height: h)
                else { continue }
                out.append(ProjectedTransit(
                    deviceCode: boundary.deviceCode,
                    direction: boundary.direction == .inbound ? .inbound : .outbound,
                    endpointCode: boundary.endpointCode,
                    viaCode: boundary.viaCode,
                    arrivesAt: ship.arrivesAt,
                    point: point, opacity: op))
            }
        }
        emit(out)
    }

    /// The screen-pixel length of one dash+gap cycle for a ship's trajectory. Each
    /// visible dash targets `shipDashWorldLength` in world units, clamped to a
    /// screen-space pixel band, so dashes never balloon on zoom-in or vanish on
    /// zoom-out. The shader lays these cycles down along the ribbon's true screen
    /// arc-length (`in.screenDist`), so the cadence is uniform even under perspective.
    private func shipDashCyclePixels(a a0: SIMD3<Float>, b b0: SIMD3<Float>,
                                     uniforms: Uniforms, params: MeshParams) -> Float {
        // Mirror the shader's system-focus recession (Shaders.metal overlayPushed) so
        // the CPU measures the same endpoints the GPU draws. Identity at overview.
        func pushed(_ p: SIMD3<Float>) -> SIMD3<Float> {
            guard uniforms.orreryReveal > 0 else { return p }
            let center = SIMD3<Float>(uniforms.orreryCenter.x, uniforms.orreryCenter.y, uniforms.orreryCenter.z)
            return center + (p - center) * (1 + uniforms.systemPush * uniforms.orreryReveal)
        }
        let a = pushed(a0)
        let b = pushed(b0)
        let worldLen = simd_length(b - a)
        // Fallback cycle (~mid-band) when the trajectory is degenerate or off-screen.
        let fallback = (shipDashMinPixels + shipDashMaxPixels)
        guard worldLen > 1e-4 else { return fallback }

        // Project both endpoints to screen pixels the same way the vertex shader does.
        // This only sets the world→screen scale for the world-length TARGET; the dash
        // *distribution* is handled per-fragment in screen space by the shader.
        let vp = uniforms.projection * uniforms.view
        let half = params.viewportPixels * 0.5
        func screen(_ p: SIMD3<Float>) -> SIMD2<Float>? {
            let c = vp * SIMD4<Float>(p, 1)
            guard c.w > 1e-4 else { return nil }            // behind the camera
            return SIMD2<Float>(c.x, c.y) / c.w * half
        }
        guard let sa = screen(a), let sb = screen(b) else { return fallback }
        let screenLen = simd_length(sb - sa)
        guard screenLen > 1e-4 else { return fallback }

        // Ideal on-screen dash length if we honoured the world target exactly, then
        // clamp to the pixel band. Cycle = dash + equal gap = 2·dash.
        let idealDashPx = shipDashWorldLength * screenLen / worldLen
        let dashPx = min(max(idealDashPx, shipDashMinPixels), shipDashMaxPixels)
        return 2 * dashPx
    }

    /// The head's fraction 0…1 along a ribbon segment (a→b) — its projection onto the
    /// segment, clamped. A segment the head has passed reads 1 (fully traveled), one ahead
    /// reads 0, the active one reads the partial split.
    private func segmentProgress(head: SIMD3<Float>, a: SIMD3<Float>, b: SIMD3<Float>) -> Float {
        let ab = b - a
        let denom = simd_dot(ab, ab)
        guard denom > 1e-6 else { return 1 }
        return min(max(simd_dot(head - a, ab) / denom, 0), 1)
    }

    /// Encode the curated labels over the tone-mapped drawable: pick the selected
    /// star plus the nearest on-screen systems, measure each name, resolve overlaps
    /// (LabelEngine), and draw the surviving labels as textured quads.
    private func encodeLabels(_ enc: MTLRenderCommandEncoder, viewportPx: SIMD2<Float>) {
        // Once labels have faded out (deep enough into the drill / orbiting the
        // orrery), stop the whole subsystem — no projection, layout, or rasterize.
        let labelDim = self.labelDim
        if labelDim <= 0.001 {
            labelOpacity.removeAll()   // already invisible; snapping the bookkeeping is unseen
            return
        }

        let view = camera.viewMatrix()
        let proj = camera.projectionMatrix(aspect: aspect)
        let ys = proj.columns.1.y                 // = 1/tan(fovy/2), for pixel sizing
        let eye = camera.eye
        let w = viewportPx.x, h = viewportPx.y

        // Mirror the shader's system-focus recession (Shaders.metal star_vertex) so a
        // label tracks its star as the field pushes away — they recede together while
        // fading. The focused star (orrery sun) is exempt, matching the shader.
        func pushed(_ i: Int) -> SIMD3<Float> {
            let p = stars[i].position
            guard i != focusedStarIndex, orreryReveal > 0 else { return p }
            return orreryCenter + (p - orreryCenter) * (1 + systemPush * orreryReveal)
        }

        // Labels are normally constant pixel size regardless of distance. During the
        // drill-in, shrink each one to match its star's recession so it reads as
        // attached: the perspective shrink from the push alone (near/far distance
        // ratio, independent of the camera dive) times the same `fieldShrink` the
        // star body gets. 1 when not focusing.
        func recessionScale(_ i: Int) -> Float {
            guard i != focusedStarIndex, orreryReveal > 0 else { return 1 }
            let near = simd_length((view * SIMD4<Float>(stars[i].position, 1)).xyz)
            let far  = simd_length((view * SIMD4<Float>(pushed(i), 1)).xyz)
            let perspective = far > 1e-4 ? near / far : 1
            return perspective * (1 + (fieldShrink - 1) * orreryReveal)
        }

        // Project a star and return its screen point, eye distance, and the pixel
        // radius of its reticle ring (the same size-encodes-depth math the markers
        // use), so the label can be placed just outside that ring.
        func screen(_ i: Int) -> (px: SIMD2<Float>, dist: Float, ringR: Float)? {
            let wp = pushed(i)
            let vpos = view * SIMD4<Float>(wp, 1)
            let clip = proj * vpos
            if clip.w <= 0 { return nil }                  // behind the camera
            let ndc = SIMD2<Float>(clip.x / clip.w, clip.y / clip.w)
            if abs(ndc.x) > 1.1 || abs(ndc.y) > 1.1 { return nil }
            let px = SIMD2<Float>((ndc.x * 0.5 + 0.5) * w, (0.5 - ndc.y * 0.5) * h)
            let camDist = simd_length(vpos.xyz)
            let rv = min(max(stars[i].worldRadius, camDist * minAngularSize), camDist * maxAngularSize)
            let starPixels = ys * rv / clip.w * (h * 0.5)
            let ringR = max(starPixels * 1.3, labelRingFloor)
            return (px, simd_length(wp - eye), ringR)
        }

        var onscreen: [(i: Int, px: SIMD2<Float>, dist: Float, ringR: Float)] = []
        for i in stars.indices {
            if let s = screen(i) { onscreen.append((i, s.px, s.dist, s.ringR)) }
        }
        onscreen.sort { $0.dist < $1.dist }

        // Curated set, gated by zoom: 0 labels when fully zoomed out, up to
        // maxContextLabels fully zoomed in. The selected star is always labelled.
        let budget = Int((Float(maxContextLabels) * camera.zoomedInFraction).rounded())
        var chosen = Array(onscreen.prefix(budget))
        if let sel = selectedStarIndex, !chosen.contains(where: { $0.i == sel }),
           let s = screen(sel) {
            chosen.append((sel, s.px, 0, s.ringR))
        }

        // Measure (rasterize once, cached) and build candidates. Each label anchors
        // at a top-centre point just below its star, clear of the ring. The selected
        // star gets top priority; the rest rank by nearness (closer = higher).
        var candidates: [LabelEngine.Candidate] = []
        var textures: [Int: MTLTexture] = [:]
        for c in chosen {
            let symbols = showSymbols ? stars[c.i].statusSymbols : []
            guard let label = labelCache.texture(name: stars[c.i].name, symbols: symbols) else { continue }
            textures[c.i] = label.texture
            let priority: Float = (c.i == selectedStarIndex) ? .greatestFiniteMagnitude : -c.dist
            let anchor = SIMD2<Float>(c.px.x, c.px.y + c.ringR + labelGap)
            candidates.append(.init(id: c.i, anchor: anchor, size: label.size, priority: priority))
        }
        let placements = LabelEngine.layout(candidates)
        let placedById = Dictionary(placements.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Ease each label's opacity toward 1 (placed) or 0 (not), so labels fade in
        // and out instead of snapping. Labels leaving the set fade in place; once
        // nearly gone (or off-screen), they're dropped.
        let now = CACurrentMediaTime()
        var dt = now - lastLabelTime
        if dt <= 0 || dt > 0.25 { dt = 1.0 / 60 }
        lastLabelTime = now
        let ease = Float(1 - exp(-dt / labelFadeTau))
        for id in placedById.keys {
            labelOpacity[id, default: 0] += (1 - (labelOpacity[id] ?? 0)) * ease
        }
        for id in Array(labelOpacity.keys) where placedById[id] == nil {
            labelOpacity[id]! += (0 - labelOpacity[id]!) * ease
        }

        enc.setRenderPipelineState(labelPipeline)
        var stale: [Int] = []
        for (id, opacity) in labelOpacity {
            if opacity < 0.01 { stale.append(id); continue }

            var origin: SIMD2<Float>, size: SIMD2<Float>
            let tex: MTLTexture
            if let p = placedById[id], let t = textures[id] {
                origin = p.origin; size = p.size; tex = t
            } else if let s = screen(id),
                      let label = labelCache.texture(name: stars[id].name,
                                                     symbols: showSymbols ? stars[id].statusSymbols : []) {
                // Fading out: recompute its centred position (not collision-tested).
                size = label.size; tex = label.texture
                origin = SIMD2<Float>(s.px.x - size.x * 0.5, s.px.y + s.ringR + labelGap)
            } else {
                stale.append(id); continue   // gone off-screen mid-fade → drop
            }

            // Shrink with the star's recession, keeping the top-centre point (the edge
            // nearest the star) fixed so the label stays hugging the reticle ring.
            let scale = recessionScale(id)
            if scale < 0.999 {
                let centerX = origin.x + size.x * 0.5
                size *= scale
                origin = SIMD2<Float>(centerX - size.x * 0.5, origin.y)
            }

            var lp = LabelParams(originPx: origin, sizePx: size, viewportPx: viewportPx,
                                 opacity: opacity * labelDim, _pad: 0)   // fade out on drill-in
            enc.setVertexBytes(&lp, length: MemoryLayout<LabelParams>.stride, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        for id in stale { labelOpacity.removeValue(forKey: id) }
    }

    /// Project a world point to view POINTS (top-left origin) for the SwiftUI overlays —
    /// the single world→screen map shared by the ship and device-cluster projections (and
    /// available to any other overlay). Nil when the point is behind the camera.
    private func projectViewPoint(_ world: SIMD3<Float>, view: float4x4, proj: float4x4,
                                  width: Float, height: Float) -> CGPoint? {
        var clip = proj * (view * SIMD4<Float>(world, 1))
        if clip.w <= 0 { return nil }
        clip /= clip.w
        return CGPoint(x: CGFloat((clip.x * 0.5 + 0.5) * width),
                       y: CGFloat((1 - (clip.y * 0.5 + 0.5)) * height))
    }

    /// Additive blend into the HDR (rgba16Float) target — shared by every pass
    /// that sums light into the field (stars, mesh links, relay markers).
    private static func configureAdditiveHDR(_ ca: MTLRenderPipelineColorAttachmentDescriptor) {
        ca.pixelFormat = .rgba16Float
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .one
        ca.destinationRGBBlendFactor = .one
        ca.sourceAlphaBlendFactor = .one
        ca.destinationAlphaBlendFactor = .one
    }

    private func makeUniforms() -> Uniforms {
        Uniforms(
            view: camera.viewMatrix(),
            projection: camera.projectionMatrix(aspect: aspect),
            minAngularSize: minAngularSize,
            maxAngularSize: maxAngularSize,
            atmoNear: atmoNear,
            atmoFar: atmoFar,
            atmoFloor: atmoFloor,
            exposure: exposure,
            lodStart: lodStart,
            lodFull: lodFull,
            time: Float(CACurrentMediaTime() - startTime),
            fieldDim: fieldDim,
            orreryReveal: orreryReveal,
            bodyReveal: bodyProgress,
            orreryAlpha: orreryReveal * layerOpacity(isBody: orreryIsBody),
            overlayDim: overlayDim,
            systemPush: systemPush,
            fieldShrink: fieldShrink,
            focusedStar: Int32(focusedStarIndex ?? -1),
            orreryCenter: SIMD4(orreryCenter, 0)
        )
    }

    private func makeHDRTexture(size: CGSize) {
        let w = max(Int(size.width), 1), h = max(Int(size.height), 1)
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        hdrTexture = device.makeTexture(descriptor: d)

        // Depth for resolved-body occlusion. Memoryless where supported: it lives
        // only in tile memory (never stored), so it costs ~no bandwidth.
        let dd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: depthFormat, width: w, height: h, mipmapped: false)
        dd.usage = .renderTarget
        dd.storageMode = .memoryless
        depthTexture = device.makeTexture(descriptor: dd)
        if depthTexture == nil {                 // memoryless unsupported (e.g. Intel) → fall back
            dd.storageMode = .private
            depthTexture = device.makeTexture(descriptor: dd)
        }
    }
}
