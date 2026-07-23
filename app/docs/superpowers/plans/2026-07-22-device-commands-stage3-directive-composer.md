# Device Commands Stage 3 — DirectiveComposer Sheet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the ~470-line inline directive editor out of `CommandGrid` into a sheet-presented `DirectiveComposer` feature (its own TCA reducer), flipping the Directive command inline→sheet per the approved presentation rule (live-data/heavy-form → sheet).

**Architecture:** `DirectiveComposer` is a child feature presented from `DevicesFeature` via the house `@Presents`/`.ifLet` dialect (the feature-sheet tier of the presentation dialect — see `ReplicantsFeature`/`ReplicantEditFeature`). All directive draft state, validation, and payload building move off the SwiftUI view into the reducer's `State` (testable; avoids the SwiftUI-View-statics test trap). The `gather_salvage` catalog hydrate moves from `DevicesFeature.salvageSitesRequested` into the composer, so `.ifLet`'s automatic child-effect cancellation cancels it on dismissal. `CommandGrid` shrinks to grid + inline light-param panels; the Directive button opens the sheet directly (like Load Cargo).

**Tech Stack:** Swift / SwiftUI (macOS 26), TCA (`@Reducer`, `@ObservableState`, `@Presents`, `@Dependency(\.dismiss)`), SQLiteData `@FetchAll`, Swift Testing.

## Global Constraints

- Existing directives only (`survey_system`, `belt_search`, `gather_salvage`, `delivery`, `shuttle`, `ferry`, `consolidate`, `patrol`) — no new command verbs (Stage 4's job).
- Design tokens only — `Space.*`, `Radius.*`, `Hairline.thin`, `.rc*` colors/fonts, `IconSize.*`. Never hard-code colors/spacing/sizes.
- Feature-sheet presentation dialect: `@Presents` optional child state + `case directiveComposer(PresentationAction<…>)` + `.ifLet` + `.sheet(item: $store.scope(…))` — NOT `.sheet(isPresented:)`, NOT a plain-value item binding (that dialect is for value sheets like TravelPreview).
- Dismissal must cancel the composer's in-flight effects — satisfied structurally by `.ifLet` (child effects are torn down on dismiss); do not add manual cancel plumbing in the parent.
- Pure logic (seeding, validation, payload building) lives on `DirectiveComposer.State` / static helpers — never as statics on a SwiftUI `View` (swift-test signal-5 trap).
- House header comment style: `//` / filename / `Replicould — Devices feature` / blank / one-paragraph purpose note.
- New files inside an existing SPM target need no `Package.swift` or pbxproj edits.
- Commits: direct to the worktree branch, message style matches `git log`, trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Run builds/tests from `app/Modules/`. For tests always use `swift test --filter <Suite> --event-stream-output-path <tmpfile>` and read pass/fail from the JSON event stream with `jq` — never grep console text.
- **Swift-LSP protocol:** use SourceKit-LSP (`documentSymbol`, `goToDefinition`, `findReferences`) to verify symbols and references before signing off; LSP root is `Modules/`. If the index won't answer for this worktree path (fresh worktrees sometimes need a session relaunch), fall back to targeted Read/grep deliberately and say so in your report.

## Reference — current code being moved

The directive editor being extracted lives in `app/Modules/DevicesFeature/Sources/CommandGrid.swift` (lines cited from the Stage 2 tip, commit `7c1ca84`): draft `@State` vars (lines 39–55), `SurveyScope` (58), `controllerBody`/`controllerSystem`/`salvageBodies` (64–92), `prepareDirective` (292–298), `seedDirectiveConfig` (304–341), `amountString` (345–347), `directiveConfig(for:)` (505–551), `requirementPayload` (555–560), `directiveConfiguration` and all config subviews (564–822), and the `set_directive` branches of `select`, `parameterPanel`, `params(for:)`, `isConfirmable`. Task 1 re-homes the logic, Task 2 the UI, Task 3 deletes the originals.

---

### Task 1: `DirectiveComposer` reducer + tests

**Files:**
- Create: `app/Modules/DevicesFeature/Sources/DirectiveComposer.swift`
- Test: `app/Modules/DevicesFeature/Tests/DirectiveComposerTests.swift`

**Interfaces:**
- Consumes: `Device` (`availableDirectives`, `currentDirective`, `currentDirectiveConfig`, `controlledDevices`, `stowedInDeviceCode`, `replicantCode`, `location`), `SystemDetail`/`SalvageBody` (UniverseModels), `LocationsClient.hydrateBody(systemDesignation:bodyDesignation:)`, `JSONValue` (Utils), `DeviceCommand.miningResources`.
- Produces (Task 2 relies on these exact names): `DirectiveComposer.State.init(device: Device, fleet: [Device])`, `state.deviceCode: String`, `state.availableDirectives: [String]`, `state.directive: String`, `state.salvageBodies: [SalvageBody]`, `state.isConfirmable: Bool`, `Action.task`, `Action.priorityToggled(String)`, `Action.confirmTapped`, `Action.cancelTapped`, `Action.delegate(.confirmed(directive: String, configuration: [String: JSONValue]?))`, plus bindable draft fields `planetsScope`, `moonsScope`, `recall`, `salvageLocation`, `collectLocation`, `deliverLocation`, `requirement: [String: String]`, `priorityResources: [String]`, and `enum SurveyScope { static let all, none }`.

- [ ] **Step 1: Write the reducer**

Create `app/Modules/DevicesFeature/Sources/DirectiveComposer.swift` with exactly this content:

```swift
//
//  DirectiveComposer.swift
//  Replicould — Devices feature
//
//  The `set_directive` editor, presented as a sheet from the device inspector
//  (per the presentation rule: live-data / heavy-form commands get a sheet).
//  Seeds its draft from the directive currently in force, validates the
//  configuration the backend requires per directive, and hands the confirmed
//  directive + configuration back to `DevicesFeature` through its delegate.
//  Selecting `gather_salvage` hydrates the controller's system into the local
//  locations catalog so the salvage-body picker can fill; dismissing the sheet
//  cancels that in-flight hydrate (the `.ifLet` presentation tears down child
//  effects automatically).
//

import ComposableArchitecture
import Foundation
import GameModels
import GameServices
import SQLiteData
import UniverseModels
import Utils

@Reducer
public struct DirectiveComposer {
    /// The `all` / `none` scope values the survey config dropdowns offer.
    enum SurveyScope { static let all = "all", none = "none" }

    @ObservableState
    public struct State: Equatable {
        public let deviceCode: String
        /// The directives this device may be set to — the picker's options.
        public let availableDirectives: [String]
        /// The controller's operating body and its star system, resolved from
        /// the fleet at presentation time (see `controllerBody(of:fleet:)`).
        /// Drive the `gather_salvage` hydrate + salvage-body picker.
        public let controllerSystem: String?
        public let controllerBody: String?

        /// The picked directive.
        public var directive: String
        /// `survey_system` configuration.
        public var planetsScope: String
        public var moonsScope: String
        public var recall: Bool
        /// `gather_salvage` configuration: the chosen salvage-body designation.
        public var salvageLocation: String
        /// AMI transport-controller directive configuration (`delivery` /
        /// `shuttle` / `ferry` / `consolidate`). `collect`/`deliver` are
        /// location designations; `requirement` is the per-resource target for
        /// a one-shot `delivery` (kept as entered text until payload-building);
        /// `priorityResources` is the ordered resource preference for the
        /// continuous directives.
        public var collectLocation: String
        public var deliverLocation: String
        public var requirement: [String: String]
        public var priorityResources: [String]

        /// The local locations catalog, source of the `gather_salvage` body
        /// picker. One blob per explored system; the controller's system is
        /// decoded on demand.
        @ObservationStateIgnored
        @FetchAll(SystemDetail.all) public var systemDetails: [SystemDetail]

        /// Seed the draft for a device: the picker lands on the directive in
        /// force when it's still offered (falling back to the first option),
        /// and that directive's configuration form mirrors what's running.
        /// Documented defaults otherwise (survey planets: all, moons: none,
        /// recall: on).
        public init(device: Device, fleet: [Device]) {
            deviceCode = device.deviceCode
            availableDirectives = device.availableDirectives
            let body = Self.controllerBody(of: device, fleet: fleet)
            controllerBody = body
            controllerSystem = Self.system(of: body)

            let options = device.availableDirectives
            if let current = device.currentDirective, options.contains(current) {
                directive = current
            } else {
                directive = options.first ?? ""
            }

            planetsScope = SurveyScope.all
            moonsScope = SurveyScope.none
            recall = true
            salvageLocation = ""
            collectLocation = ""
            deliverLocation = ""
            requirement = [:]
            priorityResources = []

            guard device.currentDirective == directive,
                  let config = device.currentDirectiveConfig
            else { return }
            switch directive {
            case "survey_system":
                planetsScope = config["planets"]?.stringValue ?? planetsScope
                moonsScope = config["moons"]?.stringValue ?? moonsScope
                recall = config["recall"]?.boolValue ?? recall
            case "gather_salvage":
                salvageLocation = config["location"]?.stringValue ?? ""
                recall = config["recall"]?.boolValue ?? recall
            case "delivery":
                // The backend nests a one-shot delivery's endpoints under `route`.
                collectLocation = config["route"]?["collect"]?.stringValue ?? ""
                deliverLocation = config["route"]?["deliver"]?.stringValue ?? ""
                if case let .object(target)? = config["requirement"] {
                    requirement = target.reduce(into: [:]) { acc, pair in
                        if let amount = pair.value.numberValue { acc[pair.key] = Self.amountString(amount) }
                    }
                }
            case "shuttle", "ferry":
                collectLocation = config["collect"]?.stringValue ?? ""
                deliverLocation = config["deliver"]?.stringValue ?? ""
                priorityResources = config["priority"]?.arrayValue?.compactMap(\.stringValue) ?? []
            case "consolidate":
                deliverLocation = config["deliver"]?.stringValue ?? ""
                priorityResources = config["priority"]?.arrayValue?.compactMap(\.stringValue) ?? []
            default:
                break
            }
        }

        /// The body the controller operates at — where its salvage drones are.
        /// A stowed controller carries no location of its own, so fall back to
        /// a controlled drone, then the stow-parent vessel, then any
        /// same-replicant device that reports a location.
        static func controllerBody(of device: Device, fleet: [Device]) -> String? {
            if let loc = device.location, !loc.isEmpty { return loc }
            if let loc = device.controlledDevices.compactMap(\.location).first(where: { !$0.isEmpty }) { return loc }
            if let parent = device.stowedInDeviceCode,
               let loc = fleet.first(where: { $0.deviceCode == parent })?.location, !loc.isEmpty { return loc }
            return fleet.first { $0.replicantCode == device.replicantCode && ($0.location?.isEmpty == false) }?.location
        }

        /// A body's star system designation — the leading segment of its
        /// designation code (e.g. "SHERATANON-7-4" → "SHERATANON").
        static func system(of body: String?) -> String? {
            guard let body else { return nil }
            let system = String(body.split(separator: "-").first ?? "")
            return system.isEmpty ? nil : system
        }

        /// Salvage-bearing bodies in the controller's system, read from the
        /// local catalog. `gather_salvage` targets a body (working every site
        /// on it), so the picker offers bodies, not individual sites. Empty
        /// until the system is hydrated; depleted bodies drop out (stream
        /// depletion events keep this current — see LocationsClient.markSalvage*).
        public var salvageBodies: [SalvageBody] {
            guard
                let system = controllerSystem,
                let row = systemDetails.first(where: { $0.designation == system }),
                let starSystem = try? row.system()
            else { return [] }
            return starSystem.salvageBodies
        }

        /// Whether Set Directive may fire. Some directives carry required
        /// configuration the backend rejects without: `gather_salvage` needs a
        /// body, the transport routes need their endpoints, and a one-shot
        /// `delivery` additionally needs at least one resource target.
        public var isConfirmable: Bool {
            switch directive {
            case "gather_salvage":
                return !salvageLocation.isEmpty
            case "delivery":
                return !collectLocation.isEmpty && !deliverLocation.isEmpty && !requirementPayload.isEmpty
            case "shuttle", "ferry":
                return !collectLocation.isEmpty && !deliverLocation.isEmpty
            case "consolidate":
                return !deliverLocation.isEmpty
            default:
                return !directive.isEmpty
            }
        }

        /// The configuration object for the picked directive, or nil for
        /// directives that take none (belt_search, patrol, and the rest).
        public var configuration: [String: JSONValue]? {
            switch directive {
            case "survey_system":
                return [
                    "planets": .string(planetsScope),
                    "moons": .string(moonsScope),
                    "recall": .bool(recall),
                ]
            case "gather_salvage":
                return [
                    "location": .string(salvageLocation),
                    "recall": .bool(recall),
                ]
            case "delivery":
                // A one-shot transfer: endpoints nest under `route`, and the
                // per-resource `requirement` defines when the run is complete.
                var config: [String: JSONValue] = [
                    "route": .object([
                        "collect": .string(collectLocation),
                        "deliver": .string(deliverLocation),
                    ]),
                ]
                let target = requirementPayload
                if !target.isEmpty { config["requirement"] = .object(target) }
                return config
            case "shuttle", "ferry":
                // Continuous in-system (shuttle) / interstellar (ferry)
                // transport: flat endpoints with an optional ordered resource
                // `priority`.
                var config: [String: JSONValue] = [
                    "collect": .string(collectLocation),
                    "deliver": .string(deliverLocation),
                ]
                if !priorityResources.isEmpty {
                    config["priority"] = .array(priorityResources.map(JSONValue.string))
                }
                return config
            case "consolidate":
                // Gather dispersed system resources to a single destination.
                var config: [String: JSONValue] = ["deliver": .string(deliverLocation)]
                if !priorityResources.isEmpty {
                    config["priority"] = .array(priorityResources.map(JSONValue.string))
                }
                return config
            default:
                return nil
            }
        }

        /// The `delivery` requirement object: the resources with a positive
        /// amount, keyed by resource type. Blank or non-positive rows are dropped.
        var requirementPayload: [String: JSONValue] {
            requirement.reduce(into: [:]) { acc, pair in
                let trimmed = pair.value.trimmingCharacters(in: .whitespaces)
                if let amount = Double(trimmed), amount > 0 { acc[pair.key] = .number(amount) }
            }
        }

        /// Render a requirement amount without a trailing `.0` so a whole
        /// number round-trips as "50" rather than "50.0".
        static func amountString(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(value)
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        /// The sheet appeared — hydrate if the seeded selection needs the
        /// local catalog filled.
        case task
        /// Toggle a resource in the ordered priority list, appending it at the
        /// end (lowest current rank) or removing it.
        case priorityToggled(String)
        case confirmTapped
        case cancelTapped
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case confirmed(directive: String, configuration: [String: JSONValue]?)
        }
    }

    @Dependency(\.locationsClient) var locationsClient
    @Dependency(\.dismiss) var dismiss

    public init() {}

    private enum CancelID { case hydrate }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding(\.directive):
                return hydrateIfNeeded(&state)

            case .binding:
                return .none

            case .task:
                return hydrateIfNeeded(&state)

            case let .priorityToggled(resource):
                if let index = state.priorityResources.firstIndex(of: resource) {
                    state.priorityResources.remove(at: index)
                } else {
                    state.priorityResources.append(resource)
                }
                return .none

            case .confirmTapped:
                guard state.isConfirmable else { return .none }
                let directive = state.directive
                let configuration = state.configuration
                let dismiss = self.dismiss
                return .run { send in
                    await send(.delegate(.confirmed(directive: directive, configuration: configuration)))
                    await dismiss()
                }

            case .cancelTapped:
                let dismiss = self.dismiss
                return .run { _ in await dismiss() }

            case .delegate:
                return .none
            }
        }
    }

    /// When `gather_salvage` is (or becomes) the selection: seed the picker
    /// with the first known body and kick off a hydrate of the controller's
    /// system so the salvage-body dropdown fills from the local catalog.
    /// Best-effort — an unreadable system just leaves the dropdown empty with
    /// its "scan the system" hint. A re-selection cancels the prior in-flight
    /// hydrate rather than stacking a duplicate.
    private func hydrateIfNeeded(_ state: inout State) -> Effect<Action> {
        guard state.directive == "gather_salvage" else { return .none }
        if state.salvageLocation.isEmpty {
            state.salvageLocation = state.salvageBodies.first?.designation ?? ""
        }
        guard let system = state.controllerSystem, let body = state.controllerBody else { return .none }
        let locationsClient = self.locationsClient
        return .run { _ in
            try? await locationsClient.hydrateBody(systemDesignation: system, bodyDesignation: body)
        }
        .cancellable(id: CancelID.hydrate, cancelInFlight: true)
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `app/Modules/DevicesFeature/Tests/DirectiveComposerTests.swift` with exactly this content:

```swift
//
//  DirectiveComposerTests.swift
//  Replicould — Devices feature
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
@testable import DevicesFeature

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
        let store = TestStore(
            initialState: DirectiveComposer.State(
                device: controller(directives: ["survey_system", "gather_salvage"], location: "ATIANFU-3"),
                fleet: []
            )
        ) {
            DirectiveComposer()
        } withDependencies: {
            $0.defaultDatabase = try GameDatabase.bootstrap()
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
        let store = TestStore(
            initialState: DirectiveComposer.State(device: controller(), fleet: [])
        ) {
            DirectiveComposer()
        } withDependencies: {
            $0.defaultDatabase = try GameDatabase.bootstrap()
            $0.dismiss = DismissEffect { dismissed.setValue(true) }
        }

        await store.send(.confirmTapped)
        await store.receive(\.delegate.confirmed) 
        await store.finish()
        #expect(dismissed.value == true)
    }

    /// A non-confirmable draft ignores the confirm tap entirely.
    @Test func confirmIsIgnoredWhileGatedConfigIsIncomplete() async throws {
        let store = TestStore(
            initialState: {
                var state = try makeState(device: controller(directives: ["gather_salvage"]))
                state.salvageLocation = ""
                return state
            }()
        ) {
            DirectiveComposer()
        } withDependencies: {
            $0.defaultDatabase = try GameDatabase.bootstrap()
        }

        await store.send(.confirmTapped)   // no delegate, no dismissal
        await store.finish()
    }

    /// Priority chips toggle: tapping appends at the end; tapping again removes
    /// and the remaining ranks close up.
    @Test func priorityTogglesAppendAndRemove() async throws {
        let store = TestStore(
            initialState: DirectiveComposer.State(device: controller(), fleet: [])
        ) {
            DirectiveComposer()
        } withDependencies: {
            $0.defaultDatabase = try GameDatabase.bootstrap()
        }

        await store.send(.priorityToggled("carbon")) { $0.priorityResources = ["carbon"] }
        await store.send(.priorityToggled("rares")) { $0.priorityResources = ["carbon", "rares"] }
        await store.send(.priorityToggled("carbon")) { $0.priorityResources = ["rares"] }
    }
}
```

Note on `confirmIsIgnoredWhileGatedConfigIsIncomplete`: `makeState` is `try`-throwing inside an immediately-invoked closure — if the compiler rejects the `try` inside the closure literal passed to `TestStore(initialState:)`, hoist it: `let state: DirectiveComposer.State = try withDependencies {...} operation: {...}; state.salvageLocation = ""` (var) then pass `state`. Keep the database dependency in `withDependencies` for the TestStore too (State copies re-evaluate `@FetchAll` lazily).

Note on `confirmDeliversDelegateWithConfiguration`: if `DismissEffect { ... }` isn't constructible that way in this TCA version, use `$0.dismiss = DismissEffect { dismissed.setValue(true) }` as written first; the fallback assertion is to drop the `dismissed` check and assert only the delegate receive (the dismissal path is exercised by TCA itself).

- [ ] **Step 3: Run the new suite — expect it to fail to compile before the source file exists, then pass**

If you wrote the source first (Step 1), just run the suite. From `app/Modules/`:

```bash
swift build 2>&1 | tail -5
EVENTS=$(mktemp)
swift test --filter DirectiveComposerTests --event-stream-output-path "$EVENTS" 2>&1 | tail -3
jq -r 'select(.kind=="event") | select(.payload.kind=="testCaseEnded" or .payload.kind=="issueRecorded") | [.payload.kind, (.payload.testID // .payload.test.id // "")] | @tsv' "$EVENTS" | sort | uniq -c
```

Expected: build clean; every `testCaseEnded` present, zero `issueRecorded`.

Also run the neighbors to prove no regression:

```bash
EVENTS2=$(mktemp)
swift test --filter DevicesFeatureTests --event-stream-output-path "$EVENTS2" >/dev/null 2>&1
jq -r 'select(.kind=="event") | select(.payload.kind=="issueRecorded")' "$EVENTS2" | wc -l   # expect 0
```

- [ ] **Step 4: Commit**

```bash
git add Modules/DevicesFeature/Sources/DirectiveComposer.swift Modules/DevicesFeature/Tests/DirectiveComposerTests.swift
git commit -m "Add DirectiveComposer: the set_directive editor as a TCA feature (Stage 3)

The inline directive editor's state, seeding, validation, and payload
building re-homed from CommandGrid's view into a presentable reducer.
The gather_salvage catalog hydrate lives here now, so dismissing the
sheet cancels it structurally (.ifLet teardown). UI lands next.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

(Adjust `git add` paths if running from the repo root: prefix `app/`.)

---

### Task 2: `DirectiveComposerSheet` + presentation wiring

**Files:**
- Create: `app/Modules/DevicesFeature/Sources/DirectiveComposerSheet.swift`
- Modify: `app/Modules/DevicesFeature/Sources/DevicesFeature.swift` (state, actions, reducer, `.ifLet`)
- Modify: `app/Modules/DevicesFeature/Sources/DeviceDetailView.swift` (`@Bindable`, `.sheet`)
- Modify: `app/Modules/DevicesFeature/Sources/CommandGrid.swift` (`select(_:)` interception only)
- Test: extend `app/Modules/DevicesFeature/Tests/DevicesFeatureTests.swift`

**Interfaces:**
- Consumes (from Task 1): `DirectiveComposer.State.init(device:fleet:)`, `Action.delegate(.confirmed(directive:configuration:))`, `state.deviceCode`, `state.isConfirmable`, `state.salvageBodies`, bindable draft fields, `Action.task` / `.priorityToggled` / `.confirmTapped` / `.cancelTapped`, `DirectiveComposer.SurveyScope`.
- Produces: `DevicesFeature.Action.directiveComposeTapped` (what CommandGrid sends), `DevicesFeature.Action.directiveComposerPresented`, `DevicesFeature.Action.directiveComposer(PresentationAction<DirectiveComposer.Action>)`, `DevicesFeature.State.directiveComposer: DirectiveComposer.State?` (`@Presents`), view `DirectiveComposerSheet(store:)`.

- [ ] **Step 1: Write the sheet view**

Create `app/Modules/DevicesFeature/Sources/DirectiveComposerSheet.swift` with exactly this content (the config subviews are the ones removed from `CommandGrid` in Task 3, rebased onto store bindings):

```swift
//
//  DirectiveComposerSheet.swift
//  Replicould — Devices feature
//
//  The `set_directive` composer sheet: a directive picker plus the selected
//  directive's configuration form (survey scopes, the salvage-body picker fed
//  by the local locations catalog, the transport routes with their requirement
//  and priority editors). Mirrors the inspector's other sheets' chrome
//  (header · divider · content · trailing footer) and drives a presented
//  `DirectiveComposer` store — confirm and cancel are reducer intents, so the
//  view stays a pure renderer.
//

import ComposableArchitecture
import SwiftUI
import UI
import UniverseModels

struct DirectiveComposerSheet: View {
    @Bindable var store: StoreOf<DirectiveComposer>

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            header
            Divider().overlay(Color.rcSeparator)
            directivePicker
            configuration(store.directive)
            footer
        }
        .padding(Space.xl)
        .frame(width: 460)
        .background(Color.rcContentBackground)
        .task { store.send(.task) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: IconSize.l, weight: .medium))
                .foregroundStyle(.rcAccent)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Set Directive")
                    .font(.rcTitle)
                    .foregroundStyle(.rcTextPrimary)
                Text(store.deviceCode)
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Directive picker

    private var directivePicker: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Directive".uppercased())
                .font(.rcSectionLabel)
                .foregroundStyle(.rcTextTertiary)
            RCValueSelect(
                "Directive",
                options: store.availableDirectives.map {
                    (label: DevicePresentation.displayName($0), value: $0)
                },
                selection: $store.directive
            )
        }
    }

    // MARK: Per-directive configuration

    /// Configuration controls for a configurable directive. Empty for
    /// directives that carry no configuration (belt_search, patrol, …).
    @ViewBuilder
    private func configuration(_ directive: String) -> some View {
        switch directive {
        case "survey_system":
            VStack(alignment: .leading, spacing: Space.s) {
                configField("Planets", selection: $store.planetsScope)
                configField("Moons", selection: $store.moonsScope)
                recallToggle
            }
            .padding(.top, Space.xs)
        case "gather_salvage":
            salvageConfiguration
        case "delivery":
            deliveryConfiguration
        case "shuttle":
            transportRouteConfiguration(interstellar: false)
        case "ferry":
            transportRouteConfiguration(interstellar: true)
        case "consolidate":
            consolidateConfiguration
        default:
            EmptyView()
        }
    }

    /// The shared "Recall when complete" switch (survey + salvage).
    private var recallToggle: some View {
        Toggle(isOn: $store.recall) {
            Text("Recall when complete")
                .font(.rcCaption)
                .foregroundStyle(.rcTextSecondary)
        }
        .toggleStyle(.switch)
        .tint(.rcAccent)
    }

    /// A labeled all/none scope dropdown for a survey config field.
    private func configField(_ label: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label.uppercased())
                .font(.rcSectionLabel)
                .foregroundStyle(.rcTextTertiary)
            RCValueSelect(
                label,
                options: [DirectiveComposer.SurveyScope.all, DirectiveComposer.SurveyScope.none],
                selection: selection
            )
        }
    }

    /// The `gather_salvage` config: a required salvage-body picker (sourced
    /// from the controller's system in the local catalog) plus the recall
    /// toggle. The directive targets a body — its drones work every salvage
    /// site there — so the picker offers bodies. The backend rejects the
    /// directive without a `location`, so confirm stays disabled until a body
    /// is chosen.
    @ViewBuilder
    private var salvageConfiguration: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xs) {
                RCSectionHeader("Salvage Location")
                if store.salvageBodies.isEmpty {
                    Text("No known salvage in this system yet. Scan its bodies in Locations to reveal them.")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                } else {
                    RCValueSelect(
                        "Salvage Location",
                        options: store.salvageBodies.map {
                            (label: salvageBodyLabel($0), value: $0.designation)
                        },
                        selection: $store.salvageLocation
                    )
                }
            }
            recallToggle
        }
        .padding(.top, Space.xs)
        // Auto-select the first body once the catalog hydrates, unless one is
        // already chosen (kept selection or a seeded running directive).
        .onChange(of: store.salvageBodies.map(\.id)) { _, _ in
            if store.salvageLocation.isEmpty {
                store.salvageLocation = store.salvageBodies.first?.designation ?? ""
            }
        }
    }

    /// A salvage body's dropdown label — its name/designation, annotated with
    /// the site count when it holds more than one (the drones work them all).
    private func salvageBodyLabel(_ body: SalvageBody) -> String {
        body.siteCount > 1 ? "\(body.displayName) · \(body.siteCount) sites" : body.displayName
    }

    /// The `delivery` config: a one-shot collect → deliver route plus the
    /// per-resource target that defines when the run is complete. The backend
    /// rejects the directive without a requirement, so confirm stays disabled
    /// until both endpoints and at least one amount are set.
    @ViewBuilder
    private var deliveryConfiguration: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            RCField("Collect From", text: $store.collectLocation, placeholder: "ATIANFU-BELT-1", mono: true)
            RCField("Deliver To", text: $store.deliverLocation, placeholder: "ALPHERATOZ-8-L4", mono: true)
            requirementEditor
        }
        .padding(.top, Space.xs)
    }

    /// The `shuttle` (in-system) / `ferry` (interstellar) config: a continuous
    /// collect → deliver route with an optional ordered resource priority.
    @ViewBuilder
    private func transportRouteConfiguration(interstellar: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            RCField(
                "Collect From",
                text: $store.collectLocation,
                placeholder: interstellar ? "TARAZEDAR-BELT-1" : "ATIANFU-BELT-1",
                hint: interstellar ? "source system" : nil,
                mono: true
            )
            RCField(
                "Deliver To",
                text: $store.deliverLocation,
                placeholder: "ALPHERATOZ-8-L4",
                hint: interstellar ? "destination system" : nil,
                mono: true
            )
            priorityEditor
        }
        .padding(.top, Space.xs)
    }

    /// The `consolidate` config: a single destination that dispersed system
    /// resources are gathered to, with an optional ordered resource priority.
    @ViewBuilder
    private var consolidateConfiguration: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            RCField("Deliver To", text: $store.deliverLocation, placeholder: "ALPHERATOZ-8-L4", mono: true)
            priorityEditor
        }
        .padding(.top, Space.xs)
    }

    // MARK: Requirement editor (delivery)

    /// The `delivery` requirement editor: one numeric field per resource type.
    /// Only resources with a positive amount are sent; together they define
    /// the quota that completes the one-shot run.
    @ViewBuilder
    private var requirementEditor: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            RCSectionHeader("Requirement")
            Text("Amounts to deliver before the run completes.")
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
            VStack(spacing: 0) {
                ForEach(Array(DeviceCommand.miningResources.enumerated()), id: \.element) { index, resource in
                    if index > 0 { Divider().overlay(Color.rcSeparator) }
                    requirementRow(resource)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(.rcSurfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(.rcSeparator, lineWidth: 1)
                    )
            )
        }
    }

    /// One requirement row — a resource label and a trailing numeric field.
    private func requirementRow(_ resource: String) -> some View {
        HStack(spacing: Space.s) {
            Text(resource.capitalized)
                .font(.rcCaption)
                .foregroundStyle(.rcTextSecondary)
            Spacer(minLength: 0)
            TextField("0", text: requirementBinding(resource))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.rcMonoSmall)
                .frame(width: 56)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
    }

    /// A string binding into the `requirement` map for a resource, so an empty
    /// field clears the entry rather than leaving a stale amount. Writes go
    /// through the bindable store, so the reducer owns the map.
    private func requirementBinding(_ resource: String) -> Binding<String> {
        Binding(
            get: { store.requirement[resource] ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                var updated = store.requirement
                if trimmed.isEmpty { updated[resource] = nil } else { updated[resource] = trimmed }
                store.requirement = updated
            }
        )
    }

    // MARK: Priority editor (shuttle / ferry / consolidate)

    /// The ordered resource-priority editor for the continuous transport
    /// directives. Tapping a resource appends it (its badge shows the rank);
    /// tapping again removes it and the remaining ranks close up. Empty means
    /// "balance everything".
    @ViewBuilder
    private var priorityEditor: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            RCSectionHeader("Priority")
            Text("Tap to rank resources in order. Leave empty to balance all.")
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 96), spacing: Space.xs)],
                spacing: Space.xs
            ) {
                ForEach(DeviceCommand.miningResources, id: \.self) { resource in
                    priorityChip(resource)
                }
            }
        }
    }

    /// A single priority chip: accent-filled with its rank number when
    /// selected, a bordered surface otherwise.
    private func priorityChip(_ resource: String) -> some View {
        let rank = store.priorityResources.firstIndex(of: resource)
        let selected = rank != nil
        return Button {
            store.send(.priorityToggled(resource))
        } label: {
            HStack(spacing: Space.xs) {
                if let rank {
                    Text("\(rank + 1)")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcAccentOnColor)
                }
                Text(resource.capitalized)
                    .font(.rcCaption)
                    .lineLimit(1)
                    .foregroundStyle(selected ? .rcAccentOnColor : .rcTextSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.xs)
            .padding(.horizontal, Space.s)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(selected ? Color.rcAccent : Color.rcSurfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(selected ? Color.clear : Color.rcSeparator, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Space.s) {
            Spacer()
            Button("Cancel") { store.send(.cancelTapped) }
                .buttonStyle(RCButtonStyle(.secondary))
            Button("Set Directive") { store.send(.confirmTapped) }
                .buttonStyle(RCButtonStyle(.primary))
                .disabled(!store.isConfirmable)
        }
    }
}
```

Note: the directive picker now shows display names (`DevicePresentation.displayName`) instead of the raw verb strings the old inline picker showed — a deliberate improvement, matching the Details card's directive readout.

- [ ] **Step 2: Wire the presentation into `DevicesFeature`**

In `app/Modules/DevicesFeature/Sources/DevicesFeature.swift`:

**2a.** In `State`, after the `diversion` property (line ~56), add:

```swift
        /// The `set_directive` composer, presented as a sheet. A *feature*
        /// sheet (its own reducer), so it uses the `@Presents` tier of the
        /// presentation dialect rather than the plain-value item bindings the
        /// preview sheets use. Non-nil ⇒ the sheet is presented.
        @Presents public var directiveComposer: DirectiveComposer.State?
```

(No `init` change — `@Presents` defaults to nil, matching `ReplicantsFeature`.)

**2b.** In `Action`, after `case cargoLoadDismissed`, add:

```swift
        /// The inspector's Directive command. A thin intent mirroring
        /// `travelConfirmed`: ends field editing and yields a runloop tick
        /// before the composer sheet presents (see `.travelConfirmed` for why).
        case directiveComposeTapped
        /// Present the composer, seeded from the currently-inspected device.
        case directiveComposerPresented
        case directiveComposer(PresentationAction<DirectiveComposer.Action>)
```

**2c.** In the reducer's `switch`, after the `.cargoLoadDismissed` case, add:

```swift
            case .directiveComposeTapped:
                // Same dance as `.travelConfirmed`: end field editing and yield
                // a runloop tick before the sheet-presenting state is set — a
                // sheet presented while a text field's completion popover is up
                // crashes AppKit's sheet presentation.
                let endEditing = self.endEditing
                let clock = self.clock
                return .run { send in
                    await endEditing()
                    try await clock.sleep(for: .zero)
                    await send(.directiveComposerPresented)
                }

            case .directiveComposerPresented:
                guard let device = state.selectedDevice else { return .none }
                logger.info("directive composer \(device.deviceCode, privacy: .public) presented")
                state.directiveComposer = DirectiveComposer.State(device: device, fleet: state.devices)
                return .none

            case let .directiveComposer(.presented(.delegate(.confirmed(directive, configuration)))):
                guard let deviceCode = state.directiveComposer?.deviceCode else { return .none }
                return .send(.commandConfirmed(
                    kind: .setDirective,
                    deviceCode: deviceCode,
                    params: CommandParams(directive: directive, configuration: configuration)
                ))

            case .directiveComposer:
                return .none
```

**2d.** After the closing brace of the `Reduce { … }` block (before the closing brace of `body`), append the presentation composition:

```swift
        .ifLet(\.$directiveComposer, action: \.directiveComposer)
```

so the end of `body` reads:

```swift
            }
        }
        .ifLet(\.$directiveComposer, action: \.directiveComposer)
    }
```

**2e.** Leave `salvageSitesRequested` untouched in this task (CommandGrid's soon-to-be-dead `prepareDirective` still references it; Task 3 removes both together).

- [ ] **Step 3: Present the sheet from `DeviceDetailView`**

In `app/Modules/DevicesFeature/Sources/DeviceDetailView.swift`:

**3a.** Change the store property (line 30) from:

```swift
    let store: StoreOf<DevicesFeature>
```

to:

```swift
    @Bindable var store: StoreOf<DevicesFeature>
```

(the `public init` body stays `self.store = store`).

**3b.** After the `cargoLoadItem` sheet (the `.sheet(item: cargoLoadItem) { … }` block ending line ~102), add:

```swift
                // The directive composer is a *feature* sheet (its own reducer),
                // so it scopes a presented child store rather than binding a
                // plain preview value like the sheets above.
                .sheet(item: $store.scope(state: \.directiveComposer, action: \.directiveComposer)) { composerStore in
                    DirectiveComposerSheet(store: composerStore)
                }
```

**3c.** In the file's header comment, update the trailing clause `and a command grid whose parameterized commands (travel / print) reveal an inline confirm panel.` to `and a command grid whose commands confirm inline or through their own sheets (travel / print / cargo / directive).`

- [ ] **Step 4: Route the Directive button to the sheet in `CommandGrid`**

In `app/Modules/DevicesFeature/Sources/CommandGrid.swift`, inside `select(_:)`, directly after the `loadCargo` interception block (ending `return }` around line 261), add:

```swift
        // Directive skips the inline panel too — its editor is a full form fed
        // by live catalog data, so it opens the composer sheet from the grid.
        if case .setDirective = command {
            pending = nil
            store.send(.directiveComposeTapped)
            return
        }
```

Touch nothing else in this file yet — the now-unreachable inline directive editor comes out in Task 3.

- [ ] **Step 5: Extend `DevicesFeatureTests`**

Append these two tests inside the `DevicesFeatureTests` suite (file `app/Modules/DevicesFeature/Tests/DevicesFeatureTests.swift`), and add `import Utils` to its imports (for `JSONValue`):

```swift
    /// The Directive command ends field editing, yields, then presents the
    /// composer seeded from the inspected device.
    @Test func directiveComposeTappedPresentsComposerForSelectedDevice() async throws {
        let database = try GameDatabase.bootstrap()
        var ami = device("AMI1")
        ami.detail = .object([
            "available_directives": .array([.string("survey_system"), .string("belt_search")]),
        ])
        let seeded = ami
        try await database.write { db in try Device.insert { seeded }.execute(db) }
        let endedEditing = LockIsolated(false)

        let store = TestStore(initialState: DevicesFeature.State(selectedDeviceCode: "AMI1")) {
            DevicesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.continuousClock = ImmediateClock()
            $0.endEditing = EndEditingClient { endedEditing.setValue(true) }
        }
        store.exhaustivity = .off

        await store.send(.directiveComposeTapped)
        await store.receive(\.directiveComposerPresented)
        #expect(endedEditing.value == true)
        #expect(store.state.directiveComposer?.deviceCode == "AMI1")
        #expect(store.state.directiveComposer?.directive == "survey_system")
    }

    /// The composer's confirmed delegate dispatches `set_directive` with the
    /// built configuration for the presented device.
    @Test func directiveComposerConfirmedDispatchesSetDirective() async throws {
        let database = try GameDatabase.bootstrap()
        let dispatched = LockIsolated<(OperationKind, String, CommandParams)?>(nil)

        let store = withDependencies {
            $0.defaultDatabase = database
            $0.commandClient.dispatch = { kind, code, params in
                dispatched.setValue((kind, code, params))
                return .accepted(operationID: "op")
            }
        } operation: {
            var state = DevicesFeature.State(selectedDeviceCode: "AMI1")
            var ami = device("AMI1")
            ami.detail = .object([
                "available_directives": .array([.string("survey_system")]),
            ])
            state.directiveComposer = DirectiveComposer.State(device: ami, fleet: [])
            return TestStore(initialState: state) { DevicesFeature() }
        }
        store.exhaustivity = .off

        await store.send(.directiveComposer(.presented(.delegate(.confirmed(
            directive: "survey_system",
            configuration: ["planets": .string("all"), "moons": .string("none"), "recall": .bool(true)]
        )))))
        await store.finish()

        #expect(dispatched.value?.0 == .setDirective)
        #expect(dispatched.value?.1 == "AMI1")
        #expect(dispatched.value?.2.directive == "survey_system")
        #expect(dispatched.value?.2.configuration?["planets"] == .string("all"))
    }
```

Notes: `device(_:status:)` is the file's existing fixture — `Device.detail` must be mutable on a `var` copy (it is a plain stored property). If `@FetchAll` hasn't observed the inserted row by the time `.directiveComposerPresented` reduces (the `state.devices` fetch is initialized with the store), poll before asserting: `while store.state.devices.isEmpty { await Task.yield() }` right after store construction. If `Device` isn't mutable this way, build the fixture inline with the full memberwise init instead (copy the `controller` fixture from `DirectiveComposerTests`).

- [ ] **Step 6: Build + run both suites**

From `app/Modules/`:

```bash
swift build 2>&1 | tail -5
EVENTS=$(mktemp)
swift test --filter DevicesFeatureTests --event-stream-output-path "$EVENTS" >/dev/null 2>&1
jq -r 'select(.kind=="event") | select(.payload.kind=="issueRecorded")' "$EVENTS" | wc -l   # expect 0
jq -r 'select(.kind=="event") | select(.payload.kind=="testCaseEnded")' "$EVENTS" | wc -l   # expect ≥ 25 (7 old DevicesFeature + 2 new + 6 CommandGroup + 15 DirectiveComposer-suite cases, all matched by the target filter)
```

Expected: clean build, zero issues. (The exact `testCaseEnded` count depends on suite matching; zero `issueRecorded` is the gate.)

- [ ] **Step 7: Commit**

```bash
git add Modules/DevicesFeature/Sources/DirectiveComposerSheet.swift \
        Modules/DevicesFeature/Sources/DevicesFeature.swift \
        Modules/DevicesFeature/Sources/DeviceDetailView.swift \
        Modules/DevicesFeature/Sources/CommandGrid.swift \
        Modules/DevicesFeature/Tests/DevicesFeatureTests.swift
git commit -m "Present the directive editor as a composer sheet (Stage 3)

The Directive command now opens DirectiveComposerSheet — the @Presents
feature-sheet dialect, scoped from DevicesFeature — instead of the grid's
inline panel. The picker gains display names; confirm hands the directive
+ configuration back through the composer's delegate to commandConfirmed.
The orphaned inline editor still sits in CommandGrid; removed next.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Strip the dead inline editor from `CommandGrid`

**Files:**
- Modify: `app/Modules/DevicesFeature/Sources/CommandGrid.swift` (deletions + small edits)
- Modify: `app/Modules/DevicesFeature/Sources/DevicesFeature.swift` (remove `salvageSitesRequested`)

**Interfaces:**
- Consumes: Task 2's `.directiveComposeTapped` routing (already in place).
- Produces: nothing new — pure removal. After this task nothing in the module references `salvageSitesRequested`, `prepareDirective`, or the directive config subviews.

All line references are to the file as of Task 2's commit; work top-to-bottom by symbol name, not line number.

- [ ] **Step 1: Delete the directive machinery from `CommandGrid.swift`**

Remove these, each with its attached doc comment:

1. The `@FetchAll(SystemDetail.all) private var systemDetails` property (and its two comment lines).
2. The eight directive draft `@State` vars and their comments: `planetsScope`, `moonsScope`, `recall`, `salvageLocation`, `collectLocation`, `deliverLocation`, `requirement`, `priorityResources`.
3. The `private enum SurveyScope` line.
4. The `controllerBody`, `controllerSystem`, and `salvageBodies` computed properties.
5. In `select(_:)`: replace the whole `case let .choice(_, options):` seeding block

   ```swift
        case let .choice(_, options):
            // Seed the directive picker with the device's current directive when
            // it's a valid option, so re-opening reflects what's in force.
            if case .setDirective = command, let current = device.currentDirective, options.contains(current) {
                choiceValue = current
                seedDirectiveConfig()
            } else {
                choiceValue = options.first ?? ""
            }
            // Load any data the initially-selected directive's config needs.
            if case .setDirective = command { prepareDirective(choiceValue) }
   ```

   with:

   ```swift
        case let .choice(_, options):
            // Seed the dropdown with the first option (mine/retarget resources).
            choiceValue = options.first ?? ""
   ```

6. The `prepareDirective(_:)` and `seedDirectiveConfig()` methods and `amountString(_:)`.
7. In `parameterPanel(_:)`, inside `case let .choice(label, options):` — delete the trailing directive block:

   ```swift
                    // A directive with its own configuration reveals it inline once
                    // selected (survey_system and gather_salvage; other directives
                    // take none).
                    if case .setDirective = command {
                        directiveConfiguration(choiceValue)
                            .onChange(of: choiceValue) { _, newValue in
                                prepareDirective(newValue)
                            }
                    }
   ```

   (keeping the surrounding `VStack` with the label + `RCValueSelect` — after this deletion the outer `VStack(alignment: .leading, spacing: Space.s)` wraps only the label/select `VStack`; collapse the now-redundant outer `VStack` so the case body is just the label + select `VStack`.)
8. In `params(for:)`: delete the `case .setDirective:` branch (two lines) — `set_directive` now dispatches through the composer's delegate, and the enum's `default` branch still compiles.
9. In `isConfirmable(_:)`, `case .choice:` — delete the `if case .setDirective = command { switch choiceValue { … } }` block so the case body is just `return !choiceValue.isEmpty`.
10. The `directiveConfig(for:)` method and `requirementPayload` property.
11. The view builders and helpers: `directiveConfiguration(_:)`, `deliveryConfiguration`, `transportRouteConfiguration(interstellar:)`, `consolidateConfiguration`, `requirementEditor`, `requirementRow(_:)`, `requirementBinding(_:)`, `priorityEditor`, `priorityChip(_:)`, `togglePriority(_:)`, `salvageConfiguration`, `salvageBodyLabel(_:)`, `configField(_:selection:)`.
12. Header comment: replace the parenthetical `(a text field, a directive picker with its own configuration, a device checkbox list, a blueprint picker, or a plain confirmation)` with `(a text field, a resource picker, a device checkbox list, a blueprint picker, or a plain confirmation); heavier commands (travel / print / cargo / directive) confirm in their own sheets.`
13. Imports: delete `import UniverseModels` (was only for `SystemDetail`/`SalvageBody`). Then try deleting `import Utils` and `import SQLiteData` one at a time with a build between — keep any the build still needs (`SQLiteData` is expected to stay for `@FetchAll`; `Utils` is expected to go once `JSONValue` uses are gone, but keep it if anything else needs it).

- [ ] **Step 2: Remove `salvageSitesRequested` from `DevicesFeature.swift`**

Delete the action case and its doc comment (lines ~143–146):

```swift
        /// The inspector opened the `gather_salvage` directive for a controller in
        /// `system`; hydrate that controller's operating `body` into the local
        /// locations catalog so the salvage-site dropdown can offer its sites.
        case salvageSitesRequested(system: String, body: String)
```

and the reducer case (lines ~465–473):

```swift
            case let .salvageSitesRequested(system, body):
                // Fill the local catalog for this controller's system in the
                // background; the SystemDetail write flows back to the picker's
                // @FetchAll. Best-effort — an unreadable system just leaves the
                // dropdown empty with its "scan the system" hint.
                let locationsClient = self.locationsClient
                return .run { _ in
                    try? await locationsClient.hydrateBody(systemDesignation: system, bodyDesignation: body)
                }
```

(`locationsClient` stays — the print and cargo flows use it.)

- [ ] **Step 3: Verify nothing else references the removed symbols**

Preferred (LSP): `findReferences` on `salvageSitesRequested` before deleting should show only `CommandGrid.prepareDirective` + the reducer case. Fallback:

```bash
grep -rn "salvageSitesRequested\|prepareDirective\|seedDirectiveConfig\|directiveConfiguration\|requirementPayload" app/Modules --include="*.swift" | grep -v .build
```

Expected after the edits: no hits (DirectiveComposer's own `requirementPayload` and `hydrateIfNeeded` are different symbols; a hit inside `DirectiveComposer.swift`/`DirectiveComposerSheet.swift` for `requirementPayload`/`configuration` is fine — the grep above deliberately lists only the CommandGrid-era names, of which only `requirementPayload` overlaps).

- [ ] **Step 4: Build + full module test run**

From `app/Modules/`:

```bash
swift build 2>&1 | tail -5
EVENTS=$(mktemp)
swift test --filter DevicesFeatureTests --event-stream-output-path "$EVENTS" >/dev/null 2>&1
jq -r 'select(.kind=="event") | select(.payload.kind=="issueRecorded")' "$EVENTS" | wc -l   # expect 0
EVENTS3=$(mktemp)
swift test --filter RefreshCadenceTests --event-stream-output-path "$EVENTS3" >/dev/null 2>&1
jq -r 'select(.kind=="event") | select(.payload.kind=="issueRecorded")' "$EVENTS3" | wc -l  # expect 0
```

Expected: clean build; zero recorded issues in both runs. `CommandGrid.swift` should land around ~550 lines (from 1,015).

- [ ] **Step 5: Commit**

```bash
git add Modules/DevicesFeature/Sources/CommandGrid.swift Modules/DevicesFeature/Sources/DevicesFeature.swift
git commit -m "Drop CommandGrid's orphaned inline directive editor (Stage 3)

Pure deletion: the draft state, seeding, config subviews, payload
builder, and the salvageSitesRequested hydrate hook all moved into
DirectiveComposer in the previous two commits and were unreachable here.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Verification (whole stage)

1. `swift build` clean from `app/Modules/`.
2. `swift test --filter DevicesFeatureTests` and `--filter RefreshCadenceTests` — zero `issueRecorded` in the event streams (expected suites: DevicesFeatureTests 9, CommandGroupTests 6, DirectiveComposerTests 15, RefreshCadenceTests 5).
3. Manual spot-check (user's): select an AMI controller → Control ▸ Directive opens the composer sheet; picking `gather_salvage` fills the salvage picker after hydrate; Cancel dismisses with no dispatch; Set Directive dispatches and the Details card's directive row updates on reconcile.

## Deliberately NOT done in Stage 3

- No new command verbs (`configure`, `message`, `repair`, `replicate`, `change_owner`, dropping `detonate`) — Stage 4.
- No changes to the travel/print/cargo value-sheet dialect — they stay plain-value `.sheet(item:)`.
- No derived-universe taxonomy test — Stage 4, when the verb list grows.
