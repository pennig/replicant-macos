//
//  StarsClient.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  Surveys observable stars from `GET /v1/replicants/{code}/stars` through the
//  generated `ReplicantSpace` client, so the call inherits bearer auth, rate
//  limiting, and logging from its middleware stack. The endpoint is paged
//  (thousands of stars); `survey` walks every page over a single client — one
//  rate-limit governor shared across the whole walk — yielding each page as it
//  lands so callers can persist and report progress incrementally.
//
//  This is the shared root survey: both the star map and the locations catalog
//  build atop the `stars` table this client fills.
//

import API
import Dependencies
import Foundation
import GameSession
import UniverseModels

/// One page of the observable-stars listing.
public struct StarPage: Equatable, Sendable {
    public var stars: [StarItem]
    public var page: Int
    public var perPage: Int
    public var totalStars: Int
    public var totalPages: Int
    public var replicantPosition: Position

    public init(
        stars: [StarItem], page: Int, perPage: Int,
        totalStars: Int, totalPages: Int, replicantPosition: Position
    ) {
        self.stars = stars
        self.page = page
        self.perPage = perPage
        self.totalStars = totalStars
        self.totalPages = totalPages
        self.replicantPosition = replicantPosition
    }
}

public struct StarsClient: Sendable {
    /// Download the entire objective star catalogue in a single request
    /// (`GET /v1/stars`) — every star's position, spectral type, planet estimate,
    /// and entry point. This is the primary galaxy source. It carries *no*
    /// per-replicant knowledge (no `explored` / `has_life`); overlay that with
    /// `survey`. The endpoint is expensive and rate-limited to roughly one call a
    /// minute — gate any UI on `cooldownUntil`.
    public var catalogue: @Sendable () async throws -> [StarItem]

    /// When the next full-catalogue download is allowed, per the endpoint's own
    /// rate-limit headers (nil = ready now). Read after a `catalogue` call — the
    /// governor captures the reset from the response even on a 429.
    public var cooldownUntil: @Sendable () async -> Date?

    /// Walk the per-replicant observable-stars listing (`GET /v1/replicants/{code}/stars`,
    /// paged), yielding each page as it arrives. Used to overlay per-replicant
    /// `explored` / `has_life` onto the catalogue; the listing is distance-sorted,
    /// so callers can stop once the nearby explored systems are covered. The
    /// stream finishes when the last page is read, or throws if any request fails.
    public var survey: @Sendable (
        _ replicantCode: String,
        _ perPage: Int
    ) -> AsyncThrowingStream<StarPage, any Error>

    public init(
        catalogue: @escaping @Sendable () async throws -> [StarItem],
        cooldownUntil: @escaping @Sendable () async -> Date?,
        survey: @escaping @Sendable (String, Int) -> AsyncThrowingStream<StarPage, any Error>
    ) {
        self.catalogue = catalogue
        self.cooldownUntil = cooldownUntil
        self.survey = survey
    }
}

extension StarsClient: DependencyKey {
    public static let liveValue = StarsClient(catalogue: {
        @Dependency(\.gameClient) var gameClient
        let output = try await gameClient.make().getV1Stars()
        let body = try output.ok.body.json
        return (body.stars ?? []).map(StarItem.init(schema:))
    }, cooldownUntil: {
        @Dependency(\.gameClient) var gameClient
        let snapshot = await gameClient.budget(.stars)
        guard let reset = snapshot.resetAt, reset > Date() else { return nil }
        return reset
    }, survey: { replicantCode, perPage in
        @Dependency(\.gameClient) var gameClient
        let make = gameClient.make
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let client = make()
                    var page = 1
                    var totalPages = 1
                    repeat {
                        try Task.checkCancellation()
                        let output = try await client.getV1ReplicantsReplicantCodeStars(
                            path: .init(replicantCode: replicantCode),
                            query: .init(page: page, perPage: perPage)
                        )
                        let body = try output.ok.body.json
                        let starPage = StarPage(body: body, fallbackPage: page, fallbackPerPage: perPage)
                        continuation.yield(starPage)
                        totalPages = starPage.totalPages
                        page += 1
                    } while page <= totalPages
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    })
}

extension StarsClient: TestDependencyKey {
    public static let testValue = StarsClient(
        catalogue: { [] },
        cooldownUntil: { nil },
        survey: { _, _ in AsyncThrowingStream { $0.finish() } }
    )

    public static let previewValue = StarsClient(
        catalogue: { StarItem.previewSeed },
        cooldownUntil: { nil },
        survey: { _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(StarPage(
                    stars: StarItem.previewSeed, page: 1, perPage: 100,
                    totalStars: StarItem.previewSeed.count, totalPages: 1,
                    replicantPosition: Position(x: 0, y: 0, z: 0)
                ))
                continuation.finish()
            }
        }
    )
}

extension DependencyValues {
    public var starsClient: StarsClient {
        get { self[StarsClient.self] }
        set { self[StarsClient.self] = newValue }
    }
}

// MARK: - Preview seed

extension StarItem {
    /// A tiny, self-contained census used only by `StarsClient.previewValue`.
    static let previewSeed: [StarItem] = [
        StarItem(
            designation: "SOL", spectralType: "G2", color: "yellow-white",
            position: Position(x: 0, y: 0, z: 0), estimatedPlanets: 8,
            explored: true, hasLife: true, entryPoint: "SOL-5-L4"
        ),
        StarItem(
            designation: "UNALEDI", spectralType: "M1", color: "Red",
            position: Position(x: 0.131, y: -1.68, z: 1.515), estimatedPlanets: 6,
            explored: true, hasLife: false, entryPoint: "UNALEDI-6-L4"
        ),
        StarItem(
            designation: "DABAH", spectralType: "M9", color: "Red",
            position: Position(x: 0.433, y: -0.039, z: -4.634), estimatedPlanets: 6,
            explored: false, hasLife: nil, entryPoint: nil
        ),
    ]
}

// MARK: - Mapping (generated schema → models)

extension StarPage {
    fileprivate init(
        body: Components.Schemas.AppSchemasStarsStarListResponseSchema,
        fallbackPage: Int,
        fallbackPerPage: Int
    ) {
        let perPage = body.perPage ?? fallbackPerPage
        let totalStars = body.totalStars ?? body.total ?? (body.stars?.count ?? 0)
        let totalPages = body.totalPages
            ?? (perPage > 0 ? Int((Double(totalStars) / Double(perPage)).rounded(.up)) : 1)
        self.init(
            stars: (body.stars ?? []).map(StarItem.init(schema:)),
            page: body.page ?? fallbackPage,
            perPage: perPage,
            totalStars: totalStars,
            totalPages: max(totalPages, 1),
            replicantPosition: body.replicantPosition.map(Position.init(schema:)) ?? Position(x: 0, y: 0, z: 0)
        )
    }
}

extension StarItem {
    fileprivate init(schema: Components.Schemas.AppSchemasStarsStarItemSchema) {
        self.init(
            designation: schema.designation ?? "",
            spectralType: schema.spectralType ?? "",
            color: schema.color ?? "",
            position: schema.position.map(Position.init(schema:)) ?? Position(x: 0, y: 0, z: 0),
            estimatedPlanets: schema.estimatedPlanets ?? 0,
            explored: schema.explored ?? false,
            hasLife: schema.hasLife,
            entryPoint: schema.entryPoint
        )
    }
}

extension Position {
    fileprivate init(schema: Components.Schemas.AppSchemasCommonPositionSchema) {
        self.init(x: schema.x ?? 0, y: schema.y ?? 0, z: schema.z ?? 0)
    }
}
