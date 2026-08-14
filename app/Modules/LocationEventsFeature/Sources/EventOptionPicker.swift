//
//  EventOptionPicker.swift
//  LocationEventsFeature
//
//  The operator's pick between a multi-option event's fulfilment criteria.
//

import ComposableArchitecture
import GameModels
import SwiftUI
import UI

/// The detail-pane control for an event offering more than one way to be
/// satisfied. Until a pick is recorded the convoy skips the event entirely.
public struct EventOptionPicker: View {
    let store: StoreOf<LocationEventsFeature>
    let event: LocationEvent
    let options: [LocationEventDetail.Option]

    public init(
        store: StoreOf<LocationEventsFeature>,
        event: LocationEvent,
        options: [LocationEventDetail.Option]
    ) {
        self.store = store
        self.event = event
        self.options = options
    }

    public var body: some View {
        RCReadoutCard("Fulfilment Option") {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(prompt)
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(options) { option in
                    EventOptionRow(
                        option: option,
                        isChosen: option.name == event.chosenOption
                    ) {
                        store.send(.chooseOption(designation: event.designation, name: option.name))
                    }
                }
                Text(event.designation)
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextTertiary)
            }
        }
    }

    private var prompt: String {
        event.chosenOption == nil
            ? "No option chosen — the convoy skips this event until one is."
            : "The convoy delivers the chosen option."
    }
}
