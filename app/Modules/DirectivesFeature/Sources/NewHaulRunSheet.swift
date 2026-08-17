//
//  NewHaulRunSheet.swift
//  Replicould — Directives feature
//
//  The Haul Run launcher sheet. Unlike every sibling launcher it has NO input:
//  the run drives every controller tagged `auto:haul` (design spec §4), so there
//  is nothing to pick and the sheet's whole job is to show which fleet the tag
//  currently resolves to before you commit.
//
//  Two empty states, deliberately distinct. A `ferry`-capable controller that is
//  merely untagged is the common near-miss — the operator has the hardware and
//  is one tagging step away — so it is named specifically rather than folded into
//  the generic "nothing to haul with" message. There is no tagging UI here; the
//  device inspector already owns that, so both states say what to do in words.
//

import ComposableArchitecture
import DirectiveEngine
import GameModels
import SwiftUI
import UI

public struct NewHaulRunSheet: View {
    @Bindable var store: StoreOf<NewHaulRunFeature>

    public init(store: StoreOf<NewHaulRunFeature>) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text("New Haul Run")
                .font(.rcTitle)
                .foregroundStyle(.rcTextPrimary)

            if store.readyControllers.isEmpty {
                if let untagged = store.untaggedController {
                    untaggedNotice(untagged)
                } else {
                    noControllerNotice
                }
            } else {
                fleetSummary
                Text("Keeps every tagged controller pointed at the richest reachable stockpile, until you cancel it.")
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

    /// No `ferry`-capable controller exists at all. Names the hardware needed,
    /// and the one thing that is easy to get wrong — the adopted transports need
    /// no tags of their own, because a controller reports them inline.
    private var noControllerNotice: some View {
        RCContentUnavailableView(
            "No Transport Controller",
            systemImage: "shippingbox",
            description: Text("A Haul Run drives AMI Transport Controllers. Print or adopt one, then tag it \"\(HaulRun.defaultFleetTag.string)\" from the device inspector — the run resolves its fleet by that tag. The transports the controller has adopted need no tags of their own.")
        )
    }

    /// A controller that can ferry but is not tagged. Names it (in a mono token,
    /// per house rule — a device code is a designation) since this is the
    /// actionable case an operator hits right after printing one.
    private func untaggedNotice(_ controller: Device) -> some View {
        RCContentUnavailableView {
            ContentUnavailableView {
                Label("Controller Untagged", systemImage: "tag")
            } description: {
                Text("\(Text(controller.deviceCode).font(.rcBodyEmphMono)) can run a ferry directive but is missing the \"\(HaulRun.defaultFleetTag.string)\" tag. Tag it from the device inspector, then retry. Its adopted transports need no tags of their own.")
            }
        }
    }

    /// What the tag currently resolves to, and where it all ends up. Both device
    /// codes and the destination are designations, so both take a mono token.
    private var fleetSummary: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            RCSectionHeader("Fleet")
            ForEach(store.readyControllers) { controller in
                Text(controller.deviceCode)
                    .font(.rcBodyEmphMono)
                    .foregroundStyle(.rcTextPrimary)
            }
            HStack(spacing: Space.xs) {
                Text("Delivering to")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
                Text(HaulRun.deliveryLocation)
                    .font(.rcBodyEmphMono)
                    .foregroundStyle(.rcTextPrimary)
            }
        }
    }
}
