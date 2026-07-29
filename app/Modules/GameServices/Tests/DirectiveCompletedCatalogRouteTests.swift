//
//  DirectiveCompletedCatalogRouteTests.swift
//  GameServicesTests
//
//  A completed survey means the system's scan counts have moved, and those
//  counts are what stamp `stars.fullyScannedAt`. The completion event itself is
//  NOT taken as evidence: SurveyRun.confirm already refuses to trust a
//  completion over the counts (it stalls `.surveyIncomplete` when the server
//  says done and the numbers disagree), so this route only triggers the re-read
//  and lets the counts decide.
//

import API
import Dependencies
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import UniverseModels
import Utils

@testable import GameServices

@Suite("directive.completed catalog route")
struct DirectiveCompletedCatalogRouteTests {
    /// Drive just the catalog route with one event, recording which systems got
    /// re-read.
    ///
    /// The stub is on `locationsClient.system` — the closure property
    /// `hydrateSystem` actually calls — because `hydrateSystem` is a real method
    /// built on top of those closures, not an overridable closure itself. Which
    /// makes this the better observation anyway: it drives the real hydrate path
    /// rather than a fake of it. `testValue` is `unimplemented(...)` by house
    /// rule, so any *other* client call this route makes would fail loudly.
    private func hydrated(for event: GameEventEnvelope) async throws -> [String] {
        let recorder = LockIsolated<[String]>([])
        let database = try GameDatabase.bootstrap()
        let ingestion = LocationsIngestion()
        guard let route = ingestion.eventRoutes.first(where: { $0.id == "locations.catalog" })
        else { return [] }
        await withDependencies {
            $0.defaultDatabase = database
            $0.date.now = Date(timeIntervalSince1970: 1_000_000)
            $0.locationsClient.system = { designation in
                recorder.withValue { $0.append(designation) }
                return StarSystem(designation: designation, recon: .visited)
            }
        } operation: {
            await route.apply(event)
        }
        return recorder.value
    }

    private func completion(directive: String, star: String?) -> GameEventEnvelope {
        GameEventEnvelope(
            id: "1-0",
            category: "directive",
            event: "directive.completed",
            star: star,
            payload: ["directive": .string(directive)]
        )
    }

    @Test func hydratesTheSystemAfterASurveyCompletes() async throws {
        let read = try await hydrated(for: completion(directive: "survey_system", star: "SOL"))
        #expect(read == ["SOL"])
    }

    @Test func ignoresANonSurveyDirective() async throws {
        let read = try await hydrated(for: completion(directive: "mine_resource", star: "SOL"))
        #expect(read.isEmpty)
    }

    @Test func ignoresACompletionWithNoSystem() async throws {
        let read = try await hydrated(for: completion(directive: "survey_system", star: nil))
        #expect(read.isEmpty)
    }
}
