//
//  SalvageTargetPlannerTests.swift
//  DirectiveEngineTests
//
//  The continuous Salvage Run's target selection. Pure function over fixtures,
//  the same shape as SurveyRoamPlanner's tests: every star lies on the X axis so
//  distances are readable by eye.
//

import Foundation
import GameModels
import Testing
import UniverseModels

@testable import DirectiveEngine

@Suite("Salvage target planner")
struct SalvageTargetPlannerTests {
    /// A star `x` light-years out along the X axis. Only position matters here,
    /// so every other column takes an inert default.
    private func star(_ designation: String, x: Double) -> Star {
        Star(
            designation: designation, spectralType: "G", color: "yellow",
            positionX: x, positionY: 0, positionZ: 0, estimatedPlanets: 3,
            explored: false, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func assay(_ system: String, body: String, units: Double, depleted: Bool = false) -> SiteAssay {
        SiteAssay(
            id: "\(body)-SAL-1", body: body, system: system,
            siteType: "salvage", totals: ["structural": units], assayedAt: .distantPast,
            depleted: depleted
        )
    }

    /// A device row with exactly the columns `meshSystems` and the fixture
    /// itself care about — everything else takes an inert default. Confined to
    /// this file: no shared `Device.fixture` exists yet in this repo (Task 1 hit
    /// the same gap), and `SurveyRunTests`' `device(...)` helper hardcodes
    /// `status`/`features` in ways that don't fit a relay row.
    private static func device(
        _ code: String, features: [String], status: String, location: String?
    ) -> Device {
        Device(
            deviceCode: code, deviceType: "relay", replicantCode: "R1",
            status: status, location: location, locationName: nil,
            operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: features, tags: [],
            detail: .object([:]),
            updatedAt: Date(timeIntervalSince1970: 0), firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func prefersAnAlreadyMeshedSystemOverARicherUnmeshedOne() {
        let stars = ["HOME": star("HOME", x: 0), "MESHED": star("MESHED", x: 3), "RICH": star("RICH", x: 5)]
        let target = SalvageTargetPlanner.nextTarget(
            assays: [assay("MESHED", body: "MESHED-1", units: 100),
                     assay("RICH", body: "RICH-1", units: 9000)],
            stars: stars, meshSystems: ["HOME", "MESHED"], attempted: [],
            vessel: Position(x: 0, y: 0, z: 0)
        )
        // The richer system is not ranked lower — it is not a candidate at all,
        // because nothing has meshed it.
        #expect(target == .init(system: "MESHED", units: 100))
    }

    @Test func rejectsASystemMoreThanOneHopOut() {
        let stars = ["HOME": star("HOME", x: 0), "FAR": star("FAR", x: 20)]
        // Nothing reachable at all: the run has no target it could work, which
        // is a `nil` rather than a bad pick. The vessel stays where it is.
        #expect(SalvageTargetPlanner.nextTarget(
            assays: [assay("FAR", body: "FAR-1", units: 9000)],
            stars: stars, meshSystems: ["HOME"], attempted: [],
            vessel: Position(x: 0, y: 0, z: 0)
        ) == nil)
    }

    /// `tendMesh` is the sole mesh authority, so an unmeshed system is not this
    /// run's to reach however rich it is and however close a relay would sit.
    /// The run waits for the mesh instead of planting its own.
    @Test func anUnmeshedSystemIsNeverOfferedEvenWhenItIsTheOnlyValue() {
        let stars = ["HOME": star("HOME", x: 0), "NEAR": star("NEAR", x: 7)]
        #expect(SalvageTargetPlanner.nextTarget(
            assays: [assay("NEAR", body: "NEAR-1", units: 9000)],
            stars: stars, meshSystems: ["HOME"], attempted: [],
            vessel: Position(x: 0, y: 0, z: 0)
        ) == nil)
    }

    /// The frontier still expands, but on `tendMesh`'s schedule rather than this
    /// run's: a system becomes workable when IT joins the mesh, not when a
    /// neighbour close enough to relay to does.
    @Test func aSystemBecomesWorkableOnlyWhenItselfMeshed() {
        let stars = ["HOME": star("HOME", x: 0), "NEAR": star("NEAR", x: 14), "FAR": star("FAR", x: 20)]
        let assays = [assay("FAR", body: "FAR-1", units: 9000)]
        // FAR sits 6 ly from meshed NEAR — one relay hop, and still not a target.
        #expect(SalvageTargetPlanner.nextTarget(
            assays: assays, stars: stars, meshSystems: ["HOME", "NEAR"], attempted: [],
            vessel: Position(x: 0, y: 0, z: 0)
        ) == nil)
        #expect(SalvageTargetPlanner.nextTarget(
            assays: assays, stars: stars, meshSystems: ["HOME", "NEAR", "FAR"], attempted: [],
            vessel: Position(x: 0, y: 0, z: 0)
        ) == .init(system: "FAR", units: 9000))
    }

    @Test func sumsEveryBodysUnitsInASystem() {
        let stars = ["HOME": star("HOME", x: 0), "TWO": star("TWO", x: 3)]
        let target = SalvageTargetPlanner.nextTarget(
            assays: [assay("TWO", body: "TWO-1", units: 100), assay("TWO", body: "TWO-6", units: 250)],
            stars: stars, meshSystems: ["HOME", "TWO"], attempted: [],
            vessel: Position(x: 0, y: 0, z: 0)
        )
        #expect(target?.units == 350)
    }

    @Test func neverOffersAnAttemptedSystem() {
        // `attempted` is `Directive.targets` — append-only history. Without this
        // the operator's Skip is a no-op, and a system that can never report
        // itself finished pins the planner forever.
        let stars = ["HOME": star("HOME", x: 0), "DONE": star("DONE", x: 3)]
        #expect(SalvageTargetPlanner.nextTarget(
            assays: [assay("DONE", body: "DONE-1", units: 100)],
            stars: stars, meshSystems: ["HOME", "DONE"], attempted: ["DONE"],
            vessel: Position(x: 0, y: 0, z: 0)
        ) == nil)
    }

    @Test func breaksEqualRanksOnDesignationSoPlansAreReproducible() {
        let stars = ["HOME": star("HOME", x: 0), "AAA": star("AAA", x: 3), "BBB": star("BBB", x: 3)]
        let target = SalvageTargetPlanner.nextTarget(
            assays: [assay("BBB", body: "BBB-1", units: 100), assay("AAA", body: "AAA-1", units: 100)],
            stars: stars, meshSystems: ["HOME", "AAA", "BBB"], attempted: [],
            vessel: Position(x: 0, y: 0, z: 0)
        )
        #expect(target?.system == "AAA")
    }

    @Test func meshSystemsAreTheOnesHoldingARelayingRelay() {
        // Derived from live device rows, never from `ftlLinks` — an isolated
        // relay produces no link rows at all, so a link-derived set would miss
        // the system this run just meshed.
        let devices = [
            Self.device("R1", features: ["relay"], status: "relaying", location: "TOSLIT-3-L4"),
            Self.device("R2", features: ["relay"], status: "idle", location: "WATTL-1-L4"),
            Self.device("V", features: ["cruise"], status: "idle", location: "TOSLIT-3"),
        ]
        #expect(SalvageTargetPlanner.meshSystems(in: devices) == ["TOSLIT"])
    }

    /// The backend appends a parenthetical parameter to some statuses, so a raw
    /// `status == "relaying"` reads a meshed system as unmeshed — and the run
    /// then spends a 370-unit relay planting a second one where one already
    /// stands. `Device.statusBase` strips the parameter.
    @Test func meshSystemsSeeARelayingStatusCarryingAParameter() {
        let devices = [
            Self.device("R1", features: ["relay"], status: "relaying (TOSLIT)", location: "TOSLIT-3-L4"),
        ]
        #expect(SalvageTargetPlanner.meshSystems(in: devices) == ["TOSLIT"])
    }

    /// A `system_hub` carries the `relay` feature because it contains an
    /// integrated relay, and it genuinely does mesh its system — so matching on
    /// the CAPABILITY rather than the device type is correct here, unlike the
    /// dispatch queries in `SalvageRun` (which must never `deploy` a hub).
    @Test func meshSystemsCountASystemHubsIntegratedRelay() {
        let devices = [
            Self.device("HUB", features: ["relay", "hub"], status: "relaying", location: "WATTL-1"),
        ]
        #expect(SalvageTargetPlanner.meshSystems(in: devices) == ["WATTL"])
    }

    /// A mining assay must never be read as salvage. The table is shared by
    /// design ("mining assays need no schema change when they land"), and the
    /// first one to land would otherwise send a salvage run to a system holding
    /// no salvage at all.
    @Test func ignoresAssaysThatArentSalvage() {
        let stars = ["HOME": star("HOME", x: 0), "ORE": star("ORE", x: 3)]
        var mining = assay("ORE", body: "ORE-1", units: 9_000)
        mining.siteType = "mining"
        #expect(SalvageTargetPlanner.nextTarget(
            assays: [mining], stars: stars, meshSystems: ["HOME"], attempted: [],
            vessel: Position(x: 0, y: 0, z: 0)
        ) == nil)
    }

    /// A drained site's `totals` only ever go up (merge-only-raises), so units
    /// alone can never tell a spent system from a rich one — `depleted` is the
    /// only signal that removes it from ranking. Without the filter this richer
    /// system would win on the second `RankKey` field despite holding nothing.
    @Test func skipsADepletedSystemEvenWhenItRanksRicher() {
        let stars = ["HOME": star("HOME", x: 0), "POOR": star("POOR", x: 3), "RICH": star("RICH", x: 3)]
        let target = SalvageTargetPlanner.nextTarget(
            assays: [assay("RICH", body: "RICH-1", units: 9000, depleted: true),
                     assay("POOR", body: "POOR-1", units: 100)],
            stars: stars, meshSystems: ["HOME", "POOR", "RICH"], attempted: [],
            vessel: Position(x: 0, y: 0, z: 0)
        )
        #expect(target == .init(system: "POOR", units: 100))
    }

    /// A system whose only salvage assay is depleted must never be offered —
    /// not even as a last resort when nothing else is reachable.
    @Test func neverOffersASystemWhoseOnlyAssayIsDepleted() {
        let stars = ["HOME": star("HOME", x: 0), "SPENT": star("SPENT", x: 3)]
        #expect(SalvageTargetPlanner.nextTarget(
            assays: [assay("SPENT", body: "SPENT-1", units: 9000, depleted: true)],
            stars: stars, meshSystems: ["HOME", "SPENT"], attempted: [],
            vessel: Position(x: 0, y: 0, z: 0)
        ) == nil)
    }
}
