//
//  AdoptionRow.swift
//  Replicould — Devices feature
//
//  One row at either end of an adoption link — glyph, display name + code, and a
//  status badge with location. Selects that device in the inspector when tapped.
//

import ComposableArchitecture
import SwiftUI
import UI

struct AdoptionRow: View {
    let link: DeviceAdoption.Link
    /// Shown in place of the display name when the fleet hasn't loaded the device.
    let unknownName: String
    let store: StoreOf<DevicesFeature>

    var body: some View {
        Button {
            store.send(.binding(.set(\.selectedDeviceCode, link.deviceCode)))
        } label: {
            HStack(spacing: Space.s) {
                RCGlyphTile(Image.rcSymbol("device.\(link.device?.deviceType ?? "unknown")"))
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.s) {
                        Text(link.device.map { DevicePresentation.displayName($0.deviceType) } ?? unknownName)
                            .font(.rcBodyEmph)
                            .foregroundStyle(.rcTextPrimary)
                            .lineLimit(1)
                        Text(link.deviceCode)
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcTextTertiary)
                    }
                    if let device = link.device {
                        HStack(spacing: Space.s) {
                            StatusBadge(device.statusBase)
                            if let location = device.location {
                                Text(device.locationName ?? location)
                                    .font(.rcMonoSmall)
                                    .foregroundStyle(.rcTextTertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: IconSize.s, weight: .semibold))
                    .foregroundStyle(.rcTextTertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
        }
        .buttonStyle(.plain)
    }
}
