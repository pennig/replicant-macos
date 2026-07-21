//
//  PrintPlanSheet.swift
//  Replicould — PrintingUI (shared print-confirmation UI)
//
//  The `enqueue_print` confirmation sheet, shared by the Devices and Print Queue
//  inspectors (both depend on this feature for the blueprint catalog). Given a
//  resolved `PrintPreview`, it shows the chosen blueprint's per-resource cost
//  against the live inventory at the device's current location — refreshed just
//  before the sheet opens — and lets the user commit or back out. Reads only
//  plain values + two callbacks, so neither feature's store leaks in here.
//

import GameModels
import SwiftUI
import UI

public struct PrintPlanSheet: View {
    let preview: PrintPreview?
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    public init(preview: PrintPreview?, onConfirm: @escaping () -> Void, onDismiss: @escaping () -> Void) {
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

    private func header(_ preview: PrintPreview) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: "printer")
                .font(.system(size: IconSize.l, weight: .medium))
                .foregroundStyle(.rcAccent)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Confirm Print")
                    .font(.rcTitle)
                    .foregroundStyle(.rcTextPrimary)
                HStack(spacing: Space.xs) {
                    Text(BlueprintPresentation.displayName(preview.deviceType))
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextSecondary)
                    if let name = locationName(preview) {
                        Text("·").foregroundStyle(.rcTextTertiary)
                        Text(name)
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcTextTertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The location name for the resolved requirements, if any.
    private func locationName(_ preview: PrintPreview) -> String? {
        guard case let .loaded(requirements) = preview.phase else { return nil }
        return requirements.locationName
    }

    // MARK: Phase-driven content

    @ViewBuilder
    private func content(_ preview: PrintPreview) -> some View {
        switch preview.phase {
        case .loading:
            HStack(spacing: Space.s) {
                ProgressView().controlSize(.small)
                Text("Checking location inventory…")
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

        case let .loaded(requirements):
            requirementsList(requirements)
        }
    }

    // MARK: Loaded — resource breakdown

    @ViewBuilder
    private func requirementsList(_ requirements: PrintRequirements) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                RCSectionHeader("Resources Required")
                Spacer(minLength: 0)
                RCSectionHeader("Have / Need")
            }

            if requirements.lines.isEmpty {
                Text("This blueprint lists no resource cost.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.m)
                    .background(cardBackground)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(requirements.lines.enumerated()), id: \.element.id) { index, line in
                        if index > 0 { Divider().overlay(Color.rcSeparator) }
                        resourceRow(line, inventoryKnown: requirements.inventoryAvailable)
                    }
                }
                .padding(.vertical, Space.xs)
                .background(cardBackground)
            }

            note(requirements)
        }
    }

    private func resourceRow(_ line: PrintResourceLine, inventoryKnown: Bool) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: statusSymbol(line, inventoryKnown: inventoryKnown))
                .font(.system(size: IconSize.s))
                .foregroundStyle(statusColor(line, inventoryKnown: inventoryKnown))
                .frame(width: 14)
            Text(line.label)
                .font(.rcBody)
                .foregroundStyle(.rcTextPrimary)
            Spacer(minLength: Space.s)
            Text(amountText(line, inventoryKnown: inventoryKnown))
                .font(.rcMonoSmall)
                .foregroundStyle(line.isMet ? .rcTextSecondary : .rcTextPrimary)
                .monospacedDigit()
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
    }

    /// A summary line beneath the breakdown: unknown stock, or a shortfall warning.
    @ViewBuilder
    private func note(_ requirements: PrintRequirements) -> some View {
        if !requirements.inventoryAvailable {
            noteRow(
                symbol: "questionmark.circle",
                color: .rcTextTertiary,
                text: "Couldn't read this location's inventory — enqueue anyway and the job waits for resources."
            )
        } else if !requirements.allMet {
            noteRow(
                symbol: "hourglass",
                color: .rcWarning,
                text: "Not enough on hand — the job will queue and wait until the missing resources arrive."
            )
        } else {
            noteRow(
                symbol: "checkmark.circle",
                color: .rcStatusReady,
                text: "All resources are in stock at this location."
            )
        }
    }

    private func noteRow(symbol: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: symbol)
                .font(.system(size: IconSize.s))
                .foregroundStyle(color)
            Text(text)
                .font(.rcCaption)
                .foregroundStyle(.rcTextSecondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: Footer

    @ViewBuilder
    private func footer(_ preview: PrintPreview) -> some View {
        HStack(spacing: Space.s) {
            Spacer()
            switch preview.phase {
            case .loaded:
                Button("Cancel", action: onDismiss)
                    .buttonStyle(RCButtonStyle(.secondary))
                Button("Enqueue Print", action: onConfirm)
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

    private func statusSymbol(_ line: PrintResourceLine, inventoryKnown: Bool) -> String {
        guard inventoryKnown else { return "circle.dashed" }
        return line.isMet ? "checkmark.circle.fill" : "hourglass"
    }

    private func statusColor(_ line: PrintResourceLine, inventoryKnown: Bool) -> Color {
        guard inventoryKnown else { return .rcTextTertiary }
        return line.isMet ? .rcStatusReady : .rcWarning
    }

    /// "12 / 8" — location stock over required cost; stock reads "—" when unknown.
    private func amountText(_ line: PrintResourceLine, inventoryKnown: Bool) -> String {
        let have = inventoryKnown ? (line.available.map(Self.number) ?? "0") : "—"
        return "\(have) / \(Self.number(line.required))"
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(.rcSurfaceRaised)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(.rcSeparator, lineWidth: Hairline.thin)
            )
    }
}
