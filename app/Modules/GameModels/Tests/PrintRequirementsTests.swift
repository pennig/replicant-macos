import Foundation
import Testing
@testable import GameModels

@Suite("PrintRequirements components")
struct PrintRequirementsTests {
    @Test("a component the location lacks makes the print unmet")
    func missingComponent() {
        let requirements = PrintRequirements.resolve(
            deviceType: "atmospheric_regulator",
            locationName: "AINALRAM-BELT-1",
            required: [PrintResourceLine(resource: "structural", label: "Structural", required: 200)],
            requiredComponents: [
                PrintComponentLine(deviceType: "atmo_processor", label: "Atmo Processor", required: 2)
            ],
            available: ["structural": 5000],
            heldComponents: ["atmo_processor": 1]
        )
        #expect(requirements.components.first?.available == 1)
        #expect(requirements.components.first?.isMet == false)
        #expect(requirements.allMet == false)
    }

    @Test("every component present makes the print met")
    func componentsSatisfied() {
        let requirements = PrintRequirements.resolve(
            deviceType: "atmospheric_regulator",
            locationName: nil,
            required: [PrintResourceLine(resource: "structural", label: "Structural", required: 200)],
            requiredComponents: [
                PrintComponentLine(deviceType: "atmo_processor", label: "Atmo Processor", required: 2)
            ],
            available: ["structural": 5000],
            heldComponents: ["atmo_processor": 2]
        )
        #expect(requirements.allMet)
    }

    @Test("a blueprint with no components behaves exactly as before")
    func noComponents() {
        let requirements = PrintRequirements.resolve(
            deviceType: "mining_drone", locationName: nil,
            required: [PrintResourceLine(resource: "structural", label: "Structural", required: 100)],
            requiredComponents: [],
            available: ["structural": 5000],
            heldComponents: [:]
        )
        #expect(requirements.components.isEmpty)
        #expect(requirements.allMet)
    }
}
