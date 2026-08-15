//
//  DirectiveStallPanel.swift
//  Replicould — Directives feature
//
//  What a stalled mission shows: why it stopped, what to do about it, and the
//  three verbs that resolve it (design spec §8). The engine pauses and surfaces
//  rather than improvising, so this panel is the whole resolution surface.
//
//  Purpose-made rather than `RCErrorBanner` (which §7 names): that control
//  hard-codes a single Dismiss button and four other screens depend on its
//  shape, so widening it for one caller would be the wrong trade.
//

import GameModels
import SwiftUI
import UI

struct DirectiveStallPanel: View {
    let reason: DirectiveAttentionReason
    /// The specific subject, when the stall named one — a designation code.
    let detail: String?
    let retry: () -> Void
    let skip: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: IconSize.m))
                    .foregroundStyle(.rcWarning)
                Text(reason.displayName)
                    .font(.rcBodyEmph)
                    .foregroundStyle(.rcTextPrimary)
                Spacer(minLength: 0)
            }
            if let detail {
                Text(detail)
                    .font(reason.detailIsDesignation ? .rcMonoSmall : .rcCaption)
                    .foregroundStyle(.rcTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(reason.guidance)
                .font(.rcCaption)
                .foregroundStyle(.rcTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s) {
                Button("Retry", action: retry)
                    .buttonStyle(RCButtonStyle(.primary))
                Button("Skip Target", action: skip)
                    .buttonStyle(RCButtonStyle(.secondary))
                Button("Cancel Run", action: cancel)
                    .buttonStyle(RCButtonStyle(.secondary))
                Spacer(minLength: 0)
            }
        }
        .padding(Space.m)
        .background(.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(.rcSeparator, lineWidth: Hairline.thin)
        )
    }
}
