import Foundation
import GameModels
import Testing
@testable import DirectiveEngine

@Suite("BlueprintClosure")
struct BlueprintClosureTests {
    /// The live catalogue's component-bearing blueprints and their leaves. The
    /// four blueprints the account cannot print are deliberately absent.
    private let bills: [String: ResourceCost] = [
        "climate_processor": ResourceCost(
            carbon: 250, structural: 200, rares: 100, conductive: 250, volatiles: 200
        ),
        "atmospheric_regulator": ResourceCost(
            silicates: 200, structural: 200, conductive: 300, volatiles: 150
        ),
        "biosphere_cultivator": ResourceCost(
            carbon: 300, structural: 100, conductive: 150, volatiles: 200
        ),
        "atmo_processor": ResourceCost(
            carbon: 150, structural: 200, conductive: 100, volatiles: 100
        ),
        "filtration_array": ResourceCost(
            carbon: 260, structural: 140, conductive: 110, volatiles: 60
        ),
        "orbital_farm": ResourceCost(
            carbon: 30, silicates: 20, structural: 400, rares: 50, conductive: 20, volatiles: 120
        ),
        "compute_core": ResourceCost(
            carbon: 2, silicates: 55, structural: 8, rares: 15, conductive: 35
        ),
        "processing_array": ResourceCost(conductive: 200),
        "mining_drone": ResourceCost(carbon: 25, silicates: 25, structural: 100, conductive: 50),
    ]

    private let components: [String: [String: Int]] = [
        "atmospheric_regulator": ["filtration_array": 1, "atmo_processor": 2],
        "biosphere_cultivator": ["hydroponic_bay": 2, "nutrient_synthesizer": 1, "orbital_farm": 1],
        "climate_processor": ["orbital_mirror": 1, "terraform_controller": 1, "atmo_processor": 2],
        "processing_array": ["compute_core": 5],
    ]

    @Test("a blueprint with no components expands to itself")
    func flat() {
        let out = BlueprintClosure.expand(["mining_drone": 2], bills: bills, components: components)
        #expect(out.resources.total == 400)
        #expect(out.jobs == [BlueprintClosure.Job(deviceType: "mining_drone", quantity: 2, depth: 0)])
        #expect(out.unprintable.isEmpty)
    }

    @Test("one level expands components before the parent")
    func oneLevel() {
        let out = BlueprintClosure.expand(
            ["processing_array": 1], bills: bills, components: components
        )
        #expect(out.jobs.map(\.deviceType) == ["compute_core", "processing_array"])
        #expect(out.jobs.first?.quantity == 5)
        // 200 for the array + 5 × 115 for the cores.
        #expect(out.resources.total == 775)
        #expect(out.unprintable.isEmpty)
    }

    @Test("a component reached twice merges into one job")
    func sharedComponent() {
        let out = BlueprintClosure.expand(
            ["atmospheric_regulator": 1, "climate_processor": 1],
            bills: bills, components: components
        )
        let atmo = out.jobs.first { $0.deviceType == "atmo_processor" }
        #expect(atmo?.quantity == 4)
        #expect(out.jobs.filter { $0.deviceType == "atmo_processor" }.count == 1)
    }

    @Test("an unknown blueprint is named and contributes nothing")
    func unknownLeaf() {
        let out = BlueprintClosure.expand(
            ["climate_processor": 2], bills: bills, components: components
        )
        #expect(out.unprintable == ["orbital_mirror", "terraform_controller"])
        // 2 × 1000 for the processors + 4 × 550 for the atmo processors. The two
        // unknown blueprints contribute nothing, so this is a lower bound.
        #expect(out.resources.total == 4200)
    }

    @Test("a cycle is refused rather than followed")
    func cycle() {
        let out = BlueprintClosure.expand(
            ["a": 1],
            bills: ["a": ResourceCost(carbon: 1), "b": ResourceCost(carbon: 1)],
            components: ["a": ["b": 1], "b": ["a": 1]]
        )
        #expect(out.unprintable.contains("a"))
    }

    @Test("deeper components sort ahead of shallower ones")
    func depthOrder() {
        let out = BlueprintClosure.expand(
            ["top": 1],
            bills: ["top": ResourceCost(), "mid": ResourceCost(), "leaf": ResourceCost()],
            components: ["top": ["mid": 1], "mid": ["leaf": 1]]
        )
        #expect(out.jobs.map(\.deviceType) == ["leaf", "mid", "top"])
    }

    @Test("print seconds sum over the whole tree")
    func printSeconds() {
        let out = BlueprintClosure.expand(
            ["processing_array": 1], bills: bills, components: components,
            printTimes: ["processing_array": 400, "compute_core": 200]
        )
        #expect(out.printSeconds == 1400)
    }

    @Test("the TABAT-4-EVT-007 options reverse order once components are counted")
    func liveEventOptions() {
        let biosphere = BlueprintClosure.expand(
            ["climate_processor": 2, "biosphere_cultivator": 1], bills: bills, components: components
        )
        let atmospheric = BlueprintClosure.expand(
            ["climate_processor": 2, "atmospheric_regulator": 1], bills: bills, components: components
        )
        // Naive (top-level bills only) makes atmospheric cheaper: 3,350 vs 3,450
        // once the event's own resources are added. Expanded, it is dearer.
        #expect(biosphere.resources.total + 700 == 6290)
        #expect(atmospheric.resources.total + 500 == 7220)
        #expect(biosphere.resources.total < atmospheric.resources.total)
    }
}
