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
                    if let subtitle = row.subtitle {
                        Text("·").foregroundStyle(.rcTextTertiary)
                        Text(subtitle)
                            .font(.rcCaption)
                            .foregroundStyle(.rcTextSecondary)
                    }
                    if isEngineOwned {
                        Image(systemName: "lock.fill")
                            .font(.system(size: IconSize.s))
                            .foregroundStyle(.rcTextTertiary)
                    }
                }
                theatreLine
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


    /// Whether this row's directive belongs to the engine rather than the user.
    private var isEngineOwned: Bool {
        if case let .builtIn(builtIn) = row { return builtIn.drivenBy != nil }
        return false
    }

    /// The theatre, subordinate to the row's own identity above it. A real
    /// depot is a designation (mono, house rule); "unassigned" is a status
    /// word, so it stays prose.
    private var theatreLine: some View {
        HStack(spacing: Space.xxs) {
            Text("Theatre").font(.rcCaption).foregroundStyle(.rcTextTertiary)
            if let depot = row.theatreDepot {
                Text(depot).font(.rcMonoSmall).foregroundStyle(.rcTextTertiary)
            } else {
                Text(row.theatreLabel).font(.rcCaption).foregroundStyle(.rcTextTertiary)
            }
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
