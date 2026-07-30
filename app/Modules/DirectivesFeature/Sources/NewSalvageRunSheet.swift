//
//  NewSalvageRunSheet.swift
//  Replicould — Directives feature
//
//  The launcher sheet. Modelled on `NewDirectiveSheet`, but with exactly one
//  input — a Salvage Run has no fixed-queue variant, no mode picker, and no
//  hand-built target queue, so there is nothing else to ask for.
//
//  Staging a vessel is the player's job, and the run resolves its whole fleet
//  BY TAG (design spec §4.2) — so a vessel this dialog considers "staged"
//  (controller + adopted drone aboard) can still be invisible to the engine
//  if nothing carries `auto:salvage`. The empty state below says so, since
//  there is no tagging UI here to point at directly.
//

import ComposableArchitecture
import DirectiveEngine
import GameModels
import SwiftUI
import UI

public struct NewSalvageRunSheet: View {
    @Bindable var store: StoreOf<NewSalvageRunFeature>

    public init(store: StoreOf<NewSalvageRunFeature>) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text("New Salvage Run")
                .font(.rcTitle)
                .foregroundStyle(.rcTextPrimary)

            if store.eligibleVessels.isEmpty {
                unstagedNotice
            } else {
                vesselPicker
                Text("Mines salvage system to system, planting FTL relays as it goes, until you cancel it.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }

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
        .frame(width: 480, height: 320)
    }

    /// Staging is the player's job, so the empty state says exactly what to
    /// do — including the tag every device in the fleet needs, since there is
    /// no tagging UI in this dialog to point at instead (it already exists on
    /// the device inspector).
    private var unstagedNotice: some View {
        RCContentUnavailableView(
            "No Vessel Ready",
            systemImage: "shippingbox",
            description: Text("Stow an AMI Mining Controller and at least one adopted Mining Drone aboard a vessel. Then, from the device inspector, tag the vessel, the controller, its adopted drones, and any FTL relays aboard as \"auto:salvage\" — the run resolves its fleet by that tag, and a device without it is invisible to the run.")
        )
    }

    private var vesselPicker: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            RCSectionHeader("Vessel")
            Picker("Vessel", selection: $store.vesselCode) {
                Text("Choose…").tag(String?.none)
                ForEach(store.eligibleVessels) { vessel in
                    Text(vessel.deviceCode).tag(String?.some(vessel.deviceCode))
                }
            }
            .labelsHidden()
            .font(.rcMonoSmall)
            if let centre = store.anchorSystem {
                HStack(spacing: Space.xs) {
                    Text("Centred on")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                    Text(centre)
                        .font(.rcBodyEmphMono)
                        .foregroundStyle(.rcTextPrimary)
                }
            }
        }
    }
}
