//
//  EventLogFeature.swift
//  Replicould — EventLogFeature
//
//  A power-user diagnostic modelled on Raw API Access: a standalone window that
//  shows every Server-Sent Event the app ingested, persisted to SQLite so it
//  survives relaunches. Each event's full envelope renders in the shared JSON tree
//  view; events that no feature-specific route consumed are flagged "unhandled" and
//  can be isolated with a filter. A Clear action empties the ledger.
//
//  The event rows are *written* elsewhere (`EventLogClient`, from the GameSync
//  dispatch choke point); this feature only observes the `EventLog` table via
//  `@FetchAll` and offers the filter + clear affordances.
//

import ComposableArchitecture
import Foundation
import GameModels
import SQLiteData

@Reducer
public struct EventLogFeature {
    @ObservableState
    public struct State: Equatable {
        /// Observed live from SQLite, newest first. Reloaded in place when the
        /// "unhandled only" filter toggles (see `.binding(\.showUnhandledOnly)`).
        @ObservationStateIgnored
        @FetchAll(EventLog.order { $0.receivedAt.desc() })
        public var events: [EventLog]

        /// When on, `events` is narrowed to unhandled rows via a reloaded query.
        public var showUnhandledOnly: Bool
        /// The selected row's id (drives the detail pane).
        public var selection: EventLog.ID?
        /// Drives the destructive "clear all" confirmation dialog.
        public var isConfirmingClear: Bool

        public init(
            showUnhandledOnly: Bool = false,
            selection: EventLog.ID? = nil,
            isConfirmingClear: Bool = false
        ) {
            self.showUnhandledOnly = showUnhandledOnly
            self.selection = selection
            self.isConfirmingClear = isConfirmingClear
        }

        /// Resolve the selected row from the observed list.
        public var selectedEvent: EventLog? {
            guard let selection else { return nil }
            return events.first { $0.id == selection }
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case clearButtonTapped
        case clearConfirmed
    }

    public init() {}

    @Dependency(\.defaultDatabase) var database

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding(\.showUnhandledOnly):
                // Reload the SQL query in place so filtering happens in the database,
                // not in memory. `.load` keeps the prior rows until the new results
                // arrive, so the list swaps atomically with no empty flash.
                return .run { [reader = state.$events, unhandledOnly = state.showUnhandledOnly] _ in
                    try await reader.load(
                        EventLog
                            .where {
                                if unhandledOnly { !$0.isHandled }
                            }
                            .order { $0.receivedAt.desc() },
                        animation: .default
                    )
                } catch: { _, _ in }

            case .binding:
                return .none

            case .clearButtonTapped:
                state.isConfirmingClear = true
                return .none

            case .clearConfirmed:
                state.isConfirmingClear = false
                state.selection = nil
                return .run { [database] _ in
                    try await database.write { db in
                        try EventLog.delete().execute(db)
                    }
                }
            }
        }
    }
}
