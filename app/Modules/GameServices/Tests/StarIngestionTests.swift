//
//  StarIngestionTests.swift
//  Replicould — GameServices
//
//  `region`, `has_hub` and `has_ward` on both star endpoints (the per-replicant
//  listing and the objective catalogue) — mapped by `StarsClient`, then persisted
//  through `Star(item:createdAt:)` the way `NewStarMapFeature` writes rows.
//  Each case gives the two flags opposing values, so a mapper reading the wrong
//  key fails rather than passing by coincidence.
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

    @Test("Region, hub flag and ward flag survive ingestion from the list endpoint")
    func regionAndFlagsIngestedFromListEndpoint() async throws {
        let item = try await surveyedItem(
            designation: "DENEBED", region: "Perseus", hasHub: true, hasWard: false
        )
        #expect(item.region == "Perseus")
        #expect(item.hasHub == true)
        #expect(item.hasWard == false)

        let star = try await persistedStar(item)
        #expect(star.region == "Perseus")
        #expect(star.hasHub == true)
        #expect(star.hasWard == false)
    }

    @Test("A star with no region ingests as nil rather than empty, from the list endpoint")
    func absentRegionIsNilFromListEndpoint() async throws {
        let item = try await surveyedItem(
            designation: "SOL", region: nil, hasHub: false, hasWard: true
        )
        #expect(item.region == nil)
        #expect(item.hasHub == false)
        #expect(item.hasWard == true)

        let star = try await persistedStar(item)
        #expect(star.region == nil)
        #expect(star.hasHub == false)
        #expect(star.hasWard == true)
    }

    @Test("An absent ward flag ingests as false, from the list endpoint")
    func absentWardIsFalseFromListEndpoint() async throws {
        let item = try await surveyedItem(
            designation: "DABAH", region: "solzone", hasHub: false, hasWard: nil
        )
        #expect(item.hasWard == false)
        #expect(try await persistedStar(item).hasWard == false)
    }

    // MARK: Catalogue endpoint (`GET /v1/stars`)

    @Test("Region, hub flag and ward flag survive ingestion from the catalogue endpoint")
    func regionAndFlagsIngestedFromCatalogueEndpoint() async throws {
        let item = try await cataloguedItem(
            designation: "DENEBED", region: "Perseus", hasHub: true, hasWard: false
        )
        #expect(item.region == "Perseus")
        #expect(item.hasHub == true)
        #expect(item.hasWard == false)

        let star = try await persistedStar(item)
        #expect(star.region == "Perseus")
        #expect(star.hasHub == true)
        #expect(star.hasWard == false)
    }

    @Test("A star with no region ingests as nil rather than empty, from the catalogue endpoint")
    func absentRegionIsNilFromCatalogueEndpoint() async throws {
        let item = try await cataloguedItem(
            designation: "SOL", region: nil, hasHub: false, hasWard: true
        )
        #expect(item.region == nil)
        #expect(item.hasHub == false)
        #expect(item.hasWard == true)

        let star = try await persistedStar(item)
        #expect(star.region == nil)
        #expect(star.hasHub == false)
        #expect(star.hasWard == true)
    }

    /// The live catalogue omits `has_ward` on all but 94 of 21,722 stars, so
    /// the absent case is the common one.
    @Test("An absent ward flag ingests as false, from the catalogue endpoint")
    func absentWardIsFalseFromCatalogueEndpoint() async throws {
        let item = try await cataloguedItem(
            designation: "DABAH", region: "solzone", hasHub: false, hasWard: nil
        )
        #expect(item.hasWard == false)
        #expect(try await persistedStar(item).hasWard == false)
    }

    // MARK: Fixtures

    /// Decodes one star through `StarsClient.survey`'s live implementation, off
    /// a stubbed transport returning the per-replicant listing shape.
    private func surveyedItem(
        designation: String, region: String?, hasHub: Bool, hasWard: Bool?
    ) async throws -> StarItem {
        let row = starItemJSON(
            designation: designation, region: region, hasHub: hasHub, hasWard: hasWard
        )
        let body = """
        {
          "replicant_position": {"x": 0, "y": 0, "z": 0},
          "page": 1, "per_page": 100, "total": 1, "total_stars": 1, "total_pages": 1,
          "stars": [\(row)]
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
    private func cataloguedItem(
        designation: String, region: String?, hasHub: Bool, hasWard: Bool?
    ) async throws -> StarItem {
        let row = catalogueStarJSON(
            designation: designation, region: region, hasHub: hasHub, hasWard: hasWard
        )
        let body = """
        {"total": 1, "generated_at": "2026-08-01T00:00:00Z", "stars": [\(row)]}
        """
        return try await withDependencies {
            $0.gameClient = stubbedGameClient(body)
        } operation: {
            let stars = try await StarsClient.liveValue.catalogue()
            return try #require(stars.first)
        }
    }

    /// Seeds a stale, conflicting row, then round-trips through the
    /// production `Star.upsertCatalogue` path — so this test exercises
    /// real conflict resolution, not a bare insert.
    private func persistedStar(_ item: StarItem) async throws -> UniverseModels.Star {
        let database = try GameDatabase.bootstrap()
        let stale = UniverseModels.Star(
            designation: item.designation, spectralType: "M0", color: "red",
            positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 0,
            explored: false, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0), region: "STALE",
            hasHub: !item.hasHub, hasWard: !item.hasWard
        )
        let fresh = UniverseModels.Star(item: item, createdAt: Date(timeIntervalSince1970: 0))
        try await database.write { db in
            try UniverseModels.Star.insert { stale }.execute(db)
            try UniverseModels.Star.upsertCatalogue([fresh], in: db)
        }
        return try await database.read { db in
            try #require(try UniverseModels.Star.where { $0.designation.eq(item.designation) }.fetchOne(db))
        }
    }

    private func starItemJSON(
        designation: String, region: String?, hasHub: Bool, hasWard: Bool?
    ) -> String {
        """
        {
          "designation": "\(designation)", "spectral_type": "G2", "color": "yellow-white",
          "position": {"x": 0, "y": 0, "z": 0}, "estimated_planets": 6, "explored": true,
          "has_hub": \(hasHub), "region": \(jsonValue(region))\(wardField(hasWard))
        }
        """
    }

    private func catalogueStarJSON(
        designation: String, region: String?, hasHub: Bool, hasWard: Bool?
    ) -> String {
        """
        {
          "designation": "\(designation)", "spectral_type": "G2", "color": "yellow-white",
          "position": {"x": 0, "y": 0, "z": 0}, "estimated_planets": 6,
          "has_hub": \(hasHub), "region": \(jsonValue(region))\(wardField(hasWard))
        }
        """
    }

    /// A nil `hasWard` omits the key entirely, which is how the live payload
    /// reports a star with no ward — never an explicit null.
    private func wardField(_ hasWard: Bool?) -> String {
        hasWard.map { ", \"has_ward\": \($0)" } ?? ""
    }

    private func jsonValue(_ string: String?) -> String {
        string.map { "\"\($0)\"" } ?? "null"
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
