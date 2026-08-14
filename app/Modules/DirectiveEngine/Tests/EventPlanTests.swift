import Foundation
import GameModels
import Testing
import Utils
@testable import DirectiveEngine

@Suite("EventPlan")
struct EventPlanTests {
    private let costs: [String: ResourceCost] = [
        "comm_satellite": ResourceCost(silicates: 100, structural: 100, conductive: 150),
        "signal_booster": ResourceCost(structural: 150, rares: 50, conductive: 200),
        "mesh_relay": ResourceCost(silicates: 30, structural: 50, conductive: 80),
        "climate_processor": ResourceCost(
            carbon: 250, structural: 200, rares: 100, conductive: 250, volatiles: 200
        ),
        "atmospheric_regulator": ResourceCost(
            silicates: 200, structural: 200, conductive: 300, volatiles: 150
        ),
    ]

    private func event(_ criteria: JSONValue, designation: String = "X-1-EVT-001") -> LocationEvent {
        LocationEvent(
            designation: designation, location: "X-1", tier: 2, status: "active",
            detail: .object(["criteria": criteria, "rewards": .object(["xp": .number(1500)])]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
    }

    private func option(_ name: String, devices: [(Int, String)], resources: [String: Int]) -> JSONValue {
        .object([
            "name": .string(name),
            "devices": .array(devices.map {
                .object(["count": .number(Double($0.0)), "device_type": .string($0.1)])
            }),
            "resources": .object(resources.mapValues { .number(Double($0)) }),
        ])
    }

    @Test("a single-option event is decided without a choice")
    func singleOption() throws {
        let row = event(.array([option("default", devices: [(2, "comm_satellite")], resources: ["conductive": 150])]))
        guard case .decided(let plan) = EventPlan.resolve(row, chosenOption: nil, bills: costs) else {
            Issue.record("expected .decided"); return
        }
        #expect(plan.name == "default")
        #expect(plan.devices == ["comm_satellite": 2])
        #expect(plan.resources == ["conductive": 150])
        #expect(plan.deviceUnits == 700)
        #expect(plan.resourceUnits == 150)
    }

    @Test("a multi-option event needs a choice until one is recorded")
    func multiOption() throws {
        let row = event(.array([
            option("satellite", devices: [(2, "comm_satellite")], resources: ["conductive": 150]),
            option("booster", devices: [(1, "signal_booster")], resources: ["conductive": 150]),
        ]))
        guard case .needsChoice(let offered) = EventPlan.resolve(row, chosenOption: nil, bills: costs) else {
            Issue.record("expected .needsChoice"); return
        }
        #expect(offered.map(\.name) == ["satellite", "booster"])

        guard case .decided(let plan) = EventPlan.resolve(row, chosenOption: "booster", bills: costs) else {
            Issue.record("expected .decided"); return
        }
        #expect(plan.name == "booster")
        #expect(plan.deviceUnits == 400)
    }

    @Test("a recorded choice naming no real option needs a choice again")
    func staleChoice() {
        let row = event(.array([
            option("satellite", devices: [(2, "comm_satellite")], resources: [:]),
            option("booster", devices: [(1, "signal_booster")], resources: [:]),
        ]))
        guard case .needsChoice = EventPlan.resolve(row, chosenOption: "gone", bills: costs) else {
            Issue.record("expected .needsChoice"); return
        }
    }

    @Test("an option over the freighter's hold is still decided, and reports it")
    func oversizedCargo() throws {
        let row = event(.array([
            option("heavy", devices: [(2, "climate_processor")], resources: ["volatiles": 300, "carbon": 400])
        ]))
        guard case .decided(let plan) = EventPlan.resolve(row, chosenOption: nil, bills: costs) else {
            Issue.record("expected .decided"); return
        }
        #expect(plan.resourceUnits == 700)
        #expect(plan.exceedsOneFreighterLoad)
    }

    @Test("an undecodable blob resolves to .undecodable rather than a free event")
    func undecodable() {
        let row = LocationEvent(
            designation: "X-1-EVT-002", location: "X-1", status: "active",
            detail: .object([:]), firstSeenAt: .distantPast, updatedAt: .distantPast
        )
        guard case .undecodable = EventPlan.resolve(row, chosenOption: nil, bills: costs) else {
            Issue.record("expected .undecodable"); return
        }
    }
}
