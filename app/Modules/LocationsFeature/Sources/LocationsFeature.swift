//
//  LocationsFeature.swift
//  LocationsFeature
//
//  The stellar-locations catalog reducer. The list is driven entirely by
//  observed SQLite queries in the views (census `Star` + hydrated `StarSystem`
//  blobs + `LocationFootprint`), so this reducer holds only intent: the current
//  selection, sort/filter, and the on-demand hydration of a system's detail when
//  it's selected.
//
//  Census population (the ~5,770-system survey) is owned by the Stars view; this
//  feature reads that shared table. Selecting an explored system fetches its
//  detail via `LocationsClient` and persists the `StarSystem` blob; selecting a
//  body additionally fetches and merges that body's scanned detail. Unexplored
//  systems return `.notExplored` and are simply left as census leaves.
//

import ComposableArchitecture
import Foundation
import SQLiteData
import UniverseModels

@Reducer
public struct LocationsFeature {
    @ObservableState
    public struct State: Equatable {
        /// Selected node designation (system or body).
        public var selection: String?
        public var sort: LocationSort
        public var filter: LocationFilter
        public var searchText: String
        /// Systems currently being hydrated — guards duplicate fetches.
        public var hydrating: Set<String>
        public var errorMessage: String?

        public init(
            selection: String? = nil,
            sort: LocationSort = .distance,
            filter: LocationFilter = .all
        ) {
            self.selection = selection
            self.sort = sort
            self.filter = filter
            self.searchText = ""
            self.hydrating = []
            self.errorMessage = nil
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case task
        case hydrate(system: String, body: String?)
        case hydrated(String)
        case hydrateFailed(system: String, message: String)
        case loadFailed(String)
        case dismissError
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.locationsClient) var locationsClient
    @Dependency(\.date.now) var now

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding(\.selection):
                guard let id = state.selection else { return .none }
                let system = String(id.split(separator: "-").first ?? "")
                guard !system.isEmpty, !state.hydrating.contains(system) else { return .none }
                state.hydrating.insert(system)
                return .send(.hydrate(system: system, body: id == system ? nil : id))

            case .binding:
                return .none

            case .task:
                // Refresh the footprint (holdings) overlay in the background.
                let database = self.database
                let locationsClient = self.locationsClient
                let now = self.now
                return .run { _ in
                    let footprint = try await locationsClient.footprint()
                    let rows = footprint.map { LocationFootprint(location: $0.key, counts: $0.value, fetchedAt: now) }
                    try await database.write { db in
                        try LocationFootprint.upsert { rows }.execute(db)
                    }
                } catch: { error, send in
                    await send(.loadFailed(error.localizedDescription))
                }

            case let .hydrate(system, body):
                let database = self.database
                let locationsClient = self.locationsClient
                let now = self.now
                return .run { send in
                    // Star-level detail: roster, belts, counts, events.
                    let starSystem = try await locationsClient.system(system)
                    var assembled = starSystem
                    // If a specific body was selected, fetch and merge its scan.
                    if let body, body != system {
                        if let detail = try? await locationsClient.body(body) {
                            assembled = assembled.applying(detail)
                        }
                    }
                    let row = try SystemDetail(system: assembled, hydratedAt: now)
                    try await database.write { db in
                        try SystemDetail.upsert { row }.execute(db)
                    }
                    await send(.hydrated(system))
                } catch: { error, send in
                    // Unexplored systems 403 — expected, not an error to surface.
                    if let locErr = error as? LocationsError, locErr == .notExplored {
                        await send(.hydrated(system))
                    } else {
                        await send(.hydrateFailed(system: system, message: error.localizedDescription))
                    }
                }

            case let .hydrated(id):
                state.hydrating.remove(id)
                return .none

            case let .hydrateFailed(system, message):
                state.hydrating.remove(system)
                state.errorMessage = message
                return .none

            case let .loadFailed(message):
                state.errorMessage = message
                return .none

            case .dismissError:
                state.errorMessage = nil
                return .none
            }
        }
    }
}
