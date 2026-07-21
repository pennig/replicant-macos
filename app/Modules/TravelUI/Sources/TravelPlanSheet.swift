//
//  TravelPlanSheet.swift
//  Replicould — TravelUI (shared travel-confirmation UI)
//
//  The `travel` command confirmation sheet, shared by the Devices inspector and
//  the star map (both plot the same command). Given a resolved `TravelPreview`,
//  it shows the dry-run itinerary (legs + totals) and lets the user commit or
//  back out. Reads only a plain value + two callbacks, so neither feature's
//  store leaks in here — parallel to `PrintingUI.PrintPlanSheet`.
//

import GameModels
import SwiftUI
import UI

public struct TravelPlanSheet: View {
    let preview: TravelPreview?
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    public init(preview: TravelPreview?, onConfirm: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.preview = preview
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            if let preview {
                header(preview)
                Divider().overlay(Color.rcSeparator)
                content(preview)
                footer(preview)
            }
        }
        .padding(Space.xl)
        .frame(width: 460)
        .background(Color.rcContentBackground)
    }

    // MARK: Header

    private func header(_ preview: TravelPreview) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: "location.north.line")
                .font(.system(size: IconSize.l, weight: .medium))
                .foregroundStyle(.rcAccent)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Travel Itinerary")
                    .font(.rcTitle)
                    .foregroundStyle(.rcTextPrimary)
                HStack(spacing: Space.xs) {
                    Text(preview.deviceCode)
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: IconSize.s, weight: .semibold))
                        .foregroundStyle(.rcTextTertiary)
                    Text(preview.destination)
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Phase-driven content

    @ViewBuilder
    private func content(_ preview: TravelPreview) -> some View {
        switch preview.phase {
        case .loading:
            HStack(spacing: Space.s) {
                ProgressView().controlSize(.small)
                Text("Plotting route…")
                    .font(.rcBody)
                    .foregroundStyle(.rcTextSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)

        case let .failed(message):
            VStack(spacing: Space.s) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: IconSize.xl))
                    .foregroundStyle(.rcWarning)
                Text(message)
                    .font(.rcBody)
                    .foregroundStyle(.rcTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 120)

        case let .loaded(plan):
            VStack(alignment: .leading, spacing: Space.l) {
                summary(plan)
                routeList(plan)
            }
        }
    }

    // MARK: Loaded — summary + legs

    private func summary(_ plan: TravelPlan) -> some View {
        HStack(spacing: Space.s) {
            summaryTile("Time", plan.totalTimeSeconds.map(Self.duration) ?? "—")
            if let ly = plan.totalDistanceLy, ly > 0 {
                summaryTile("Distance", Self.distanceLy(ly))
            }
            summaryTile("Legs", "\(plan.route.count)")
            if let type = plan.destinationType {
                summaryTile("Arrival", type.capitalized)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func summaryTile(_ label: String, _ value: String) -> some View {
        VStack(spacing: Space.xs) {
            Text(value)
                .font(.rcHeadline)
                .foregroundStyle(.rcTextPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label.uppercased())
                .font(.rcSectionLabel).kerning(0.5)
                .foregroundStyle(.rcTextTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.s)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(.rcSurfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(.rcSeparator, lineWidth: Hairline.thin)
                )
        )
    }

    private func routeList(_ plan: TravelPlan) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            RCSectionHeader("Route")
            VStack(spacing: 0) {
                ForEach(Array(plan.route.enumerated()), id: \.offset) { index, leg in
                    if index > 0 { Divider().overlay(Color.rcSeparator) }
                    legRow(leg, number: index + 1)
                }
            }
            .padding(.vertical, Space.xs)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(.rcSurfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .strokeBorder(.rcSeparator, lineWidth: Hairline.thin)
                    )
            )
        }
    }

    private func legRow(_ leg: TravelPlan.Leg, number: Int) -> some View {
        HStack(alignment: .center, spacing: Space.m) {
            Text("\(leg.leg ?? number)")
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextTertiary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(leg.from ?? "—")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextSecondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: IconSize.s, weight: .semibold))
                        .foregroundStyle(.rcTextTertiary)
                    Text(leg.to ?? "—")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextPrimary)
                }
                if let type = leg.type {
                    Text(type.capitalized)
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                }
            }

            Spacer(minLength: Space.s)

            VStack(alignment: .trailing, spacing: 2) {
                if let seconds = leg.timeSeconds {
                    Text(Self.duration(seconds))
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextSecondary)
                        .monospacedDigit()
                }
                Text(Self.legDistance(leg))
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
    }

    // MARK: Footer

    @ViewBuilder
    private func footer(_ preview: TravelPreview) -> some View {
        HStack(spacing: Space.s) {
            Spacer()
            switch preview.phase {
            case .loaded:
                Button("Cancel", action: onDismiss)
                    .buttonStyle(RCButtonStyle(.secondary))
                Button("Confirm Travel", action: onConfirm)
                    .buttonStyle(RCButtonStyle(.primary))
            case .failed:
                Button("Close", action: onDismiss)
                    .buttonStyle(RCButtonStyle(.secondary))
            case .loading:
                Button("Cancel", action: onDismiss)
                    .buttonStyle(RCButtonStyle(.secondary))
            }
        }
    }

    // MARK: Formatting

    /// Whole-second duration: `"50s"`, `"2m 6s"`, `"2m"`.
    private static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let remainder = total % 60
        return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
    }

    private static func distanceLy(_ ly: Double) -> String {
        String(format: "%.2f ly", ly)
    }

    /// A leg's distance — light-years for an interstellar hop, AU within a system.
    private static func legDistance(_ leg: TravelPlan.Leg) -> String {
        if let ly = leg.distanceLy { return String(format: "%.2f ly", ly) }
        if let au = leg.distanceAu { return String(format: "%.2f AU", au) }
        return "—"
    }
}
