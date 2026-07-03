//
//  DevicesView.swift
//  Replicould — Devices feature
//
//  The fleet master list for the split view's content column. Rows render
//  straight from the `Device` table via `@FetchAll`, so every relay update flows
//  in automatically; the store drives selection and the cold-load/refresh.
//

import ComposableArchitecture
import DependencyClients
import GameModels
import SQLiteData
import SwiftUI
import UI

public struct DevicesListView: View {
    @Bindable var store: StoreOf<DevicesFeature>

    public init(store: StoreOf<DevicesFeature>) {
        self.store = store
    }

    public var body: some View {
        List(selection: $store.selectedDeviceCode) {
            ForEach(store.devices) { device in
                DeviceRow(device: device)
                    .tag(device.deviceCode)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if store.devices.isEmpty {
                if store.isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        "No Devices",
                        systemImage: SidebarSymbol.devices,
                        description: Text("Your fleet will appear here once it loads.")
                    )
                }
            }
        }
        .navigationTitle("Devices")
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage = store.errorMessage {
                RCErrorBanner(errorMessage) { store.send(.dismissError) }
            }
        }
        .toolbar {
            ToolbarItem {
                if !store.devices.isEmpty {
                    Text("\(store.devices.count) devices")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                }
            }
            ToolbarItem {
                Button {
                    store.send(.refreshButtonTapped)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh fleet")
                .disabled(store.isLoading)
            }
        }
        .task { store.send(.task) }
    }

}

// MARK: - Row

private struct DeviceRow: View {
    let device: Device

    var body: some View {
        HStack(spacing: Space.s) {
            VStack(spacing: Space.xs) {
                RCGlyphTile(Image.rcSymbol("device.\(device.deviceType)"))
                capacityBar
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    Text(DevicePresentation.displayName(device.deviceType))
                        .font(.rcBodyEmph)
                        .foregroundStyle(.rcTextPrimary)
                        .lineLimit(1)
                    Text(device.deviceCode)
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                    Spacer(minLength: Space.xs)
                }
                HStack(spacing: Space.s) {
                    StatusBadge(device.statusBase)
                    if let location = device.location {
                        Text(location)
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcTextTertiary)
                            .lineLimit(1)
                    } else if let destination = travelDestination {
                        Label(destination, systemImage: "location.north.line")
                            .labelStyle(.titleAndIcon)
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcTextTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Space.xs)
                }
            }
        }
        .padding(.vertical, Space.xs)
    }

    /// The trip's destination code while the device is en route — surfaced only
    /// when there's no settled `location` to show instead. Prefers the whole
    /// route's `final_destination` over the active leg's `destination`.
    private var travelDestination: String? {
        guard device.derivedActivity?.kind == .travel else { return nil }
        return device.detail["travel"]?["final_destination"]?.stringValue
            ?? device.detail["travel"]?["destination"]?.stringValue
    }


    private var capacityBar: some View {
        Capsule()
            .fill(.rcSeparator)
            .frame(width: 30, height: 4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(.rcAccent)
                    .frame(width: 30 * device.operationalCapacity / 100, height: 4)
            }
    }
}
