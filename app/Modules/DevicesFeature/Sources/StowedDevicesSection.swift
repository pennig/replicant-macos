//
//  StowedDevicesSection.swift
//  Replicould — Devices feature
//
//  The device inspector's "Stowed Devices" card for a carrier with stow
//  capacity: its stowed roster resolved against the observed fleet, with a
//  tap-to-select row per device and a free-slots count in the header.
//

import ComposableArchitecture
import GameModels
import SQLiteData
import SwiftUI
import UI

/// The roster of devices currently stowed inside a carrier (one whose
/// `stow_capacity` is greater than zero). The codes come from the carrier's
/// `stowed_devices` tail; each is resolved against the observed fleet so the row
/// can show the device's type, status, and location. Tapping a row selects that
/// device in the inspector. The header reports how many slots remain free
/// (`stow_capacity − stow_used`); an empty carrier still renders the section so
/// its available capacity is discoverable.
struct StowedDevicesSection: View {
    let device: Device
    let store: StoreOf<DevicesFeature>

    /// The whole fleet, so each stowed code can be resolved to its full record.
    @FetchAll(Device.order { $0.deviceCode }) private var fleet

    /// The stowed devices, resolved to full records where the fleet knows them. An
    /// unknown code (not yet loaded) still yields a row so the count is honest.
    private var stowed: [(code: String, device: Device?)] {
        device.stowedDeviceCodes.map { code in
            (code, fleet.first { $0.deviceCode == code })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                RCSectionHeader("Stowed Devices")
                Spacer(minLength: 0)
                Text("\(device.stowUsed)/\(device.stowCapacity) · \(device.stowRemaining) free")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }

            if stowed.isEmpty {
                Text("No devices stowed.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.m)
                    .background(cardBackground)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(stowed.enumerated()), id: \.element.code) { index, entry in
                        if index > 0 { Divider().overlay(Color.rcSeparator) }
                        row(code: entry.code, stowed: entry.device)
                    }
                }
                .background(cardBackground)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One stowed-device row — glyph, display name + code, and a status badge with
    /// its location. Selects the device in the inspector when tapped.
    @ViewBuilder
    private func row(code: String, stowed: Device?) -> some View {
        Button {
            store.send(.binding(.set(\.selectedDeviceCode, code)))
        } label: {
            HStack(spacing: Space.s) {
                RCGlyphTile(Image.rcSymbol("device.\(stowed?.deviceType ?? "unknown")"))
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.s) {
                        Text(stowed.map { DevicePresentation.displayName($0.deviceType) } ?? "Stowed Device")
                            .font(.rcBodyEmph)
                            .foregroundStyle(.rcTextPrimary)
                            .lineLimit(1)
                        Text(code)
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcTextTertiary)
                    }
                    if let stowed {
                        HStack(spacing: Space.s) {
                            StatusBadge(stowed.statusBase)
                            if let location = stowed.location {
                                Text(stowed.locationName ?? location)
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

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(.rcSurfaceRaised)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(.rcSeparator, lineWidth: Hairline.thin)
            )
    }
}
