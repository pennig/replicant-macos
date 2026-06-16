//
//  Controls.swift
//  Replicant — buttons & text fields for the design system.
//
//  Extends ReplicantDesignSystem.swift with the interactive controls used
//  across the app. Everything reads the Color.rc* tokens + Space/Radius/Font,
//  so the controls track light/dark automatically and never hard-code hex.
//
//  ── Buttons ──────────────────────────────────────────────────────────────
//  Four ButtonStyles, picked by a single enum:
//
//      Button("Deploy")    { … }.buttonStyle(RCButtonStyle(.primary))
//      Button("Cancel")    { … }.buttonStyle(RCButtonStyle(.secondary))  // outline
//      Button("Deactivate"){ … }.buttonStyle(RCButtonStyle(.destructive))
//      Button("Show key")  { … }.buttonStyle(RCButtonStyle(.text))
//
//  Plus `.destructiveProminent` — the solid-red CONFIRM action (the second
//  step after a `.destructive` trigger). Use the tinted `.destructive` for the
//  affordance that *opens* a confirm ("Deactivate", "Log out"); use
//  `.destructiveProminent` for the button that actually fires it.
//
//  `RCButtonStyle(_, fullWidth: true)` stretches to its container (form CTAs).
//
//  Why ButtonStyle and not a custom control: makeBody can't see hover or the
//  enabled environment by itself, so it returns a small inner View that owns
//  @State hover + @Environment(\.isEnabled) and reads configuration.isPressed.
//  That gives press / hover / disabled on one style per variant — no NSButton.
//
//  ── Text fields ──────────────────────────────────────────────────────────
//  TextFieldStyle's makeBody is SPI and can't read focus, so the amber focus
//  ring can't live there. Instead:
//
//      RCField("Email", text: $email, placeholder: "you@example.com")
//      RCField("API Key", text: $key, placeholder: "rk_live_…",
//              mono: true, secure: true, hint: "from your account")
//
//  …or style your own TextField/SecureField with the `.rcField(focused:)`
//  modifier (pass it a @FocusState bool so it can draw the ring).
//

import SwiftUI

// MARK: - Button styles

public enum RCButtonKind {
    case primary               // amber fill — the main action
    case secondary             // outline — transparent fill + neutral hairline — Cancel / secondary
    case destructive           // tinted danger — opens a confirm (Deactivate, Log out)
    case destructiveProminent  // solid danger — the confirm itself
    case text                  // accent label only — inline / link-like
}

public struct RCButtonStyle: ButtonStyle {
    public let kind: RCButtonKind
    public var fullWidth: Bool

    public init(_ kind: RCButtonKind, fullWidth: Bool = false) {
        self.kind = kind
        self.fullWidth = fullWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        RCButtonBody(kind: kind, fullWidth: fullWidth, configuration: configuration)
    }
}

/// Inner view so we can read hover + isEnabled (ButtonStyle.makeBody can't).
private struct RCButtonBody: View {
    let kind: RCButtonKind
    let fullWidth: Bool
    let configuration: ButtonStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @State private var hover = false

    private var pressed: Bool { configuration.isPressed }
    private var isText: Bool { kind == .text }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.control, style: .continuous) }

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: isText ? .semibold : .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, isText ? 2 : Space.l)
            .padding(.vertical, isText ? 2 : 9)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(fill)
            .overlay(stroke)
            .clipShape(shape)
            .overlay(alignment: .bottom) { underline }      // text variant only
            .shadow(color: shadowColor, radius: shadowRadius, y: shadowRadius == 0 ? 0 : 6)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : (isText ? 0.35 : 0.4))
            .scaleEffect(pressed && isEnabled && !isText ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .animation(.easeOut(duration: 0.12), value: hover)
            .onHover { if isEnabled { hover = $0 } }
    }

    // Foreground -------------------------------------------------------------
    private var foreground: Color {
        switch kind {
        case .primary:              return .rcAccentOnColor
        case .destructiveProminent: return .white
        case .secondary:            return hover ? .rcTextPrimary : .rcTextSecondary
        case .destructive:          return .rcDanger
        case .text:                 return .rcAccent
        }
    }

    // Fill -------------------------------------------------------------------
    @ViewBuilder private var fill: some View {
        switch kind {
        case .primary:
            ZStack {
                Color.rcAccent
                // subtle top sheen + press-darken, both derived from the one token
                LinearGradient(colors: [.white.opacity(hover ? 0.20 : 0.14), .clear],
                               startPoint: .top, endPoint: .center)
                if pressed { Color.black.opacity(0.12) }
            }
        case .destructiveProminent:
            ZStack {
                Color.rcDanger
                LinearGradient(colors: [.white.opacity(0.16), .clear],
                               startPoint: .top, endPoint: .center)
                if pressed { Color.black.opacity(0.12) }
            }
        case .secondary:
            Color.rcTextPrimary.opacity(hover ? 0.06 : 0)
        case .destructive:
            Color.rcDanger.opacity(hover ? 0.14 : (pressed ? 0.18 : 0.0))
        case .text:
            Color.clear
        }
    }

    // Border -----------------------------------------------------------------
    @ViewBuilder private var stroke: some View {
        switch kind {
        case .secondary:
            shape.strokeBorder(Color.rcSeparatorStrong, lineWidth: 1)
        case .destructive:
            shape.strokeBorder(Color.rcDanger.opacity(hover ? 0.55 : 0.35), lineWidth: 1)
        default:
            EmptyView()
        }
    }

    // Accent underline on hover for the text variant --------------------------
    @ViewBuilder private var underline: some View {
        if isText {
            Rectangle()
                .fill(Color.rcAccent.opacity(hover ? 0.9 : 0))
                .frame(height: 1)
                .offset(y: pressed ? -1.5 : 0)
        }
    }

    // Shadow -----------------------------------------------------------------
    private var shadowColor: Color {
        switch kind {
        case .primary:              return Color.rcAccent.opacity(isEnabled ? 0.32 : 0)
        case .destructiveProminent: return Color.rcDanger.opacity(isEnabled ? 0.32 : 0)
        default:                    return .clear
        }
    }
    private var shadowRadius: CGFloat {
        (kind == .primary || kind == .destructiveProminent) && isEnabled ? 14 : 0
    }
}

// MARK: - Text fields

/// Styles a bare TextField/SecureField as a Replicant field. Pass a focus flag
/// (from @FocusState) so it can draw the amber focus ring.
public struct RCFieldStyle: ViewModifier {
    public var focused: Bool
    public var mono: Bool
    public init(focused: Bool, mono: Bool = false) { self.focused = focused; self.mono = mono }

    public func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(mono ? .system(size: 13, design: .monospaced) : .system(size: 13.5))
            .foregroundStyle(Color.rcTextPrimary)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(Color.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(focused ? Color.rcAccentBorder : Color.rcSeparator,
                                  lineWidth: focused ? 1.5 : 1)
            )
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

public extension View {
    func rcField(focused: Bool, mono: Bool = false) -> some View {
        modifier(RCFieldStyle(focused: focused, mono: mono))
    }
}

/// A labeled Replicant field — uppercase caption label, optional inline hint,
/// focus ring, optional mono / secure (with reveal). Matches First Launch.
public struct RCField: View {
    let label: String?
    let hint: String?
    @Binding var text: String
    var placeholder: String
    var mono: Bool
    var secure: Bool

    @FocusState private var focused: Bool
    @State private var reveal = false

    public init(_ label: String? = nil, text: Binding<String>, placeholder: String = "",
                hint: String? = nil, mono: Bool = false, secure: Bool = false) {
        self.label = label; self._text = text; self.placeholder = placeholder
        self.hint = hint; self.mono = mono; self.secure = secure
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xs + 2) {
            if let label {
                HStack(spacing: 6) {
                    Text(label.uppercased())
                        .font(.system(size: 10.5, weight: .bold)).kerning(0.5)
                        .foregroundStyle(Color.rcTextTertiary)
                    if let hint {
                        Text("— \(hint)").font(.system(size: 11)).foregroundStyle(Color.rcTextTertiary)
                    }
                }
            }
            HStack(spacing: 6) {
                Group {
                    if secure && !reveal { SecureField(placeholder, text: $text) }
                    else { TextField(placeholder, text: $text) }
                }
                .focused($focused)
                if secure {
                    Button(reveal ? "Hide" : "Show") { reveal.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.rcTextTertiary)
                }
            }
            .rcField(focused: focused, mono: mono)
        }
    }
}

// MARK: - Gallery (living spec — open the #Preview)

public struct RCControlsGalleryView: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            column(.dark)
            Divider()
            column(.light)
        }
    }

    private func column(_ scheme: ColorScheme) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                Text(scheme == .dark ? "DARK" : "LIGHT")
                    .font(.rcSectionLabel).kerning(1.2).foregroundStyle(Color.rcTextTertiary)

                section("Buttons") {
                    GalleryButtons()
                }
                section("Text fields") {
                    GalleryFields()
                }
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.rcContentBackground)
        .environment(\.colorScheme, scheme)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(title.uppercased()).font(.rcSectionLabel).kerning(1).foregroundStyle(Color.rcTextTertiary).opacity(0.8)
            content()
        }
    }
}

private struct GalleryButtons: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            row("Primary") {
                Button("Deploy") {}.buttonStyle(RCButtonStyle(.primary))
                Button("Deploy") {}.buttonStyle(RCButtonStyle(.primary)).disabled(true)
            }
            row("Secondary") {
                Button("Cancel") {}.buttonStyle(RCButtonStyle(.secondary))
                Button("Cancel") {}.buttonStyle(RCButtonStyle(.secondary)).disabled(true)
            }
            row("Destructive") {
                Button("Deactivate") {}.buttonStyle(RCButtonStyle(.destructive))
                Button("Log out") {}.buttonStyle(RCButtonStyle(.destructive))
            }
            row("Destructive · confirm") {
                Button("Decommission device") {}.buttonStyle(RCButtonStyle(.destructiveProminent))
            }
            row("Text") {
                Button("Create one") {}.buttonStyle(RCButtonStyle(.text))
                Button("Show key") {}.buttonStyle(RCButtonStyle(.text))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Full width").font(.rcCaption).foregroundStyle(Color.rcTextTertiary)
                Button("Log in") {}.buttonStyle(RCButtonStyle(.primary, fullWidth: true))
            }
            .frame(maxWidth: 320, alignment: .leading)
        }
    }

    private func row<C: View>(_ name: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.rcCaption).foregroundStyle(Color.rcTextTertiary)
            HStack(spacing: Space.s) { content() }
        }
    }
}

private struct GalleryFields: View {
    @State private var name = ""
    @State private var email = "kell@pennig.name"
    @State private var key = ""
    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            RCField("Name", text: $name, placeholder: "What should we call you?")
            RCField("Email", text: $email, placeholder: "you@example.com")
            RCField("API Key", text: $key, placeholder: "rk_live_…",
                    hint: "paste the key from your account", mono: true, secure: true)
        }
        .frame(maxWidth: 360)
    }
}

#Preview("Controls · light + dark") {
    RCControlsGalleryView().frame(width: 760, height: 760)
}
