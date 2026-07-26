//
//  DirectiveComposer.swift
//  Replicould — Directive composer feature
//
//  The `set_directive` editor, presented as a sheet from the device inspector
//  and from the Directives list (per the presentation rule: live-data /
//  heavy-form commands get a sheet). Seeds its draft from the directive
//  currently in force, validates the configuration the backend requires per
//  directive, and hands the confirmed directive + configuration back to its
//  parent through the delegate. Selecting `gather_salvage` hydrates the
//  controller's system into the local locations catalog so the salvage-body
//  picker can fill; dismissing the sheet cancels that in-flight hydrate (the
//  `.ifLet` presentation tears down child effects automatically).
//
//  It is its own module because two features present it. It owns a reducer, so
//  it cannot live in the TCA-free UI-tier modules (PrintingUI / TravelUI).
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

        /// Stored site totals, so the picker can rank bodies by what's on them.
        @ObservationStateIgnored
        @FetchAll(SiteAssay.all) public var siteAssays: [SiteAssay]

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
            return starSystem.salvageBodies(
                totals: siteAssays.reduce(into: [:]) { $0[$1.id] = $1.totals }
            )
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

        @CasePathable
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
