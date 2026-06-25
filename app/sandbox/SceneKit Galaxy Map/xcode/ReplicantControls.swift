//
//  ReplicantControls.swift
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
//  ── Segmented control ─────────────────────────────────────────────────────
//  Sliding-thumb picker (the chosen "Option A"). A recessed track with a
//  SurfaceRaised thumb that springs between segments via matchedGeometryEffect:
//
//      RCSegmentedControl(selection: $view, options: ["Grid","List","Map"])
//      RCSegmentedControl(selection: $range, options: TimeRange.allCases) { $0.label }
//
//  ── Dropdowns ─────────────────────────────────────────────────────────────
//  Both wrap a native `Menu`, so the open popover IS the system Liquid-Glass
//  surface (free keyboard nav, hit targets, light/dark). Two shapes:
//
//      RCValueSelect("Destination", systemImage: "mappin.and.ellipse",
//                    options: stars, selection: $destination)   // field — pick one value
//
//      RCEntitySwitcher(replicants, selection: $active)          // rich — switch entity
//
//  RCValueSelect is the parameterized-command picker (e.g. travel destination);
//  RCEntitySwitcher is the ACTIVE REPLICANT picker — it always shows the host
//  icon (HostKind), per the design rules.
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
            .clipShape(isText ? AnyShape(Rectangle()) : AnyShape(shape))
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
            shape.strokeBorder(.rcSeparatorStrong, lineWidth: 1)
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
            .foregroundStyle(.rcTextPrimary)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
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
                        .foregroundStyle(.rcTextTertiary)
                    if let hint {
                        Text("— \(hint)").font(.system(size: 11)).foregroundStyle(.rcTextTertiary)
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
                        .foregroundStyle(.rcTextTertiary)
                }
            }
            .rcField(focused: focused, mono: mono)
        }
    }
}

// MARK: - Segmented control (sliding glass thumb)

/// Recessed track + raised thumb that slides between options. Generic over any
/// Hashable option; supply a `label` closure (defaults to `String(describing:)`).
public struct RCSegmentedControl<Option: Hashable>: View {
    @Binding public var selection: Option
    public let options: [Option]
    public var label: (Option) -> String

    @Namespace private var thumb

    public init(selection: Binding<Option>, options: [Option],
                label: @escaping (Option) -> String = { String(describing: $0) }) {
        self._selection = selection
        self.options = options
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Segment(title: label(option),
                        isOn: option == selection,
                        thumbNS: thumb) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        selection = option
                    }
                }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(.rcSeparatorSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(.rcSeparator, lineWidth: 0.5)
                )
        )
    }

    /// One segment — owns its own hover so unselected labels brighten.
    private struct Segment: View {
        let title: String
        let isOn: Bool
        let thumbNS: Namespace.ID
        let tap: () -> Void
        @State private var hover = false

        var body: some View {
            Text(title)
                .font(.rcBodyEmph)
                .foregroundStyle(isOn ? Color.rcTextPrimary
                                      : (hover ? Color.rcTextPrimary : Color.rcTextSecondary))
                .padding(.vertical, 6)
                .padding(.horizontal, Space.m + 3)
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: Radius.control - 1, style: .continuous)
                            .fill(.rcSurfaceRaisedStrong)
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.control - 1, style: .continuous)
                                    .strokeBorder(.rcSeparatorSoft, lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                            .matchedGeometryEffect(id: "thumb", in: thumbNS)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: tap)
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

// MARK: - Value select (field-style dropdown — parameterized commands)

/// macOS pop-up button built on a native `Menu` + `Picker`, so the popover is
/// the system Liquid-Glass surface and the chosen row gets the OS checkmark.
/// The trigger reads like an `RCField`: leading glyph · mono value · chevron.
public struct RCValueSelect: View {
    let title: String
    let systemImage: String?
    let options: [String]
    @Binding var selection: String

    public init(_ title: String, systemImage: String? = nil,
                options: [String], selection: Binding<String>) {
        self.title = title; self.systemImage = systemImage
        self.options = options; self._selection = selection
    }

    public var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: Space.s - 2) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13))
                        .foregroundStyle(.rcTextTertiary)
                }
                Text(selection)
                    .font(.rcMono)
                    .foregroundStyle(.rcTextPrimary)
                Spacer(minLength: Space.xs)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.rcTextSecondary)
            }
            .frame(minWidth: 214, minHeight: 36)
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
        .fixedSize()
    }
}

// MARK: - Entity switcher (ACTIVE REPLICANT picker)

/// Lightweight model for the switcher. `host` drives the leading icon — a
/// replicant is never drawn without its host glyph (design rule).
public struct RCReplicant: Identifiable, Hashable {
    public let id: String        // replicant_code
    public let name: String
    public let host: HostKind
    public let isNPC: Bool
    public init(id: String, name: String, host: HostKind, isNPC: Bool = false) {
        self.id = id; self.name = name; self.host = host; self.isNPC = isNPC
    }
    /// Subtitle per spec: "<HostLabel>" (· NPC handled with a glyph in the row).
    var subtitle: String { host.label }
}

/// The titled ACTIVE-REPLICANT box: host icon · name · subtitle · chevron,
/// opening a native menu of all replicants. Switches the active entity.
public struct RCEntitySwitcher: View {
    let replicants: [RCReplicant]
    @Binding var selection: RCReplicant
    var onCommission: (() -> Void)?

    public init(_ replicants: [RCReplicant], selection: Binding<RCReplicant>,
                onCommission: (() -> Void)? = nil) {
        self.replicants = replicants; self._selection = selection
        self.onCommission = onCommission
    }

    public var body: some View {
        Menu {
            ForEach(replicants) { r in
                Button { selection = r } label: {
                    Label("\(r.name)  —  \(r.subtitle)", systemImage: r.host.sfSymbol)
                }
            }
            if let onCommission {
                Divider()
                Button { onCommission() } label: {
                    Label("Commission new replicant", systemImage: "plus")
                }
            }
        } label: {
            HStack(spacing: Space.s + 2) {
                hostTile(selection.host)
                VStack(alignment: .leading, spacing: 1) {
                    Text(selection.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.rcTextPrimary)
                    HStack(spacing: 5) {
                        Text(selection.subtitle)
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcTextTertiary)
                        if selection.isNPC {
                            Image(systemName: SidebarSymbol.npc)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.rcNPC)
                        }
                    }
                }
                Spacer(minLength: Space.s)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.rcTextSecondary)
            }
            .frame(minWidth: 248)
            .padding(.leading, Space.s + 2).padding(.trailing, Space.m)
            .padding(.vertical, Space.s)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(.rcSurfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .strokeBorder(.rcSeparator, lineWidth: 0.5)
                    )
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func hostTile(_ host: HostKind) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(.rcAccentMuted)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(.rcAccentBorder, lineWidth: 0.5)
                )
            Image(systemName: host.sfSymbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.rcAccent)
        }
        .frame(width: 30, height: 30)
    }
}

// MARK: - Type-erased shape (clipShape needs a concrete type per branch)

private struct AnyShape: Shape {
    private let pathFn: (CGRect) -> Path
    init<S: Shape>(_ shape: S) { pathFn = { shape.path(in: $0) } }
    func path(in rect: CGRect) -> Path { pathFn(rect) }
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
                    .font(.rcSectionLabel).kerning(1.2).foregroundStyle(.rcTextTertiary)

                section("Buttons") {
                    GalleryButtons()
                }
                section("Text fields") {
                    GalleryFields()
                }
                section("Segmented control") {
                    GallerySegments()
                }
                section("Dropdowns") {
                    GalleryDropdowns()
                }
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.rcContentBackground)
        .environment(\.colorScheme, scheme)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(title.uppercased()).font(.rcSectionLabel).kerning(1).foregroundStyle(.rcTextTertiary).opacity(0.8)
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
                Text("Full width").font(.rcCaption).foregroundStyle(.rcTextTertiary)
                Button("Log in") {}.buttonStyle(RCButtonStyle(.primary, fullWidth: true))
            }
            .frame(maxWidth: 320, alignment: .leading)
        }
    }

    private func row<C: View>(_ name: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.rcCaption).foregroundStyle(.rcTextTertiary)
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
            RCField("API Key", text: $key, placeholder: "xsPaUKCPJxa…",
                    hint: "paste the key from your account", mono: true, secure: true)
        }
        .frame(maxWidth: 360)
    }
}

private struct GallerySegments: View {
    @State private var view = "Grid"
    @State private var range = "Live"
    var body: some View {
        HStack(spacing: Space.l) {
            RCSegmentedControl(selection: $view, options: ["Grid", "List", "Map"])
            RCSegmentedControl(selection: $range, options: ["Live", "24h"])
        }
    }
}

private struct GalleryDropdowns: View {
    @State private var destination = "Elysium Shelf"
    private let stars = ["Tharsis Forge", "Elysium Shelf", "Olympus Rim", "Hellas Basin", "Valles Relay"]

    private let reps = [
        RCReplicant(id: "B58FCC78", name: "Roy",   host: .vessel),
        RCReplicant(id: "A21D90F3", name: "Pris",  host: .matrix),
        RCReplicant(id: "C77E1A2B", name: "Zhora", host: .hub),
        RCReplicant(id: "D40B5E91", name: "Leon",  host: .vessel, isNPC: true),
    ]
    @State private var active = RCReplicant(id: "B58FCC78", name: "Roy", host: .vessel)

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Value select · destination").font(.rcCaption).foregroundStyle(.rcTextTertiary)
                RCValueSelect("Destination", systemImage: "mappin.and.ellipse",
                              options: stars, selection: $destination)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Entity switcher · active replicant").font(.rcCaption).foregroundStyle(.rcTextTertiary)
                RCEntitySwitcher(reps, selection: $active) {}
            }
        }
    }
}

#Preview("Controls · light + dark") {
    RCControlsGalleryView().frame(width: 820, height: 1000)
}
