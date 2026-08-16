import AppKit
import CStarMapShaderTypes
import MetalKit
import UniverseModels
import os
import simd

private let logger = Logger(subsystem: "name.pennig.replicould", category: "NewStarMapFeature")

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
    private var pointPipeline: MTLRenderPipelineState?
    private var tonemapPipeline: MTLRenderPipelineState?
    private var bodyDepthState: MTLDepthStencilState?
    private var readDepthState: MTLDepthStencilState?
    private var noDepthState: MTLDepthStencilState?
    private var hdrTexture: MTLTexture?
    private var depthTexture: MTLTexture?
    private let start = CACurrentMediaTime()

    /// `extent()` and `encodeSubject` both derive the current planet/moon's look;
    /// cached here so a frame pays for it once, invalidated by subject/options.
    private var cachedAppearance: (subject: BodyPortrait, options: OrreryMapping.OrreryPlaneOptions, value: BodyAppearance)?

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
        else {
            logger.error("BodyPortraitRenderer.configure: no Metal device, queue, or default library")
            return
        }
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
            do {
                return try device.makeRenderPipelineState(descriptor: d)
            } catch {
                logger.error("BodyPortraitRenderer pipeline \(vertex)/\(fragment) failed: \(error)")
                return nil
            }
        }

        bodyPipeline = pipeline("orrery_body_vertex", "orrery_body_fragment", alphaOver)
        ringPipeline = pipeline("orrery_ring_vertex", "orrery_ring_fragment", alphaOver)
        atmoPipeline = pipeline("orrery_atmosphere_vertex", "orrery_atmosphere_fragment", additive)
        starGlowPipeline = pipeline("star_vertex", "star_fragment", additive)
        starDiscPipeline = pipeline("star_vertex", "star_body_fragment", alphaOver)
        pointPipeline = pipeline("orrery_point_vertex", "orrery_point_fragment", additive)

        let tm = MTLRenderPipelineDescriptor()
        tm.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
        tm.fragmentFunction = library.makeFunction(name: "tonemap_fragment")
        tm.colorAttachments[0].pixelFormat = view.colorPixelFormat
        do {
            tonemapPipeline = try device.makeRenderPipelineState(descriptor: tm)
        } catch {
            logger.error("BodyPortraitRenderer pipeline fullscreen_vertex/tonemap_fragment failed: \(error)")
        }

        let bd = MTLDepthStencilDescriptor()
        bd.depthCompareFunction = .less; bd.isDepthWriteEnabled = true
        bodyDepthState = device.makeDepthStencilState(descriptor: bd)
        let rd = MTLDepthStencilDescriptor()
        rd.depthCompareFunction = .less; rd.isDepthWriteEnabled = false
        readDepthState = device.makeDepthStencilState(descriptor: rd)
        let nd = MTLDepthStencilDescriptor()
        nd.depthCompareFunction = .always; nd.isDepthWriteEnabled = false
        noDepthState = device.makeDepthStencilState(descriptor: nd)
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
            guard let a = appearance() else { return }
            encodeBody(a, designation: p.designation, into: enc, uniforms: &u)
        case .moon(let m):
            guard let a = appearance() else { return }
            encodeBody(a, designation: m.designation, into: enc, uniforms: &u)
        case .star(let s):
            encodeStar(s, into: enc, uniforms: &u)
        case .belt(let b):
            encodePoints(Self.beltBand(for: b), into: enc, uniforms: &u)
        case .region(let s):
            encodePoints(Self.regionBand(for: s), into: enc, uniforms: &u)
        case .none:
            break
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
        guard let starGlowPipeline, let starDiscPipeline, let bodyDepthState, let noDepthState
        else { return }

        var instance = Self.starInstance(for: star, radius: bodyRadius)
        var relevance: Float = 1                  // 1.0 = fully relevant
        var relRange = SIMD2<Float>(0, 2)         // one draw, keep every fragment

        // Both draws share star_vertex's billboard geometry, so a depth-writing glow
        // would occlude the disc drawn right behind it at the same depth.
        enc.setRenderPipelineState(starGlowPipeline)
        enc.setDepthStencilState(noDepthState)
        enc.setVertexBytes(&instance, length: MemoryLayout<StarInstance>.stride, index: 0)
        enc.setVertexBytes(&relevance, length: MemoryLayout<Float>.stride, index: 1)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)

        enc.setRenderPipelineState(starDiscPipeline)
        enc.setDepthStencilState(bodyDepthState)
        enc.setVertexBytes(&instance, length: MemoryLayout<StarInstance>.stride, index: 0)
        enc.setVertexBytes(&relevance, length: MemoryLayout<Float>.stride, index: 1)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
        enc.setFragmentBytes(&relRange, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
    }

    /// A belt framed on its own. Absolute orbital radius means nothing without the
    /// star to measure it against, so only the band's true width carries over.
    static func beltBand(for belt: Belt) -> BeltModel {
        let inner = OrreryMapping.sceneRadius(au: belt.innerRadiusAu ?? 0)
        let outer = OrreryMapping.sceneRadius(au: belt.outerRadiusAu ?? 0)
        let width = max(outer - inner, 0.8)
        return BeltModel(designation: belt.designation, innerScene: 6,
                         outerScene: 6 + width, density: belt.density,
                         richness: belt.richness, hasSites: !belt.sites.isEmpty)
    }

    static func regionBand(for site: SpecialSite) -> BeltModel {
        BeltModel(designation: site.designation, innerScene: 5, outerScene: 9,
                  density: "sparse", richness: [:], hasSites: false)
    }

    private func encodePoints(_ band: BeltModel, into enc: MTLRenderCommandEncoder,
                              uniforms u: inout Uniforms) {
        guard let pointPipeline, let device, let readDepthState else { return }
        let star = StarDetail(designation: band.designation, name: nil, spectralType: nil,
                              color: nil, position: Position(x: 0, y: 0, z: 0),
                              temperatureK: nil, massSolar: nil, luminositySolar: nil,
                              ageMy: nil, habitableZone: nil, miningBonusPct: nil)
        let model = SystemModel(star: star, hzInnerScene: nil, hzOuterScene: nil,
                                planets: [], belts: [band], hazards: [], kuiperScene: nil,
                                frameScene: band.outerScene, deviceCount: 0, vesselCount: 0)
        let pts = OrreryGeometry.beltPoints(model: model, center: .zero, scale: 1)
        guard !pts.isEmpty,
              let buffer = device.makeBuffer(
                  bytes: pts,
                  length: MemoryLayout<AmbientVertex>.stride * pts.count,
                  options: .storageModeShared)
        else { return }
        enc.setRenderPipelineState(pointPipeline)
        enc.setDepthStencilState(readDepthState)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pts.count)
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
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                              vertexCount: (StarFieldRenderer.ringSegments + 1) * 2)
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
        case .planet:
            let rings = appearance()?.rings
            return max(1.54, rings.map { $0.outerFrac } ?? 1)
        case .belt(let b):   return Float(Self.beltBand(for: b).outerScene)
        case .region(let s): return Float(Self.regionBand(for: s).outerScene)
        default:
            return 1.54
        }
    }

    /// The current planet/moon subject's derived look, cached until `subject`
    /// or `options` changes.
    private func appearance() -> BodyAppearance? {
        guard let subject else { return nil }
        if let c = cachedAppearance, c.subject == subject, c.options == options {
            return c.value
        }
        let value: BodyAppearance
        switch subject {
        case .planet(let p): value = OrreryMapping.appearance(planet: p, options: options)
        case .moon(let m):   value = OrreryMapping.appearance(moon: m, options: options)
        default: return nil
        }
        cachedAppearance = (subject, options, value)
        return value
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
        // A ring viewed near edge-on reads as a line, so give it a steeper camera.
        let elevation: Float
        switch subject {
        case .belt, .region: elevation = cameraElevation * 1.6
        default:              elevation = cameraElevation
        }
        let ce = cos(elevation), se = sin(elevation)
        let eye = SIMD3<Float>(d * ce * sin(cameraAzimuth), d * se, d * ce * cos(cameraAzimuth))
        u.view = .lookAt(eye: eye, center: .zero, up: SIMD3(0, 1, 0))
        u.projection = .perspective(fovyRadians: fovy, aspect: aspect,
                                    near: max(0.01, d * 0.02), far: 200)
        u.time = Float(CACurrentMediaTime() - start)
        // Body, ring and halo all multiply coverage by this. At 0 the body renders
        // correctly and completely invisibly.
        u.orreryAlpha = 1
        u.exposure = exposure
        switch subject {
        case .belt, .region:
            // The point vertex scales its local offset by reveal; at 0 the whole ring
            // collapses into its own centre.
            u.orreryReveal = 1
            u.orreryCenter = SIMD4(repeating: 0)
            u.orreryBuildCenter = SIMD4(repeating: 0)
        default:
            break
        }
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
