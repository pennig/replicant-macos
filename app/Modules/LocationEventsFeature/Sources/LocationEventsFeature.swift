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
        /// Every discovered event, active first — and within active, ready-to-complete
        /// first, then higher tier — observed from SQLite. The view groups them into
        /// Active / Completed sections.
        @ObservationStateIgnored
        @FetchAll(LocationEvent.order { ($0.status.asc(), $0.objectivesMet.desc(), $0.tier.desc()) })
        public var events: [LocationEvent]

        /// The selected event's designation (drives the detail pane).
        public var selection: String?
        /// A refresh is in flight (spinner in the toolbar).
        public var isRefreshing: Bool
        /// A completion POST is in flight (disables the Complete button).
        public var isCompleting: Bool
        public var errorMessage: String?

        public init(
            selection: String? = nil,
            isRefreshing: Bool = false,
            isCompleting: Bool = false,
            errorMessage: String? = nil
        ) {
            self.selection = selection
            self.isRefreshing = isRefreshing
            self.isCompleting = isCompleting
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
        /// The screen appeared — re-read the authoritative list if it's stale.
        case task
        /// Explicit refresh (toolbar button).
        case refresh
        case refreshed
        case refreshFailed(String)
        /// Record which fulfilment option the convoy is to satisfy. Local only:
        /// the pick is the brain's input, and the backend is never told.
        case chooseOption(designation: String, name: String)
        /// The pick's write failed — surfaced, never swallowed: the operator
        /// would otherwise see the row simply not take.
        case chooseOptionFailed(String)
        /// Complete the selected (ready) event via an empty POST to its designation.
        case completeButtonTapped
        case completeSucceeded
        case completeFailed(String)
        case dismissError
    }

    @Dependency(\.locationEventsClient) var locationEventsClient
    @Dependency(\.domainFreshness) var domainFreshness
    @Dependency(\.defaultDatabase) var database

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .task:
                // The SSE quest route keeps the table warm, so a pane appear
                // only pays the full `accounts/events` walk when the domain is
                // marked stale or its TTL lapsed (V3.4-B6 — this was a full
                // paged walk per appear). No spinner: the common case is a
                // no-op over an already-live table.
                let domainFreshness = self.domainFreshness
                return .run { _ in await domainFreshness.refreshIfStale(.locationEvents) }

            case .refresh:
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

            case let .chooseOption(designation, name):
                // Bound to a local: referencing the property wrapper inside the
                // @Sendable closure would capture the non-Sendable reducer.
                let database = self.database
                return .run { _ in
                    try await database.write { db in
                        try LocationEvent
                            .where { $0.designation.eq(designation) }
                            .update { $0.chosenOption = #bind(name) }
                            .execute(db)
                    }
                } catch: { error, send in
                    await send(.chooseOptionFailed(error.localizedDescription))
                }

            case let .chooseOptionFailed(message):
                state.errorMessage = message
                return .none

            case .completeButtonTapped:
                guard !state.isCompleting, let event = state.selectedEvent, event.isReady
                else { return .none }
                state.isCompleting = true
                state.errorMessage = nil
                let location = event.location
                let designation = event.designation
                return .run { [locationEventsClient] send in
                    try await locationEventsClient.complete(location, designation)
                    await send(.completeSucceeded)
                } catch: { error, send in
                    let message = (error as? LocationEventError)?.message ?? error.localizedDescription
                    await send(.completeFailed(message))
                }

            case .completeSucceeded:
                state.isCompleting = false
                return .none

            case let .completeFailed(message):
                state.isCompleting = false
                state.errorMessage = message
                return .none

            case .dismissError:
                state.errorMessage = nil
                return .none
            }
        }
    }
}
