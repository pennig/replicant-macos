//
//  LocationEventsFeature.swift
//  LocationEventsFeature
//
//  The Location Events ("Missions") screen: a galaxy-wide quest log. The account's
//  discovered events are observed straight from the `LocationEvent` table
//  (@FetchAll), so the list is live and survives relaunch; a pull-to-refresh (and
//  the appear task) re-reads the authoritative `accounts/events` list through
//  `LocationEventsClient`, which upserts into that table. The detail pane decodes
//  the full quest — criteria progress and rewards — from the selected row.
//

import ComposableArchitecture
import Foundation
import GameModels
import GameServices
import SQLiteData

@Reducer
public struct LocationEventsFeature {
    @ObservableState
    public struct State: Equatable {
        /// Every discovered event, active first (then higher tier first), observed
        /// from SQLite. The view groups them into Active / Completed sections.
        @ObservationStateIgnored
        @FetchAll(LocationEvent.order { ($0.status.asc(), $0.tier.desc()) })
        public var events: [LocationEvent]

        /// The selected event's designation (drives the detail pane).
        public var selection: String?
        /// A refresh is in flight (spinner in the toolbar).
        public var isRefreshing: Bool
        public var errorMessage: String?

        public init(selection: String? = nil, isRefreshing: Bool = false, errorMessage: String? = nil) {
            self.selection = selection
            self.isRefreshing = isRefreshing
            self.errorMessage = errorMessage
        }

        /// The currently-selected event, resolved from the observed list.
        public var selectedEvent: LocationEvent? {
            guard let selection else { return nil }
            return events.first { $0.designation == selection }
        }

        /// Active events, in observed order (active-first, tier-desc).
        public var active: [LocationEvent] { events.filter(\.isActive) }
        /// Everything else (completed / expired), in observed order.
        public var inactive: [LocationEvent] { events.filter { !$0.isActive } }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        /// The screen appeared — re-read the authoritative list.
        case task
        /// Explicit refresh (toolbar button).
        case refresh
        case refreshed
        case refreshFailed(String)
        case dismissError
    }

    @Dependency(\.locationEventsClient) var locationEventsClient

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .task, .refresh:
                guard !state.isRefreshing else { return .none }
                state.isRefreshing = true
                state.errorMessage = nil
                return .run { [locationEventsClient] send in
                    _ = try await locationEventsClient.refresh()
                    await send(.refreshed)
                } catch: { error, send in
                    await send(.refreshFailed(error.localizedDescription))
                }

            case .refreshed:
                state.isRefreshing = false
                return .none

            case let .refreshFailed(message):
                state.isRefreshing = false
                state.errorMessage = message
                return .none

            case .dismissError:
                state.errorMessage = nil
                return .none
            }
        }
    }
}
