//
//  NewSalvageRunSheet.swift
//  Replicould — Directives feature
//
//  The launcher sheet. Modelled on `NewDirectiveSheet`, but with exactly one
//  input — a Salvage Run has no fixed-queue variant, no mode picker, and no
//  hand-built target queue, so there is nothing else to ask for.
//
//  Staging a vessel is the player's job, and the run resolves its whole fleet
//  BY TAG (design spec §4.2) — so a vessel that is physically "staged"
//  (controller + adopted drone aboard) can still be invisible to the engine
//  if nothing carries `auto:salvage`. `Device.tags` is a real, locally-synced
//  column, so the picker tells the two states apart rather than guessing:
//  only a vessel that is BOTH staged and tagged (`NewSalvageRunFeature.State
//  .readyVessels`) is offered, and a staged-but-untagged one gets a specific,
//  named empty state instead of the generic "nothing staged" one. There is no
//  tagging UI in this sheet — the device inspector already owns that — so
//  both empty states say what to do in words.
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

            if store.readyVessels.isEmpty {
                if let untagged = store.untaggedStagedVessel {
                    untaggedNotice(untagged)
                } else {
                    unstagedNotice
                }
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
    /// the device inspector). Only reached when NO vessel in the fleet is even
    /// physically staged; see `untaggedNotice` for the staged-but-untagged
    /// case, which is a different, more specific message.
    private var unstagedNotice: some View {
        RCContentUnavailableView(
            "No Vessel Ready",
            systemImage: "shippingbox",
            description: Text("Stow an AMI Mining Controller and at least one adopted Mining Drone aboard a vessel. Then, from the device inspector, tag the vessel, the controller, its adopted drones, and any FTL relays aboard as \"\(SalvageRun.defaultFleetTag.string)\" — the run resolves its fleet by that tag, and a device without it is invisible to the run.")
        )
    }

    /// A vessel IS physically staged (controller + adopted drone aboard) but
    /// its fleet is missing `auto:salvage` somewhere, so it cannot be
    /// launched — the user has done the hard part and is one tagging step
    /// away. Names the vessel (in a mono token, per house rule — a device
    /// code is a designation) rather than repeating the generic "some vessel
    /// needs a tag" message, since a staged vessel is the actionable, common
    /// case a user hits right after staging one.
    private func untaggedNotice(_ vessel: Device) -> some View {
        RCContentUnavailableView {
            ContentUnavailableView {
                Label("Staged But Untagged", systemImage: "tag")
            } description: {
                Text("\(Text(vessel.deviceCode).font(.rcBodyEmphMono)) is staged — its mining controller and an adopted drone are aboard — but its fleet is missing the \"\(SalvageRun.defaultFleetTag.string)\" tag. From the device inspector, tag the vessel, its controller, its adopted drones, and any FTL relays aboard, then retry.")
            }
        }
    }

    private var vesselPicker: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            RCSectionHeader("Vessel")
            Picker("Vessel", selection: $store.vesselCode) {
                Text("Choose…").tag(String?.none)
                ForEach(store.readyVessels) { vessel in
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
