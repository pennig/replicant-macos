//  Pins `GET /v1/species` against the strict generated decoder.
//  `app_schemas_species_SpeciesSchema` is `additionalProperties: false`, so the
//  `environment` and `star_regions` blocks throw unless the spec declares them.

import Foundation
import Testing
import API

struct SpeciesResponseDecodingTests {
    private typealias Response = Components.Schemas.AppSchemasSpeciesSpeciesListResponseSchema

    private func decode(_ json: String) throws -> Response {
        try JSONDecoder().decode(Response.self, from: Data(json.utf8))
    }

    // Every species carries all eight environment ranges as [min, max].
    @Test func decodesEnvironmentRanges() throws {
        let response = try decode(
            """
            {
              "species": [
                {
                  "description": "Nomadic arthropods migrating across vast deserts.",
                  "environment": {
                    "biosphere": [5, 25],
                    "gravity": [0.8, 1.5],
                    "hydrosphere": [0, 10],
                    "oxygen": [12, 18],
                    "pressure": [0.3, 0.7],
                    "tectonic": [0, 15],
                    "temperature": [300, 340],
                    "toxicity": [0, 15]
                  },
                  "government": "Traveller Council",
                  "greeting": "Short-range directional signal. Source is in motion.",
                  "homeworld_type": "desert_world",
                  "name": "Branthar",
                  "species_key": "branthar",
                  "tech_affinity": "navigation",
                  "trait": "nomadic"
                }
              ]
            }
            """)

        let environment = try #require(response.species?.first?.environment)
        #expect(environment.temperature == [300, 340])
        #expect(environment.gravity == [0.8, 1.5])
        #expect(environment.pressure == [0.3, 0.7])
        #expect(environment.toxicity == [0, 15])
    }

    // `star_regions` is present on some species and absent on most.
    @Test func decodesStarRegionsAlongsideEnvironment() throws {
        let response = try decode(
            """
            {
              "species": [
                {
                  "environment": {
                    "biosphere": [0, 5],
                    "gravity": [0.5, 2.0],
                    "hydrosphere": [0, 5],
                    "oxygen": [0, 2],
                    "pressure": [0, 0.1],
                    "tectonic": [0, 10],
                    "temperature": [50, 120],
                    "toxicity": [0, 5]
                  },
                  "name": "Vothek",
                  "species_key": "vothek",
                  "star_regions": ["alpha"]
                }
              ]
            }
            """)

        #expect(response.species?.first?.starRegions == ["alpha"])
        #expect(response.species?.first?.environment?.temperature == [50, 120])
    }
}
