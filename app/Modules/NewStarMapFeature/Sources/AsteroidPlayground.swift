import AppKit
import CStarMapShaderTypes
import MetalKit
import SwiftUI
import UI
import simd

// A live inspection surface for the irregular-body impostor: ONE captured asteroid,
// centred, that you can orbit with the trackpad and re-roll at will. Finding a real one
// in the orrery means drilling into the right planet and zooming onto a body a few pixels
// across, which is a slow way to answer "does this read as a rock?".
//
// It draws through the PRODUCTION path on purpose — `orrery_body_vertex` /
// `orrery_body_fragment` and the real `tonemap_fragment`, fed a real `OrreryBodyUniform`
// built the same way `StarFieldRenderer.bodyUniform` builds one, with the surface resolved
// by the same `PlanetMaterial.surface`. A playground with its own copy of the shader would
// drift from the thing it is supposed to be judging, and would then lie about it. The cost
// of that choice is that this file has to reproduce the renderer's two-pass setup (HDR
// offscreen, then tone-map to the drawable); the benefit is that what you see here is what
// the map draws.

// MARK: - Knobs

struct AsteroidParams: Equatable {
    /// Drives the shape, the noise field, and the tumble axis — everything that makes one
    /// rock differ from another. This is the value "Randomize" re-rolls.
    var seed: Float = 0.37
    /// `PlanetMaterial.irregularity` bakes 0.45 for every captured asteroid; exposed here
    /// because it is the one constant most likely to want tuning by eye.
    var irregularity: Float = 0.45
    var spinRate: Float = 0.35
    var sunAzimuth: Float = 0.9
    var sunElevation: Float = 0.30
    var exposure: Float = 1.3
    /// An unscanned body renders duller and staticky — the same `estimated` flag the map
    /// uses for an unconfirmed moon.
    var scanned: Bool = true

    /// The API type string, run through the same lookups the renderer uses, so the
    /// playground cannot accidentally render a body the orrery would classify differently.
    static let apiType = "Captured Asteroid"
}

// MARK: - Renderer

final class AsteroidRenderer: NSObject, MTKViewDelegate {
    var params = AsteroidParams()

    // Camera. Held here rather than in SwiftUI state so a drag doesn't re-evaluate the
    // whole view tree on every mouse-moved event.
    var azimuth: Float = 0.6
    var elevation: Float = 0.25
    /// Far enough that the WHOLE rock fits at any roll. The long axis reaches ~1.54×
    /// the nominal radius (unit-product axes), which at the 0.6 rad vertical FOV below
    /// subtends atan(1.54/d); keeping that under the 0.3 rad half-FOV needs d > 5.1.
    /// Zooming closer than that is allowed — it just crops, which is often what you want.
    var distance: Float = 6

    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var bodyPipeline: MTLRenderPipelineState?
    private var tonemapPipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var hdrTexture: MTLTexture?
    private var depthTexture: MTLTexture?
    private let start = CACurrentMediaTime()

    /// The body's world radius. Everything else (camera distance, sun distance) is in the
    /// same units, so this is really just "1" with a name.
    private let bodyRadius: Float = 1

    @MainActor func configure(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: .module)
        else { return }
        self.device = device
        self.queue = queue

        // Mirrors `StarFieldRenderer`'s orreryBodyDesc exactly — same formats, same blend.
        let bodyDesc = MTLRenderPipelineDescriptor()
        bodyDesc.vertexFunction = library.makeFunction(name: "orrery_body_vertex")
        bodyDesc.fragmentFunction = library.makeFunction(name: "orrery_body_fragment")
        let att = bodyDesc.colorAttachments[0]!
        att.pixelFormat = .rgba16Float
        att.isBlendingEnabled = true
        att.rgbBlendOperation = .add
        att.alphaBlendOperation = .add
        att.sourceRGBBlendFactor = .sourceAlpha
        att.destinationRGBBlendFactor = .oneMinusSourceAlpha
        att.sourceAlphaBlendFactor = .one
        att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        bodyDesc.depthAttachmentPixelFormat = .depth32Float
        bodyPipeline = try? device.makeRenderPipelineState(descriptor: bodyDesc)

        let tmDesc = MTLRenderPipelineDescriptor()
        tmDesc.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
        tmDesc.fragmentFunction = library.makeFunction(name: "tonemap_fragment")
        tmDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        tonemapPipeline = try? device.makeRenderPipelineState(descriptor: tmDesc)

        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dd)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        hdrTexture = nil
        depthTexture = nil
    }

    func draw(in view: MTKView) {
        let size = view.drawableSize
        guard let device, let queue, let bodyPipeline, let tonemapPipeline, let depthState,
              size.width > 0, size.height > 0,
              let drawable = view.currentDrawable,
              let finalPass = view.currentRenderPassDescriptor
        else { return }

        makeTargets(device: device, size: size)
        guard let hdrTexture, let depthTexture,
              let cmd = queue.makeCommandBuffer()
        else { return }

        var u = uniforms(aspect: Float(size.width / size.height))
        var body = bodyUniform()

        // Pass 1 — the body into the HDR target, exactly as the map's orrery pass runs.
        let scene = MTLRenderPassDescriptor()
        scene.colorAttachments[0].texture = hdrTexture
        scene.colorAttachments[0].loadAction = .clear
        scene.colorAttachments[0].storeAction = .store
        scene.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        scene.depthAttachment.texture = depthTexture
        scene.depthAttachment.loadAction = .clear
        scene.depthAttachment.storeAction = .dontCare
        scene.depthAttachment.clearDepth = 1
        if let enc = cmd.makeRenderCommandEncoder(descriptor: scene) {
            enc.setRenderPipelineState(bodyPipeline)
            enc.setDepthStencilState(depthState)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setVertexBytes(&body, length: MemoryLayout<OrreryBodyUniform>.stride, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.endEncoding()
        }

        // Pass 2 — tone-map to the drawable. Without this the body is raw linear HDR and
        // reads far darker than it does in the map.
        if let enc = cmd.makeRenderCommandEncoder(descriptor: finalPass) {
            enc.setRenderPipelineState(tonemapPipeline)
            enc.setFragmentTexture(hdrTexture, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: Camera controls (called from the view's event overrides)

    func orbit(dAzimuth: Float, dElevation: Float) {
        azimuth += dAzimuth
        // Clamped short of the poles: at exactly ±90° the look-at up vector is parallel to
        // the view direction and the basis collapses.
        elevation = max(-1.45, min(1.45, elevation + dElevation))
    }

    func dolly(_ amount: Float) {
        distance = max(1.6, min(20, distance * exp(-amount)))
    }

    // MARK: Building the frame

    private func makeTargets(device: MTLDevice, size: CGSize) {
        let w = Int(size.width), h = Int(size.height)
        if let hdrTexture, hdrTexture.width == w, hdrTexture.height == h { return }

        let color = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        color.usage = [.renderTarget, .shaderRead]
        color.storageMode = .private
        hdrTexture = device.makeTexture(descriptor: color)

        let depth = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
        depth.usage = [.renderTarget]
        depth.storageMode = .private
        depthTexture = device.makeTexture(descriptor: depth)
    }

    private func uniforms(aspect: Float) -> Uniforms {
        var u = Uniforms()
        let ce = cos(elevation), se = sin(elevation)
        let eye = SIMD3<Float>(distance * ce * sin(azimuth), distance * se, distance * ce * cos(azimuth))
        u.view = .lookAt(eye: eye, center: .zero, up: SIMD3(0, 1, 0))
        u.projection = .perspective(fovyRadians: 0.6, aspect: aspect, near: 0.05, far: 200)
        u.time = Float(CACurrentMediaTime() - start)
        // The body fragment multiplies its alpha by this; at 0 the rock is invisible.
        u.orreryAlpha = 1
        u.exposure = params.exposure
        return u
    }

    /// Built the same way `StarFieldRenderer.bodyUniform` builds one, from the same
    /// `PlanetMaterial` lookups — so a change to either shows up here without editing this
    /// file.
    private func bodyUniform() -> OrreryBodyUniform {
        let type = PlanetType(apiType: AsteroidParams.apiType)
        let s = PlanetMaterial.surface(for: type, lifeStage: nil, estimated: !params.scanned)
        let axes = params.irregularity > 0
            ? PlanetMaterial.irregularAxes(seed: params.seed)
            : SIMD3<Float>(1, 0, 0)
        let spinAxis = BodySpin.renderSpinAxis(
            irregularity: params.irregularity, locked: false,
            pole: BodySpin.unknown.pole(seed: params.seed), tumbleSeed: params.seed)

        let ce = cos(params.sunElevation), se = sin(params.sunElevation)
        let sun = SIMD3<Float>(50 * ce * sin(params.sunAzimuth), 50 * se, 50 * ce * cos(params.sunAzimuth))

        return OrreryBodyUniform(
            centerRadius: SIMD4(.zero, bodyRadius),
            color: SIMD4(s.base, s.polarIce),
            sunEmissive: SIMD4(sun, s.greenVibrancy),
            detailColor: SIMD4(s.detail, Float(s.style.rawValue)),
            surfaceParams: SIMD4(s.estimated ? 1 : 0, s.life, 0, params.seed),
            surfaceMods: SIMD4(s.mods.craters, s.mods.atmosphere, s.mods.lava, s.mods.frost),
            spinAxis: SIMD4(spinAxis, params.spinRate),
            surfaceExtras: SIMD4(0, params.irregularity, axes.y, axes.z))
    }
}

// MARK: - Metal view bridge

/// Same gesture dialect as the real star map (`MetalStarView`): two-finger scroll orbits,
/// pinch zooms, roll is ignored. Dragging orbits too, for anyone on a mouse.
final class AsteroidMTKView: MTKView {
    var renderer: AsteroidRenderer?

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        renderer?.orbit(dAzimuth: Float(event.scrollingDeltaX) * 0.005,
                        dElevation: Float(event.scrollingDeltaY) * 0.005)
    }

    override func mouseDragged(with event: NSEvent) {
        renderer?.orbit(dAzimuth: Float(event.deltaX) * 0.008,
                        dElevation: Float(event.deltaY) * 0.008)
    }

    override func magnify(with event: NSEvent) {
        renderer?.dolly(Float(event.magnification) * 2.0)
    }
}

struct MetalAsteroidView: NSViewRepresentable {
    var params: AsteroidParams

    func makeCoordinator() -> AsteroidRenderer { AsteroidRenderer() }

    func makeNSView(context: Context) -> MTKView {
        let view = AsteroidMTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.delegate = context.coordinator
        view.renderer = context.coordinator
        context.coordinator.configure(view: view)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.params = params
    }
}

// MARK: - Playground UI

public struct AsteroidPlaygroundView: View {
    @State private var params = AsteroidParams()

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            MetalAsteroidView(params: params)
                .frame(minWidth: 380, minHeight: 380)
                .background(Color.black)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    group("Body") {
                        Button("Randomize") { params.seed = Float.random(in: 0..<1) }
                            .keyboardShortcut(.space, modifiers: [])
                        shapeReadout
                        slider("Irregularity", $params.irregularity, 0...1)
                        slider("Spin rate", $params.spinRate, 0...2)
                        Toggle("Scanned", isOn: $params.scanned)
                            .font(.rcCaption)
                    }
                    group("Lighting") {
                        slider("Sun azimuth", $params.sunAzimuth, -3.14...3.14)
                        slider("Sun elevation", $params.sunElevation, -1.5...1.5)
                        slider("Exposure", $params.exposure, 0.2...3)
                    }

                    Text("Two-finger scroll orbits · pinch zooms")
                        .font(.rcCaption)
                        .foregroundStyle(.secondary)

                    Button("Reset") { params = AsteroidParams() }
                        .padding(.top, Space.xs)
                }
                .padding(Space.l)
            }
            .frame(width: 300)
        }
        .frame(minWidth: 700, minHeight: 440)
    }

    // MARK: Pieces

    /// The resolved shape, so a roll that looks wrong can be read as numbers rather than
    /// guessed at. Aspect is the cue that separates "rock" from "small planet".
    @ViewBuilder
    private var shapeReadout: some View {
        let a = PlanetMaterial.irregularAxes(seed: params.seed)
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "seed %.3f", params.seed))
            Text(String(format: "axes %.2f · %.2f · %.2f", a.x, a.y, a.z))
            Text(String(format: "aspect %.2f : 1", a.x / a.z))
        }
        .font(.rcMonoSmall)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(.rcCaption).foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func slider(_ label: String, _ value: Binding<Float>, _ range: ClosedRange<Float>) -> some View {
        HStack {
            Text(label).font(.rcCaption)
            Spacer()
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.rcMonoSmall).foregroundStyle(.secondary)
        }
        Slider(value: value, in: range)
    }
}

#Preview {
    AsteroidPlaygroundView().frame(width: 860, height: 520)
}
