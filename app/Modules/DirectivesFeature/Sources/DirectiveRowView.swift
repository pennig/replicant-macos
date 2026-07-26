//
//  DirectiveRowView.swift
//  Replicould — Directives feature
//
//  One row of the unified list. The kind badge is the whole point of the
//  surface: built-in directives the server runs, custom missions the app runs.
//

import GameModels
import SwiftUI
import UI

struct DirectiveRowView: View {
    let row: DirectiveRow

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: symbol)
                .font(.system(size: IconSize.m))
                .foregroundStyle(.rcAccent)
                .frame(width: IconSize.m)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.xxs) {
                    Text(row.headline)
                        .font(.rcBodyEmph)
                        .foregroundStyle(.rcTextPrimary)
                        .lineLimit(1)
                    if let designation = row.headlineDesignation {
                        Text("→")
                            .font(.rcCaption)
                            .foregroundStyle(.rcTextTertiary)
                        Text(designation)
                            .font(.rcBodyEmphMono)
                            .foregroundStyle(.rcTextPrimary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: Space.xs) {
                    Text(row.deviceCode)
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextSecondary)
                    if let subtitle {
                        Text("·").foregroundStyle(.rcTextTertiary)
                        Text(subtitle)
                            .font(.rcCaption)
                            .foregroundStyle(.rcTextSecondary)
                    }
                }
            }
            Spacer(minLength: 0)
            kindBadge
        }
        .padding(.vertical, Space.xs)
    }

    /// Missions carry a host glyph; built-ins carry the AMI brain.
    private var symbol: String {
        switch row {
        case .custom: "flag.checkered"
        case .builtIn: "brain.head.profile"
        }
    }

    /// Progress for a mission; the controlled-drone count for a built-in.
    private var subtitle: String? {
        switch row {
        case let .custom(directive):
            let progress = directive.progress
            return "\(progress.completed)/\(progress.total)"
        case let .builtIn(builtIn):
            let count = builtIn.controlledDevices.count
            return count > 0 ? "\(count) controlled" : nil
        }
    }

    private var kindBadge: some View {
        Text(badgeLabel)
            .font(.rcMicroMono)
            .foregroundStyle(.rcTextTertiary)
            .padding(.horizontal, Space.xs)
            .padding(.vertical, Space.xxs)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(.rcSeparator, lineWidth: 1)
            )
    }

    private var badgeLabel: String {
        switch row {
        case .custom: "CUSTOM"
        case .builtIn: "BUILT-IN"
        }
    }
}
