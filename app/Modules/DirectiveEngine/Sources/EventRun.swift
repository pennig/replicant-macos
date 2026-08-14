//
//  EventRun.swift
//  Replicould — DirectiveEngine
//
//  One location event end to end: print, load, deliver, commit, beacon, home.
//

import Foundation
import GameModels
import GameServices
import OSLog
import UniverseModels

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

public struct EventRun: MissionStepMachine {
    public let kind = DirectiveKind.eventRun

    /// The reserve rail, injected as `RelayRun`/`MineFleetPrint` inject it.
    public let reserveFloor: Int?

    public init(reserveFloor: Int? = BrainCeiling.aggregateSpendFloor) {
        self.reserveFloor = reserveFloor
    }

    /// This mission's step vocabulary, as the bare strings `Directive.step` holds.
    public enum Step {
        public static let preflight = "preflight"
        public static let printing = "printing"
        public static let loading = "loading"
        public static let confirmingLoad = "confirmingLoad"
        public static let departing = "departing"
        public static let confirmingArrival = "confirmingArrival"
        public static let staging = "staging"
        public static let confirmingStage = "confirmingStage"
        public static let confirmingProgress = "confirmingProgress"
        public static let committing = "committing"
        public static let collecting = "collecting"
        public static let recovering = "recovering"
        public static let returning = "returning"
    }

    public var firstStep: String { Step.preflight }

    public static let carrierDeviceType = "surge_carrier"
    public static let freighterDeviceType = "cargo_freighter"
    public static let courierDeviceType = "matrix_container"
    /// The bare tag every wire-bound query must use.
    public static let rootTag = "auto:event"
    /// The tag the carrier pool wears.
    public static let carrierTag = "auto:carrier"

    /// Deadlines, all in the shape the sibling runs use.
    public static let printDeadline: TimeInterval = RestockRun.printDeadline
    public static let loadConfirmDeadline: TimeInterval = 5 * 60
    public static let arrivalConfirmDeadline: TimeInterval = 5 * 60
    public static let stageConfirmDeadline: TimeInterval = 5 * 60
    /// Generous: `progress` moves on the server's own schedule after a deposit.
    public static let progressDeadline: TimeInterval = 15 * 60

    /// Local-only, never sent to `GET devices/tags/{tag}`.
    public static func fleetTag(forTheatre depot: String) -> String {
        "\(rootTag):\(depot.lowercased())"
    }

    /// The event this run is working.
    public static func targetEvent(of directive: Directive) -> String? {
        directive.targets.first
    }

    /// The three hulls, resolved off the row rather than re-derived.
    public struct Convoy: Equatable, Sendable {
        public let carrier: Device
        public let freighter: Device?
        public let courier: Device?
    }

    /// A container aboard ANOTHER carrier is that run's courier, not this one's.
    /// Sorted before `first`, so two containers cannot resolve differently per tick.
    public static func convoy(of directive: Directive, in world: WorldSnapshot) -> Convoy? {
        guard let carrier = world.device(directive.deviceCode) else { return nil }
        let freighter = directive.freighterCode.flatMap { world.device($0) }
        let courier = world.devices.values
            .filter {
                guard $0.deviceType == courierDeviceType else { return false }
                if let host = $0.attachedToDeviceCode { return host == carrier.deviceCode }
                return $0.location == carrier.location
            }
            .sorted { $0.deviceCode < $1.deviceCode }
            .first
        return Convoy(carrier: carrier, freighter: freighter, courier: courier)
    }

    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        guard let convoy = Self.convoy(of: directive, in: world) else {
            return .stall(.unreachableDevice)
        }
        guard let designation = Self.targetEvent(of: directive),
              let event = world.event(designation)
        else { return .refreshEvents(thenStall: .unreachableDevice) }

        switch directive.step {
        case Step.printing: return printing(directive, convoy, event, world)
        case Step.loading: return loading(directive, convoy, event, world)
        case Step.confirmingLoad: return confirmLoad(directive, convoy, event, world)
        case Step.departing: return departing(directive, convoy, event, world)
        case Step.confirmingArrival: return confirmArrival(directive, convoy, event, world)
        case Step.staging: return staging(directive, convoy, event, world)
        case Step.confirmingStage: return confirmStage(directive, convoy, event, world)
        default: return preflight(directive, convoy, event, world)
        }
    }

    // MARK: - Preflight

    private func preflight(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard event.isActive else {
            logger.notice("event run \(directive.id, privacy: .public): \(event.designation, privacy: .public) already closed — recovering")
            return .advanceStep(nextStep: Step.recovering)
        }
        guard world.theatreDepot(for: directive) != nil else {
            if world.theatreWentClaimed(for: directive) { return .wait }
            return .stall(.unreachableDevice)
        }
        return .advanceStep(nextStep: Step.printing)
    }

    // MARK: - Printing

    /// What the option still needs, standing free at `depot` and unclaimed.
    static func missingDevices(
        for option: EventPlan.Option, at depot: String, in world: WorldSnapshot, tag: String
    ) -> [String: Int] {
        var wanted = option.devices
        for device in world.devices.values
        where device.location == depot && device.hasTag(tag) {
            if let outstanding = wanted[device.deviceType] {
                wanted[device.deviceType] = outstanding > 1 ? outstanding - 1 : nil
            }
        }
        return wanted
    }

    /// Whether a beacon already stands at the event's location.
    static func beaconStands(at location: String, in world: WorldSnapshot) -> Bool {
        world.devices.values.contains {
            $0.deviceType == EventPlan.beaconDeviceType && $0.location == location
        }
    }

    private func printing(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let depot = world.theatreDepot(for: directive),
              case .decided(let option) = EventPlan.resolve(
                  event, chosenOption: event.chosenOption, bills: [:]
              )
        else { return .stall(.unreachableDevice) }

        let tag = Self.fleetTag(forTheatre: depot)
        var wanted = Self.missingDevices(for: option, at: depot, in: world, tag: tag)
        if !Self.beaconStands(at: event.location, in: world),
           !world.devices.values.contains(where: {
               $0.deviceType == EventPlan.beaconDeviceType && $0.location == depot && $0.hasTag(tag)
           })
        {
            wanted[EventPlan.beaconDeviceType] = 1
        }
        if wanted.isEmpty { return .advanceStep(nextStep: Step.loading) }

        // Sorted before `first`: two printers at one depot must not alternate.
        guard let printer = world.devices.values
            .filter({ $0.location == depot && $0.deviceType == "autofactory" })
            .sorted(by: { $0.deviceCode < $1.deviceCode })
            .first
        else { return .stall(.unreachableDevice) }

        if world.openOperation(for: printer.deviceCode) != nil { return .wait }

        let rail = RelayRun(reserveFloor: reserveFloor)
        if rail.footprintCensusIsStale(world) {
            return .refreshFootprint(nextStep: Step.printing, thenStall: nil)
        }
        if rail.printStockIsShort(at: depot, world) { return .wait }
        if MineFleetPrint.fleetEvidenceIsStale(directive, at: depot, in: world) {
            return .refreshDevicesInSystem(designation: depot, thenStall: .unreachableDevice)
        }

        // Beacon last: the option's devices are the long prints.
        let order = option.devices.keys.sorted() + [EventPlan.beaconDeviceType]
        guard let type = order.first(where: { wanted[$0] != nil }),
              let quantity = wanted[type]
        else { return .wait }

        return .dispatch(
            kind: .print, deviceCode: printer.deviceCode,
            params: CommandParams(deviceType: type, quantity: quantity, printTags: [tag]),
            nextStep: Step.printing
        )
    }

    // MARK: - Loading

    /// Attach the courier, the beacon and the option's devices one per round,
    /// then fill the freighter. `attach` moves one row at a time.
    private func loading(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let depot = world.theatreDepot(for: directive),
              case .decided(let option) = EventPlan.resolve(
                  event, chosenOption: event.chosenOption, bills: [:]
              )
        else { return .stall(.unreachableDevice) }

        guard let courier = convoy.courier else {
            return .refreshFleet(tag: Self.rootTag, thenStall: .unreachableDevice)
        }
        guard let freighter = convoy.freighter else {
            return .refreshFleet(tag: Self.rootTag, thenStall: .unreachableDevice)
        }

        let carrier = convoy.carrier
        let tag = Self.fleetTag(forTheatre: depot)
        var payload = [courier]
        payload += world.devices.values
            .filter {
                $0.hasTag(tag) && $0.location == depot
                    && ($0.deviceType == EventPlan.beaconDeviceType || option.devices[$0.deviceType] != nil)
            }
            .sorted { $0.deviceCode < $1.deviceCode }

        if let next = payload.first(where: { $0.attachedToDeviceCode != carrier.deviceCode }) {
            return .dispatch(
                kind: .attach, deviceCode: carrier.deviceCode,
                params: CommandParams(devices: [next.deviceCode]),
                nextStep: Step.confirmingLoad
            )
        }

        if option.resources.isEmpty { return .advanceStep(nextStep: Step.departing) }
        if freighter.cargoUsed > 0 { return .advanceStep(nextStep: Step.departing) }
        if world.openOperation(for: freighter.deviceCode) != nil { return .wait }
        return .dispatch(
            kind: .collectResources, deviceCode: freighter.deviceCode,
            params: CommandParams(resources: option.resources),
            nextStep: Step.confirmingLoad
        )
    }

    /// Judge the attach or collect just ordered, looping back for the next.
    /// The dispatch's own confirm-read lands BEFORE the step stamp, so the
    /// loop's round count proves it landed, not row freshness.
    private func confirmLoad(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        if world.openOperation(for: convoy.carrier.deviceCode) != nil { return .wait }
        if let freighter = convoy.freighter, world.openOperation(for: freighter.deviceCode) != nil {
            return .wait
        }
        return .advanceStep(nextStep: Step.loading)
    }

    // MARK: - Delivery

    /// Move the carrier first, then the freighter. Each leg is its own dispatch:
    /// two hulls cannot share one travel command.
    private func departing(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        let destination = event.location
        if convoy.carrier.location != destination {
            if world.openOperation(for: convoy.carrier.deviceCode) != nil { return .wait }
            // The equality check above misreads a row still lagging an arrival.
            if let unconfirmed = SalvageRun.travelPositionUnconfirmed(convoy.carrier, world) {
                return unconfirmed
            }
            return .dispatch(
                kind: .travel, deviceCode: convoy.carrier.deviceCode,
                params: CommandParams(destination: destination), nextStep: Step.departing
            )
        }
        guard let freighter = convoy.freighter else {
            return .refreshFleet(tag: Self.rootTag, thenStall: .unreachableDevice)
        }
        if freighter.location != destination {
            if world.openOperation(for: freighter.deviceCode) != nil { return .wait }
            if let unconfirmed = SalvageRun.travelPositionUnconfirmed(freighter, world) {
                return unconfirmed
            }
            return .dispatch(
                kind: .travel, deviceCode: freighter.deviceCode,
                params: CommandParams(destination: destination), nextStep: Step.confirmingArrival
            )
        }
        return .advanceStep(nextStep: Step.confirmingArrival)
    }

    /// Both hulls placed at the event, on rows read since the step began.
    private func confirmArrival(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        var rows = [convoy.carrier]
        if let freighter = convoy.freighter { rows.append(freighter) }
        let placed = rows.allSatisfy {
            $0.updatedAt >= directive.stepStartedAt && $0.location == event.location
        }
        if placed { return .advanceStep(nextStep: Step.staging) }
        if rows.contains(where: { world.openOperation(for: $0.deviceCode) != nil }) { return .wait }
        return MissionConfirm.ladder(
            rows, directive, world,
            deadline: Self.arrivalConfirmDeadline, thenStall: .vesselPositionUnconfirmed
        )
    }

    /// Set the load down and empty the hold. The courier stays attached — it is
    /// the convoy's replicant and comes home with the carrier.
    private func staging(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard case .decided(let option) = EventPlan.resolve(
            event, chosenOption: event.chosenOption, bills: [:]
        ) else { return .stall(.unreachableDevice) }

        let courierCode = convoy.courier?.deviceCode
        let aboard = world.devices.values
            .filter { $0.attachedToDeviceCode == convoy.carrier.deviceCode && $0.deviceCode != courierCode }
            .sorted { $0.deviceCode < $1.deviceCode }
        if !aboard.isEmpty {
            return .dispatch(
                kind: .detach, deviceCode: convoy.carrier.deviceCode,
                params: CommandParams(devices: aboard.map(\.deviceCode)),
                nextStep: Step.confirmingStage
            )
        }

        guard !option.resources.isEmpty else { return .advanceStep(nextStep: Step.confirmingProgress) }
        guard let freighter = convoy.freighter else {
            return .refreshFleet(tag: Self.rootTag, thenStall: .unreachableDevice)
        }
        if world.openOperation(for: freighter.deviceCode) != nil { return .wait }
        // An empty hold means the deposit landed only once one was ordered.
        if case .dispatched(let kind, _) = MissionLogBudget.lastDispatch(
            world, dispatch: Step.staging, confirm: Step.confirmingStage
        ), kind == OperationKind.depositResources.rawValue, freighter.cargoUsed == 0 {
            return .advanceStep(nextStep: Step.confirmingProgress)
        }
        return .dispatch(
            kind: .depositResources, deviceCode: freighter.deviceCode,
            params: CommandParams(resources: option.resources),
            nextStep: Step.confirmingStage
        )
    }

    private func confirmStage(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        if world.openOperation(for: convoy.carrier.deviceCode) != nil { return .wait }
        if let freighter = convoy.freighter, world.openOperation(for: freighter.deviceCode) != nil {
            return .wait
        }
        return .advanceStep(nextStep: Step.staging)
    }

    /// The run never roams.
    public func plan(_ context: RoamContext) -> RoamPlan { .exhausted }
}
