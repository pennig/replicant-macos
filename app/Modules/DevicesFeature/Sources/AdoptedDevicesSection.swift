//
//  AdoptedDevicesSection.swift
//  Replicould — Devices feature
//
//  The device inspector's "Adopted Devices" card for an AMI controller: the
//  devices it shepherds, read from both ends of the link and resolved against
//  the observed fleet, with a tap-to-select row each.
//

import ComposableArchitecture
import GameModels
import SQLiteData
import SwiftUI
import UI

/// The roster of devices an AMI controller currently controls. Shown for any
/// controller (`DeviceAdoption.canAdopt`); an empty one still renders the section
/// so the affordance to adopt is discoverable.
struct AdoptedDevicesSection: View {
    let device: Device
    let store: StoreOf<DevicesFeature>

    /// The whole fleet, so each adopted code can be resolved to its full record —
    /// and so a controller whose `controlled_devices` tail a list sync erased is
    /// still readable from the drones' own `controller_device_code`.
    @FetchAll(Device.order { $0.deviceCode }) private var fleet

    private var adopted: [DeviceAdoption.Link] {
        DeviceAdoption.adopted(by: device, fleet: fleet)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                RCSectionHeader("Adopted Devices")
                Spacer(minLength: 0)
                if !adopted.isEmpty {
                    Text("\(adopted.count)")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                }
            }

            if adopted.isEmpty {
                Text("No devices adopted.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.m)
                    .deviceCardBackground()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(adopted.enumerated()), id: \.element.deviceCode) { index, link in
                        if index > 0 { Divider().overlay(Color.rcSeparator) }
                        AdoptionRow(link: link, unknownName: "Adopted Device", store: store)
                    }
                }
                .deviceCardBackground()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
