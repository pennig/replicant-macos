//
//  StarIngestionTests.swift
//  Replicould — GameServices
//
//  `region` and `has_hub` on both star endpoints (the per-replicant listing and
//  the objective catalogue) — mapped by `StarsClient`, then persisted through
//  `Star(item:createdAt:)` the way `NewStarMapFeature` writes rows.
//

import API
import Dependencies
import Foundation
import GameDatabase
import GameSession
import HTTPTypes
import OpenAPIRuntime
import SQLiteData
import Testing
import UniverseModels
@testable import GameServices

@Suite struct StarIngestionTests {

    // MARK: List endpoint (`GET /v1/replicants/{code}/stars`)

    @Test("Region and hub flag survive ingestion from the list endpoint")
    func regionAndHubIngestedFromListEndpoint() async throws {
        let item = try await surveyedItem(designation: "DENEBED", region: "Perseus", hasHub: true)
        #expect(item.region == "Perseus")
        #expect(item.hasHub == true)

        let star = try await persistedStar(item)
        #expect(star.region == "Perseus")
        #expect(star.hasHub == true)
    }

    @Test("A star with no region ingests as nil rather than empty, from the list endpoint")
    func absentRegionIsNilFromListEndpoint() async throws {
        let item = try await surveyedItem(designation: "SOL", region: nil, hasHub: false)
        #expect(item.region == nil)
        #expect(item.hasHub == false)

        let star = try await persistedStar(item)
        #expect(star.region == nil)
        #expect(star.hasHub == false)
    }

    // MARK: Catalogue endpoint (`GET /v1/stars`)

    @Test("Region and hub flag survive ingestion from the catalogue endpoint")
    func regionAndHubIngestedFromCatalogueEndpoint() async throws {
        let item = try await cataloguedItem(designation: "DENEBED", region: "Perseus", hasHub: true)
        #expect(item.region == "Perseus")
        #expect(item.hasHub == true)

        let star = try await persistedStar(item)
        #expect(star.region == "Perseus")
        #expect(star.hasHub == true)
    }

    @Test("A star with no region ingests as nil rather than empty, from the catalogue endpoint")
    func absentRegionIsNilFromCatalogueEndpoint() async throws {
        let item = try await cataloguedItem(designation: "SOL", region: nil, hasHub: false)
        #expect(item.region == nil)
        #expect(item.hasHub == false)

        let star = try await persistedStar(item)
        #expect(star.region == nil)
        #expect(star.hasHub == false)
    }

    // MARK: Fixtures

    /// Decodes one star through `StarsClient.survey`'s live implementation, off
    /// a stubbed transport returning the per-replicant listing shape.
    private func surveyedItem(designation: String, region: String?, hasHub: Bool) async throws -> StarItem {
        let body = """
        {
          "replicant_position": {"x": 0, "y": 0, "z": 0},
          "page": 1, "per_page": 100, "total": 1, "total_stars": 1, "total_pages": 1,
          "stars": [\(starItemJSON(designation: designation, region: region, hasHub: hasHub))]
        }
        """
        return try await withDependencies {
            $0.gameClient = stubbedGameClient(body)
        } operation: {
            var first: StarItem?
            for try await page in StarsClient.liveValue.survey("R1", 100) {
                first = page.stars.first
                break
            }
            return try #require(first)
        }
    }

    /// Same, off `StarsClient.catalogue`'s stubbed transport returning the
    /// objective-catalogue shape.
    private func cataloguedItem(designation: String, region: String?, hasHub: Bool) async throws -> StarItem {
        let body = """
        {"total": 1, "generated_at": "2026-08-01T00:00:00Z", "stars": [\(catalogueStarJSON(designation: designation, region: region, hasHub: hasHub))]}
        """
        return try await withDependencies {
            $0.gameClient = stubbedGameClient(body)
        } operation: {
            let stars = try await StarsClient.liveValue.catalogue()
            return try #require(stars.first)
        }
    }

    /// Round-trips a `StarItem` through `Star(item:createdAt:)` and a real
    /// migrated database, mirroring how `NewStarMapFeature` persists a page.
    private func persistedStar(_ item: StarItem) async throws -> UniverseModels.Star {
        let database = try GameDatabase.bootstrap()
        let record = UniverseModels.Star(item: item, createdAt: Date(timeIntervalSince1970: 0))
        try await database.write { db in
            try UniverseModels.Star.insert { record }.execute(db)
        }
        return try await database.read { db in
            try #require(try UniverseModels.Star.where { $0.designation.eq(item.designation) }.fetchOne(db))
        }
    }

    private func starItemJSON(designation: String, region: String?, hasHub: Bool) -> String {
        """
        {
          "designation": "\(designation)", "spectral_type": "G2", "color": "yellow-white",
          "position": {"x": 0, "y": 0, "z": 0}, "estimated_planets": 6, "explored": true,
          "has_hub": \(hasHub), "region": \(region.map { "\"\($0)\"" } ?? "null")
        }
        """
    }

    private func catalogueStarJSON(designation: String, region: String?, hasHub: Bool) -> String {
        """
        {
          "designation": "\(designation)", "spectral_type": "G2", "color": "yellow-white",
          "position": {"x": 0, "y": 0, "z": 0}, "estimated_planets": 6,
          "has_hub": \(hasHub), "region": \(region.map { "\"\($0)\"" } ?? "null")
        }
        """
    }

    private func stubbedGameClient(_ body: String) -> GameClient {
        GameClient(make: {
            Client(
                serverURL: URL(string: "https://stub.invalid")!,
                transport: FixedJSONTransport(body: body)
            )
        })
    }
}

/// A transport that answers every request with the same canned JSON body.
private struct FixedJSONTransport: ClientTransport {
    let body: String
    func send(
        _ request: HTTPRequest, body requestBody: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        (
            HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
            HTTPBody(Array(body.utf8))
        )
    }
}
