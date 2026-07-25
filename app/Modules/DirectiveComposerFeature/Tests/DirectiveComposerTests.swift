//
//  DirectiveComposerTests.swift
//  Replicould — Directive composer feature
//
//  The directive composer's pure core: seeding the draft from the directive in
//  force, building each directive's configuration payload, the per-directive
//  confirm gating, the controller-body fallback chain, and the reducer flow
//  (gather_salvage hydrate on selection; confirm delivers the delegate).
//

import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
import Utils
@testable import DirectiveComposerFeature

/// An AMI controller fixture. `detail` carries the runtime directive vocabulary
/// and, when `current` is set, the in-force `ami_directive` block.
private func controller(
    code: String = "AMI1",
    type: String = "ami_survey_controller",
    directives: [String] = ["survey_system", "belt_search"],
    current: String? = nil,
    config: JSONValue? = nil,
    location: String? = "ATIANFU-3",
    stowedIn: String? = nil,
    controlled: [(code: String, location: String?)] = []
) -> Device {
    var detail: [String: JSONValue] = [
        "available_directives": .array(directives.map(JSONValue.string)),
    ]
    if let current {
        var ami: [String: JSONValue] = ["name": .string(current)]
        if let config { ami["config"] = config }
        detail["ami_directive"] = .object(ami)
    }
    if !controlled.isEmpty {
        detail["controlled_devices"] = .array(controlled.map { entry in
            var fields: [String: JSONValue] = ["device_code": .string(entry.code)]
            if let loc = entry.location { fields["location"] = .string(loc) }
            return .object(fields)
        })
    }
    return Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: "active",
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: stowedIn, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: ["set_directive"],
        features: ["ami"], tags: [],
        detail: .object(detail), updatedAt: Date(timeIntervalSince1970: 1_000),
        firstSeenAt: Date(timeIntervalSince1970: 1_000)
    )
}

/// A plain fleet member at a location, for the controller-body fallback chain.
private func fleetDevice(_ code: String, location: String?) -> Device {
    Device(
        deviceCode: code, deviceType: "heaven_vessel", replicantCode: "R1", status: "idle",
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: [], tags: [],
        detail: .object([:]), updatedAt: Date(timeIntervalSince1970: 1_000),
        firstSeenAt: Date(timeIntervalSince1970: 1_000)
    )
}

/// Build a composer State with the `@FetchAll` dependency satisfied.
private func makeState(device: Device, fleet: [Device] = []) throws -> DirectiveComposer.State {
    try withDependencies {
        $0.defaultDatabase = try GameDatabase.bootstrap()
    } operation: {
        DirectiveComposer.State(device: device, fleet: fleet)
    }
}

@MainActor
@Suite struct DirectiveComposerTests {

    // MARK: Seeding

    /// No directive in force: the picker lands on the first option and every
    /// config field carries its documented default.
    @Test func seedsDefaultsWhenNoDirectiveInForce() throws {
        let state = try makeState(device: controller())
        #expect(state.directive == "survey_system")
        #expect(state.planetsScope == "all")
        #expect(state.moonsScope == "none")
        #expect(state.recall == true)
        #expect(state.salvageLocation.isEmpty)
        #expect(state.collectLocation.isEmpty)
        #expect(state.deliverLocation.isEmpty)
        #expect(state.requirement.isEmpty)
        #expect(state.priorityResources.isEmpty)
    }

    /// A running `survey_system`'s config mirrors into the draft, so re-opening
    /// reflects what's in force.
    @Test func seedsSurveyConfigFromDirectiveInForce() throws {
        let state = try makeState(device: controller(
            current: "survey_system",
            config: .object(["planets": .string("none"), "moons": .string("all"), "recall": .bool(false)])
        ))
        #expect(state.directive == "survey_system")
        #expect(state.planetsScope == "none")
        #expect(state.moonsScope == "all")
        #expect(state.recall == false)
    }

    @Test func seedsSalvageConfigFromDirectiveInForce() throws {
        let state = try makeState(device: controller(
            type: "ami_mining_controller",
            directives: ["gather_salvage"],
            current: "gather_salvage",
            config: .object(["location": .string("ATIANFU-BELT-1"), "recall": .bool(false)])
        ))
        #expect(state.directive == "gather_salvage")
        #expect(state.salvageLocation == "ATIANFU-BELT-1")
        #expect(state.recall == false)
    }

    /// A `delivery`'s nested route + requirement seed the draft; whole-number
    /// amounts round-trip without a trailing ".0".
    @Test func seedsDeliveryConfigFromDirectiveInForce() throws {
        let state = try makeState(device: controller(
            type: "ami_transport_controller",
            directives: ["delivery", "shuttle"],
            current: "delivery",
            config: .object([
                "route": .object(["collect": .string("ATIANFU-BELT-1"), "deliver": .string("ATIANFU-1")]),
                "requirement": .object(["carbon": .number(50), "rares": .number(2.5)]),
            ])
        ))
        #expect(state.directive == "delivery")
        #expect(state.collectLocation == "ATIANFU-BELT-1")
        #expect(state.deliverLocation == "ATIANFU-1")
        #expect(state.requirement == ["carbon": "50", "rares": "2.5"])
    }

    @Test func seedsShuttleConfigFromDirectiveInForce() throws {
        let state = try makeState(device: controller(
            type: "ami_transport_controller",
            directives: ["delivery", "shuttle"],
            current: "shuttle",
            config: .object([
                "collect": .string("ATIANFU-BELT-1"),
                "deliver": .string("ATIANFU-1"),
                "priority": .array([.string("carbon"), .string("rares")]),
            ])
        ))
        #expect(state.directive == "shuttle")
        #expect(state.collectLocation == "ATIANFU-BELT-1")
        #expect(state.deliverLocation == "ATIANFU-1")
        #expect(state.priorityResources == ["carbon", "rares"])
    }

    /// A directive no longer offered by the device falls back to the first
    /// option, and its stale config is NOT seeded.
    @Test func staleDirectiveFallsBackToFirstOptionUnseeded() throws {
        let state = try makeState(device: controller(
            directives: ["survey_system", "belt_search"],
            current: "gather_salvage",
            config: .object(["location": .string("ATIANFU-BELT-1")])
        ))
        #expect(state.directive == "survey_system")
        #expect(state.salvageLocation.isEmpty)
    }

    // MARK: Controller body resolution

    /// The fallback chain: own location → a controlled drone's location → the
    /// stow-parent's location → any same-replicant device with a location.
    @Test func controllerBodyFallsBackThroughTheChain() throws {
        let own = try makeState(device: controller(location: "SHERATANON-7-4"))
        #expect(own.controllerBody == "SHERATANON-7-4")
        #expect(own.controllerSystem == "SHERATANON")

        let viaDrone = try makeState(device: controller(
            location: nil,
            controlled: [("D1", nil), ("D2", "ATIANFU-BELT-1")]
        ))
        #expect(viaDrone.controllerBody == "ATIANFU-BELT-1")
        #expect(viaDrone.controllerSystem == "ATIANFU")

        let viaParent = try makeState(
            device: controller(location: nil, stowedIn: "V1"),
            fleet: [fleetDevice("V1", location: "IZARUM-2")]
        )
        #expect(viaParent.controllerBody == "IZARUM-2")

        let viaFleet = try makeState(
            device: controller(location: nil),
            fleet: [fleetDevice("X1", location: nil), fleetDevice("X2", location: "TARAZEDAR-1")]
        )
        #expect(viaFleet.controllerBody == "TARAZEDAR-1")

        let nowhere = try makeState(device: controller(location: nil))
        #expect(nowhere.controllerBody == nil)
        #expect(nowhere.controllerSystem == nil)
    }

    // MARK: Configuration payloads

    @Test func buildsSurveyConfiguration() throws {
        var state = try makeState(device: controller())
        state.directive = "survey_system"
        state.planetsScope = "all"
        state.moonsScope = "none"
        state.recall = false
        #expect(state.configuration == [
            "planets": .string("all"), "moons": .string("none"), "recall": .bool(false),
        ])
    }

    @Test func buildsSalvageConfiguration() throws {
        var state = try makeState(device: controller())
        state.directive = "gather_salvage"
        state.salvageLocation = "ATIANFU-BELT-1"
        state.recall = true
        #expect(state.configuration == [
            "location": .string("ATIANFU-BELT-1"), "recall": .bool(true),
        ])
    }

    /// `delivery` nests its endpoints under `route`; blank and non-positive
    /// requirement rows are dropped, and an all-dropped requirement is omitted.
    @Test func buildsDeliveryConfigurationDroppingEmptyRequirementRows() throws {
        var state = try makeState(device: controller())
        state.directive = "delivery"
        state.collectLocation = "A-1"
        state.deliverLocation = "B-2"
        state.requirement = ["carbon": "50", "rares": "", "volatiles": "0", "silicates": "junk"]
        #expect(state.configuration == [
            "route": .object(["collect": .string("A-1"), "deliver": .string("B-2")]),
            "requirement": .object(["carbon": .number(50)]),
        ])

        state.requirement = [:]
        #expect(state.configuration == [
            "route": .object(["collect": .string("A-1"), "deliver": .string("B-2")]),
        ])
    }

    /// `shuttle`/`ferry` are flat routes; `priority` appears only when ranked.
    @Test func buildsShuttleConfigurationWithOptionalPriority() throws {
        var state = try makeState(device: controller())
        state.directive = "ferry"
        state.collectLocation = "A-1"
        state.deliverLocation = "B-2"
        #expect(state.configuration == [
            "collect": .string("A-1"), "deliver": .string("B-2"),
        ])

        state.priorityResources = ["carbon"]
        #expect(state.configuration == [
            "collect": .string("A-1"), "deliver": .string("B-2"),
            "priority": .array([.string("carbon")]),
        ])
    }

    @Test func buildsConsolidateConfiguration() throws {
        var state = try makeState(device: controller())
        state.directive = "consolidate"
        state.deliverLocation = "B-2"
        state.priorityResources = ["rares", "carbon"]
        #expect(state.configuration == [
            "deliver": .string("B-2"),
            "priority": .array([.string("rares"), .string("carbon")]),
        ])
    }

    /// Directives without configuration (belt_search, patrol) send none.
    @Test func unconfiguredDirectivesHaveNilConfiguration() throws {
        var state = try makeState(device: controller())
        state.directive = "belt_search"
        #expect(state.configuration == nil)
        state.directive = "patrol"
        #expect(state.configuration == nil)
    }

    // MARK: Confirm gating

    /// Directives with required config the backend rejects without gate the
    /// confirm; the rest are always ready.
    @Test func confirmGatesOnRequiredConfiguration() throws {
        var state = try makeState(device: controller())

        state.directive = "belt_search"
        #expect(state.isConfirmable)

        state.directive = "gather_salvage"
        state.salvageLocation = ""
        #expect(!state.isConfirmable)
        state.salvageLocation = "ATIANFU-BELT-1"
        #expect(state.isConfirmable)

        state.directive = "delivery"
        state.collectLocation = "A-1"
        state.deliverLocation = "B-2"
        state.requirement = [:]
        #expect(!state.isConfirmable)
        state.requirement = ["carbon": "50"]
        #expect(state.isConfirmable)

        state.directive = "shuttle"
        state.collectLocation = ""
        #expect(!state.isConfirmable)
        state.collectLocation = "A-1"
        #expect(state.isConfirmable)

        state.directive = "consolidate"
        state.deliverLocation = ""
        #expect(!state.isConfirmable)
        state.deliverLocation = "B-2"
        #expect(state.isConfirmable)
    }

    // MARK: Reducer flow

    /// Picking `gather_salvage` kicks off a hydrate of the controller's
    /// operating system so the salvage picker can fill from the local catalog.
    @Test func selectingGatherSalvageHydratesTheControllersSystem() async throws {
        let requested = LockIsolated<[String]>([])
        let db = try GameDatabase.bootstrap()
        let store = TestStore(
            initialState: DirectiveComposer.State(
                device: controller(directives: ["survey_system", "gather_salvage"], location: "ATIANFU-3"),
                fleet: []
            )
        ) {
            DirectiveComposer()
        } withDependencies: {
            $0.defaultDatabase = db
            $0.date = .constant(Date(timeIntervalSince1970: 2_000))  // hydrateBody stamps hydratedAt
            // `hydrateBody` reads the cached system, then falls back to the
            // star-level fetch; recording `system` proves the hydrate ran.
            $0.locationsClient.system = { designation in
                requested.withValue { $0.append(designation) }
                throw LocationsError.notFound
            }
        }

        await store.send(.binding(.set(\.directive, "gather_salvage"))) {
            $0.directive = "gather_salvage"
        }
        await store.finish()
        #expect(requested.value == ["ATIANFU"])
    }

    /// Confirm hands the picked directive + built configuration to the parent
    /// via the delegate, then dismisses itself.
    @Test func confirmDeliversDelegateWithConfiguration() async throws {
        let dismissed = LockIsolated(false)
        let db = try GameDatabase.bootstrap()
        let store = TestStore(
            initialState: DirectiveComposer.State(device: controller(), fleet: [])
        ) {
            DirectiveComposer()
        } withDependencies: {
            $0.defaultDatabase = db
            $0.dismiss = DismissEffect { dismissed.setValue(true) }
        }

        await store.send(.confirmTapped)
        await store.receive(\.delegate.confirmed)
        await store.finish()
        #expect(dismissed.value == true)
    }

    /// Cancel dismisses the sheet without delivering any delegate.
    @Test func cancelDismissesWithoutDelegate() async throws {
        let database = try GameDatabase.bootstrap()
        let dismissed = LockIsolated(false)
        let store = TestStore(
            initialState: DirectiveComposer.State(device: controller(), fleet: [])
        ) {
            DirectiveComposer()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.dismiss = DismissEffect { dismissed.setValue(true) }
        }

        await store.send(.cancelTapped)   // no delegate received
        await store.finish()
        #expect(dismissed.value == true)
    }

    /// A non-confirmable draft ignores the confirm tap entirely.
    @Test func confirmIsIgnoredWhileGatedConfigIsIncomplete() async throws {
        var state = try makeState(device: controller(directives: ["gather_salvage"]))
        state.salvageLocation = ""

        let db = try GameDatabase.bootstrap()
        let store = TestStore(
            initialState: state
        ) {
            DirectiveComposer()
        } withDependencies: {
            $0.defaultDatabase = db
        }

        await store.send(.confirmTapped)   // no delegate, no dismissal
        await store.finish()
    }

    /// Priority chips toggle: tapping appends at the end; tapping again removes
    /// and the remaining ranks close up.
    @Test func priorityTogglesAppendAndRemove() async throws {
        let db = try GameDatabase.bootstrap()
        let store = TestStore(
            initialState: DirectiveComposer.State(device: controller(), fleet: [])
        ) {
            DirectiveComposer()
        } withDependencies: {
            $0.defaultDatabase = db
        }

        await store.send(.priorityToggled("carbon")) { $0.priorityResources = ["carbon"] }
        await store.send(.priorityToggled("rares")) { $0.priorityResources = ["carbon", "rares"] }
        await store.send(.priorityToggled("carbon")) { $0.priorityResources = ["rares"] }
    }
}
