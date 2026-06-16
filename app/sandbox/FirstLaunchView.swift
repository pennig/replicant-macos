//
//  FirstLaunchView.swift
//  Replicant — first-launch / sign-in screen.
//
//  A faithful SwiftUI port of "First Launch - Bloom.html": the Bloom mark as a
//  live logo, a continuously radiating hex→circle ring field, a seeded
//  starfield, the violet deep-space gradient + nebula + legibility veil, and the
//  Log in / Create account forms.
//
//  Pure SwiftUI, no assets required. macOS 12+ (Canvas + TimelineView).
//  Host it in a borderless / hidden-title window for the full-bleed look:
//
//      WindowGroup { FirstLaunchView() }
//          .windowStyle(.hiddenTitleBar)
//
//  Colors are inlined to match the mockup exactly; swap for Color.rc* tokens
//  from ReplicantDesignSystem.swift if you want them centralized.
//

import SwiftUI
import UI

// MARK: - Color helpers

private struct RGB { var r: Double; var g: Double; var b: Double }

private let cAccent = RGB(r: 255, g: 178, b: 62)     // #ffb23e
private let cViolet = RGB(r: 181, g: 139, b: 255)    // relay tint
private func mix(_ a: RGB, _ b: RGB, _ f: Double) -> RGB {
    RGB(r: a.r + (b.r - a.r) * f, g: a.g + (b.g - a.g) * f, b: a.b + (b.b - a.b) * f)
}
private func col(_ c: RGB, _ o: Double = 1) -> Color {
    Color(.sRGB, red: c.r / 255, green: c.g / 255, blue: c.b / 255, opacity: o)
}
private extension Color {
    init(hex: String, _ opacity: Double = 1) {
        var s = hex; if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0
        self = Color(.sRGB,
                     red: Double((v >> 16) & 0xff) / 255,
                     green: Double((v >> 8) & 0xff) / 255,
                     blue: Double(v & 0xff) / 255,
                     opacity: opacity)
    }
}

// palette
private enum P {
    static let t1 = Color(hex: "e9eef7")
    static let t2 = Color(hex: "9aa6bc")
    static let t3 = Color(hex: "697488")
    static let accent = Color(hex: "ffb23e")
    static let accentText = Color(hex: "2a1a05")
    static let panel = Color.white.opacity(0.05)
    static let line = Color.white.opacity(0.09)
    static let selRing = Color(hex: "ffb23e", 0.34)
    static let winTop = Color(hex: "1b1733")
    static let winBot = Color(hex: "08060f")
}

// MARK: - Geometry (ported from the icon)

/// Pointy-top hexagon, optionally rounded toward a circle (k: 0 sharp … 1 circle).
private func roundedHexPath(center: CGPoint, radius R: CGFloat, k: Double) -> Path {
    var path = Path()
    var pts: [CGPoint] = []
    for i in 0..<6 {
        let a = (-90.0 + Double(i) * 60.0) * .pi / 180
        pts.append(CGPoint(x: center.x + R * CGFloat(cos(a)), y: center.y + R * CGFloat(sin(a))))
    }
    let kk = min(max(k, 0), 1)
    if kk <= 0.001 {
        path.move(to: pts[0])
        for i in 1..<6 { path.addLine(to: pts[i]) }
        path.closeSubpath()
        return path
    }
    // corner radius → at k=1 the six arcs meet at edge midpoints ≈ a circle
    let r = CGFloat(kk) * R * 0.8660254
    func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
    path.move(to: mid(pts[5], pts[0]))
    for i in 0..<6 {
        path.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % 6], radius: r)
    }
    path.closeSubpath()
    return path
}

private func polyPath(_ points: [CGPoint]) -> Path {
    var p = Path()
    guard let first = points.first else { return p }
    p.move(to: first)
    for pt in points.dropFirst() { p.addLine(to: pt) }
    p.closeSubpath()
    return p
}

// MARK: - Ring tweaks (defaults match the saved Tweaks panel values)

public struct RingTweaks {
    public var ringCount: Double
    public var appearRadius: Double
    public var circleRadius: Double
    public var vanishRadius: Double
    public var spacingEase: Double
    public var speed: Double
    public init(ringCount: Double = 12, appearRadius: Double = 20, circleRadius: Double = 170,
                vanishRadius: Double = 580, spacingEase: Double = 2.4, speed: Double = 0.4) {
        self.ringCount = ringCount; self.appearRadius = appearRadius; self.circleRadius = circleRadius
        self.vanishRadius = vanishRadius; self.spacingEase = spacingEase; self.speed = speed
    }
}

// MARK: - Radiating ring field

private struct RingField: View {
    var origin: CGPoint
    var tweaks: RingTweaks
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let birthR: Double = 16
    private let baseLife: Double = 7.2   // seconds at speed 1×

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { tl in
            Canvas { ctx, _ in
                let now = reduceMotion
                    ? baseLife * 0.5
                    : tl.date.timeIntervalSinceReferenceDate
                draw(into: ctx, now: now)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(into ctx: GraphicsContext, now: TimeInterval) {
        let count = max(2, Int(tweaks.ringCount.rounded()))
        let appearR = tweaks.appearRadius
        let vanishR = max(appearR + 40, tweaks.vanishRadius)
        let circleR = max(birthR + 1, tweaks.circleRadius)
        let ease = tweaks.spacingEase
        let period = baseLife / max(0.05, tweaks.speed)
        let span = vanishR - birthR

        for i in 0..<count {
            var p = (now / period + Double(i) / Double(count)).truncatingRemainder(dividingBy: 1)
            if p < 0 { p += 1 }
            let Rc = birthR + span * pow(p, ease)              // eased outward radius
            let k = min(max((Rc - birthR) / (circleR - birthR), 0), 1)  // hex → circle by circleR

            var op = 0.0
            if Rc > appearR && Rc < vanishR {
                let f = (Rc - appearR) / (vanishR - appearR)
                op = 0.2 * min(1, f / 0.10) * min(1, (1 - f) / 0.45)
            }
            if op <= 0.001 { continue }

            let w = 1.0//0.8 + 2.2 * (1 - min(1, Rc / vanishR))
            let c = mix(cAccent, cViolet, k * 0.45)
            let path = roundedHexPath(center: origin, radius: CGFloat(Rc), k: k)
            ctx.stroke(path, with: .color(col(c, op)),
                       style: StrokeStyle(lineWidth: CGFloat(w), lineJoin: .round))
        }
    }
}

// MARK: - Bloom mark (the logo imagery — transparent)

private struct BloomMark: View {
    var size: CGFloat = 116
    var body: some View {
        Canvas { ctx, sz in
            let scale = sz.width / 500.0   // icon viewBox is -250…250
            ctx.translateBy(x: sz.width / 2, y: sz.height / 2)
            ctx.scaleBy(x: scale, y: scale)
            let O = CGPoint(x: 0, y: 0)

            // soft amber glow
            ctx.fill(
                Path(ellipseIn: CGRect(x: -210, y: -210, width: 420, height: 420)),
                with: .radialGradient(
                    Gradient(colors: [col(cAccent, 0.45), col(cAccent, 0)]),
                    center: O, startRadius: 0, endRadius: 210))

            // ring 1 (rounded) then ring 0 (sharp, carries buds)
            ctx.stroke(roundedHexPath(center: O, radius: 224, k: 0.174),
                       with: .color(col(cAccent, 0.422)),
                       style: StrokeStyle(lineWidth: 6.6, lineJoin: .round))
            ctx.stroke(roundedHexPath(center: O, radius: 158, k: 0),
                       with: .color(col(cAccent, 0.55)),
                       style: StrokeStyle(lineWidth: 7, lineJoin: .round))

            // core cube — base hex with a lit radial fill
            let core = roundedHexPath(center: O, radius: 78, k: 0)
            ctx.fill(core, with: .radialGradient(
                Gradient(colors: [col(mix(cAccent, RGB(r: 255, g: 255, b: 255), 0.55)),
                                  col(cAccent),
                                  col(mix(cAccent, RGB(r: 0, g: 0, b: 0), 0.5))]),
                center: CGPoint(x: -16, y: -22), startRadius: 0, endRadius: 110))

            // three isometric faces (contrast 45%)
            let top = polyPath([CGPoint(x: 0, y: -78), CGPoint(x: 67.55, y: -39),
                                CGPoint(x: 0, y: 0), CGPoint(x: -67.55, y: -39)])
            let right = polyPath([CGPoint(x: 67.55, y: -39), CGPoint(x: 67.55, y: 39),
                                  CGPoint(x: 0, y: 78), CGPoint(x: 0, y: 0)])
            let left = polyPath([CGPoint(x: -67.55, y: -39), CGPoint(x: 0, y: 0),
                                 CGPoint(x: 0, y: 78), CGPoint(x: -67.55, y: 39)])
            ctx.fill(left, with: .color(.black.opacity(0.081)))
            ctx.fill(right, with: .color(.black.opacity(0.027)))
            ctx.fill(top, with: .linearGradient(
                Gradient(colors: [Color(hex: "fff3d8", 0.117), Color(hex: "fff3d8", 0)]),
                startPoint: CGPoint(x: 0, y: -78), endPoint: CGPoint(x: 0, y: 0)))

            // interior edges (edge opacity 15%)
            var ridge = Path()
            ridge.move(to: CGPoint(x: -67.55, y: -39))
            ridge.addLine(to: O); ridge.addLine(to: CGPoint(x: 67.55, y: -39))
            ctx.stroke(ridge, with: .color(Color(hex: "fff4da", 0.045)),
                       style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            var front = Path()
            front.move(to: O); front.addLine(to: CGPoint(x: 0, y: 78))
            ctx.stroke(front, with: .color(Color(hex: "2a1500", 0.048)),
                       style: StrokeStyle(lineWidth: 1.8, lineCap: .round))

            // offspring buds (halo + dot) at the six ring-0 vertices
            let budFill = col(mix(cAccent, RGB(r: 255, g: 255, b: 255), 0.18))
            for i in 0..<6 {
                let a = (-90.0 + Double(i) * 60.0) * .pi / 180
                let x = 158 * cos(a), y = 158 * sin(a)
                ctx.fill(Path(ellipseIn: CGRect(x: x - 24, y: y - 24, width: 48, height: 48)),
                         with: .color(col(cAccent, 0.30)))
                ctx.fill(Path(ellipseIn: CGRect(x: x - 13, y: y - 13, width: 26, height: 26)),
                         with: .color(budFill))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Starfield (seeded to match the HTML)

private struct Starfield: View {
    struct Star { var x: Double; var y: Double; var r: Double; var o: Double }
    private let stars: [Star] = {
        var s: UInt64 = 11
        func rnd() -> Double { s = (s &* 1103515245 &+ 12345) & 0x7fffffff; return Double(s) / Double(0x7fffffff) }
        return (0..<95).map { _ in
            Star(x: rnd(), y: rnd(), r: rnd() * 1.2 + 0.35, o: rnd() * 0.55 + 0.2)
        }
    }()
    var body: some View {
        Canvas { ctx, sz in
            for st in stars {
                let d = st.r * 2
                ctx.fill(Path(ellipseIn: CGRect(x: st.x * sz.width - st.r, y: st.y * sz.height - st.r,
                                                width: d, height: d)),
                         with: .color(Color(hex: "dfe8ff", st.o)))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Background (gradient + nebula + veil)

private struct CosmicBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [P.winTop, P.winBot], startPoint: .top, endPoint: .bottom)
            // nebula
            RadialGradient(colors: [Color(hex: "ffb23e", 0.14), .clear],
                           center: UnitPoint(x: 0.5, y: -0.12), startRadius: 0, endRadius: 460)
            RadialGradient(colors: [Color(hex: "658cff", 0.10), .clear],
                           center: UnitPoint(x: 0.12, y: 1.16), startRadius: 0, endRadius: 440)
            RadialGradient(colors: [Color(hex: "3fd3cb", 0.07), .clear],
                           center: UnitPoint(x: 1.04, y: 0.9), startRadius: 0, endRadius: 420)
        }
    }
}

private struct Veil: View {
    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(hex: "06090f", 0.62), .clear],
                           center: UnitPoint(x: 0.5, y: 0.34), startRadius: 0, endRadius: 240)
            RadialGradient(colors: [Color(hex: "06090f", 0.40), .clear],
                           center: UnitPoint(x: 0.5, y: 0.78), startRadius: 0, endRadius: 360)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Form controls

private struct FieldLabel: View {
    let text: String
    var hint: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased()).font(.system(size: 10.5, weight: .bold)).kerning(0.5).foregroundStyle(P.t3)
            if let hint { Text("— \(hint)").font(.system(size: 11)).foregroundStyle(P.t3) }
        }
    }
}

private struct CosmicField<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13.5))
            .foregroundStyle(P.t1, P.t1, P.t1)
            .padding(.horizontal, 13).padding(.vertical, 11)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(P.line, lineWidth: 1))
    }
}

private struct SubmitButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 14, weight: .bold))
                Image(systemName: "arrow.right").font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(P.accentText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(LinearGradient(colors: [Color(hex: "ffc05c"), Color(hex: "ff9e2c")],
                                       startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: Color(hex: "ff9e2c", 0.32), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Logo-center reporting (so rings emanate from the mark)

private struct LogoCenterKey: PreferenceKey {
    static let defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}
private extension CGRect { var center: CGPoint { CGPoint(x: midX, y: midY) } }

// MARK: - Root view

public struct FirstLaunchView: View {
    public init(tweaks: RingTweaks = RingTweaks()) { self.tweaks = tweaks }
    var tweaks: RingTweaks

    enum Mode { case login, signup }
    @State private var mode: Mode = .login
    @State private var apiKey = ""
    @State private var reveal = false
    @State private var name = ""
    @State private var email = ""
    @State private var timeZone = TimeZone.current.identifier
    @State private var logoCenter: CGPoint = .zero

    private let zones = [
        "Pacific/Honolulu", "America/Anchorage", "America/Los_Angeles", "America/Denver",
        "America/Chicago", "America/New_York", "America/Sao_Paulo", "UTC",
        "Europe/London", "Europe/Paris", "Europe/Berlin", "Europe/Athens", "Africa/Cairo",
        "Asia/Dubai", "Asia/Kolkata", "Asia/Shanghai", "Asia/Tokyo", "Australia/Sydney", "Pacific/Auckland",
    ]

    public var body: some View {
        GeometryReader { _ in
            ZStack {
                CosmicBackground()
                RingField(origin: logoCenter == .zero ? CGPoint(x: 380, y: 136) : logoCenter, tweaks: tweaks)
                Starfield()
                Veil()
                content
            }
            .coordinateSpace(name: "screen")
            .onPreferenceChange(LogoCenterKey.self) { logoCenter = $0 }
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(P.winBot)
    }

    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            // brand
            VStack(spacing: 14) {
                BloomMark(size: 116)
                    .background(GeometryReader { p in
                        Color.clear.preference(key: LogoCenterKey.self,
                                               value: p.frame(in: .named("screen")).center)
                    })
                VStack(spacing: 2) {
                    Text("Replicant").font(.system(size: 26, weight: .bold)).kerning(-0.4).foregroundStyle(P.t1)
                    Text("Command your probes across the local cluster.")
                        .font(.system(size: 13.5)).foregroundStyle(P.t2)
                }
            }
            .padding(.bottom, 24)

            segmented.padding(.bottom, 22)

            Group {
                if mode == .login { loginForm } else { signupForm }
            }
            .frame(maxWidth: 360)

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var segmented: some View {
        HStack(spacing: 3) {
            seg("Log in", .login)
            seg("Create account", .signup)
        }
        .padding(3)
        .background(P.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(P.line, lineWidth: 0.5))
    }

    private func seg(_ title: String, _ m: Mode) -> some View {
        let on = mode == m
        return Button { withAnimation(.easeOut(duration: 0.15)) { mode = m } } label: {
            Text(title).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(on ? P.t1 : P.t2)
                .padding(.horizontal, 18).padding(.vertical, 7)
                .background(on ? AnyShapeStyle(Color.white.opacity(0.065)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private var loginForm: some View {
        VStack(spacing: 13) {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "API Key", hint: "paste the key from your account")
                CosmicField {
                    HStack(spacing: 6) {
                        Group {
                            if reveal { TextField("rk_live_…", text: $apiKey).foregroundStyle(P.t1, P.t1, P.t1) }
                            else { SecureField("rk_live_…", text: $apiKey).foregroundStyle(P.t1, P.t1, P.t1) }
                        }
                        .font(.system(size: 13, design: .monospaced))
                        Button(reveal ? "Hide" : "Show") { reveal.toggle() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(P.t3)
                    }
                }
            }
            SubmitButton(title: "Log in") {}
            footer(prompt: "No account yet?", action: "Create one", trailing: "to get started.") { mode = .signup }
        }
        .transition(.opacity)
    }

    private var signupForm: some View {
        VStack(spacing: 13) {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Name")
                CosmicField { TextField("What should we call you?", text: $name) }
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Email")
                CosmicField { TextField("you@example.com", text: $email) }
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Time zone")
                Picker("", selection: $timeZone) {
                    ForEach(zoneList, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).tint(P.t2)
            }
            SubmitButton(title: "Begin") {}
            footer(prompt: "Already have a key?", action: "Log in instead", trailing: ".") { mode = .login }
        }
        .transition(.opacity)
    }

    private var zoneList: [String] {
        var z = zones
        if !z.contains(timeZone) { z.insert(timeZone, at: 0) }
        return z
    }

    private func footer(prompt: String, action: String, trailing: String, tap: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(prompt).foregroundStyle(P.t3)
            Button(action) { withAnimation(.easeOut(duration: 0.15)) { tap() } }
                .buttonStyle(.plain).foregroundStyle(P.accent)
            Text(trailing).foregroundStyle(P.t3)
        }
        .font(.system(size: 11.5))
        .padding(.top, 6)
    }
}

#Preview("First launch") {
    FirstLaunchView().frame(width: 760, height: 560)
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .windowResizeBehavior(.disabled)
}
