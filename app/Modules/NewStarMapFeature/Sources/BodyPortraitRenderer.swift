import AppKit
import CStarMapShaderTypes
import MetalKit
import UniverseModels
import simd

/// Draws one body alone through the star map's own shaders and tone-map, so a body
/// looks the same in a location inspector as it does in the map.
final class BodyPortraitRenderer: NSObject, MTKViewDelegate {
    var subject: BodyPortrait?
    /// Must match what the map reads, or a body leans differently in the two views.
    /// `OrreryPlaneOptions` is nested in `OrreryMapping`, so it needs qualifying here.
    var options: OrreryMapping.OrreryPlaneOptions = .default

    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var bodyPipeline: MTLRenderPipelineState?
    private var ringPipeline: MTLRenderPipelineState?
    private var atmoPipeline: MTLRenderPipelineState?
    private var starGlowPipeline: MTLRenderPipelineState?
    private var starDiscPipeline: MTLRenderPipelineState?
    private var tonemapPipeline: MTLRenderPipelineState?
    private var bodyDepthState: MTLDepthStencilState?
    private var readDepthState: MTLDepthStencilState?
    private var hdrTexture: MTLTexture?
    private var depthTexture: MTLTexture?
    private let start = CACurrentMediaTime()

    private let bodyRadius: Float = 1
    private let fovy: Float = 60 * .pi / 180
    private let cameraAzimuth: Float = 0.6
    private let cameraElevation: Float = 18 * .pi / 180
    private let sunAzimuth: Float = 0.9
    private let sunElevation: Float = 0.30
    private let exposure: Float = 1.3

    @MainActor func configure(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: .module)
        else { return }
        self.device = device
        self.queue = queue

        func alphaOver(_ ca: MTLRenderPipelineColorAttachmentDescriptor) {
            ca.pixelFormat = .rgba16Float
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .sourceAlpha
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.sourceAlphaBlendFactor = .one
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        func additive(_ ca: MTLRenderPipelineColorAttachmentDescriptor) {
            ca.pixelFormat = .rgba16Float
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .one
            ca.destinationRGBBlendFactor = .one
            ca.sourceAlphaBlendFactor = .one
            ca.destinationAlphaBlendFactor = .one
        }
        func pipeline(_ vertex: String, _ fragment: String,
                      _ blend: (MTLRenderPipelineColorAttachmentDescriptor) -> Void)
            -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            blend(d.colorAttachments[0]!)
            d.depthAttachmentPixelFormat = .depth32Float
            return try? device.makeRenderPipelineState(descriptor: d)
        }

        bodyPipeline = pipeline("orrery_body_vertex", "orrery_body_fragment", alphaOver)
        ringPipeline = pipeline("orrery_ring_vertex", "orrery_ring_fragment", alphaOver)
        atmoPipeline = pipeline("orrery_atmosphere_vertex", "orrery_atmosphere_fragment", additive)
        starGlowPipeline = pipeline("star_vertex", "star_fragment", additive)
        starDiscPipeline = pipeline("star_vertex", "star_body_fragment", alphaOver)

        let tm = MTLRenderPipelineDescriptor()
        tm.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
        tm.fragmentFunction = library.makeFunction(name: "tonemap_fragment")
        tm.colorAttachments[0].pixelFormat = view.colorPixelFormat
        tonemapPipeline = try? device.makeRenderPipelineState(descriptor: tm)

        let bd = MTLDepthStencilDescriptor()
        bd.depthCompareFunction = .less; bd.isDepthWriteEnabled = true
        bodyDepthState = device.makeDepthStencilState(descriptor: bd)
        let rd = MTLDepthStencilDescriptor()
        rd.depthCompareFunction = .less; rd.isDepthWriteEnabled = false
        readDepthState = device.makeDepthStencilState(descriptor: rd)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        hdrTexture = nil
        depthTexture = nil
    }

    func draw(in view: MTKView) {
        let size = view.drawableSize
        guard let device, let queue, let tonemapPipeline,
              size.width > 0, size.height > 0,
              let drawable = view.currentDrawable,
              let finalPass = view.currentRenderPassDescriptor
        else { return }

        makeTargets(device: device, size: size)
        guard let hdrTexture, let depthTexture, let cmd = queue.makeCommandBuffer() else { return }

        var u = uniforms(aspect: Float(size.width / size.height))

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
            encodeSubject(into: enc, uniforms: &u)
            enc.endEncoding()
        }

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

    private func encodeSubject(into enc: MTLRenderCommandEncoder, uniforms u: inout Uniforms) {
        switch subject {
        case .planet(let p):
            encodeBody(OrreryMapping.appearance(planet: p, options: options),
                       designation: p.designation, into: enc, uniforms: &u)
        case .moon(let m):
            encodeBody(OrreryMapping.appearance(moon: m, options: options),
                       designation: m.designation, into: enc, uniforms: &u)
        case .star(let s):
            encodeStar(s, into: enc, uniforms: &u)
        case .belt, .region, .none:
            break   // Task 9
        }
    }

    /// A star's rendered colour comes from its spectral-class STRING, exactly as
    /// `LiveStar` derives it. `SystemStar.temperatureK` is real but the map ignores it.
    static func starInstance(for star: SystemStar, radius: Float) -> StarInstance {
        let klass = StellarClass(spectralType: star.stellarClass ?? "G")
        return StarInstance(
            positionRadius: SIMD4(SIMD3<Float>.zero, radius),
            color: SIMD4(Star.color(forTemperature: klass.representativeTemperature), 1))
    }

    private func encodeStar(_ star: SystemStar, into enc: MTLRenderCommandEncoder,
                            uniforms u: inout Uniforms) {
        guard let starGlowPipeline, let starDiscPipeline, let bodyDepthState else { return }

        var instance = Self.starInstance(for: star, radius: bodyRadius)
        var relevance: Float = 1                  // 1.0 = fully relevant
        var relRange = SIMD2<Float>(0, 2)         // one draw, keep every fragment

        enc.setRenderPipelineState(starGlowPipeline)
        enc.setDepthStencilState(bodyDepthState)
        enc.setVertexBytes(&instance, length: MemoryLayout<StarInstance>.stride, index: 0)
        enc.setVertexBytes(&relevance, length: MemoryLayout<Float>.stride, index: 1)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)

        enc.setRenderPipelineState(starDiscPipeline)
        enc.setVertexBytes(&instance, length: MemoryLayout<StarInstance>.stride, index: 0)
        enc.setVertexBytes(&relevance, length: MemoryLayout<Float>.stride, index: 1)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
        enc.setFragmentBytes(&relRange, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
    }

    private func encodeBody(_ appearance: BodyAppearance, designation: String,
                            into enc: MTLRenderCommandEncoder, uniforms u: inout Uniforms) {
        guard let bodyPipeline, let bodyDepthState, let readDepthState else { return }
        let placed = PlacedBody(portrait: appearance, designation: designation,
                                center: .zero, radius: bodyRadius, sun: sunPosition())

        enc.setRenderPipelineState(bodyPipeline)
        enc.setDepthStencilState(bodyDepthState)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        var body = bodyUniform(placed)
        enc.setVertexBytes(&body, length: MemoryLayout<OrreryBodyUniform>.stride, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        if var ring = ringUniform(placed), let ringPipeline {
            enc.setRenderPipelineState(ringPipeline)
            enc.setDepthStencilState(readDepthState)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setVertexBytes(&ring, length: MemoryLayout<OrreryRingUniform>.stride, index: 2)
            enc.setFragmentBytes(&ring, length: MemoryLayout<OrreryRingUniform>.stride, index: 2)
            // SYNC POINT: kRingSegments = 192 in Orrery.metal.
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 193 * 2)
        }

        if var atmo = atmosphereUniform(placed), let atmoPipeline {
            enc.setRenderPipelineState(atmoPipeline)
            enc.setDepthStencilState(readDepthState)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setVertexBytes(&atmo, length: MemoryLayout<OrreryAtmosphereUniform>.stride, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

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

    /// The widest thing the frame must hold, in body radii — a ring's outer edge, or
    /// an irregular body's long axis at 1.54x (unit-product axes).
    private func extent() -> Float {
        switch subject {
        case .planet(let p):
            let rings = OrreryMapping.appearance(planet: p, options: options).rings
            return max(1.54, rings.map { $0.outerFrac } ?? 1)
        default:
            return 1.54
        }
    }

    private func cameraDistance() -> Float {
        if case .star = subject { return bodyRadius * 2.3 }
        let fill: Float = 0.85
        return max(extent() * bodyRadius / (tan(fovy * 0.5) * fill), bodyRadius * 5.1)
    }

    private func sunPosition() -> SIMD3<Float> {
        let ce = cos(sunElevation), se = sin(sunElevation)
        // 40x the radius, matching bodySunDistance. A nearer sun unlights the body.
        let d = bodyRadius * 40
        return SIMD3(d * ce * sin(sunAzimuth), d * se, d * ce * cos(sunAzimuth))
    }

    private func uniforms(aspect: Float) -> Uniforms {
        var u = Uniforms()
        let d = cameraDistance()
        let ce = cos(cameraElevation), se = sin(cameraElevation)
        let eye = SIMD3<Float>(d * ce * sin(cameraAzimuth), d * se, d * ce * cos(cameraAzimuth))
        u.view = .lookAt(eye: eye, center: .zero, up: SIMD3(0, 1, 0))
        u.projection = .perspective(fovyRadians: fovy, aspect: aspect,
                                    near: max(0.01, d * 0.02), far: 200)
        u.time = Float(CACurrentMediaTime() - start)
        // Body, ring and halo all multiply coverage by this. At 0 the body renders
        // correctly and completely invisibly.
        u.orreryAlpha = 1
        u.exposure = exposure
        if case .star = subject {
            u.minAngularSize = 0.0015
            u.maxAngularSize = 0.05
            // Left at zero, `atmo` collapses to 0 and the star renders black.
            u.atmoNear = 40; u.atmoFar = 420; u.atmoFloor = 1
            u.lodStart = 0.004; u.lodFull = 0.018
            u.fieldDim = 1
            // Matching focusedStar to the instance with bodyReveal 0 lifts the angular
            // ceiling from 0.05 to 1e9; otherwise no distance yields a full disc.
            u.focusedStar = 0
            u.bodyReveal = 0
        }
        return u
    }
}
