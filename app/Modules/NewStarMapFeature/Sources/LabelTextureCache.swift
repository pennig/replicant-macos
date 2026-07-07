import Metal
import CoreText
import CoreGraphics
import AppKit
import simd

// Rasterizes labels to cached Metal textures via Core Text + SF Symbols. A label
// is the system name plus an optional row of white SF Symbols beneath it
// (exploration / life / resources / inventory). Each unique (name, symbols) pair
// is drawn once — labels are few and repeat frame to frame — with a soft dark halo
// for legibility over the bright additive field. The texture is premultiplied RGBA;
// the label pass composites it over the tone-mapped drawable (never dimmed).

struct LabelTexture {
    let texture: MTLTexture
    let size: SIMD2<Float>   // pixels (already at raster scale)
}

final class LabelTextureCache {
    private let device: MTLDevice
    private let fontSize: CGFloat
    private let scale: CGFloat        // raster scale (≈ backing scale for crisp text)
    private var cache: [String: LabelTexture] = [:]

    init(device: MTLDevice, fontSize: CGFloat = 12, scale: CGFloat = 2) {
        self.device = device
        self.fontSize = fontSize
        self.scale = scale
    }

    /// Texture for a label: the name, plus a row of SF Symbols below it if
    /// `symbols` is non-empty. Cached by the (name, symbols) pair.
    func texture(name: String, symbols: [StatusSymbol] = []) -> LabelTexture? {
        let key = name + "\u{1}" + symbols.map { "\($0.name):\($0.value ?? -1)" }.joined(separator: ",")
        if let t = cache[key] { return t }
        let t = rasterize(name: name, symbols: symbols)
        if let t { cache[key] = t }
        return t
    }

    private func line(_ text: String, size: CGFloat) -> (line: CTLine, w: CGFloat, asc: CGFloat, desc: CGFloat) {
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let ctLine = CTLineCreateWithAttributedString(attr)
        var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
        let w = CTLineGetTypographicBounds(ctLine, &asc, &desc, &lead)
        return (ctLine, CGFloat(w), asc, desc)
    }

    /// A white-tinted SF Symbol rendered to a CGImage, with its point size. A
    /// non-nil `value` uses SF Symbols' variable rendering (0…1 proportional fill).
    private func symbolImage(_ sym: StatusSymbol, pointSize: CGFloat) -> (cg: CGImage, size: CGSize)? {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let base = sym.value.map {
            NSImage(systemSymbolName: sym.name, variableValue: Double($0), accessibilityDescription: nil)
        } ?? NSImage(systemSymbolName: sym.name, accessibilityDescription: nil)
        guard let img = base?.withSymbolConfiguration(cfg) else { return nil }
        var rect = CGRect(origin: .zero, size: img.size)
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return (cg, img.size)
    }

    private func rasterize(name: String, symbols: [StatusSymbol]) -> LabelTexture? {
        let pad = 4 * scale
        let gap = 4 * scale                            // between name and symbol row
        let spacing = 3 * scale                        // between symbols

        let nameL = line(name, size: fontSize * scale)
        let nameH = nameL.asc + nameL.desc

        let syms = symbols.compactMap { symbolImage($0, pointSize: fontSize * scale * 0.95) }
        let symRowW = syms.isEmpty ? 0
            : syms.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(syms.count - 1)
        let symRowH = syms.map { $0.size.height }.max() ?? 0

        let contentW = max(nameL.w, symRowW)
        let contentH = nameH + (syms.isEmpty ? 0 : gap + symRowH)
        let w = Int(ceil(contentW + pad * 2)), h = Int(ceil(contentH + pad * 2))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        ctx.setShadow(offset: .zero, blur: 3 * scale,
                      color: NSColor.black.withAlphaComponent(0.95).cgColor)

        // y-up context: name on top, symbol row centred below it.
        let top = CGFloat(h) - pad
        ctx.textPosition = CGPoint(x: (CGFloat(w) - nameL.w) / 2, y: top - nameL.asc)
        CTLineDraw(nameL.line, ctx)

        if !syms.isEmpty {
            var x = (CGFloat(w) - symRowW) / 2
            let rowTop = top - nameH - gap
            for s in syms {
                let sw = s.size.width, sh = s.size.height
                let bottom = rowTop - symRowH + (symRowH - sh) / 2   // vertically centre in the row
                // The bitmap context is y-up, where `draw(_:in:)` already renders a
                // CGImage upright (same convention the name text draws in) — so no
                // manual flip; one would turn the glyph upside-down.
                ctx.draw(s.cg, in: CGRect(x: x, y: bottom, width: sw, height: sh))
                x += sw + spacing
            }
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc), let data = ctx.data else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: data, bytesPerRow: ctx.bytesPerRow)
        return LabelTexture(texture: tex, size: SIMD2(Float(w), Float(h)))
    }
}
