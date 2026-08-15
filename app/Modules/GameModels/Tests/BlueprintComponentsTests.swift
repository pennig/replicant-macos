import API
import Foundation
import Testing
@testable import GameModels

@Suite("Blueprint components")
struct BlueprintComponentsTests {
    @Test("a blueprint with no components decodes to an empty map")
    func absentComponents() {
        let blueprint = Blueprint(
            deviceType: "mining_drone", shortDescription: "", fullDescription: "",
            printTime: 200, features: [], directives: [],
            resources: ResourceCost(carbon: 25), stowCapacity: 0, cargoCapacity: 0,
            attachCapacity: 0, queueSize: 0, strength: 0, currentHubs: nil
        )
        #expect(blueprint.components.isEmpty)
    }

    @Test("a blueprint carries its component bill")
    func presentComponents() {
        let blueprint = Blueprint(
            deviceType: "atmospheric_regulator", shortDescription: "", fullDescription: "",
            printTime: 3600, features: [], directives: [],
            resources: ResourceCost(silicates: 200, structural: 200, conductive: 300, volatiles: 150),
            stowCapacity: 0, cargoCapacity: 0, attachCapacity: 0, queueSize: 0,
            strength: 0, currentHubs: nil,
            components: ["filtration_array": 1, "atmo_processor": 2]
        )
        #expect(blueprint.components == ["filtration_array": 1, "atmo_processor": 2])
    }

    /// The wire mapping, not the memberwise init: `Blueprint(schema:)` dropped
    /// `components` at one line while the field shipped in the payload and in the
    /// generated client, and nothing above this level could tell.
    @Test("init(schema:) carries the payload's components through")
    func schemaMappingCarriesComponents() throws {
        func blueprint(_ json: String) throws -> Blueprint {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return Blueprint(schema: try decoder.decode(
                Components.Schemas.AppSchemasBlueprintsBlueprintSchema.self,
                from: Data(json.utf8)
            ))
        }
        let carried = try blueprint(
            #"""
            {
              "device_type": "atmospheric_regulator",
              "print_time": 3600.0,
              "resources": {"structural": 200},
              "components": {"filtration_array": 1, "atmo_processor": 2}
            }
            """#
        )
        #expect(carried.components == ["filtration_array": 1, "atmo_processor": 2])

        let omitted = try blueprint(#"{"device_type": "mining_drone"}"#)
        #expect(omitted.components.isEmpty, "the wire omits the key entirely on most blueprints")
    }
}
