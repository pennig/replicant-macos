//
//  CivilisationsFeature.swift
//  Replicould — Civilisations feature
//
//  A read-only reference catalog of the galaxy's civilisations (backend
//  "species"), blended with the account's reputation standings. The catalog is
//  observed straight from the `Civilisation` SQLite table (via `@FetchAll` in
//  state), so search filters reactively through SQL; the reducer owns only
//  intent — the cold load (first run / explicit refresh) fetching species +
//  reputation, and the cheap reputation-only refresh on every later visit
//  (standings move with gameplay; the roster itself is near-static).
//

import ComposableArchitecture
import Foundation
import GameModels
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Civilisations")

@Reducer
public struct CivilisationsFeature {
    @ObservableState
    public struct State: Equatable {
        /// The catalog, observed straight from SQLite — a dynamic query the
        /// reducer reloads from `searchText` (filtering in SQL). Seeded with the
        /// full ordered set so the first render is correct with no async step,
        /// and `@ObservationStateIgnored` because `@FetchAll` drives its own
        /// observation.
        @ObservationStateIgnored
        @FetchAll(Civilisation.order { $0.name }, animation: .default) public var civilisations: [Civilisation]

        /// The inspected civilisation (drives the detail pane).
        public var selectedSpeciesKey: String?
        /// The list's search query. Held in state (so it survives tab switches)
        /// and drives the SQL query via `.binding(\.searchText)`.
        public var searchText: String
        public var isLoading: Bool
        /// Cold-load failure, shown as a banner over the list.
        public var errorMessage: String?

        public init(selectedSpeciesKey: String? = nil) {
            self.selectedSpeciesKey = selectedSpeciesKey
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
        case refreshReputation
        case reputationRefreshed
        case dismissError
    }

    public init() {}

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.civilisationsClient) var civilisationsClient

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding(\.searchText):
                // Reload the SQL query in place whenever the search text changes.
                // `.load` keeps the prior rows until the new results arrive, so
                // the list updates atomically with no empty flash.
                return .run { [reader = state.$civilisations, search = state.searchText] _ in
                    try await reader.load(
                        Civilisation
                            .where {
                                if !search.isEmpty {
                                    $0.name.like("%\(search)%")
                                    || $0.trait.like("%\(search)%")
                                    || $0.government.like("%\(search)%")
                                    || $0.techAffinity.like("%\(search)%")
                                }
                            }
                            .order { $0.name },
                        animation: .default
                    )
                } catch: { _, _ in }

            case .binding:
                return .none

            case .task:
                // First visit: cold-load the whole catalog. Every later visit:
                // refresh only the reputation standings — one cheap read that
                // tracks gameplay, while the near-static roster stays cached.
                let database = self.database
                return .run { send in
                    let count = try await database.read { db in try Civilisation.fetchCount(db) }
                    await send(count == 0 ? .load : .refreshReputation)
                } catch: { _, _ in }

            case .refreshButtonTapped:
                return .send(.load)

            case .load:
                guard !state.isLoading else { return .none }
                state.isLoading = true
                state.errorMessage = nil
                let civilisationsClient = self.civilisationsClient
                let database = self.database
                logger.info("cold-load starting")
                return .run { send in
                    let species = try await civilisationsClient.fetchSpecies()
                    let reputations = try await civilisationsClient.fetchReputation()
                    try await database.write { db in
                        try Civilisation.upsert { species }.execute(db)
                        try Self.apply(reputations, in: db)
                    }
                    logger.info("cold-load upserted \(species.count) civilisations, \(reputations.count) standings")
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

            case .refreshReputation:
                // Quiet by design: it runs on every visit over a still-valid
                // cached catalog, so a failure logs instead of raising a banner.
                let civilisationsClient = self.civilisationsClient
                let database = self.database
                return .run { send in
                    let reputations = try await civilisationsClient.fetchReputation()
                    try await database.write { db in
                        try Self.apply(reputations, in: db)
                    }
                    await send(.reputationRefreshed)
                } catch: { error, _ in
                    logger.error("reputation refresh failed: \(error.localizedDescription, privacy: .public)")
                }

            case .reputationRefreshed:
                return .none

            case .dismissError:
                state.errorMessage = nil
                return .none
            }
        }
    }

    /// Replaces every stored standing with the payload's, atomically within the
    /// caller's transaction: species absent from the payload return to unmet
    /// (their standing is stale by definition), and an entry whose key matches
    /// no species row is a harmless no-op.
    private static func apply(_ reputations: [SpeciesReputation], in db: Database) throws {
        try Civilisation.update { $0.totalReputation = #bind(Int?.none) }.execute(db)
        for entry in reputations {
            try Civilisation
                .where { $0.speciesKey.eq(entry.speciesKey) }
                .update { $0.totalReputation = #bind(entry.totalReputation) }
                .execute(db)
        }
    }
}
