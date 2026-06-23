//
//  ReplicantDesignSystem.swift
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

private let rcBundle: Bundle = .main

// MARK: - Semantic colors

public extension Color {
    // Surfaces
    static let rcWindowBackground    = Color("WindowBackground",    bundle: rcBundle)
    static let rcContentBackground   = Color("ContentBackground",   bundle: rcBundle)
    static let rcSidebarBackground   = Color("SidebarBackground",   bundle: rcBundle)
    static let rcSurfaceRaised       = Color("SurfaceRaised",       bundle: rcBundle)
    static let rcSurfaceRaisedStrong = Color("SurfaceRaisedStrong", bundle: rcBundle)

    // Hairlines / separators (carry alpha)
    static let rcSeparator     = Color("Separator",     bundle: rcBundle)
    static let rcSeparatorStrong = Color("SeparatorStrong", bundle: rcBundle)
    static let rcSeparatorSoft = Color("SeparatorSoft", bundle: rcBundle)

    // Text
    static let rcTextPrimary   = Color("TextPrimary",   bundle: rcBundle)
    static let rcTextSecondary = Color("TextSecondary", bundle: rcBundle)
    static let rcTextTertiary  = Color("TextTertiary",  bundle: rcBundle)

    // Accent (amber)
    static let rcAccent        = Color("AccentPrimary", bundle: rcBundle)
    static let rcAccentOnColor = Color("AccentOnColor", bundle: rcBundle) // text/icon on top of accent fills
    static let rcAccentMuted   = Color("AccentMuted",   bundle: rcBundle) // selection background
    static let rcAccentBorder  = Color("AccentBorder",  bundle: rcBundle) // selection hairline

    // Status taxonomy
    static let rcStatusReady   = Color("StatusReady",   bundle: rcBundle)
    static let rcStatusWorking = Color("StatusWorking", bundle: rcBundle)
    static let rcStatusTransit = Color("StatusTransit", bundle: rcBundle)
    static let rcStatusSensing = Color("StatusSensing", bundle: rcBundle)
    static let rcStatusRelay   = Color("StatusRelay",   bundle: rcBundle)
    static let rcStatusWaiting = Color("StatusWaiting", bundle: rcBundle)
    static let rcStatusOffline = Color("StatusOffline", bundle: rcBundle)

    // Special
    static let rcNPC         = Color("NPCAccent",  bundle: rcBundle)
    static let rcDanger      = Color("Danger",     bundle: rcBundle)
    static let rcDangerMuted = Color("DangerMuted", bundle: rcBundle)
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
        case "idle":
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
    case vessel, matrix, hub

    public var label: String {
        switch self {
        case .vessel: return "Vessel"
        case .matrix: return "Matrix"
        case .hub:    return "System Hub"
        }
    }
    public var isMobile: Bool { self == .vessel } // only vessels can travel
    public var sfSymbol: String {
        switch self {
        case .vessel: return "paperplane"            // spacecraft
        case .matrix: return "square.grid.2x2"       // immobile container
        case .hub:    return "circle.circle"         // claimed system
        }
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
    public static let printQueue = "printer"
    public static let signals    = "antenna.radiowaves.left.and.right"
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
    public static let control: CGFloat = 8   // buttons, fields, list rows
    public static let card:    CGFloat = 12  // panels / cards
    public static let window:  CGFloat = 13  // window corners (handled by the OS on macOS)
    public static let pill:    CGFloat = 999
}

public extension Font {
    static let rcTitle        = Font.system(size: 20, weight: .bold)            // inspector / list title
    static let rcHeadline     = Font.system(size: 15, weight: .semibold)
    static let rcBody         = Font.system(size: 13, weight: .regular)
    static let rcBodyEmph     = Font.system(size: 13, weight: .semibold)
    static let rcCaption      = Font.system(size: 11, weight: .medium)
    static let rcSectionLabel = Font.system(size: 11, weight: .bold)            // UPPERCASE + tracking
    static let rcMono         = Font.system(size: 12, weight: .regular, design: .monospaced) // IDs / codes
    static let rcMonoSmall    = Font.system(size: 11, weight: .semibold, design: .monospaced)
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
        }
        .padding(.vertical, 3).padding(.horizontal, 8)
        .background(Capsule().fill(tone.color.opacity(0.12)))
        .overlay(Capsule().stroke(tone.color.opacity(0.4), lineWidth: 0.5))
    }
}
