import AppKit
import CStarMapShaderTypes
import MetalKit
import QuartzCore
import SwiftUI
import simd

// A live tuning surface for the reworked nebulae — the sibling of FlarePlayground.
// The left pane renders a representative surveyed-star scatter (Galaxy.generate) with
// the dust clouds drawn over/among it by NebulaField + the nebula playground shaders,
// on a slowly orbiting camera so their volume and depth read. The right pane exposes
// every knob: three style "experiments" (puffs / filaments / turbulent), the render
// controls (exposure, size, softness…), the cloud shape, and the star-diffusion. Dial
// in a look, hit "Copy values", and paste the config back into the live ambient field.
//
// Open it the same way as the flare playground: via its #Preview at the bottom.

// MARK: - Defaults

extension NebulaUniforms {
    static var playgroundDefault: NebulaUniforms {
        var u = NebulaUniforms()
        u.sizeScale = 1.0
        u.brightness = 1.0
        u.softness = 1.6
        u.exposure = 1.2
        u.saturation = 1.1
        u.coreBoost = 0.4
        u.time = 0
        return u
    }
}

// MARK: - Renderer

final class NebulaRenderer: NSObject, MTKViewDelegate {

    /// Generation-side config. A change flags a CPU rebuild of the puff buffer (only on
    /// an actual change — the view pushes this every frame).
    var config = NebulaConfig() { didSet { if config != oldValue { needsRegen = true } } }
    /// Live render knobs (free, per-frame).
    var renderParams = NebulaUniforms.playgroundDefault
    var cameraOrbitSpeed: Float = 0.15
    var showStars = true

    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var nebulaPipeline: MTLRenderPipelineState?
    private var starPipeline: MTLRenderPipelineState?
    private var tonemapPipeline: MTLRenderPipelineState?

    private var hdrTexture: MTLTexture?
    private var hdrSize = CGSize.zero

    // The fixed star scatter (stable while tuning) and its GPU instances.
    private let starPositions: [SIMD3<Float>]
    private let starInstances: [StarInstance]
    private var starBuffer: MTLBuffer?

    private var nebulaBuffer: MTLBuffer?
    private var nebulaCount = 0
    private var needsRegen = true

    // Camera: a slow turntable framing the ~90 ly survey bubble plus surrounding clouds.
    private let distance: Float = 340
    private let elevation: Float = 0.42
    private var orbit: Float = 0.6
    private let startTime = CACurrentMediaTime()
    private var lastTime = CACurrentMediaTime()

    /// Puff count from the last rebuild (surfaced in the UI so the cap is visible).
    private(set) var lastPuffCount = 0

    override init() {
        let stars = Galaxy.generate(starCount: 2500, seed: 0xC0FFEE)
        starPositions = stars.map(\.position)
        starInstances = stars.map(\.renderInstance)
        super.init()
    }

    @MainActor func configure(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: .module)
        else { return }
        self.device = device
        self.queue = queue

        starBuffer = device.makeBuffer(
            bytes: starInstances,
            length: starInstances.count * MemoryLayout<StarInstance>.stride,
            options: .storageModeShared)

        // HDR passes accumulate additively into rgba16Float; the tone-map resolves to
        // the drawable. Star + nebula share the additive HDR pipeline config.
        func additiveHDR(_ desc: MTLRenderPipelineDescriptor) {
            let a = desc.colorAttachments[0]!
            a.pixelFormat = .rgba16Float
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .one
            a.destinationRGBBlendFactor = .one
            a.sourceAlphaBlendFactor = .one
            a.destinationAlphaBlendFactor = .one
        }

        let nebDesc = MTLRenderPipelineDescriptor()
        nebDesc.vertexFunction = library.makeFunction(name: "neb_nebula_vertex")
        nebDesc.fragmentFunction = library.makeFunction(name: "neb_nebula_fragment")
        additiveHDR(nebDesc)

        let starDesc = MTLRenderPipelineDescriptor()
        starDesc.vertexFunction = library.makeFunction(name: "neb_star_vertex")
        starDesc.fragmentFunction = library.makeFunction(name: "neb_star_fragment")
        additiveHDR(starDesc)

        let toneDesc = MTLRenderPipelineDescriptor()
        toneDesc.vertexFunction = library.makeFunction(name: "neb_fullscreen_vertex")
        toneDesc.fragmentFunction = library.makeFunction(name: "neb_tonemap_fragment")
        toneDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat

        nebulaPipeline = try? device.makeRenderPipelineState(descriptor: nebDesc)
        starPipeline = try? device.makeRenderPipelineState(descriptor: starDesc)
        tonemapPipeline = try? device.makeRenderPipelineState(descriptor: toneDesc)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let device, let queue,
              let nebulaPipeline, let tonemapPipeline
        else { return }

        regenerateIfNeeded(device: device)
        ensureHDR(device: device, size: view.drawableSize)

        guard let hdr = hdrTexture,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer()
        else { return }

        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastTime, 0), 0.1))
        lastTime = now
        orbit += cameraOrbitSpeed * dt

        var u = renderParams
        u.time = Float(now - startTime)
        let size = view.drawableSize
        let aspect = size.height > 0 ? Float(size.width / size.height) : 1
        u.view = Self.turntable(distance: distance, elevation: elevation, azimuth: orbit)
        u.projection = Self.perspective(fovYRadians: 0.80, aspect: aspect, near: 1, far: 4000)

        // Pass 1 — additive HDR accumulation.
        let p1 = MTLRenderPassDescriptor()
        p1.colorAttachments[0].texture = hdr
        p1.colorAttachments[0].loadAction = .clear
        p1.colorAttachments[0].storeAction = .store
        p1.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        if let e = cmd.makeRenderCommandEncoder(descriptor: p1) {
            if showStars, let starPipeline, let starBuffer, !starInstances.isEmpty {
                e.setRenderPipelineState(starPipeline)
                e.setVertexBuffer(starBuffer, offset: 0, index: 0)
                e.setVertexBytes(&u, length: MemoryLayout<NebulaUniforms>.stride, index: 1)
                e.drawPrimitives(type: .point, vertexStart: 0, vertexCount: starInstances.count)
            }
            if let nebulaBuffer, nebulaCount > 0 {
                e.setRenderPipelineState(nebulaPipeline)
                e.setVertexBuffer(nebulaBuffer, offset: 0, index: 0)
                e.setVertexBytes(&u, length: MemoryLayout<NebulaUniforms>.stride, index: 1)
                e.setFragmentBytes(&u, length: MemoryLayout<NebulaUniforms>.stride, index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                 instanceCount: nebulaCount)
            }
            e.endEncoding()
        }

        // Pass 2 — tone-map to the drawable.
        if let pass = view.currentRenderPassDescriptor,
           let e = cmd.makeRenderCommandEncoder(descriptor: pass) {
            e.setRenderPipelineState(tonemapPipeline)
            e.setFragmentBytes(&u, length: MemoryLayout<NebulaUniforms>.stride, index: 0)
            e.setFragmentTexture(hdr, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            e.endEncoding()
        }

        cmd.present(drawable)
        cmd.commit()
    }

    private func regenerateIfNeeded(device: MTLDevice) {
        guard needsRegen else { return }
        needsRegen = false
        let puffs = NebulaField.generate(config: config, stars: starPositions)
        lastPuffCount = puffs.count
        nebulaCount = puffs.count
        nebulaBuffer = puffs.isEmpty ? nil : device.makeBuffer(
            bytes: puffs,
            length: puffs.count * MemoryLayout<NebulaPuff>.stride,
            options: .storageModeShared)
    }

    private func ensureHDR(device: MTLDevice, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if hdrTexture != nil, hdrSize == size { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: Int(size.width), height: Int(size.height), mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        hdrTexture = device.makeTexture(descriptor: desc)
        hdrSize = size
    }

    // MARK: Camera math

    private static func perspective(fovYRadians: Float, aspect: Float,
                                    near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tan(fovYRadians * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4(xs, 0, 0, 0),
            SIMD4(0, ys, 0, 0),
            SIMD4(0, 0, zs, -1),
            SIMD4(0, 0, zs * near, 0)))
    }

    private static func turntable(distance: Float, elevation: Float, azimuth: Float) -> simd_float4x4 {
        translation(0, 0, -distance) * rotationX(elevation) * rotationY(azimuth)
    }

    private static func rotationY(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0),
                             SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1))
    }
    private static func rotationX(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0),
                             SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1))
    }
    private static func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0),
                      SIMD4(0, 0, 1, 0), SIMD4(x, y, z, 1))
    }
}

// MARK: - Metal view bridge

struct MetalNebulaView: NSViewRepresentable {
    var config: NebulaConfig
    var renderParams: NebulaUniforms
    var cameraOrbitSpeed: Float
    var showStars: Bool

    func makeCoordinator() -> NebulaRenderer { NebulaRenderer() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.delegate = context.coordinator
        context.coordinator.configure(view: view)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.config = config
        context.coordinator.renderParams = renderParams
        context.coordinator.cameraOrbitSpeed = cameraOrbitSpeed
        context.coordinator.showStars = showStars
    }
}

// MARK: - Playground UI

public struct NebulaPlaygroundView: View {
    @State private var config = NebulaConfig()
    @State private var params = NebulaUniforms.playgroundDefault
    @State private var cameraOrbitSpeed: Float = 0.15
    @State private var showStars = true

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            MetalNebulaView(config: config, renderParams: params,
                            cameraOrbitSpeed: cameraOrbitSpeed, showStars: showStars)
                .frame(minWidth: 420, minHeight: 420)
                .background(Color.black)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    group("Experiment") {
                        Picker("Style", selection: $config.style) {
                            ForEach(NebulaStyle.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Toggle("Show stars", isOn: $showStars)
                            .font(.caption)
                        HStack {
                            Button("Reseed") { config.seed = UInt32.random(in: 1...UInt32.max) }
                            Spacer()
                            Text("seed \(String(config.seed, radix: 16))")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }

                    group("Render") {
                        slider("Exposure", $params.exposure, 0.2...3)
                        slider("Brightness", $params.brightness, 0...3)
                        slider("Puff size", $params.sizeScale, 0.2...3)
                        slider("Softness", $params.softness, 0.4...5)
                        slider("Core boost", $params.coreBoost, 0...2)
                        slider("Saturation", $params.saturation, 0...2)
                        slider("Camera orbit", $cameraOrbitSpeed, 0...1)
                    }

                    group("Shape") {
                        intSlider("Clouds", $config.cloudCount, 1...40)
                        intSlider("Puffs/cloud", $config.puffsPerCloud, 20...1200)
                        slider("Field radius", $config.fieldRadius, 20...300)
                        slider("Thickness", $config.thickness, 0.1...1)
                        slider("Cloud spread", $config.cloudSpread, 8...140)
                        slider("Elongation", $config.elongation, 1...6)
                        slider("Puff radius", $config.puffRadius, 3...60)
                        slider("Radius jitter", $config.puffRadiusJitter, 0...1)
                        slider("Turbulence", $config.turbulence, 0...4)
                        slider("Noise scale", $config.noiseScale, 0.005...0.12)
                    }

                    group("Color & density") {
                        slider("Base alpha", $config.baseAlpha, 0.01...0.4)
                        slider("Two-tone", $config.twoTone, 0...1)
                    }

                    group("Star diffusion") {
                        slider("Avoid radius", $config.starAvoidRadius, 2...80)
                        slider("Avoid strength", $config.starAvoidStrength, 0...1)
                    }

                    HStack {
                        Button("Reset") {
                            config = NebulaConfig()
                            params = .playgroundDefault
                            cameraOrbitSpeed = 0.15
                            showStars = true
                        }
                        Button("Copy values") { copyValues() }
                    }
                    .padding(.top, 4)
                }
                .padding(16)
            }
            .frame(width: 340)
        }
        .frame(minWidth: 780, minHeight: 520)
    }

    // MARK: Pieces

    @ViewBuilder
    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func slider(_ label: String, _ value: Binding<Float>, _ range: ClosedRange<Float>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 96, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.3f", value.wrappedValue))
                .font(.caption.monospaced()).frame(width: 50, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    private func intSlider(_ label: String, _ value: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 96, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
            Text("\(value.wrappedValue)")
                .font(.caption.monospaced()).frame(width: 50, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    private func copyValues() {
        func f(_ v: Float) -> String { String(format: "%.3f", v) }
        let c = config
        let p = params
        let text = """
        // Nebula tuning — style: \(c.style.label)
        // NebulaConfig
        style             = .\(String(describing: c.style))
        cloudCount        = \(c.cloudCount)
        puffsPerCloud     = \(c.puffsPerCloud)
        fieldRadius       = \(f(c.fieldRadius))
        thickness         = \(f(c.thickness))
        cloudSpread       = \(f(c.cloudSpread))
        elongation        = \(f(c.elongation))
        puffRadius        = \(f(c.puffRadius))
        puffRadiusJitter  = \(f(c.puffRadiusJitter))
        turbulence        = \(f(c.turbulence))
        noiseScale        = \(f(c.noiseScale))
        baseAlpha         = \(f(c.baseAlpha))
        twoTone           = \(f(c.twoTone))
        starAvoidRadius   = \(f(c.starAvoidRadius))
        starAvoidStrength = \(f(c.starAvoidStrength))
        // NebulaUniforms (render)
        sizeScale   = \(f(p.sizeScale))
        brightness  = \(f(p.brightness))
        softness    = \(f(p.softness))
        exposure    = \(f(p.exposure))
        saturation  = \(f(p.saturation))
        coreBoost   = \(f(p.coreBoost))
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

#Preview("Nebula Playground") {
    NebulaPlaygroundView().frame(width: 940, height: 640)
}
