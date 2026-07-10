import AppKit
import CStarMapShaderTypes
import MetalKit
import SwiftUI
import simd

// A live tuning surface for the star's solar flares: a single centred star rendered
// by the dedicated playground shader (FlarePlaygroundShaders.metal), with a slider
// for every knob the production star_fragment bakes as a constant. Dial in the look,
// hit "Copy values", and paste the winners back into Shaders.metal.

// MARK: - Defaults (mirror the current production constants)

extension FlareParams {
    static var playgroundDefault: FlareParams {
        var p = FlareParams()
        p.lod = 1.0
        p.discEdge = 0.798
        p.spinRate = 0.12
        p.intensity = 0.348
        p.baseFreq = 3.0
        p.baseTimeScale = 0.30
        p.baseWeight = 0.528
        p.flickFreq = 10.548
        p.flickTimeScale = 0.55
        p.flickWeight = 0.536
        p.heightPower = 1.953
        p.tongueBand = 0.457
        p.radialFalloff = 0.455
        p.edgeFadeStart = 0.749
        p.hotMix = 0.604
        p.coolMix = 0.896
        p.discBrightness = 2.2
        p.granTimeScale = 0.29
        p.exposure = 1.3
        p.starColor = SIMD4(1.00, 0.88, 0.70, 1)
        p.hotColor = SIMD4(1.00, 0.82, 0.50, 1)
        p.coolColor = SIMD4(0.95, 0.20, 0.05, 1)
        return p
    }
}

// MARK: - Renderer

final class FlareRenderer: NSObject, MTKViewDelegate {
    var params = FlareParams.playgroundDefault
    var cameraOrbitSpeed: Float = 0.2

    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private let startTime = CACurrentMediaTime()
    private var lastTime = CACurrentMediaTime()
    private var orbitAngle: Float = 0

    @MainActor func configure(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: .module)
        else { return }
        self.device = device
        self.queue = queue

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "fp_vertex")
        desc.fragmentFunction = library.makeFunction(name: "fp_fragment")
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipeline = try? device.makeRenderPipelineState(descriptor: desc)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline, let queue,
              let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastTime, 0), 0.1))
        lastTime = now
        orbitAngle += cameraOrbitSpeed * dt

        var p = params
        p.time = Float(now - startTime)
        let size = view.drawableSize
        p.aspect = size.height > 0 ? Float(size.width / size.height) : 1
        var viewMatrix = Self.rotationX(0.35) * Self.rotationY(orbitAngle)

        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&p, length: MemoryLayout<FlareParams>.stride, index: 0)
        enc.setFragmentBytes(&p, length: MemoryLayout<FlareParams>.stride, index: 0)
        enc.setFragmentBytes(&viewMatrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
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
}

// MARK: - Metal view bridge

struct MetalFlareView: NSViewRepresentable {
    var params: FlareParams
    var cameraOrbitSpeed: Float

    func makeCoordinator() -> FlareRenderer { FlareRenderer() }

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
        context.coordinator.params = params
        context.coordinator.cameraOrbitSpeed = cameraOrbitSpeed
    }
}

// MARK: - Playground UI

public struct FlarePlaygroundView: View {
    @State private var params = FlareParams.playgroundDefault
    @State private var cameraOrbitSpeed: Float = 0.2

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            MetalFlareView(params: params, cameraOrbitSpeed: cameraOrbitSpeed)
                .frame(minWidth: 380, minHeight: 380)
                .background(Color.black)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    group("Scene") {
                        slider("LOD", $params.lod, 0...1)
                        slider("Camera orbit", $cameraOrbitSpeed, 0...1.5)
                        slider("Spin rate", $params.spinRate, 0...1)
                        slider("Disc edge", $params.discEdge, 0.30...0.95)
                        slider("Disc bright", $params.discBrightness, 0...4)
                        slider("Gran boil", $params.granTimeScale, 0...0.5)
                        slider("Exposure", $params.exposure, 0.2...3)
                    }
                    group("Tongue shape") {
                        slider("Intensity", $params.intensity, 0...6)
                        slider("Height power", $params.heightPower, 0.5...3)
                        slider("Tongue band", $params.tongueBand, 0.02...0.5)
                        slider("Radial falloff", $params.radialFalloff, 0...1)
                        slider("Edge fade", $params.edgeFadeStart, 0.5...1)
                    }
                    group("Noise — slow layer") {
                        slider("Base freq", $params.baseFreq, 0.5...8)
                        slider("Base time", $params.baseTimeScale, 0...2)
                        slider("Base weight", $params.baseWeight, 0...1.5)
                    }
                    group("Noise — fast layer") {
                        slider("Flick freq", $params.flickFreq, 1...16)
                        slider("Flick time", $params.flickTimeScale, 0...4)
                        slider("Flick weight", $params.flickWeight, 0...1.5)
                    }
                    group("Colour") {
                        slider("Hot mix", $params.hotMix, 0...1)
                        slider("Cool mix", $params.coolMix, 0...1)
                        colorRow("Star", \.starColor)
                        colorRow("Hot base", \.hotColor)
                        colorRow("Cool tip", \.coolColor)
                    }

                    HStack {
                        Button("Reset") { params = .playgroundDefault; cameraOrbitSpeed = 0.2 }
                        Button("Copy values") { copyValues() }
                    }
                    .padding(.top, 4)
                }
                .padding(16)
            }
            .frame(width: 340)
        }
        .frame(minWidth: 740, minHeight: 460)
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
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.caption.monospaced()).frame(width: 42, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    private func colorRow(_ label: String, _ keyPath: WritableKeyPath<FlareParams, SIMD4<Float>>) -> some View {
        ColorPicker(selection: colorBinding(keyPath), supportsOpacity: false) {
            Text(label).font(.caption).frame(width: 96, alignment: .leading)
        }
    }

    private func colorBinding(_ keyPath: WritableKeyPath<FlareParams, SIMD4<Float>>) -> Binding<Color> {
        Binding(
            get: {
                let c = params[keyPath: keyPath]
                return Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z))
            },
            set: { newValue in
                let ns = NSColor(newValue).usingColorSpace(.sRGB) ?? .white
                params[keyPath: keyPath] = SIMD4(Float(ns.redComponent), Float(ns.greenComponent),
                                                 Float(ns.blueComponent), 1)
            })
    }

    private func copyValues() {
        let p = params
        func f(_ v: Float) -> String { String(format: "%.3f", v) }
        func c(_ v: SIMD4<Float>) -> String { "float3(\(f(v.x)), \(f(v.y)), \(f(v.z)))" }
        let text = """
        // Flare tuning
        discEdge        = \(f(p.discEdge))
        spinRate        = \(f(p.spinRate))
        granTimeScale   = \(f(p.granTimeScale))
        intensity       = \(f(p.intensity))
        baseFreq        = \(f(p.baseFreq))
        baseTimeScale   = \(f(p.baseTimeScale))
        baseWeight      = \(f(p.baseWeight))
        flickFreq       = \(f(p.flickFreq))
        flickTimeScale  = \(f(p.flickTimeScale))
        flickWeight     = \(f(p.flickWeight))
        heightPower     = \(f(p.heightPower))
        tongueBand      = \(f(p.tongueBand))
        radialFalloff   = \(f(p.radialFalloff))
        edgeFadeStart   = \(f(p.edgeFadeStart))
        hotMix          = \(f(p.hotMix))
        coolMix         = \(f(p.coolMix))
        hotColor        = \(c(p.hotColor))
        coolColor       = \(c(p.coolColor))
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

#Preview("Flare Playground") {
    FlarePlaygroundView().frame(width: 900, height: 620)
}
