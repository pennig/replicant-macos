//
//  BlueprintsClient.swift
//  Replicould — Blueprints feature
//
//  The dependency that talks to the blueprints endpoint. It fetches the
//  account's unlocked catalog (`GET /v1/blueprints`) via the shared generated
//  `ReplicantSpace` client, so the call inherits bearer auth, rate limiting, and
//  logging from its middleware stack. The single response carries the whole
//  catalog (no paging). Generated payloads are mapped to value-typed `Blueprint`
//  records. Exposed via `@Dependency(\.blueprintsClient)`.
//

import API
import ComposableArchitecture
import Foundation
import GameModels
import GameServices

public struct BlueprintsClient: Sendable {
    /// Fetch the account's full unlocked blueprint catalog.
    public var fetchAll: @Sendable () async throws -> [Blueprint]
}

// MARK: - Live implementation

extension BlueprintsClient: DependencyKey {
    public static let liveValue = BlueprintsClient(
        fetchAll: {
            @Dependency(\.gameClient) var gameClient
            let body = try await gameClient().getV1Blueprints().ok.body.json
            return (body.blueprints ?? []).map(Blueprint.init(schema:))
        }
    )
}

// MARK: - Test / preview implementation

extension BlueprintsClient: TestDependencyKey {
    /// Unimplemented by default so a test that reaches the network without
    /// stubbing it fails loudly.
    public static let testValue = BlueprintsClient(
        fetchAll: unimplemented("BlueprintsClient.fetchAll", placeholder: [])
    )

    /// Previews get the sample catalog so the UI renders with content.
    public static let previewValue = BlueprintsClient(
        fetchAll: { Blueprint.previewCatalog }
    )
}

extension DependencyValues {
    public var blueprintsClient: BlueprintsClient {
        get { self[BlueprintsClient.self] }
        set { self[BlueprintsClient.self] = newValue }
    }
}
