import AppKit
import Metal
import simd
import UI

// Rasterizes the in-transit ship icon — the `device.<type>` glyph in its 20pt
// disc — to cached Metal textures, one per (deviceType, state). The icons used to
// be SwiftUI views floated over the GPU pips and repositioned per frame through an
// observable bridge; drawing them INSIDE the Metal frame (same command buffer,
// same camera matrices as the trajectory) makes icon/trajectory sync structural
// instead of best-effort. Visuals mirror the retired `ShipIcon` SwiftUI view:
// `rcSurfaceRaised` disc, hairline ring (brighter on hover), `rcAccent` ring +
// glyph when selected. Colors resolve through the design-system tokens under the
// map's forced-dark appearance — never inline values.

/// The icon's interaction state — each rasterizes (and caches) separately.
enum ShipIconState: Hashable {
    case normal, hovered, selected
}

final class ShipIconTextureCache {
    /// Canvas edge in POINTS (the 20pt disc + breathing room for the ring's AA).
    /// The renderer sizes the drawn quad by this at the live backing scale.
    static let canvasPoints: CGFloat = 24

    private let device: MTLDevice
    private let scale: CGFloat        // raster scale (≈ backing scale for crisp glyphs)
    private var cache: [String: LabelTexture] = [:]

    private let diameter: CGFloat = 20
    private let glyphPointSize: CGFloat = IconSize.s

    init(device: MTLDevice, scale: CGFloat = 2) {
        self.device = device
        self.scale = scale
    }

    /// Texture for one ship icon. Cached by (deviceType, state) — a fleet has few
    /// distinct types and three states, so the cache stays tiny.
    func texture(deviceType: String, state: ShipIconState) -> LabelTexture? {
        let key = "\(deviceType)\u{1}\(state)"
        if let t = cache[key] { return t }
        let t = rasterize(deviceType: deviceType, state: state)
        if let t { cache[key] = t }
        return t
    }

    private func rasterize(deviceType: String, state: ShipIconState) -> LabelTexture? {
        let edge = Int(ceil(Self.canvasPoints * scale))
        guard edge > 0,
              let ctx = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // The map is forced dark (`.environment(\.colorScheme, .dark)`), so the
        // dynamic tokens — AND the symbol rasterization that consumes one — must
        // resolve inside the dark appearance regardless of the system setting.
        let draw = {
            let center = CGFloat(edge) / 2
            let r = self.diameter * self.scale / 2

            // Disc fill.
            ctx.setFillColor(NSColor.rcSurfaceRaised.cgColor)
            ctx.fillEllipse(in: CGRect(x: center - r, y: center - r, width: r * 2, height: r * 2))

            // Ring — stroked inside the disc edge (SwiftUI `strokeBorder` semantics).
            let (ringColor, ringWidth): (CGColor, CGFloat) = switch state {
            case .selected: (NSColor.rcAccent.cgColor, 1.5 * self.scale)
            case .hovered:  (NSColor.white.withAlphaComponent(0.35).cgColor, 0.5 * self.scale)
            case .normal:   (NSColor.white.withAlphaComponent(0.10).cgColor, 0.5 * self.scale)
            }
            let inset = r - ringWidth / 2
            ctx.setStrokeColor(ringColor)
            ctx.setLineWidth(ringWidth)
            ctx.strokeEllipse(in: CGRect(x: center - inset, y: center - inset,
                                         width: inset * 2, height: inset * 2))

            // Glyph — monochrome, tinted like the SwiftUI icon (accent when selected).
            let tint: NSColor = state == .selected ? .rcAccent : .rcTextPrimary
            let cfg = NSImage.SymbolConfiguration(pointSize: self.glyphPointSize * self.scale,
                                                  weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
            if let glyph = NSImage.rcSymbol("device.\(deviceType)")?.withSymbolConfiguration(cfg) {
                var rect = CGRect(origin: .zero, size: glyph.size)
                if let cg = glyph.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                    let gw = glyph.size.width, gh = glyph.size.height
                    ctx.draw(cg, in: CGRect(x: center - gw / 2, y: center - gh / 2,
                                            width: gw, height: gh))
                }
            }
        }
        if let dark = NSAppearance(named: .darkAqua) {
            dark.performAsCurrentDrawingAppearance(draw)
        } else {
            draw()
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: edge, height: edge, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc), let data = ctx.data else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, edge, edge), mipmapLevel: 0,
                    withBytes: data, bytesPerRow: ctx.bytesPerRow)
        return LabelTexture(texture: tex, size: SIMD2(Float(edge), Float(edge)))
    }
}
