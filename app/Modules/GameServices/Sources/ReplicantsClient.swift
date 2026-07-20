//
//  ReplicantsClient.swift
//  Replicould — GameServices (shared clients + command engine)
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
    /// the server rejects the change. Kept as the Sidebar's fast inline plan edit
    /// (optimistic local reflect, no re-fetch); the full inspector editor uses
    /// `updateProfile`.
    public var updatePlan: @Sendable (_ code: String, _ plan: String) async throws -> Void

    /// Update the editable profile fields of one of the account's own replicants
    /// (`PATCH /v1/replicants/{code}`). On success, re-fetches the full record so
    /// the inspector shows canonical, server-normalized values, and reflects a name
    /// change into the local roster (so the sidebar updates without an account
    /// round-trip). Throws `UpdateError` when the server rejects the change.
    public var updateProfile: @Sendable (_ code: String, _ update: ReplicantProfileUpdate) async throws -> Void

    /// Perform a replication: issue the `replicate` device command on the source
    /// `replicant_matrix`, spawning a new replicant in the target
    /// `empty_replicant_matrix` (`POST /v1/devices/{matrix_code}`). Never throws —
    /// the result is reported as a `ReplicateOutcome`. Does not itself refresh the
    /// roster/fleet; the caller reconciles the new replicant + rehosted device.
    public var replicate: @Sendable (_ sourceMatrixCode: String, _ targetCode: String, _ name: String?) async -> ReplicateOutcome

    /// A failed replicant update, carrying a user-facing message.
    public struct UpdateError: Error, Equatable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }
}

/// The editable profile fields for `PATCH /v1/replicants/{code}`. Every field is
/// optional; a nil field is omitted from the request so the server leaves it
/// unchanged (mirrors `AccountUpdate`).
public struct ReplicantProfileUpdate: Equatable, Sendable {
    public var name: String?
    public var isNPC: Bool?
    public var pronouns: String?
    public var description: String?
    public var plan: String?
    public var project: String?
    public var cohortPermission: String?

    public init(
        name: String? = nil,
        isNPC: Bool? = nil,
        pronouns: String? = nil,
        description: String? = nil,
        plan: String? = nil,
        project: String? = nil,
        cohortPermission: String? = nil
    ) {
        self.name = name
        self.isNPC = isNPC
        self.pronouns = pronouns
        self.description = description
        self.plan = plan
        self.project = project
        self.cohortPermission = cohortPermission
    }
}

/// The outcome of a replication attempt. `success` carries the newly-created
/// replicant's identity (when the server reported it); `rejected` is a server 4xx
/// (with its message); `failed` is a transport/encoding error.
public enum ReplicateOutcome: Sendable, Equatable {
    case success(newReplicantCode: String?, newReplicantName: String?)
    case rejected(String)
    case failed(String)

    /// The user-facing message for a non-success outcome, if any.
    public var failureMessage: String? {
        switch self {
        case .success: return nil
        case let .rejected(message), let .failed(message): return message
        }
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
            try await storeDetails(code)
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
        },
        updateProfile: { code, update in
            @Dependency(\.gameClient) var gameClient
            @Dependency(\.defaultDatabase) var database

            let output = try await gameClient().patchV1ReplicantsReplicantCode(
                path: .init(replicantCode: code),
                body: .json(.init(
                    name: update.name,
                    isNpc: update.isNPC,
                    pronouns: update.pronouns,
                    description: update.description,
                    plan: update.plan,
                    project: update.project,
                    cohortPermission: update.cohortPermission
                ))
            )
            switch output {
            case .ok:
                break
            case let .badRequest(response):
                throw UpdateError((try? response.body.json.error) ?? "Couldn’t save your changes.")
            default:
                // 404 (not our replicant) / 422 (validation) / anything unexpected.
                throw UpdateError("Couldn’t save your changes.")
            }
            // Reflect a name change into the local roster immediately so the sidebar
            // updates without an accounts/me round-trip…
            if let name = update.name {
                try? await database.write { db in
                    if var roster = try Replicant.where({ $0.replicantCode.eq(code) }).fetchOne(db) {
                        roster.name = name
                        try Replicant.upsert { roster }.execute(db)
                    }
                }
            }
            // …then re-fetch the full record so the inspector shows canonical,
            // server-normalized values and the whole detail blob stays consistent.
            try await storeDetails(code)
        },
        replicate: { sourceMatrixCode, targetCode, name in
            @Dependency(\.gameClient) var gameClient

            let body: Operations.PostV1DevicesDeviceCode.Input.Body =
                .json(.replicate(.init(command: "replicate", target: targetCode, name: name)))
            do {
                let output = try await gameClient().postV1DevicesDeviceCode(
                    path: .init(deviceCode: sourceMatrixCode), body: body
                )
                switch output {
                case let .created(created):
                    let json = try? created.body.json
                    return .success(newReplicantCode: json?.newReplicantCode, newReplicantName: json?.newReplicantName)
                case let .ok(ok):
                    // Defensive: if the server ever answers 200 instead of the
                    // documented 201, still read the new-replicant identity.
                    let json = try? ok.body.json
                    return .success(newReplicantCode: json?.newReplicantCode, newReplicantName: json?.newReplicantName)
                case let .badRequest(response):
                    return .rejected((try? response.body.json.error) ?? "Replication was rejected.")
                case let .forbidden(response):
                    return .rejected((try? response.body.json.error) ?? "Not permitted.")
                case let .notFound(response):
                    return .rejected((try? response.body.json.error) ?? "Device not found.")
                case let .default(statusCode, _):
                    return .failed("Server error (\(statusCode)).")
                @unknown default:
                    return .failed("Unexpected server response.")
                }
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    )

    /// Fetch one replicant's full details (`GET /v1/replicants/{code}`) and merge
    /// them into its `KnownReplicant` record. Shared by `loadDetails` and the
    /// post-update refresh in `updateProfile`.
    private static func storeDetails(_ code: String) async throws {
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
    }

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
        updatePlan: unimplemented("ReplicantsClient.updatePlan"),
        updateProfile: unimplemented("ReplicantsClient.updateProfile"),
        replicate: unimplemented("ReplicantsClient.replicate", placeholder: .failed("unimplemented"))
    )
}

extension DependencyValues {
    public var replicantsClient: ReplicantsClient {
        get { self[ReplicantsClient.self] }
        set { self[ReplicantsClient.self] = newValue }
    }
}
