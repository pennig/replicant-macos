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
}
