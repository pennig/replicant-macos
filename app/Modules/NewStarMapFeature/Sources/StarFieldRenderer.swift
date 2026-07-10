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

    private let starBuffer: MTLBuffer
    private let stars: [Star]
    let relevance: RelevanceField

    // The interstellar medium behind the charted field: one additive point buffer.
    private let ambientBuffer: MTLBuffer?
    private let ambientVertexCount: Int

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
    /// Drill/zoom durations (seconds); match the reducer's transition lock.
    private let drillDurationBase = 1.15
    private let zoomDurationBase = 0.95

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
    private var shipLineBuffer: MTLBuffer?        // 6 ribbon vertices per ship
    private var shipLineHalfWidth: Float = 1.6    // trajectory thickness in pixels
    private var playerMarkerRadius: Float = 11    // player reticle radius in pixels
    private var shipHeadRadius: Float = 6         // ship comet-head radius in pixels
    private let playerColor = SIMD3<Float>(1.0, 0.82, 0.35)   // gold
    private let shipColor   = SIMD3<Float>(0.55, 0.95, 1.0)   // bright cyan-white

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
    private let orreryOrbitSpeed: Float = 1.2    // seconds of animation per "period day" — larger = slower
    private var atmoNear: Float = 40             // depth dimming band
    private var atmoFar: Float = 420
    private var atmoFloor: Float = 0.35          // atmospheric floor (≠ semantic floor)
    private var exposure: Float = 1.3            // global tone-map exposure
    private var lodStart: Float = 0.004          // angular size where the disc begins to appear
    private var lodFull: Float = 0.018           // angular size where it's a full luminous disc
    private var overviewRadius: Float = 180      // home / overview pull-back distance
    private var diveRadius: Float = 6           // double-click close-focus distance
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
            orreryBodyPipeline = try device.makeRenderPipelineState(descriptor: orreryBodyDesc)
            orreryLinePipeline = try device.makeRenderPipelineState(descriptor: orreryLineDesc)
            orreryPointPipeline = try device.makeRenderPipelineState(descriptor: orreryPointDesc)
            orreryPipPipeline = try device.makeRenderPipelineState(descriptor: orreryPipDesc)
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

        // Extend the far plane to contain the ambient backdrop + star shell, which
        // sit far beyond the charted bubble.
        camera.far = 6000

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
        camera.step(now: now)                // advance eased camera framing

        // Advance the shared transition progress (time-based smoothstep — a real
        // start and end), then drop the orrery only once fully back to the galaxy,
        let raw = Float(min(max((now - transitionStart) / transitionDuration, 0), 1))
        let eased = raw * raw * (3 - 2 * raw)
        systemProgress = transitionFrom + (transitionTarget - transitionFrom) * eased
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
            // 1(pre) — the interstellar medium behind everything (additive, no depth).
            if let ambientBuffer, ambientVertexCount > 0 {
                enc.setRenderPipelineState(ambientPipeline)
                enc.setDepthStencilState(noDepthState)
                enc.setVertexBuffer(ambientBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: ambientVertexCount)
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

            // Galaxy overlays (mesh + state) — hidden once the orrery dominates.
            if orreryReveal < 0.5 {
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

            // --- Orrery (system focus): scaffold rings + belt (additive), then the
            // lit sun/planets (over-blend, depth-write) so bodies occlude correctly.
            if orreryReveal > 0.001, let model = orreryModel {
                let t = Float(now - startTime)
                if let lineBuf = orreryLineBuffer, orreryLineVertexCount > 0 {
                    enc.setRenderPipelineState(orreryLinePipeline)
                    enc.setDepthStencilState(readDepthState)
                    enc.setVertexBuffer(lineBuf, offset: 0, index: 0)
                    enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                    enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                    enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: orreryLineVertexCount)
                }
                if let beltBuf = orreryBeltBuffer, orreryBeltCount > 0 {
                    enc.setRenderPipelineState(orreryPointPipeline)
                    enc.setDepthStencilState(readDepthState)
                    enc.setVertexBuffer(beltBuf, offset: 0, index: 0)
                    enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                    enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: orreryBeltCount)
                }
                // Planets: billboard sphere-impostors (round, no facets), depth-tested
                // so they occlude one another and hide behind the sun (the focused star).
                enc.setRenderPipelineState(orreryBodyPipeline)
                enc.setDepthStencilState(bodyDepthState)
                enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                for var body in orreryBodies(model: model, time: t) {
                    enc.setVertexBytes(&body, length: MemoryLayout<OrreryBodyUniform>.stride, index: 2)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                }
                // Annotation pips: indicator dots + hazard markers, on top of the
                // bodies (depth-read so a pip behind the sun is occluded), additive.
                let pips = orreryPips(model: model, time: t,
                                      viewportPx: SIMD2<Float>(Float(size.width), Float(size.height)))
                if !pips.isEmpty {
                    var pipParams = MeshParams(
                        viewportPixels: SIMD2<Float>(Float(size.width), Float(size.height)),
                        halfWidthPixels: 0, nodeRadiusPixels: 0)
                    enc.setRenderPipelineState(orreryPipPipeline)
                    enc.setDepthStencilState(readDepthState)
                    pips.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
                    enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                    enc.setVertexBytes(&pipParams, length: MemoryLayout<MeshParams>.stride, index: 2)
                    enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                       instanceCount: pips.count)
                }
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
        cameraStack.append(camera)               // restore this galaxy pose on zoom-out
        systemFocused = true
        camera.focusFloor = dFinal * 0.6         // limit how far you can zoom in
        let now = CACurrentMediaTime()
        beginTransition(to: 1, duration: drillDurationBase, now: now)
        camera.dive(on: orreryCenter, radius: dFinal, now: now, duration: transitionDuration)
    }

    /// Drill from a system into one of its planets: the planet (captured at its
    /// current orbit position in the system orrery we're leaving) becomes the lit
    /// central body with its moons orbiting. The galaxy stays receded
    /// (systemProgress holds at 1) and the star stays the (now distant) sun that
    /// lights the scene — only the camera flies and the orrery model swaps.
    func enterBody(starIndex: Int, planetID: String, model: SystemModel) {
        guard stars.indices.contains(starIndex) else { return }
        // Where the planet is right now, in the system orrery still loaded.
        let planetCenter = currentOrbiterWorldPosition(id: planetID) ?? orreryCenter
        focusedStarIndex = starIndex             // keep the system star as the (unfaded) light source
        orreryCenter = planetCenter
        orrerySunWorldPos = stars[starIndex].position
        // Body orrery: scale to a fixed world frame, dive to fill the view with it.
        let frameWorld: Float = 14
        orreryScale = frameWorld / Float(max(model.frameScene, 1))
        setOrreryModel(model)

        cameraStack.append(camera)               // restore this system pose on zoom-out
        systemFocused = true
        let dFinal = frameWorld / (tan(camera.fovy * 0.5) * 0.9)
        camera.focusFloor = dFinal * 0.6
        let now = CACurrentMediaTime()
        // Reveal already at 1 (still focused) — beginTransition only drives the fly.
        beginTransition(to: 1, duration: drillDurationBase, now: now)
        camera.dive(on: planetCenter, radius: dFinal, now: now, duration: transitionDuration)
    }

    /// Zoom out from a body back to its system: restore the system pose, put the
    /// star back at the centre as the sun, and rebuild the system orrery. The
    /// galaxy stays receded (systemProgress holds at 1).
    func exitToSystem(starIndex: Int, model: SystemModel) {
        guard stars.indices.contains(starIndex) else { return }
        focusedStarIndex = starIndex
        orreryCenter = stars[starIndex].position
        orrerySunWorldPos = orreryCenter
        let dFinal = stars[starIndex].worldRadius / maxAngularSize
        orreryScale = orreryScaleToFit(frameScene: model.frameScene, atDistance: dFinal)
        setOrreryModel(model)

        let now = CACurrentMediaTime()
        beginTransition(to: 1, duration: zoomDurationBase, now: now)
        if let saved = cameraStack.popLast() {
            camera.focusFloor = saved.focusFloor
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
        setOrreryModel(model)
    }

    /// Zoom back out to the galaxy: ease the camera back to the exact pre-drill
    /// pose. The orrery reveal fades out in `draw`; its buffers drop on next drill.
    func exitSystem() {
        systemFocused = false
        let now = CACurrentMediaTime()
        beginTransition(to: 0, duration: zoomDurationBase, now: now)
        if let saved = cameraStack.popLast() {
            camera.focusFloor = saved.focusFloor
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
    }

    /// The per-frame lit planets at their current orbit angle (`phase0 + time/period`),
    /// lit by the sun (the focused star at `orreryCenter`). Orbit radii scale with
    /// `orreryReveal` so planets EMERGE from the star on drill-in and retreat into
    /// it on zoom-out. The sun is not here — it's the persistent focused field star.
    private func orreryBodies(model: SystemModel, time: Float) -> [OrreryBodyUniform] {
        let orbitSpeed = orreryOrbitSpeed
        var bodies: [OrreryBodyUniform] = []
        bodies.reserveCapacity(model.planets.count + 1)

        // Body level: the drilled planet as a lit impostor at the centre (no orbit),
        // lit — like the moons — by the system star's distant position.
        if let central = model.centralBody {
            bodies.append(OrreryBodyUniform(
                centerRadius: SIMD4(orreryCenter, Float(central.displayRadius) * orreryScale),
                color: SIMD4(OrreryGeometry.rgb(hex: central.colorHex), 1),
                sunEmissive: SIMD4(orrerySunWorldPos, 1)))
        }

        for planet in model.planets {
            let period = max(Float(planet.periodDays) * orbitSpeed, 0.001)
            let angle = Float(planet.phase0Deg) * .pi / 180 + (time / period) * 2 * .pi
            let r = Float(planet.semiMajorScene) * orreryScale * orreryReveal   // emerge from the centre
            let pos = orreryCenter + SIMD3<Float>(cos(angle) * r, 0, sin(angle) * r)
            bodies.append(OrreryBodyUniform(
                centerRadius: SIMD4(pos, Float(planet.displayRadius) * orreryScale),
                color: SIMD4(OrreryGeometry.rgb(hex: planet.colorHex), 1),
                sunEmissive: SIMD4(orrerySunWorldPos, 0)))
        }
        return bodies
    }

    /// The per-frame annotation pips: a centred row of indicator dots above each
    /// body that carries notable features, plus a pulsing marker on each incoming
    /// hazard. Positions mirror `orreryBodies` (same orbit math, same reveal scale)
    /// so the pips track their bodies as they orbit and emerge on drill-in.
    private func orreryPips(model: SystemModel, time: Float, viewportPx: SIMD2<Float>) -> [OrreryPip] {
        let orbitSpeed = orreryOrbitSpeed    // matches orreryBodies
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

        for planet in model.planets {
            let entries = OrreryGeometry.pipEntries(planet.indicators)
            guard !entries.isEmpty else { continue }
            let period = max(Float(planet.periodDays) * orbitSpeed, 0.001)
            let angle = Float(planet.phase0Deg) * .pi / 180 + (time / period) * 2 * .pi
            let r = Float(planet.semiMajorScene) * orreryScale * orreryReveal
            let pos = orreryCenter + SIMD3<Float>(cos(angle) * r, 0, sin(angle) * r)

            // The planet's on-screen radius: project a point offset by its world
            // radius along view-x and measure the pixel span (same trick as the
            // star disc in `pickStar`). Scale the row's offset + spacing to it.
            let worldRadius = Float(planet.displayRadius) * orreryScale
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

        // Incoming hazards: one pulsing red marker at the asteroid's position; the
        // pulse quickens as its progress climbs toward impact.
        for hazard in model.hazards where hazard.orbitScene > 0 {
            let pos = orreryCenter + OrreryGeometry.hazardOffset(hazard) * orreryScale * orreryReveal
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
    /// this instant's orbit angle — same math as `orreryBodies`. Used to capture a
    /// planet's live position when drilling from the system into it.
    private func currentOrbiterWorldPosition(id: String) -> SIMD3<Float>? {
        guard let planet = orreryModel?.planets.first(where: { $0.id == id }) else { return nil }
        let orbitSpeed = orreryOrbitSpeed
        let time = Float(CACurrentMediaTime() - startTime)
        let period = max(Float(planet.periodDays) * orbitSpeed, 0.001)
        let angle = Float(planet.phase0Deg) * .pi / 180 + (time / period) * 2 * .pi
        let r = Float(planet.semiMajorScene) * orreryScale * orreryReveal
        return orreryCenter + SIMD3<Float>(cos(angle) * r, 0, sin(angle) * r)
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
        let fleet: [Ship] = overlays.ships.compactMap { route in
            guard let from = indexByName[route.from], let to = indexByName[route.to], from != to
            else { return nil }
            return Ship(fromStar: from, toStar: to,
                        departedMedia: media(route.departedAt), arrivesMedia: media(route.arrivesAt))
        }
        ships = fleet
        let shipVerts = fleet.flatMap {
            MeshLineVertex.ribbon(stars[$0.fromStar].position, stars[$0.toStar].position)
        }
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
            for (i, ship) in ships.enumerated() {
                var sp = ShipParams(color: shipColor, progress: ship.progress(at: now),
                                    halfWidthPixels: shipLineHalfWidth,
                                    tailLength: 0.35, dashPeriod: 24)
                enc.setVertexBytes(&sp, length: MemoryLayout<ShipParams>.stride, index: 3)
                enc.setFragmentBytes(&sp, length: MemoryLayout<ShipParams>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: i * 6, vertexCount: 6)
            }
        }

        enc.setRenderPipelineState(stateMarkerPipeline)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setVertexBytes(&params, length: MemoryLayout<MeshParams>.stride, index: 2)

        // Player reticle — a ring on its star, depth-tested so a nearer body
        // occludes it (reads with the bodies, not through them).
        var playerMarker = StateMarker(
            position: stars[playerStarIndex].position, color: playerColor,
            radiusPixels: playerMarkerRadius, style: 0,
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
