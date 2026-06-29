//
//  BlueprintsFeature.swift
//  Replicould — Blueprints feature
//
//  A read-only reference catalog of the account's unlocked device blueprints.
//  The catalog itself is observed straight from the `Blueprint` SQLite table
//  (via `@FetchAll` in the views), so search filters reactively through SQL; the
//  reducer owns only intent — the cold load (first run / explicit refresh),
//  which fetches the catalog and upserts it into the table.
//

import ComposableArchitecture
import Foundation
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould.feature", category: "Blueprints")

@Reducer
public struct BlueprintsFeature {
    @ObservableState
    public struct State: Equatable {
        /// The inspected blueprint (drives the detail pane).
        public var selectedDeviceType: String?
        /// The list's search query; the actual filtering is a `@FetchAll` query
        /// in the view, not stored here.
        public var searchText: String
        public var isLoading: Bool
        /// Cold-load failure, shown as a banner over the list.
        public var errorMessage: String?

        public init(selectedDeviceType: String? = nil) {
            self.selectedDeviceType = selectedDeviceType
            self.searchText = ""
            self.isLoading = false
            self.errorMessage = nil
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case task
        case refreshButtonTapped
        case load
        case loadSucceeded
        case loadFailed(String)
        case dismissError
    }

    public init() {}

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.blueprintsClient) var blueprintsClient

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .task:
                // First run only: cold-load if the catalog is empty. The unlocked
                // set rarely changes, so navigating here later spends no reads —
                // the user can still force a refresh.
                let database = self.database
                return .run { send in
                    let count = try await database.read { db in try Blueprint.fetchCount(db) }
                    if count == 0 { await send(.load) }
                } catch: { _, _ in }

            case .refreshButtonTapped:
                return .send(.load)

            case .load:
                guard !state.isLoading else { return .none }
                state.isLoading = true
                state.errorMessage = nil
                let blueprintsClient = self.blueprintsClient
                let database = self.database
                logger.info("cold-load starting")
                return .run { send in
                    let blueprints = try await blueprintsClient.fetchAll()
                    try await database.write { db in
                        try Blueprint.upsert { blueprints }.execute(db)
                    }
                    logger.info("cold-load upserted \(blueprints.count) blueprints")
                    await send(.loadSucceeded)
                } catch: { error, send in
                    logger.error("cold-load failed: \(error.localizedDescription, privacy: .public)")
                    await send(.loadFailed(error.localizedDescription))
                }

            case .loadSucceeded:
                state.isLoading = false
                return .none

            case let .loadFailed(message):
                state.isLoading = false
                state.errorMessage = message
                return .none

            case .dismissError:
                state.errorMessage = nil
                return .none
            }
        }
    }
}
