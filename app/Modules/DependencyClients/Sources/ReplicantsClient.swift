//
//  ReplicantsClient.swift
//  Replicould — shared dependency clients
//
//  Moved here from ReplicantsFeature: it's a shared domain client (the Sidebar
//  drives it too), so it belongs beside the other clients rather than trapped in
//  a feature — which was one of the feature→feature edges the GameModels split
//  removed. It feeds the `KnownReplicant` table (now in GameModels).
//
//  Talks to the replicant directory and details endpoints via the shared
//  generated client (bearer auth + rate limiting + logging from the middleware
//  stack). `refresh` seeds the account's own roster into the `KnownReplicant`
//  table (so the user's replicants always appear, with current location) and then
//  walks the paged galaxy directory (`GET /v1/replicants`). `loadDetails` fetches
//  one replicant's full record (`GET /v1/replicants/{code}`) on demand for the
//  inspector. All persistence goes through `KnownReplicant`'s merge helpers so
//  scan sightings and prior detail fetches survive. Exposed via
//  `@Dependency(\.replicantsClient)`.
//

import API
import ComposableArchitecture
import Foundation
import GameModels
import SQLiteData
import Utils

public struct ReplicantsClient: Sendable {
    /// Seed the owned roster, then walk the whole directory, upserting into the
    /// `KnownReplicant` table. Returns the number of replicants now known.
    public var refresh: @Sendable () async throws -> Int
    /// Fetch one replicant's full details and merge them into its record.
    public var loadDetails: @Sendable (_ code: String) async throws -> Void
    /// Update one of the account's own replicants' public `plan` (max 500 chars),
    /// then reflect the new value in its local record. Throws `UpdateError` when
    /// the server rejects the change.
    public var updatePlan: @Sendable (_ code: String, _ plan: String) async throws -> Void

    /// A failed replicant update, carrying a user-facing message.
    public struct UpdateError: Error, Equatable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }
}

// MARK: - Live implementation

extension ReplicantsClient: DependencyKey {
    /// Directory page size. The endpoint pages with an integer cursor; a generous
    /// page keeps the whole-galaxy walk to a handful of requests.
    private static let pageSize = 100
    /// A backstop so a misbehaving cursor can't loop forever.
    private static let maxPages = 100

    public static let liveValue = ReplicantsClient(
        refresh: {
            @Dependency(\.gameClient) var gameClient
            @Dependency(\.defaultDatabase) var database
            @Dependency(\.date) var date

            // Seed the owned roster first so the account's own replicants show
            // immediately with their current location, even if the directory walk
            // lists them later (or not at all).
            let roster = try await database.read { db in try Replicant.fetchAll(db) }
            try await database.write { db in
                try KnownReplicant.upsert(roster: roster, into: db, now: date.now)
            }

            // Resolve the client once and reuse it across the whole paged walk.
            let client = gameClient()
            var cursor: Int? = nil
            var pages = 0
            repeat {
                let body = try await client.getV1Replicants(
                    query: .init(cursor: cursor, limit: pageSize)
                ).ok.body.json
                let items = body.replicants ?? []
                try await database.write { db in
                    try KnownReplicant.upsert(directory: items, into: db, now: date.now)
                }
                cursor = body.nextCursor
                pages += 1
            } while cursor != nil && pages < maxPages

            return try await database.read { db in try KnownReplicant.fetchCount(db) }
        },
        loadDetails: { code in
            @Dependency(\.gameClient) var gameClient
            @Dependency(\.defaultDatabase) var database
            @Dependency(\.date) var date

            let schema = try await gameClient().getV1ReplicantsReplicantCode(
                path: .init(replicantCode: code)
            ).ok.body.json
            let blob = jsonValue(from: schema)
            try await database.write { db in
                try KnownReplicant.upsert(detailsFor: code, schema: schema, blob: blob, into: db, now: date.now)
            }
        },
        updatePlan: { code, plan in
            @Dependency(\.gameClient) var gameClient
            @Dependency(\.defaultDatabase) var database
            @Dependency(\.date) var date

            let output = try await gameClient().patchV1ReplicantsReplicantCode(
                path: .init(replicantCode: code),
                body: .json(.init(plan: plan))
            )
            switch output {
            case .ok:
                break
            case let .badRequest(response):
                throw UpdateError((try? response.body.json.error) ?? "Couldn't update the plan.")
            default:
                // 404 (not our replicant) / 422 (validation) / anything unexpected.
                throw UpdateError("Couldn't update the plan.")
            }
            // Reflect the accepted value locally so the sidebar updates at once,
            // without a second details round-trip.
            try await database.write { db in
                try KnownReplicant.upsert(planFor: code, plan: plan, into: db, now: date.now)
            }
        }
    )

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Re-encode a generated details payload into a `JSONValue` blob for
    /// `KnownReplicant.detail`, preserving the schemaless tail (stowed devices,
    /// cargo, lore) the typed columns don't capture.
    private static func jsonValue(from value: some Encodable) -> JSONValue {
        guard
            let data = try? jsonEncoder.encode(value),
            let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return .object([:]) }
        return json
    }
}

// MARK: - Test / preview implementation

extension ReplicantsClient: TestDependencyKey {
    /// Unimplemented by default so a test that reaches the network without
    /// stubbing it fails loudly.
    public static let testValue = ReplicantsClient(
        refresh: unimplemented("ReplicantsClient.refresh", placeholder: 0),
        loadDetails: unimplemented("ReplicantsClient.loadDetails"),
        updatePlan: unimplemented("ReplicantsClient.updatePlan")
    )
}

extension DependencyValues {
    public var replicantsClient: ReplicantsClient {
        get { self[ReplicantsClient.self] }
        set { self[ReplicantsClient.self] = newValue }
    }
}
