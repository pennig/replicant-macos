//
//  CivilisationsClient.swift
//  Replicould — Civilisations feature
//
//  The dependency that talks to the species endpoints. It fetches the full
//  species roster (`GET /v1/species`) and the account's reputation standings
//  (`GET /v1/accounts/reputation`) via the shared generated `ReplicantSpace`
//  client, so both calls inherit bearer auth, rate limiting, and logging from
//  its middleware stack. Each response carries its whole set (no paging).
//  Generated payloads are mapped to value-typed `Civilisation` /
//  `SpeciesReputation` records. Exposed via `@Dependency(\.civilisationsClient)`.
//

import API
import ComposableArchitecture
import Foundation
import GameModels
import GameSession

public struct CivilisationsClient: Sendable {
    /// Fetch the full species roster (reputation nil on every record).
    public var fetchSpecies: @Sendable () async throws -> [Civilisation]
    /// Fetch the account's reputation standings — met species only.
    public var fetchReputation: @Sendable () async throws -> [SpeciesReputation]
}

// MARK: - Live implementation

extension CivilisationsClient: DependencyKey {
    public static let liveValue = CivilisationsClient(
        fetchSpecies: {
            @Dependency(\.gameClient) var gameClient
            let body = try await gameClient().getV1Species().ok.body.json
            return (body.species ?? []).map(Civilisation.init(schema:))
        },
        fetchReputation: {
            @Dependency(\.gameClient) var gameClient
            let body = try await gameClient().getV1AccountsReputation().ok.body.json
            return (body.reputation ?? []).map(SpeciesReputation.init(schema:))
        }
    )
}

// MARK: - Test / preview implementation

extension CivilisationsClient: TestDependencyKey {
    /// Unimplemented by default so a test that reaches the network without
    /// stubbing it fails loudly.
    public static let testValue = CivilisationsClient(
        fetchSpecies: unimplemented("CivilisationsClient.fetchSpecies", placeholder: []),
        fetchReputation: unimplemented("CivilisationsClient.fetchReputation", placeholder: [])
    )

    /// Previews get the sample roster and standings so the UI renders with
    /// content.
    public static let previewValue = CivilisationsClient(
        fetchSpecies: { Civilisation.previewCatalog },
        fetchReputation: { Civilisation.previewReputations }
    )
}

extension DependencyValues {
    public var civilisationsClient: CivilisationsClient {
        get { self[CivilisationsClient.self] }
        set { self[CivilisationsClient.self] = newValue }
    }
}
