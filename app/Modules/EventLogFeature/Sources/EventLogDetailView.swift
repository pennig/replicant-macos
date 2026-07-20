//
//  EventLogDetailView.swift
//  Replicould — EventLogFeature
//
//  The detail pane: a metadata header for the selected event followed by its full
//  envelope rendered in the shared `JSONTreeView` (the same tree the Raw API
//  console uses). Empty when nothing is selected.
//

import ComposableArchitecture
import GameModels
import SwiftUI
import UI

struct EventLogDetailView: View {
    let store: StoreOf<EventLogFeature>

    var body: some View {
        if let event = store.selectedEvent {
            VStack(alignment: .leading, spacing: 0) {
                header(event)
                    .padding(Space.m)
                Divider()
                JSONTreeView(node: JSONTreeNode(value: event.envelopeJSON))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            RCContentUnavailableView(
                "No Event Selected",
                systemImage: "dot.radiowaves.left.and.right",
                description: Text("Select an event to inspect its full JSON payload.")
            )
        }
    }

    @ViewBuilder
    private func header(_ event: EventLog) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(event.event)
                    .font(.rcTitleMono)
                    .foregroundStyle(.rcTextPrimary)
                    .textSelection(.enabled)
                Spacer(minLength: Space.s)
                if !event.isHandled {
                    Text("UNHANDLED")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcWarning)
                        .padding(.vertical, 3)
                        .padding(.horizontal, Space.s)
                        .background(
                            .rcWarning.opacity(0.14),
                            in: Capsule()
                        )
                }
            }

            // Loosely-wrapping metadata chips; codes in mono per the design rules.
            HStack(spacing: Space.m) {
                metaChip("Category", event.category)
                metaChip("Provenance", event.provenance)
                metaChip("Received", event.receivedAt.formatted(.dateTime.hour().minute().second()))
            }

            let codes = scopeChips(event)
            if !codes.isEmpty {
                HStack(spacing: Space.m) {
                    ForEach(codes, id: \.label) { chip in
                        metaChip(chip.label, chip.value, mono: true)
                    }
                }
            }

            if let routes = event.matchedRoutes {
                metaChip("Handled by", routes)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A labelled metadata value. Codes/designations use a mono token.
    @ViewBuilder
    private func metaChip(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.rcMicro)
                .kerning(0.6)
                .foregroundStyle(.rcTextTertiary)
            Text(value)
                .font(mono ? .rcMonoSmall : .rcCaption)
                .foregroundStyle(.rcTextSecondary)
                .textSelection(.enabled)
        }
    }

    /// The scope codes present on the event, each as a labelled mono chip.
    private func scopeChips(_ event: EventLog) -> [(label: String, value: String)] {
        var chips: [(label: String, value: String)] = []
        if let code = event.replicantCode { chips.append(("Replicant", code)) }
        if let code = event.deviceCode { chips.append(("Device", code)) }
        if let type = event.deviceType { chips.append(("Device Type", type)) }
        if let star = event.star { chips.append(("Star", star)) }
        if let location = event.location { chips.append(("Location", location)) }
        return chips
    }
}
