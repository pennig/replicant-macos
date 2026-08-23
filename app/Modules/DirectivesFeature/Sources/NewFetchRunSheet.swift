//
//  NewFetchRunSheet.swift
//  Replicould — Directives feature
//
//  The Fetch Run launcher sheet: pick a device, pick where it goes. The plate
//  is shown rather than chosen — there is one right answer and no reason to
//  make the operator find it — but it is shown BEFORE Launch, because which
//  hull flies is the part an operator would otherwise only learn afterwards.
//
//  Device codes and location designations are both designations, so every one
//  of them takes a mono token per house rule.
//

import ComposableArchitecture
import DirectiveEngine
import GameModels
import SwiftUI
import UI

public struct NewFetchRunSheet: View {
    @Bindable var store: StoreOf<NewFetchRunFeature>

    public init(store: StoreOf<NewFetchRunFeature>) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text("New Fetch Run")
                .font(.rcTitle)
                .foregroundStyle(.rcTextPrimary)

            if store.eligiblePayloads.isEmpty {
                nothingToFetchNotice
            } else {
                devicePicker
                destinationPicker
                plateSummary
                Text("Flies the plate to the device, carries it to the destination, then parks the plate at the nearest theatre. A modular device is compacted for the trip and left that way.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }

            Spacer(minLength: 0)

            HStack(spacing: Space.s) {
                Spacer()
                Button("Cancel") { store.send(.cancelTapped) }
                    .buttonStyle(RCButtonStyle(.secondary))
                Button("Launch") { store.send(.launchTapped) }
                    .buttonStyle(RCButtonStyle(.primary))
                    .disabled(!store.canLaunch)
            }
        }
        .padding(Space.xl)
        .frame(width: 520, height: 420)
    }

    /// Every device is stowed, in transit, or already held by a running
    /// directive. Names both reasons, since they need different fixes.
    private var nothingToFetchNotice: some View {
        RCContentUnavailableView(
            "Nothing to Fetch",
            systemImage: "shippingbox",
            description: Text("Every device is either stowed or in transit — a plate can only collect one that is standing somewhere — or already held by a running directive. Finish or cancel that run, or wait for the device to land.")
        )
    }

    private var devicePicker: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            RCSectionHeader("Device")
            Picker("Device", selection: $store.payloadCode) {
                Text("Choose…").tag(String?.none)
                ForEach(store.eligiblePayloads) { device in
                    Text("\(device.deviceCode) — \(device.location ?? "")")
                        .font(.rcBodyEmphMono)
                        .tag(String?.some(device.deviceCode))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            RCSectionHeader("Destination")
            Picker("Destination", selection: $store.destination) {
                Text("Choose…").tag(String?.none)
                ForEach(store.destinations, id: \.self) { location in
                    Text(location)
                        .font(.rcBodyEmphMono)
                        .tag(String?.some(location))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(store.payloadCode == nil)
        }
    }

    /// Which hull will fly, or why none will. A plate that cannot be resolved
    /// is the one thing that silently makes Launch unavailable, so it is named.
    private var plateSummary: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            RCSectionHeader("Plate")
            if let plate = store.resolvedPlate {
                HStack(spacing: Space.xs) {
                    Text(plate.deviceCode)
                        .font(.rcBodyEmphMono)
                        .foregroundStyle(.rcTextPrimary)
                    if let location = plate.location {
                        Text("at")
                            .font(.rcCaption)
                            .foregroundStyle(.rcTextTertiary)
                        Text(location)
                            .font(.rcBodyEmphMono)
                            .foregroundStyle(.rcTextPrimary)
                    }
                }
            } else if store.payloadCode == nil {
                Text("Pick a device and the nearest free plate is resolved for you.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            } else {
                Text("No free surge plate carries the \"\(FetchRun.fetchTag)\" tag with an attach slot to spare. Tag one from the device inspector, or wait for a running fetch to release one.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }
        }
    }
}
