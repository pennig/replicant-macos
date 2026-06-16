//
//  Swatches.swift
//  A living style guide — renders every design token from
//  ReplicantColors.xcassets, side by side in light and dark.
//
//  Drop into the app target alongside ReplicantDesignSystem.swift, then open
//  the canvas (the #Previews below) or push `SwatchesView()` anywhere.
//

import SwiftUI

private struct Token: Identifiable {
    let id = UUID()
    let name: String
    let color: Color
    var alpha: Bool = false   // drawn over a surface so translucency reads
}

private struct TokenGroup: Identifiable {
    let id = UUID()
    let title: String
    let tokens: [Token]
}

private let tokenGroups: [TokenGroup] = [
    .init(title: "Surfaces", tokens: [
        .init(name: "WindowBackground", color: .rcWindowBackground),
        .init(name: "ContentBackground", color: .rcContentBackground),
        .init(name: "SidebarBackground", color: .rcSidebarBackground),
        .init(name: "SurfaceRaised", color: .rcSurfaceRaised),
        .init(name: "SurfaceRaisedStrong", color: .rcSurfaceRaisedStrong),
    ]),
    .init(title: "Separators", tokens: [
        .init(name: "Separator", color: .rcSeparator, alpha: true),
        .init(name: "SeparatorSoft", color: .rcSeparatorSoft, alpha: true),
    ]),
    .init(title: "Text", tokens: [
        .init(name: "TextPrimary", color: .rcTextPrimary),
        .init(name: "TextSecondary", color: .rcTextSecondary),
        .init(name: "TextTertiary", color: .rcTextTertiary),
    ]),
    .init(title: "Accent", tokens: [
        .init(name: "AccentPrimary", color: .rcAccent),
        .init(name: "AccentOnColor", color: .rcAccentOnColor),
        .init(name: "AccentMuted", color: .rcAccentMuted, alpha: true),
        .init(name: "AccentBorder", color: .rcAccentBorder, alpha: true),
    ]),
    .init(title: "Status", tokens: [
        .init(name: "StatusReady", color: .rcStatusReady),
        .init(name: "StatusWorking", color: .rcStatusWorking),
        .init(name: "StatusTransit", color: .rcStatusTransit),
        .init(name: "StatusSensing", color: .rcStatusSensing),
        .init(name: "StatusRelay", color: .rcStatusRelay),
        .init(name: "StatusWaiting", color: .rcStatusWaiting),
        .init(name: "StatusOffline", color: .rcStatusOffline),
    ]),
    .init(title: "Special", tokens: [
        .init(name: "NPCAccent", color: .rcNPC),
        .init(name: "Danger", color: .rcDanger),
        .init(name: "DangerMuted", color: .rcDangerMuted, alpha: true),
    ]),
]

private struct SwatchRow: View {
    let token: Token
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(token.alpha ? AnyShapeStyle(Color.rcSurfaceRaised) : AnyShapeStyle(.clear))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(token.color))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.rcSeparator, lineWidth: 1))
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(token.name).font(.rcBodyEmph).foregroundStyle(Color.rcTextPrimary)
                Text("Color.rc\(token.name.prefix(1).lowercased())\(token.name.dropFirst())")
                    .font(.rcMonoSmall).foregroundStyle(Color.rcTextTertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct SwatchColumn: View {
    let scheme: ColorScheme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(scheme == .dark ? "Dark appearance" : "Light appearance")
                    .font(.rcSectionLabel).textCase(.uppercase).kerning(1.2)
                    .foregroundStyle(Color.rcTextTertiary)
                ForEach(tokenGroups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title).font(.rcSectionLabel).textCase(.uppercase).kerning(1)
                            .foregroundStyle(Color.rcTextTertiary).opacity(0.8)
                        ForEach(group.tokens) { SwatchRow(token: $0) }
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.rcContentBackground)
        .environment(\.colorScheme, scheme)   // forces dynamic colors to resolve for this column
    }
}

public struct SwatchesView: View {
    public init() {}
    public var body: some View {
        HStack(spacing: 0) {
            SwatchColumn(scheme: .dark)
            Divider()
            SwatchColumn(scheme: .light)
        }
    }
}

#Preview("Swatches · light + dark") {
    SwatchesView().frame(width: 720, height: 900)
}
