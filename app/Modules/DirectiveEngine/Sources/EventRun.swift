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
        public static let confirmingRecovery = "confirmingRecovery"
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
    public static let recoveryConfirmDeadline: TimeInterval = 5 * 60
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
        case Step.confirmingProgress: return confirmProgress(directive, convoy, event, world)
        case Step.committing: return committing(directive, convoy, event, world)
        case Step.collecting: return collecting(directive, convoy, event, world)
        case Step.recovering: return recovering(directive, convoy, event, world)
        case Step.confirmingRecovery: return confirmRecovery(directive, convoy, event, world)
        case Step.returning: return returning(directive, convoy, event, world)
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

    /// The courier, then the beacon and the option's devices standing at `depot`,
    /// in the order `loading` attaches them.
    static func loadPayload(
        courier: Device, option: EventPlan.Option, depot: String, tag: String,
        in world: WorldSnapshot
    ) -> [Device] {
        var payload = [courier]
        payload += world.devices.values
            .filter {
                $0.hasTag(tag) && $0.location == depot
                    && ($0.deviceType == EventPlan.beaconDeviceType || option.devices[$0.deviceType] != nil)
            }
            .sorted { $0.deviceCode < $1.deviceCode }
        return payload
    }

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
        let payload = Self.loadPayload(
            courier: courier, option: option, depot: depot,
            tag: Self.fleetTag(forTheatre: depot), in: world
        )

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
    /// `attach` and `collect_resources` are immediate, so the loop's round count
    /// is the bound — no op is ever open and the step stamp post-dates the read.
    private func confirmLoad(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        let carrier = convoy.carrier
        var landed = world.devices.values
            .filter { $0.attachedToDeviceCode == carrier.deviceCode }
            .count
        if let freighter = convoy.freighter, freighter.cargoUsed > 0 { landed += 1 }
        let rounds = MissionLogBudget.dispatchRounds(
            world, dispatch: Step.loading, confirm: Step.confirmingLoad
        )
        if landed >= rounds { return .advanceStep(nextStep: Step.loading) }

        guard let depot = world.theatreDepot(for: directive), let courier = convoy.courier,
              case .decided(let option) = EventPlan.resolve(
                  event, chosenOption: event.chosenOption, bills: [:]
              )
        else { return .refreshFleet(tag: Self.rootTag, thenStall: .unreachableDevice) }

        let payload = Self.loadPayload(
            courier: courier, option: option, depot: depot,
            tag: Self.fleetTag(forTheatre: depot), in: world
        )
        let loose = payload.filter { $0.attachedToDeviceCode != carrier.deviceCode }
        guard let next = loose.first ?? convoy.freighter else {
            return .advanceStep(nextStep: Step.loading)
        }
        return MissionConfirm.ladder(
            [next], directive, world,
            deadline: Self.loadConfirmDeadline, thenStall: .commandRejected
        )
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

    /// Everything on the carrier's grid bar the courier, which stays aboard as
    /// the convoy's replicant and flies home with it.
    static func staged(_ convoy: Convoy, in world: WorldSnapshot) -> [Device] {
        let courierCode = convoy.courier?.deviceCode
        return world.devices.values
            .filter {
                $0.attachedToDeviceCode == convoy.carrier.deviceCode && $0.deviceCode != courierCode
            }
            .sorted { $0.deviceCode < $1.deviceCode }
    }

    private static func stageRounds(_ world: WorldSnapshot, _ kind: OperationKind) -> Int {
        MissionLogBudget.dispatchRounds(
            world, dispatch: Step.staging, confirm: Step.confirmingStage, kind: kind
        )
    }

    /// Set the load down and empty the hold, each leg ordered at most once. Both
    /// verbs are immediate, so the event's own progress judges the delivery.
    private func staging(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard case .decided(let option) = EventPlan.resolve(
            event, chosenOption: event.chosenOption, bills: [:]
        ) else { return .stall(.unreachableDevice) }

        let aboard = Self.staged(convoy, in: world)
        if !aboard.isEmpty, Self.stageRounds(world, .detach) < 1 {
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
        if Self.stageRounds(world, .depositResources) < 1 {
            return .dispatch(
                kind: .depositResources, deviceCode: freighter.deviceCode,
                params: CommandParams(resources: option.resources),
                nextStep: Step.confirmingStage
            )
        }
        return .advanceStep(nextStep: Step.confirmingProgress)
    }

    /// Judge a detach on the rows it moved. A deposit leaves no local proof — a
    /// hold may carry more than the option asked for — so it hands straight back.
    private func confirmStage(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard case .dispatched(let kind, _) = MissionLogBudget.lastDispatch(
            world, dispatch: Step.staging, confirm: Step.confirmingStage
        ), kind == OperationKind.detach.rawValue else {
            return .advanceStep(nextStep: Step.staging)
        }
        let aboard = Self.staged(convoy, in: world)
        if aboard.isEmpty { return .advanceStep(nextStep: Step.staging) }
        return MissionConfirm.ladder(
            aboard, directive, world,
            deadline: Self.stageConfirmDeadline, thenStall: .commandRejected
        )
    }

    // MARK: - Commit

    /// The event's own live progress is the authority: met, and a replicant on
    /// site. A row read before the deposit landed proves nothing, so a stale
    /// ledger buys one read per cycle until the deadline.
    private func confirmProgress(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard event.isActive else { return .advanceStep(nextStep: Step.recovering) }
        let detail = LocationEventDetail(event.detail)
        if detail?.met == true, detail?.replicantPresent == true {
            return .advanceStep(nextStep: Step.committing)
        }
        if world.now.timeIntervalSince(directive.stepStartedAt) > Self.progressDeadline {
            return .stall(.eventCriteriaUnmet, detail: event.designation)
        }
        return .refreshEvents(thenStall: nil)
    }

    /// The commit: an empty POST, then the ledger re-read the engine folds in.
    private func committing(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard event.isActive else { return .advanceStep(nextStep: Step.collecting) }
        return .completeEvent(
            location: event.location, designation: event.designation, nextStep: Step.collecting
        )
    }

    /// What the closed event's reward is worth to the freighter standing on it.
    /// Three outcomes, not two: nothing paid and nothing liftable are the same
    /// step move but different facts, and only one of them loses resources.
    enum Sweep: Equatable, Sendable {
        /// The reward paid no resources — an XP-only event.
        case nothingPaid
        /// A real pile the hold has no room for. It stays for a Haul Run.
        case willNotFit([String: Int])
        /// The clamped manifest to ask for.
        case lift([String: Int])
    }

    static func sweep(_ event: LocationEvent, into freighter: Device) -> Sweep {
        let pile = rewardPile(event)
        if pile.isEmpty { return .nothingPaid }
        let manifest = sweepManifest(pile, into: freighter)
        return manifest.isEmpty ? .willNotFit(pile) : .lift(manifest)
    }

    /// What the completion paid, per resource type. An XP-only reward pays none.
    private static func rewardPile(_ event: LocationEvent) -> [String: Int] {
        let reward = LocationEventDetail(event.detail)?.rewardResources ?? []
        return Dictionary(
            reward.filter { $0.amount > 0 }.map { ($0.resourceType, $0.amount) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// `pile` in the order the hold fills, clamped to the room left. Capacity 0
    /// is an unhydrated tail rather than a hull with no hold — this one is a
    /// freighter — so it asks for the whole pile.
    private static func sweepManifest(_ pile: [String: Int], into freighter: Device) -> [String: Int] {
        var room = freighter.cargoCapacity > 0 ? freighter.cargoRemaining : Int.max
        var manifest: [String: Int] = [:]
        for type in pile.keys.sorted() {
            let take = min(pile[type] ?? 0, room)
            if take <= 0 { break }
            manifest[type] = take
            room -= take
        }
        return manifest
    }

    /// Take the reward home. `collect_resources` demands an explicit per-type
    /// map, so the event's own reward manifest names it; whatever will not fit
    /// stays on the ground for a Haul Run.
    private func collecting(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        if event.isActive {
            if world.now.timeIntervalSince(directive.stepStartedAt) > Self.progressDeadline {
                return .stall(.eventCommitRejected, detail: event.designation)
            }
            return .refreshEvents(thenStall: nil)
        }
        guard let freighter = convoy.freighter else { return .advanceStep(nextStep: Step.recovering) }
        if world.openOperation(for: freighter.deviceCode) != nil { return .wait }
        switch Self.sweep(event, into: freighter) {
        case .nothingPaid:
            return .advanceStep(nextStep: Step.recovering)
        case .willNotFit(let pile):
            let unswept = pile.keys.sorted().map { "\($0) \(pile[$0] ?? 0)" }.joined(separator: ", ")
            logger.notice("event run \(directive.id, privacy: .public): hold full at \(event.location, privacy: .public) — reward left for a haul: \(unswept, privacy: .public)")
            return .advanceStep(nextStep: Step.recovering)
        case .lift(let manifest):
            return .dispatch(
                kind: .collectResources, deviceCode: freighter.deviceCode,
                params: CommandParams(resources: manifest), nextStep: Step.recovering
            )
        }
    }

    // MARK: - Recovery and return

    /// Take the courier back aboard. Never depart while it stands loose — a
    /// convoy that leaves its replicant behind loses the capability, not a hull.
    /// The beacon and the option's devices stay: both were spent on the event.
    private func recovering(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let courier = convoy.courier else {
            return .refreshFleet(tag: Self.rootTag, thenStall: .unreachableDevice)
        }
        if courier.attachedToDeviceCode == convoy.carrier.deviceCode {
            return .advanceStep(nextStep: Step.returning)
        }
        if world.openOperation(for: convoy.carrier.deviceCode) != nil { return .wait }
        return .dispatch(
            kind: .attach, deviceCode: convoy.carrier.deviceCode,
            params: CommandParams(devices: [courier.deviceCode]),
            nextStep: Step.confirmingRecovery
        )
    }

    /// Judge the re-attach on the courier's own row. `attach` is immediate and
    /// untracked, so this step's deadline is the only bound on a rejected one;
    /// it hands back to `recovering` only once the courier reads as aboard.
    private func confirmRecovery(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let courier = convoy.courier else {
            return .refreshFleet(tag: Self.rootTag, thenStall: .unreachableDevice)
        }
        if courier.attachedToDeviceCode == convoy.carrier.deviceCode {
            return .advanceStep(nextStep: Step.recovering)
        }
        return MissionConfirm.ladder(
            [courier], directive, world,
            deadline: Self.recoveryConfirmDeadline, thenStall: .commandRejected
        )
    }

    /// Both hulls to the depot, resolved through the row's own theatre — never
    /// `originDesignation`, a bare system that travels to an entry point rather
    /// than to the depot where the printer stands.
    private func returning(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let depot = world.theatreDepot(for: directive) else {
            if world.theatreWentClaimed(for: directive) { return .wait }
            logger.notice("event run \(directive.id, privacy: .public): no depot to return to — leaving the convoy where it stands")
            return .done
        }
        for hull in [convoy.carrier, convoy.freighter].compactMap({ $0 })
        where hull.location != depot {
            if world.openOperation(for: hull.deviceCode) != nil { return .wait }
            if let unconfirmed = SalvageRun.travelPositionUnconfirmed(hull, world) { return unconfirmed }
            return .dispatch(
                kind: .travel, deviceCode: hull.deviceCode,
                params: CommandParams(destination: depot), nextStep: Step.returning
            )
        }
        return .done
    }

    /// The run never roams.
    public func plan(_ context: RoamContext) -> RoamPlan { .exhausted }
}
