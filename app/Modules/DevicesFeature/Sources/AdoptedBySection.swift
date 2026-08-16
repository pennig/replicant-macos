//
//  AdoptedBySection.swift
//  Replicould — Devices feature
//
//  The device inspector's "Adopted By" card: the AMI controller shepherding this
//  device, when one has adopted it, as a tap-to-select row.
//

import ComposableArchitecture
import GameModels
import SQLiteData
import SwiftUI
import UI

/// The controller that adopted this device. Renders nothing when none has — an
/// unadopted device has no relationship to report, unlike an empty carrier.
struct AdoptedBySection: View {
    let device: Device
    let store: StoreOf<DevicesFeature>

    /// The whole fleet, so the controller's code resolves to its full record.
    @FetchAll(Device.order { $0.deviceCode }) private var fleet

    private var controller: DeviceAdoption.Link? {
        DeviceAdoption.controller(of: device, fleet: fleet)
    }

    var body: some View {
        if let controller {
            VStack(alignment: .leading, spacing: Space.s) {
                RCSectionHeader("Adopted By")
                AdoptionRow(link: controller, unknownName: "Controller", store: store)
                    .deviceCardBackground()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
