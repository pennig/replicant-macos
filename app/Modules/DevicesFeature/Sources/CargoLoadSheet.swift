//
//  CargoLoadSheet.swift
//  Replicould — Devices feature
//
//  The `collect_resources` (Load Cargo) confirmation sheet for the device
//  inspector. Given a resolved `CargoLoadPreview` — the transport's free hold
//  space plus the location's live stockpile — it presents one quantity control
//  per available resource (each capped by what's on hand and by the hold's
//  remaining room) and dispatches the chosen per-resource amounts. Mirrors the
//  print/travel preview sheets: reads a plain value + two callbacks so the store
//  never leaks in here.
//

import GameModels
import SwiftUI
import UI

struct CargoLoadSheet: View {
    let preview: CargoLoadPreview?
    let onConfirm: ([String: Int]) -> Void
    let onDismiss: () -> Void

    /// Chosen units per resource type. Rows default to 0 (absent); a resource is
    /// dropped from the map when its amount returns to 0 so `total` stays honest.
    @State private var amounts: [String: Int] = [:]

    var body: some View {
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

    private func header(_ preview: CargoLoadPreview) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: IconSize.l, weight: .medium))
                .foregroundStyle(.rcAccent)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Load Cargo")
                    .font(.rcTitle)
                    .foregroundStyle(.rcTextPrimary)
                HStack(spacing: Space.xs) {
                    Text(preview.deviceCode)
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextSecondary)
                    if let name = preview.locationName {
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

    // MARK: Phase-driven content

    @ViewBuilder
    private func content(_ preview: CargoLoadPreview) -> some View {
        switch preview.phase {
        case .loading:
            HStack(spacing: Space.s) {
                ProgressView().controlSize(.small)
                Text("Reading location stockpile…")
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

        case let .loaded(stock):
            stockpileList(stock, capacityRemaining: preview.capacityRemaining)
        }
    }

    // MARK: Loaded — per-resource quantity picker

    @ViewBuilder
    private func stockpileList(_ stock: [CargoStock], capacityRemaining: Int) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                RCSectionHeader("Stockpile")
                Spacer(minLength: 0)
                Text("\(total) / \(capacityRemaining) units · \(max(0, capacityRemaining - total)) free")
                    .font(.rcSectionLabel)
                    .foregroundStyle(total > 0 ? .rcAccent : .rcTextTertiary)
                    .monospacedDigit()
            }

            if stock.isEmpty {
                Text("This location has no resources to load.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.m)
                    .deviceCardBackground()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(stock.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().overlay(Color.rcSeparator) }
                        stockRow(item, capacityRemaining: capacityRemaining)
                    }
                }
                .padding(.vertical, Space.xs)
                .deviceCardBackground()

                Text("Pick how much of each resource to load, up to the hold's free space.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }
        }
    }

    private func stockRow(_ item: CargoStock, capacityRemaining: Int) -> some View {
        let rowMax = rowMax(for: item, capacityRemaining: capacityRemaining)
        return HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(DevicePresentation.displayName(item.resourceType))
                    .font(.rcBody)
                    .foregroundStyle(.rcTextPrimary)
                Text("\(item.available) on hand")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
                    .monospacedDigit()
            }
            Spacer(minLength: Space.s)
            TextField("0", text: amountBinding(for: item, rowMax: rowMax))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.rcMonoSmall)
                .monospacedDigit()
                .frame(width: 56)
            Button("Max") { amounts[item.resourceType] = rowMax }
                .buttonStyle(.plain)
                .font(.rcCaption)
                .foregroundStyle(rowMax > (amounts[item.resourceType] ?? 0) ? .rcAccent : .rcTextTertiary)
                .disabled(rowMax <= (amounts[item.resourceType] ?? 0))
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
    }

    // MARK: Footer

    @ViewBuilder
    private func footer(_ preview: CargoLoadPreview) -> some View {
        HStack(spacing: Space.s) {
            Spacer()
            switch preview.phase {
            case .loaded:
                Button("Cancel", action: onDismiss)
                    .buttonStyle(RCButtonStyle(.secondary))
                Button(total > 0 ? "Load \(total) Unit\(total == 1 ? "" : "s")" : "Load") {
                    onConfirm(amounts.filter { $0.value > 0 })
                }
                .buttonStyle(RCButtonStyle(.primary))
                .disabled(total == 0)
            case .failed:
                Button("Close", action: onDismiss)
                    .buttonStyle(RCButtonStyle(.secondary))
            case .loading:
                Button("Cancel", action: onDismiss)
                    .buttonStyle(RCButtonStyle(.secondary))
            }
        }
    }

    // MARK: Selection math

    /// Total units chosen across all resources.
    private var total: Int { amounts.values.reduce(0, +) }

    /// The most this resource may be set to: capped by what's on hand and by the
    /// hold's remaining room once the *other* resources' selections are accounted
    /// for. `capacityRemaining - (total - current)` is the space left for this row.
    private func rowMax(for item: CargoStock, capacityRemaining: Int) -> Int {
        let current = amounts[item.resourceType] ?? 0
        let roomForRow = capacityRemaining - (total - current)
        return max(0, min(item.available, roomForRow))
    }

    /// A string binding into the `amounts` map for a resource: parses the field,
    /// clamps it into `0...rowMax`, and clears the entry at 0 so `total` and the
    /// picker's caps stay consistent.
    private func amountBinding(for item: CargoStock, rowMax: Int) -> Binding<String> {
        Binding(
            get: {
                let value = amounts[item.resourceType] ?? 0
                return value == 0 ? "" : String(value)
            },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                let parsed = Int(digits) ?? 0
                let clamped = min(max(0, parsed), rowMax)
                if clamped == 0 { amounts[item.resourceType] = nil }
                else { amounts[item.resourceType] = clamped }
            }
        )
    }

}
