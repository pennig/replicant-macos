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
            .padding(.vertical, isText ? 2 : Space.xs)
            .frame(minHeight: isText ? nil : Control.height)
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
        (kind == .primary || kind == .destructiveProminent) && isEnabled ? 12 : 0
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
                    Button { reveal.toggle() } label: {
                        Image(systemName: reveal ? "eye.slash" : "eye")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.rcTextTertiary)
                            .padding(8)               // enlarge the hit target…
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(-8)                      // …without affecting layout
                    .accessibilityLabel(reveal ? "Hide" : "Show")
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
                .fill(.rcSurfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(.rcSeparator, lineWidth: 0.5)
                )
        )
        // Keep the control at its intrinsic width so surrounding content
        // wraps/truncates before any segment compresses.
        .fixedSize(horizontal: true, vertical: false)
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
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(isOn ? Color.rcAccentOnColor
                                      : (hover ? Color.rcTextPrimary : Color.rcTextSecondary))
                .padding(.vertical, 6)
                .padding(.horizontal, Space.m + 3)
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: Radius.control - 1, style: .continuous)
                            .fill(.rcAccent)
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.control - 1, style: .continuous)
                                    .strokeBorder(.rcSeparator, lineWidth: 0.5)
                            )
                            .shadow(color: .rcAccent.opacity(0.32), radius: 12, y: 6)
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
public struct RCValueSelect<Value: Hashable>: View {
    let title: String
    let systemImage: String?
    /// Ordered (label, value) pairs. Stored as an array so both a
    /// dictionary-literal (`KeyValuePairs`, which preserves order — a plain
    /// `Dictionary` does not) and a bare `[String]` can construct it.
    let options: [(label: String, value: Value)]
    @Binding var selection: Value

    /// The ergonomic initializer: pass options as a dictionary literal, e.g.
    /// `["All": Filter.all, "Explored": .explored]`, and bind directly to the
    /// value type — no string round-tripping at the call site.
    public init(_ title: String, systemImage: String? = nil,
                options: KeyValuePairs<String, Value>, selection: Binding<Value>) {
        self.title = title
        self.systemImage = systemImage
        self.options = options.map { (label: $0.key, value: $0.value) }
        self._selection = selection
    }

    /// Runtime pairs where the label differs from the value (e.g. a blueprint's
    /// display name mapped to its `device_type`). Use this when the options are
    /// built from data rather than a compile-time literal.
    public init(_ title: String, systemImage: String? = nil,
                options: [(label: String, value: Value)], selection: Binding<Value>) {
        self.title = title
        self.systemImage = systemImage
        self.options = options
        self._selection = selection
    }

    /// The label shown in the trigger for the current selection.
    private var selectedLabel: String {
        options.first { $0.value == selection }?.label ?? String(describing: selection)
    }

    public var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].label).tag(options[index].value)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: Space.s - 2) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13))
                        .foregroundStyle(.rcTextTertiary)
                }
                ZStack(alignment: .leading) {
                    // Reserve width for the longest label so the trigger stays a
                    // fixed size as the selection changes. The hidden copies are
                    // laid out (establishing the max width) but never drawn.
                    ForEach(options.indices, id: \.self) { index in
                        Text(options[index].label)
                            .font(.rcMono)
                            .hidden()
                    }
                    Text(selectedLabel)
                        .font(.rcMono)
                        .foregroundStyle(.rcTextPrimary)
                }
                Spacer(minLength: Space.xs)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.rcTextSecondary)
            }
            .frame(minHeight: 36)
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

public extension RCValueSelect where Value == String {
    /// Convenience for a plain list of strings where the label *is* the value
    /// (e.g. runtime-built option lists). Keeps existing call sites working.
    init(_ title: String, systemImage: String? = nil,
         options: [String], selection: Binding<String>) {
        self.title = title
        self.systemImage = systemImage
        self.options = options.map { (label: $0, value: $0) }
        self._selection = selection
    }
}

// MARK: - Entity switcher (ACTIVE REPLICANT picker)

/// Lightweight model for the switcher. `host` drives the leading icon — a
/// replicant is never drawn without its host glyph (design rule).
public struct RCReplicant: Identifiable, Hashable {
    public let id: String        // replicant_code
    public let name: String
    public let host: HostKind
    /// The host device's raw `device_type`, when known — drives the leading glyph
    /// via the design system's custom device symbols (e.g. `device.heaven_vessel`).
    public let hostDeviceType: String?
    public let isNPC: Bool
    public init(id: String, name: String, host: HostKind, hostDeviceType: String? = nil, isNPC: Bool = false) {
        self.id = id; self.name = name; self.host = host
        self.hostDeviceType = hostDeviceType; self.isNPC = isNPC
    }
    /// Subtitle per spec: "<HostLabel>" (· NPC handled with a glyph in the row).
    var subtitle: String { host.label }

    /// The leading host glyph: the design system's custom `device.<device_type>`
    /// symbol when one ships for the host's type, otherwise the host kind's SF
    /// Symbol. Falls back to the SF Symbol too when the host type is unknown.
    var hostImage: Image {
        if let hostDeviceType {
            Image.rcSymbol("device.\(hostDeviceType)", fallback: host.sfSymbol)
        } else {
            Image(systemName: host.sfSymbol)
        }
    }
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
                    Label { Text("\(r.name)  —  \(r.subtitle)") } icon: { r.hostImage }
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
                hostTile(selection)
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
            // Fill the available width (it lives in the narrow sidebar), but never
            // squeeze below a legible minimum.
            .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
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
    }

    private func hostTile(_ replicant: RCReplicant) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(.rcAccentMuted)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(.rcAccentBorder, lineWidth: 0.5)
                )
            replicant.hostImage
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.rcTextPrimary, .rcAccent, .rcTextSecondary)
        }
        .frame(width: 30, height: 30)
    }
}

// MARK: - Glyph tile (icon chip for list rows & detail headers)

/// The rounded surface chip that frames a device/blueprint/replicant glyph. The
/// chrome (surface fill + hairline border, square tile) is identical across
/// every list row and detail header; only the glyph image and size vary — so
/// callers pass the `Image` and pick a `TileSize`. Replaces the per-feature
/// `glyphTile` copies.
public struct RCGlyphTile: View {
    private let image: Image
    private let size: CGFloat

    public init(_ image: Image, size: CGFloat = TileSize.small) {
        self.image = image
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(.rcSurfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(.rcSeparator, lineWidth: Hairline.thin)
                )
            image
                .font(.system(size: size * 0.5, weight: .regular))
                .foregroundStyle(.rcTextPrimary, .rcAccent, .rcTextSecondary)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Error banner (inline dismissible warning strip)

/// The inline warning strip shown above a list when an action fails: a warning
/// glyph, the message, and a Dismiss button, on a raised surface with a bottom
/// hairline. Byte-identical across five feature list views before this; the only
/// per-site difference is what Dismiss does, so that's the one parameter.
public struct RCErrorBanner: View {
    private let message: String
    private let onDismiss: () -> Void

    public init(_ message: String, onDismiss: @escaping () -> Void) {
        self.message = message
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.rcWarning)
            Text(message)
                .font(.rcCaption)
                .foregroundStyle(.rcTextSecondary)
                .lineLimit(2)
            Spacer(minLength: Space.s)
            Button("Dismiss", action: onDismiss)
                .buttonStyle(RCButtonStyle(.text))
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(.rcSurfaceRaised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.rcSeparator).frame(height: Hairline.thin)
        }
    }
}

// MARK: - Section header & readout card (detail-pane building blocks)

/// An uppercase section label, optionally trailed by a monospaced count — the
/// `Text(heading.uppercased()).font(.rcSectionLabel)…` line that recurs ~20×
/// across the detail panes.
public struct RCSectionHeader: View {
    private let heading: String
    private let count: Int?

    public init(_ heading: String, count: Int? = nil) {
        self.heading = heading
        self.count = count
    }

    public var body: some View {
        HStack {
            Text(heading.uppercased())
                .font(.rcSectionLabel)
                .foregroundStyle(.rcTextTertiary)
            if let count {
                Text("\(count)")
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextTertiary)
            }
        }
    }
}

/// A titled card on a raised surface — an `RCSectionHeader` above arbitrary
/// content. Hoisted from `LocationDetailView`'s private `ReadoutCard`/`SectionCard`
/// (the right abstraction, previously in the wrong place) so every detail pane
/// shares one card instead of re-inlining the surface + heading.
public struct RCReadoutCard<Content: View>: View {
    private let heading: String
    private let count: Int?
    private let content: Content

    public init(_ heading: String, count: Int? = nil, @ViewBuilder content: () -> Content) {
        self.heading = heading
        self.count = count
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            RCSectionHeader(heading, count: count)
            VStack(alignment: .leading, spacing: Space.xs) { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
        .background(.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.card))
    }
}

// MARK: - Pill badge (compact inline capsule)

public enum RCPillTone { case accent, neutral }

public extension View {
    /// Wrap inline text as a compact capsule badge. `.accent` = amber fill +
    /// hairline border (queue counts, HOST); `.neutral` = separator fill (NPC).
    /// Standardizes the ad-hoc `Capsule().fill(…)`/`.overlay(…)` pills that were
    /// re-inlined per feature; the text's own font/colour stay with the caller.
    func rcPill(_ tone: RCPillTone) -> some View {
        modifier(RCPillModifier(tone: tone))
    }
}

struct RCPillModifier: ViewModifier {
    let tone: RCPillTone
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(Capsule().fill(fill))
            .overlay {
                if tone == .accent {
                    Capsule().stroke(Color.rcAccent.opacity(0.4), lineWidth: Hairline.thin)
                }
            }
    }
    private var fill: Color {
        switch tone {
        case .accent:  Color.rcAccent.opacity(0.12)
        case .neutral: Color.rcSeparator.opacity(0.5)
        }
    }
}

// MARK: - Meter bar (accent fill over a track)

/// A horizontal fill bar — accent over a separator track — that fills the width
/// it's given (wrap in a `.frame` for a fixed size). Replaces the per-feature
/// capacity/resource bars that each re-inlined the same capsule-over-capsule.
public struct RCMeterBar: View {
    private let fraction: Double
    private let height: CGFloat

    public init(fraction: Double, height: CGFloat = 4) {
        self.fraction = min(1, max(0, fraction))
        self.height = height
    }

    public var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(.rcSeparator)
                .overlay(alignment: .leading) {
                    Capsule().fill(.rcAccent).frame(width: proxy.size.width * fraction)
                }
        }
        .frame(height: height)
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
                section("Segmented control") {
                    GallerySegments()
                }
                section("Dropdowns") {
                    GalleryDropdowns()
                }
                section("Badges, tiles & meters") {
                    GalleryBadges()
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

private struct GalleryBadges: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(spacing: Space.m) {
                Text("+3").font(.rcMonoSmall).foregroundStyle(.rcAccent).rcPill(.accent)
                Text("HOST").font(.rcSectionLabel).kerning(0.5).foregroundStyle(.rcAccent).rcPill(.accent)
                Text("NPC").font(.rcMonoSmall).foregroundStyle(.rcTextTertiary).rcPill(.neutral)
                StatusBadge("mining", parameter: "iron")
            }
            HStack(spacing: Space.m) {
                RCGlyphTile(Image(systemName: "cpu"))
                RCGlyphTile(Image(systemName: "cpu"), size: TileSize.large)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Meter · 72%").font(.rcCaption).foregroundStyle(Color.rcTextTertiary)
                RCMeterBar(fraction: 0.72).frame(width: 160)
            }
            RCErrorBanner("Something went wrong while dispatching.") {}
                .frame(width: 320)
            RCReadoutCard("Readout Card", count: 2) {
                Text("First line").font(.rcBody).foregroundStyle(.rcTextSecondary)
                Text("Second line").font(.rcBody).foregroundStyle(.rcTextSecondary)
            }
            .frame(width: 320)
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
        RCReplicant(id: "B58FCC78", name: "Roy",   host: .heaven_vessel),
        RCReplicant(id: "A21D90F3", name: "Pris",  host: .matrix),
        RCReplicant(id: "C77E1A2B", name: "Zhora", host: .hub),
        RCReplicant(id: "D40B5E91", name: "Leon",  host: .heaven_vessel, isNPC: true),
    ]
    @State private var active = RCReplicant(id: "B58FCC78", name: "Roy", host: .heaven_vessel)

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
                    .frame(maxWidth: 320)
            }
        }
    }
}

#Preview("Controls · light + dark") {
    RCControlsGalleryView().frame(width: 760, height: 760)
}
