//
//  DesignSystem.swift
//  Generated from the Replicant dashboard design exploration.
//
//  Drop this file + ReplicantColors.xcassets into your app target. Every
//  color resolves dynamically for light/dark (the asset catalog carries both
//  appearances), so you generally do NOT branch on colorScheme yourself.
//
//  If you put the assets in a Swift package instead of the app target,
//  change `.main` below to `.module`.
//

import SwiftUI

private let rcBundle: Bundle = .module

// MARK: - Symbols

public extension Image {
    /// Resolves a custom symbol from the UI module's `Symbols.xcassets`.
    /// Use this for any asset-catalog image shipped in the design system, since
    /// callers in other modules would otherwise look in `Bundle.main` and fail.
    static func rcSymbol(_ name: String, fallback: String = "circle.hexagonpath") -> Image {
        if rcBundle.image(forResource: name) != nil {
            Image(name, bundle: rcBundle)
        } else {
            Image(systemName: fallback)
        }
    }
}

// MARK: - Semantic colors

// Defined on `ShapeStyle where Self == Color` so each token is usable both as a
// plain `Color` value (`Color.rcAccent`, `let c: Color = .rcAccent`) and in any
// `ShapeStyle`-expecting API (`.foregroundStyle(.rcAccent)`, `.fill(.rcAccent)`,
// `.tint(.rcAccent)`). One definition serves both — the way Apple ships `.red`.
public extension ShapeStyle where Self == Color {
    // Surfaces
    static var rcWindowBackground:    Color { Color("WindowBackground",    bundle: rcBundle) }
    static var rcContentBackground:   Color { Color("ContentBackground",   bundle: rcBundle) }
    static var rcSidebarBackground:   Color { Color("SidebarBackground",   bundle: rcBundle) }
    static var rcSurfaceRaised:       Color { Color("SurfaceRaised",       bundle: rcBundle) }
    static var rcSurfaceRaisedStrong: Color { Color("SurfaceRaisedStrong", bundle: rcBundle) }

    // Hairlines / separators (carry alpha)
    static var rcSeparator:       Color { Color("Separator",       bundle: rcBundle) }
    static var rcSeparatorStrong: Color { Color("SeparatorStrong", bundle: rcBundle) }
    static var rcSeparatorSoft:   Color { Color("SeparatorSoft",   bundle: rcBundle) }

    // Text
    static var rcTextPrimary:   Color { Color("TextPrimary",   bundle: rcBundle) }
    static var rcTextSecondary: Color { Color("TextSecondary", bundle: rcBundle) }
    static var rcTextTertiary:  Color { Color("TextTertiary",  bundle: rcBundle) }

    // JSON syntax highlighting (raw API inspector). Tuned to sit alongside the
    // amber accent: keys blue, strings green, numbers a redder burnt orange so
    // they read as distinct from the gold accent.
    static var rcJSONKey:    Color { Color("JSONKey",    bundle: rcBundle) }
    static var rcJSONString: Color { Color("JSONString", bundle: rcBundle) }
    static var rcJSONNumber: Color { Color("JSONNumber", bundle: rcBundle) }

    // Accent (amber)
    static var rcAccent:        Color { Color("AccentPrimary", bundle: rcBundle) }
    static var rcAccentOnColor: Color { Color("AccentOnColor", bundle: rcBundle) } // text/icon on top of accent fills
    static var rcAccentMuted:   Color { Color("AccentMuted",   bundle: rcBundle) } // selection background
    static var rcAccentBorder:  Color { Color("AccentBorder",  bundle: rcBundle) } // selection hairline

    // Status taxonomy
    static var rcStatusReady:   Color { Color("StatusReady",   bundle: rcBundle) }
    static var rcStatusWorking: Color { Color("StatusWorking", bundle: rcBundle) }
    static var rcStatusTransit: Color { Color("StatusTransit", bundle: rcBundle) }
    static var rcStatusSensing: Color { Color("StatusSensing", bundle: rcBundle) }
    static var rcStatusRelay:   Color { Color("StatusRelay",   bundle: rcBundle) }
    static var rcStatusWaiting: Color { Color("StatusWaiting", bundle: rcBundle) }
    static var rcStatusOffline: Color { Color("StatusOffline", bundle: rcBundle) }

    // Special
    static var rcNPC:         Color { Color("NPCAccent",   bundle: rcBundle) }
    static var rcDanger:      Color { Color("Danger",      bundle: rcBundle) }
    static var rcDangerMuted: Color { Color("DangerMuted", bundle: rcBundle) }

    // Outcome / semantics (e.g. HTTP response codes): success · warning · error
    static var rcSuccess: Color { Color("Success", bundle: rcBundle) }
    static var rcWarning: Color { Color("Warning", bundle: rcBundle) }
    static var rcError:   Color { Color("Error",   bundle: rcBundle) }
}

// MARK: - Status taxonomy
//
// The backend reports device/replicant status as a snake_case string, often
// with a parameter ("mining (iron)", "printing (mining_drone)"). Map the bare
// status to a tone, and the tone to a color + label.

public enum StatusTone: String, CaseIterable {
    case ready, working, transit, sensing, relay, waiting, offline

    public var color: Color {
        switch self {
        case .ready:   return .rcStatusReady
        case .working: return .rcStatusWorking
        case .transit: return .rcStatusTransit
        case .sensing: return .rcStatusSensing
        case .relay:   return .rcStatusRelay
        case .waiting: return .rcStatusWaiting
        case .offline: return .rcStatusOffline
        }
    }
}

public enum DeviceStatus {
    /// Map a raw backend status string (without its parameter) to a tone.
    public static func tone(for rawStatus: String) -> StatusTone {
        switch rawStatus {
        case "idle", "ready":
            return .ready
        case "collecting", "depositing", "mining", "printing", "repairing", "diverting":
            return .working
        case "travelling", "cruising", "surging", "recalling":
            return .transit
        case "prospecting", "tracking", "scanning", "monitoring", "patrolling", "coordinating":
            return .sensing
        case "relaying":
            return .relay
        case "recall_waiting", "waiting_for_surge_plate", "waiting_for_resources":
            return .waiting
        case "stowed", "decommissioning", "inactive":
            return .offline
        default:
            return .offline
        }
    }

    /// Human label for a raw status (parameter appended by the caller).
    public static func label(for rawStatus: String) -> String {
        let map: [String: String] = [
            "ready": "Ready",
            "stowed": "Stowed", "idle": "Idle", "travelling": "Travelling",
            "cruising": "Cruising", "surging": "Surging", "recalling": "Recalling",
            "recall_waiting": "Recall · waiting", "decommissioning": "Decommissioning",
            "collecting": "Collecting", "depositing": "Depositing",
            "waiting_for_surge_plate": "Awaiting surge", "mining": "Mining",
            "prospecting": "Prospecting", "tracking": "Tracking", "scanning": "Scanning",
            "monitoring": "Monitoring", "printing": "Printing",
            "waiting_for_resources": "Awaiting resources", "repairing": "Repairing",
            "diverting": "Diverting", "patrolling": "Patrolling",
            "coordinating": "Coordinating", "relaying": "Relaying", "inactive": "Inactive",
        ]
        return map[rawStatus] ?? rawStatus.capitalized
    }
}

// MARK: - Replicant host
//
// A replicant always lives inside exactly one host. The header/switcher icon
// reflects the host kind. SF Symbol names below are starting suggestions —
// swap for custom symbols if you want the schematic look from the mockups.

public enum HostKind: String, CaseIterable {
    case heaven_vessel, matrix, hub

    public var label: String {
        switch self {
        case .heaven_vessel: return "HEAVEN Vessel"
        case .matrix: return "Matrix"
        case .hub:    return "System Hub"
        }
    }
    public var sfSymbol: String {
        switch self {
        case .heaven_vessel: return "paperplane"            // spacecraft
        case .matrix: return "square.grid.2x2"       // immobile container
        case .hub:    return "circle.circle"         // claimed system
        }
    }

    /// Infer the host kind from a hosting device's `device_type`. A replicant
    /// lives inside exactly one host device (`heaven_vessel`, a matrix, or a
    /// system hub); we match on the type name and default to a vessel — the most
    /// common host — when the type is unknown or the device isn't loaded yet.
    public init(deviceType: String) {
        let type = deviceType.lowercased()
        if type.contains("matrix") { self = .matrix }
        else if type.contains("hub") { self = .hub }
        else { self = .heaven_vessel }
    }
}

// MARK: - SF Symbol suggestions for the sidebar
//
// enum SidebarItem -> symbol. Replace any with custom symbols as desired.
public enum SidebarSymbol {
    public static let stars      = "sparkles"
    public static let devices    = "circle.hexagongrid"
    public static let replicants = "point.3.connected.trianglepath.dotted"
    public static let blueprints = "doc.plaintext"
    public static let messages   = "envelope"
    public static let bobnet     = "bubble.left.and.bubble.right"
    public static let eventLog   = "list.bullet.rectangle"
    public static let account    = "key"
    public static let npc        = "cpu"
}

// MARK: - Spacing, radius, type tokens

public enum Space {
    public static let xs: CGFloat = 4
    public static let s:  CGFloat = 8
    public static let m:  CGFloat = 12
    public static let l:  CGFloat = 16
    public static let xl: CGFloat = 24
}

public enum Radius {
    public static let textBadge: CGFloat = 4   // text badges
    public static let control: CGFloat = 8   // buttons, fields, list rows
    public static let card:    CGFloat = 12  // panels / cards
    public static let window:  CGFloat = 13  // window corners (handled by the OS on macOS)
    public static let pill:    CGFloat = 999
}

/// Hairline widths for separators/strokes. Formalizes the `0.5`/`1` literals that
/// recur across cards, rows, and glyph tiles (`Rectangle().frame(height:)`,
/// `strokeBorder(lineWidth:)`).
public enum Hairline {
    public static let thin:    CGFloat = 0.5
    public static let regular: CGFloat = 1
}

/// Square dimensions for the icon/glyph tiles used in list rows (small) and
/// detail headers (large). Owned here so the two recurring magic numbers live in
/// one place; consumed by `RCGlyphTile`.
public enum TileSize {
    public static let small: CGFloat = 30
    public static let large: CGFloat = 52
}

/// Standard control dimensions. `height` pins non-text buttons to one consistent
/// height so variance in label content (e.g. differing SF Symbol glyph heights)
/// can't make otherwise-identical buttons render at different heights. Consumed by
/// `RCButtonStyle`.
public enum Control {
    public static let height: CGFloat = 34
}

public extension Font {
    static let rcTitle        = Font.system(size: 20, weight: .bold)            // inspector / list title
    static let rcHeadline     = Font.system(size: 15, weight: .semibold)
    static let rcBody         = Font.system(size: 13, weight: .regular)
    static let rcBodyEmph     = Font.system(size: 13, weight: .semibold)
    static let rcCaption      = Font.system(size: 11, weight: .medium)
    static let rcSectionLabel = Font.system(size: 10, weight: .semibold).uppercaseSmallCaps()            // UPPERCASE + tracking
    static let rcMono         = Font.system(size: 13, weight: .regular, design: .monospaced) // IDs / codes
    static let rcMonoSmall    = Font.system(size: 11, weight: .medium, design: .monospaced)
    // Monospaced variants at title/headline/emphasized-body prominence, for the
    // system-name rule: any system name (a designation code) is always monospace.
    static let rcTitleMono    = Font.system(size: 20, weight: .bold, design: .monospaced)     // system name, title prominence
    static let rcHeadlineMono = Font.system(size: 15, weight: .semibold, design: .monospaced) // system name, headline prominence
    static let rcBodyEmphMono  = Font.system(size: 13, weight: .semibold, design: .monospaced) // system name, list-row prominence
    static let rcDisplay      = Font.system(size: 28, weight: .semibold)            // large detail-header glyph / number
    static let rcMicro        = Font.system(size: 9, weight: .semibold)             // micro badge / caption below rcSectionLabel
}

// MARK: - Tiny reusable views matching the mockups

/// Status dot + label, e.g. ● Mining · Iron
public struct StatusBadge: View {
    public let rawStatus: String
    public let parameter: String?
    public init(_ rawStatus: String, parameter: String? = nil) {
        self.rawStatus = rawStatus; self.parameter = parameter
    }
    public var body: some View {
        let tone = DeviceStatus.tone(for: rawStatus)
        var text = DeviceStatus.label(for: rawStatus)
        if let parameter { text += " · \(parameter)" }
        return HStack(spacing: 6) {
            Circle().fill(tone.color).frame(width: 6, height: 6)
                .shadow(color: tone.color.opacity(0.6), radius: 3)
            Text(text).font(.rcCaption).foregroundStyle(tone.color)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.vertical, 3).padding(.horizontal, 8)
        .background(Capsule().fill(tone.color.opacity(0.12)))
        .overlay(Capsule().stroke(tone.color.opacity(0.4), lineWidth: 0.5))
    }
}
