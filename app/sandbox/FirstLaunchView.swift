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

import AppKit
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

// Bespoke deep-space window gradient — not part of the shared token set, so it
// stays inline. Everything else now uses the Color.rc* design tokens.
private enum P {
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

// MARK: - Radiating ring field

private struct RingField: View, Animatable {
    var origin: CGPoint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Interpolate `origin` so the field glides when the logo moves between forms.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(origin.x, origin.y) }
        set { origin = CGPoint(x: newValue.first, y: newValue.second) }
    }

    // Static config (matches the saved Tweaks panel values).
    private static let ringCount: Double = 12
    private static let appearRadius: Double = 20
    private static let circleRadius: Double = 170
    private static let vanishRadius: Double = 580
    private static let spacingEase: Double = 2.4
    private static let speed: Double = 0.4

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
        let count = max(2, Int(Self.ringCount.rounded()))
        let appearR = Self.appearRadius
        let vanishR = max(appearR + 40, Self.vanishRadius)
        let circleR = max(birthR + 1, Self.circleRadius)
        let ease = Self.spacingEase
        let period = baseLife / max(0.05, Self.speed)
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

// MARK: - Replicould logo (the logo imagery — transparent)

private struct ReplicouldLogoView: View {
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

// MARK: - Logo-center reporting (so rings emanate from the mark)

private extension CGRect { var center: CGPoint { CGPoint(x: midX, y: midY) } }

// MARK: - Root view

public struct FirstLaunchView: View {
    public init() {}

    enum Mode { case login, signup, confirmation }
    @State private var mode: Mode = .signup
    @State private var apiKey = ""
    @State private var name = ""
    @State private var email = ""
    @State private var timeZone = TimeZone.current.identifier
    @State private var logoCenter: CGPoint = .zero

    // The key the server issues on successful signup, shown once so the user can
    // copy it for use elsewhere (the app also stores it for its own calls).
    @State private var issuedKey = ""
    @State private var copied = false

    // All IANA time zone identifiers known to the system (always includes the current
    // zone), grouped by region — the prefix before the first "/".
    private let zoneGroups: [(region: String, identifiers: [String])] = {
        Dictionary(grouping: TimeZone.knownTimeZoneIdentifiers) { id in
            id.split(separator: "/").first.map(String.init) ?? id
        }
        .map { (region: $0.key, identifiers: $0.value.sorted()) }
        .sorted { $0.region < $1.region }
    }()

    public var body: some View {
        GeometryReader { _ in
            ZStack {
                CosmicBackground()
                RingField(origin: logoCenter == .zero ? CGPoint(x: 380, y: 136) : logoCenter)
                Starfield()
                Veil()
                content
            }
            .coordinateSpace(name: "screen")
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(P.winBot)
    }

    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            // brand
            VStack(spacing: 8) {
                ReplicouldLogoView(size: 116)
                    .onGeometryChange(for: CGPoint.self) { proxy in
                        proxy.frame(in: .named("screen")).center
                    } action: { center in
                        withAnimation(.easeOut(duration: 0.15)) { logoCenter = center }
                    }
                VStack(spacing: 2) {
                    Text("Repli\(Text("could").italic())")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.rcTextPrimary)
                    HStack(spacing: 0) {
                        Text("A fun interface for the API-based game,")
                        .foregroundStyle(.secondary)
                        Button("replicant.space") {
                            
                        }.buttonStyle(RCButtonStyle(.text))
                    }
                }
            }
            .padding(.bottom, 24)

            if mode != .confirmation {
                modeFooter.padding(.bottom, 22)
            }

            Group {
                switch mode {
                case .login:        loginForm
                case .signup:       signupForm
                case .confirmation: confirmationForm
                }
            }
            .frame(maxWidth: 400)

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var modeFooter: some View {
        if mode == .login {
            footer(prompt: "No account yet? ", action: "Create one", trailing: " to get started.") { mode = .signup }
        } else {
            footer(prompt: "Already have a key? ", action: "Log in instead", trailing: ".") { mode = .login }
        }
    }

    private var loginForm: some View {
        VStack(spacing: 13) {
            RCField("API Key", text: $apiKey, placeholder: "rk_live_…",
                    hint: "paste the key from your account", mono: true, secure: true)
            submit("Log in")
        }
        .transition(.opacity)
    }

    private var signupForm: some View {
        VStack(spacing: 13) {
            RCField("Name", text: $name, placeholder: "What should we call you?")
            RCField("Email", text: $email, placeholder: "you@example.com")
            VStack(alignment: .leading, spacing: Space.xs + 2) {
                Text("Time zone".uppercased())
                    .font(.system(size: 10.5, weight: .bold)).kerning(0.5)
                    .foregroundStyle(.rcTextTertiary)
                timeZoneField
            }
            submit("Begin") { completeSignup() }
        }
        .transition(.opacity)
    }

    /// Sign-up confirmation: surface the server-issued key so the user can copy
    /// it for use elsewhere before continuing into the app.
    private var confirmationForm: some View {
        VStack(spacing: 13) {
            VStack(alignment: .leading, spacing: Space.xs + 2) {
                HStack(spacing: 6) {
                    Text("Your API key".uppercased())
                        .font(.system(size: 10.5, weight: .bold)).kerning(0.5)
                        .foregroundStyle(.rcTextTertiary)
                    Text("— store it somewhere safe")
                        .font(.system(size: 11)).foregroundStyle(.rcTextTertiary)
                }
                keyDisplay
            }
            Text("Saved to this device so you can start right away. Copy it to use your account from the API or other tools.")
                .font(.system(size: 11.5))
                .foregroundStyle(.rcTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            submit("Continue") {}
        }
        .transition(.opacity)
    }

    /// Read-only key readout with a copy button, styled like the other fields.
    private var keyDisplay: some View {
        HStack(spacing: Space.s) {
            Text(issuedKey)
                .font(.rcMono)
                .foregroundStyle(.rcTextPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { copyKey() } label: {
                HStack(spacing: 5) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    Text(copied ? "Copied" : "Copy")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(copied ? .rcAccent : .rcTextSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(.rcSeparator, lineWidth: 1)
        )
    }

    /// Full-width primary CTA with the trailing arrow, using the design system.
    private func submit(_ title: String, action: @escaping () -> Void = {}) -> some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Text(title)
                Image(systemName: "arrow.right")
            }
        }
        .buttonStyle(RCButtonStyle(.primary, fullWidth: true))
    }

    /// Stand-in for the signup request. The real flow posts name/email/timeZone
    /// and receives the new account's API key in the response.
    private func completeSignup() {
        issuedKey = "rk_live_9f2c7b1e84a64d3f6c0a5e2b7d1f6093"
        withAnimation(.easeOut(duration: 0.15)) { mode = .confirmation }
    }

    private func copyKey() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(issuedKey, forType: .string)
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { copied = false }
        }
    }

    /// Grouped time-zone menu with an `RCValueSelect`-style field trigger.
    private var timeZoneField: some View {
        Menu {
            Picker("Time zone", selection: $timeZone) {
                ForEach(zoneGroups, id: \.region) { group in
                    Section(group.region) {
                        ForEach(group.identifiers, id: \.self) { id in
                            Text(zoneLabel(id)).tag(id)
                        }
                    }
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: Space.s - 2) {
                Image(systemName: "clock")
                    .font(.system(size: 13))
                    .foregroundStyle(.rcTextTertiary)
                Text(timeZone.replacingOccurrences(of: "_", with: " "))
                    .font(.rcMono)
                    .foregroundStyle(.rcTextPrimary)
                Spacer(minLength: Space.xs)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.rcTextSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .padding(.horizontal, Space.m)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(.rcSurfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(.rcSeparator, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    /// Display name for a zone within its region section: drops the region prefix
    /// (keeping any sub-region, e.g. "Argentina/Buenos Aires") and de-underscores.
    private func zoneLabel(_ id: String) -> String {
        let rest = id.split(separator: "/").dropFirst()
        let name = rest.isEmpty ? id : rest.joined(separator: "/")
        return name.replacingOccurrences(of: "_", with: " ")
    }

    private func footer(prompt: String, action: String, trailing: String, tap: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Text(prompt).foregroundStyle(.rcTextTertiary)
            Button(action) { withAnimation(.easeOut(duration: 0.15)) { tap() } }
                .buttonStyle(.plain).foregroundStyle(.rcAccent)
            Text(trailing).foregroundStyle(.rcTextTertiary)
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
