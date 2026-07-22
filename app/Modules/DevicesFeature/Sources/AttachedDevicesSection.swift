//
//  AttachedDevicesSection.swift
//  Replicould — Devices feature
//
//  The device inspector's "Attached Devices" card for a carrier (a vessel with
//  the `attach` feature): its attached roster resolved against the observed
//  fleet, with a tap-to-select row per device.
//

import ComposableArchitecture
import GameModels
import SQLiteData
import SwiftUI
import UI

/// The roster of devices currently attached to a carrier (a vessel with the
/// `attach` feature). The codes come from the carrier's `attached_devices` tail;
/// each is resolved against the observed fleet so the row can show the device's
/// type, status, and location. Tapping a row selects that device in the inspector.
/// Shown only for carriers; an empty carrier still renders the section with its
/// capacity so the affordance to attach is discoverable.
struct AttachedDevicesSection: View {
    let device: Device
    let store: StoreOf<DevicesFeature>

    /// The whole fleet, so each attached code can be resolved to its full record.
    @FetchAll(Device.order { $0.deviceCode }) private var fleet

    /// The attached devices, resolved to full records where the fleet knows them.
    /// An unknown code (not yet loaded) still yields a row so the count is honest.
    private var attached: [(code: String, device: Device?)] {
        device.attachedDeviceCodes.map { code in
            (code, fleet.first { $0.deviceCode == code })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                RCSectionHeader("Attached Devices")
                Spacer(minLength: 0)
                if device.attachCapacity > 0 {
                    Text("\(attached.count)/\(device.attachCapacity)")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                }
            }

            if attached.isEmpty {
                Text("No devices attached.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.m)
                    .deviceCardBackground()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(attached.enumerated()), id: \.element.code) { index, entry in
                        if index > 0 { Divider().overlay(Color.rcSeparator) }
                        row(code: entry.code, attached: entry.device)
                    }
                }
                .deviceCardBackground()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One attached-device row — glyph, display name + code, and a status badge
    /// with its location. Selects the device in the inspector when tapped.
    @ViewBuilder
    private func row(code: String, attached: Device?) -> some View {
        Button {
            store.send(.binding(.set(\.selectedDeviceCode, code)))
        } label: {
            HStack(spacing: Space.s) {
                RCGlyphTile(Image.rcSymbol("device.\(attached?.deviceType ?? "unknown")"))
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.s) {
                        Text(attached.map { DevicePresentation.displayName($0.deviceType) } ?? "Attached Device")
                            .font(.rcBodyEmph)
                            .foregroundStyle(.rcTextPrimary)
                            .lineLimit(1)
                        Text(code)
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcTextTertiary)
                    }
                    if let attached {
                        HStack(spacing: Space.s) {
                            StatusBadge(attached.statusBase)
                            if let location = attached.location {
                                Text(attached.locationName ?? location)
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
