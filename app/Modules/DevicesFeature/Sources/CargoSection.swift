//
//  CargoSection.swift
//  Replicould — Devices feature
//
//  The device inspector's "Cargo" card for a transport device: the resource
//  manifest currently aboard, with a fullness readout in the header.
//

import GameModels
import SwiftUI
import UI

/// The cargo manifest for a transport device (one with the `transport` feature):
/// each resource stack aboard with its quantity, plus a header reporting how full
/// the hold is (`cargo_used`/`cargo_capacity`). An empty hold still renders the
/// section — with an explicit "empty" note — so the capacity is discoverable and
/// the manifest is always present for a transport device.
struct CargoSection: View {
    let device: Device

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                RCSectionHeader("Cargo")
                Spacer(minLength: 0)
                if device.cargoCapacity > 0 {
                    Text("\(Self.number(device.cargoUsed))/\(device.cargoCapacity) · \(device.cargoRemaining) free")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                }
            }

            if device.cargoItems.isEmpty {
                Text("Cargo hold empty.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.m)
                    .background(cardBackground)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(device.cargoItems.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().overlay(Color.rcSeparator) }
                        row(item)
                    }
                }
                .background(cardBackground)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One cargo row — the resource's display name and how many units are aboard.
    private func row(_ item: Device.CargoItem) -> some View {
        HStack(spacing: Space.s) {
            Text(DevicePresentation.displayName(item.resourceType))
                .font(.rcBodyEmph)
                .foregroundStyle(.rcTextPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(item.quantity) unit\(item.quantity == 1 ? "" : "s")")
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextSecondary)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(.rcSurfaceRaised)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(.rcSeparator, lineWidth: Hairline.thin)
            )
    }

    /// Whole numbers stay whole (`80`), fractions keep one place (`1.5`).
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
