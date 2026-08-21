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

    /// This mission's step vocabulary, as `Directive.step` holds it (D6).
    public enum Step: String, CaseIterable, Sendable {
        case preflight
        case printing
        case loading
        case confirmingLoad
        case departing
        case confirmingArrival
        case staging
        case confirmingStage
        case confirmingProgress
        case committing
        case collecting
        case recovering
        case confirmingRecovery
        case returning
        case depositing
        case confirmingDeposit
    }

    public var firstStep: String { Step.preflight.rawValue }

    public static let carrierDeviceType = "surge_carrier"
    public static let freighterDeviceType = "cargo_freighter"
    public static let courierDeviceType = "matrix_container"
    /// The unscoped tag the convoy's own devices wear.
    public static let rootTag = FleetTag(goal: .event)

    /// Deadlines, all in the shape the sibling runs use.
    /// What a print gets on top of its own run time: queue wait and confirm lag.
    public static let printSlack: TimeInterval = PrintJob.deadline
    public static let loadConfirmDeadline: TimeInterval = 5 * 60
    public static let arrivalConfirmDeadline: TimeInterval = 5 * 60
    public static let stageConfirmDeadline: TimeInterval = 5 * 60
    public static let recoveryConfirmDeadline: TimeInterval = 5 * 60
    public static let depositConfirmDeadline: TimeInterval = 5 * 60
    /// Generous: `progress` moves on the server's own schedule after a deposit.
    public static let progressDeadline: TimeInterval = 15 * 60

    public static func fleetTag(forTheatre depot: String) -> FleetTag {
        FleetTag(goal: .event, scope: .theatre(depot: depot))
    }

    /// The event this run is working.
    public static func targetEvent(of directive: Directive) -> String? {
        directive.targets.first
    }

    /// The hulls, resolved off the row rather than re-derived. No step speaks to
    /// one freighter: `freighters` is the only way in, however many it holds.
    public struct Convoy: Equatable, Sendable {
        public let carrier: Device
        /// Every leased freighter whose row the world holds, in load order.
        public let freighters: [Device]
        public let courier: Device?
    }

    /// A container this capability printed. An untagged one hosts some other
    /// automation's replicant, whatever it happens to stand beside.
    public static func isCourierHull(_ device: Device) -> Bool {
        device.deviceType == courierDeviceType && device.carries(rootTag, policy: .exact)
    }

    /// A courier: an owned container with a replicant replicated into it.
    /// Untagged it is not ours to fly; unhosted it cannot resolve the commit.
    public static func isCourier(_ device: Device, in world: WorldSnapshot) -> Bool {
        isCourierHull(device) && world.replicantHostDevices.contains(device.deviceCode)
    }

    /// Where `device` physically stands: its host's location while it rides one,
    /// its own otherwise. A carried row lags the hull carrying it, and the hull
    /// is the authority on where both of them are.
    static func standingLocation(of device: Device, in world: WorldSnapshot) -> String? {
        var current = device
        var seen: Set<String> = [device.deviceCode]
        while let hostCode = current.attachedToDeviceCode ?? current.stowedInDeviceCode,
              seen.insert(hostCode).inserted,
              let host = world.device(hostCode)
        {
            current = host
        }
        return current.location
    }

    /// A container aboard ANOTHER carrier is that run's courier, not this one's.
    /// Sorted before `first`, so two containers cannot resolve differently per tick.
    public static func convoy(of directive: Directive, in world: WorldSnapshot) -> Convoy? {
        guard let carrier = world.device(directive.deviceCode) else { return nil }
        let freighters = directive.freighterCodes.compactMap { world.device($0) }
        let courier = world.devices.values
            .filter {
                guard isCourier($0, in: world) else { return false }
                if let host = $0.attachedToDeviceCode { return host == carrier.deviceCode }
                return $0.location == carrier.location
            }
            .sorted { $0.deviceCode < $1.deviceCode }
            .first
        return Convoy(carrier: carrier, freighters: freighters, courier: courier)
    }

    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        guard let convoy = Self.convoy(of: directive, in: world) else {
            return .stall(.unreachableDevice)
        }
        guard let designation = Self.targetEvent(of: directive),
              let event = world.event(designation)
        else { return .refreshEvents(thenStall: .unreachableDevice) }

        guard let step = Step(rawValue: directive.step) else {
            logger.notice("\(kind.rawValue, privacy: .public) \(directive.id, privacy: .public): unknown step \(directive.step, privacy: .public) — waiting")
            return .wait
        }
        switch step {
        case .preflight: return preflight(directive, convoy, event, world)
        case .printing: return printing(directive, convoy, event, world)
        case .loading: return loading(directive, convoy, event, world)
        case .confirmingLoad: return confirmLoad(directive, convoy, event, world)
        case .departing: return departing(directive, convoy, event, world)
        case .confirmingArrival: return confirmArrival(directive, convoy, event, world)
        case .staging: return staging(directive, convoy, event, world)
        case .confirmingStage: return confirmStage(directive, convoy, event, world)
        case .confirmingProgress: return confirmProgress(directive, convoy, event, world)
        case .committing: return committing(directive, convoy, event, world)
        case .collecting: return collecting(directive, convoy, event, world)
        case .recovering: return recovering(directive, convoy, event, world)
        case .confirmingRecovery: return confirmRecovery(directive, convoy, event, world)
        case .returning: return returning(directive, convoy, event, world)
        case .depositing: return depositing(directive, convoy, event, world)
        case .confirmingDeposit: return confirmDeposit(directive, convoy, event, world)
        }
    }

    // MARK: - Preflight

    private func preflight(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard event.isActive else {
            logger.notice("event run \(directive.id, privacy: .public): \(event.designation, privacy: .public) already closed — recovering")
            return .advanceStep(nextStep: Step.recovering.rawValue)
        }
        guard let depot = world.theatreDepot(for: directive) else {
            if world.theatreWentClaimed(for: directive) { return .wait }
            return .stall(.unreachableDevice)
        }
        // The rail is the ceiling on the WHOLE run, resources included, so it
        // sits ahead of the first spend rather than only ahead of the prints.
        let rail = PrintRail(reserveFloor: reserveFloor)
        if rail.footprintCensusIsStale(world) {
            return .refreshFootprint(nextStep: Step.preflight.rawValue, thenStall: nil)
        }
        if rail.printStockIsShort(at: depot, world) { return .wait }
        return .advanceStep(nextStep: Step.printing.rawValue)
    }

    // MARK: - The option in force

    /// The option every step works toward, or why no step can name one.
    enum OptionVerdict: Equatable, Sendable {
        case decided(EventPlan.Option)
        case unresolved(DirectiveAttentionReason, detail: String)
    }

    /// The option `event` is being worked under, resolved on the SAME catalogue
    /// `EventRanking` launched the run under. Resolving on an empty one widens
    /// the printable set to every option, which no `chosenOption` then settles.
    static func optionInForce(_ event: LocationEvent, in world: WorldSnapshot) -> OptionVerdict {
        switch EventPlan.resolve(
            event, chosenOption: event.chosenOption,
            bills: world.blueprintBills, components: world.blueprintComponents
        ) {
        case .decided(let option):
            return .decided(option)
        case .needsChoice:
            return .unresolved(.eventOptionNotChosen, detail: event.designation)
        case .blocked(let offered):
            let missing = offered.reduce(into: Set<String>()) { $0.formUnion($1.unprintable) }
            return .unresolved(
                .eventOptionBlueprintMissing,
                detail: missing.sorted().map(BlueprintPresentation.displayName)
                    .joined(separator: ", ")
            )
        case .undecodable:
            return .unresolved(.unreachableDevice, detail: event.designation)
        }
    }

    // MARK: - Printing

    /// What the option still needs printed, and the device types in its tree the
    /// account holds no blueprint for. `jobs` is a SUBSET of the build order
    /// whenever `unprintable` is non-empty, never a complete one.
    struct Outstanding: Equatable, Sendable {
        let jobs: [BlueprintClosure.Job]
        let unprintable: Set<String>
    }

    /// Every print the option still needs, prerequisites first: the top level
    /// netted against what stands free at `depot` under this run's tag, the
    /// remainder expanded, then the component levels netted from the same pool.
    static func missingTree(
        for option: EventPlan.Option, at depot: String, in world: WorldSnapshot, tag: FleetTag
    ) -> Outstanding {
        // One pool, spent once: a type can be both a top-level requirement and
        // a sibling's component, and must not be counted for both.
        var remaining: [String: Int] = [:]
        for device in world.devices.values
        where device.location == depot && device.carries(tag, policy: .exact) {
            remaining[device.deviceType, default: 0] += 1
        }

        var outstanding: [String: Int] = [:]
        for (type, count) in option.devices.sorted(by: { $0.key < $1.key }) {
            let used = min(remaining[type] ?? 0, count)
            remaining[type] = (remaining[type] ?? 0) - used
            if count - used > 0 { outstanding[type] = count - used }
        }

        // An unread catalogue makes every type look unprintable. Treat the top
        // level as leaves instead, which is what this step did before bills.
        guard !world.blueprintBills.isEmpty else {
            return Outstanding(
                jobs: outstanding.sorted(by: { $0.key < $1.key }).map {
                    BlueprintClosure.Job(deviceType: $0.key, quantity: $0.value, depth: 0)
                },
                unprintable: []
            )
        }

        let expansion = BlueprintClosure.expand(
            outstanding, bills: world.blueprintBills, components: world.blueprintComponents
        )
        var jobs: [BlueprintClosure.Job] = []
        for job in expansion.jobs {
            let used = min(remaining[job.deviceType] ?? 0, job.quantity)
            remaining[job.deviceType] = (remaining[job.deviceType] ?? 0) - used
            guard job.quantity - used > 0 else { continue }
            jobs.append(
                BlueprintClosure.Job(
                    deviceType: job.deviceType, quantity: job.quantity - used, depth: job.depth
                )
            )
        }
        return Outstanding(jobs: jobs, unprintable: expansion.unprintable)
    }

    /// The printing step's bound: the longest single job it still has queued,
    /// plus `printSlack`. A print time the catalogue has no row for adds nothing.
    static func printDeadline(for wanted: [String: Int], in world: WorldSnapshot) -> TimeInterval {
        let longest = wanted.keys.compactMap { world.blueprintPrintTimes[$0] }.max() ?? 0
        return printSlack + TimeInterval(longest)
    }

    /// When this run last put a job on a bench — the newest print op it still
    /// has open, or the step's start before it has ordered any. A bound shaped
    /// as one job's time must not be measured against a whole tree of them.
    static func lastOrderedAt(_ directive: Directive, in world: WorldSnapshot) -> Date {
        world.dispatchedOperations.values
            .filter { $0.kind == OperationKind.print.rawValue && $0.status.isOpen }
            .map(\.startedAt)
            .max() ?? directive.stepStartedAt
    }

    /// What a printer THIS run has a print open on reports its queued job still
    /// missing — a narrower scope than the expansion, so the caller orders the
    /// GREATER of the two. A type with no blueprint is dropped as unorderable.
    static func blockedComponents(at depot: String, in world: WorldSnapshot) -> [String: Int] {
        let ours = Set(
            world.dispatchedOperations.values
                .filter { $0.kind == OperationKind.print.rawValue && $0.status.isOpen }
                .map(\.entityCode)
        )
        var missing: [String: Int] = [:]
        for device in world.devices.values
        where device.location == depot && ours.contains(device.deviceCode) {
            for row in device.waitingForComponents where !row.isMet {
                let shortfall = Int((row.need ?? 0) - (row.have ?? 0))
                guard shortfall > 0, world.blueprintBills[row.resource] != nil else { continue }
                missing[row.resource] = max(missing[row.resource] ?? 0, shortfall)
            }
        }
        return missing
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
        guard let depot = world.theatreDepot(for: directive) else {
            return .stall(.unreachableDevice)
        }
        let option: EventPlan.Option
        switch Self.optionInForce(event, in: world) {
        case .decided(let decided): option = decided
        case .unresolved(let reason, let detail): return .stall(reason, detail: detail)
        }

        let tag = Self.fleetTag(forTheatre: depot)
        let outstanding = Self.missingTree(for: option, at: depot, in: world, tag: tag)
        guard outstanding.unprintable.isEmpty else {
            return .stall(
                .eventOptionBlueprintMissing,
                detail: outstanding.unprintable.sorted()
                    .map(BlueprintPresentation.displayName).joined(separator: ", ")
            )
        }

        var wanted: [String: Int] = [:]
        // Deepest-first, so a component is ORDERED before its consumer. Not
        // executed before: several free printers enqueue several levels at once.
        var order: [String] = []
        for job in outstanding.jobs {
            wanted[job.deviceType] = job.quantity
            order.append(job.deviceType)
        }
        // Sorted before folding: a type the expansion never named leads the
        // order, and two of them must not alternate between ticks.
        var reported: [String] = []
        for (type, count) in Self.blockedComponents(at: depot, in: world)
            .sorted(by: { $0.key < $1.key })
        {
            if wanted[type] == nil { reported.append(type) }
            wanted[type] = max(wanted[type] ?? 0, count)
        }
        order.insert(contentsOf: reported, at: 0)
        if !Self.beaconStands(at: event.location, in: world),
           !world.devices.values.contains(where: {
               $0.deviceType == EventPlan.beaconDeviceType && $0.location == depot && $0.carries(tag, policy: .exact)
           })
        {
            wanted[EventPlan.beaconDeviceType] = 1
            order.append(EventPlan.beaconDeviceType)
        }
        if wanted.isEmpty { return .advanceStep(nextStep: Step.loading.rawValue) }
        let deadline = Self.printDeadline(for: wanted, in: world)

        let rail = PrintRail(reserveFloor: reserveFloor)
        if rail.footprintCensusIsStale(world) {
            return .refreshFootprint(nextStep: Step.printing.rawValue, thenStall: nil)
        }
        if rail.printStockIsShort(at: depot, world) { return .wait }
        if PrintJob.fleetEvidenceIsStale(directive, at: depot, in: world) {
            return .refreshDevicesInSystem(designation: depot, thenStall: .unreachableDevice)
        }

        // `missingTree` counts only what STANDS at the depot, so a job already
        // on order still reads as wanted.
        for (type, onOrder) in PrintScheduler.onOrder(for: directive.id, at: depot, in: world) {
            guard let count = wanted[type] else { continue }
            wanted[type] = count > onOrder ? count - onOrder : nil
        }

        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        guard PrintJob(depot: depot).hasBench(ctx) else { return .stall(.unreachableDevice) }

        // Every path that orders nothing consults the deadline: a free printer
        // with the bill in flight waits on the print an all-busy depot does.
        let noProgress: MissionAction =
            world.now.timeIntervalSince(Self.lastOrderedAt(directive, in: world)) > deadline
            ? .stall(.printBlockedOnComponents, detail: depot) : .wait

        guard let type = order.first(where: { wanted[$0] != nil }),
              let quantity = wanted[type]
        else { return noProgress }

        let job = PrintOrder(
            deviceType: type, quantity: quantity, tags: [tag],
            owner: directive.id, onRailShort: .wait
        )
        guard let chosen = PrintScheduler.choose(job, at: depot, in: world) else { return noProgress }

        return .dispatch(
            kind: .print, deviceCode: chosen.device.deviceCode,
            params: CommandParams(deviceType: type, quantity: quantity, printTags: [tag.string]),
            nextStep: Step.printing.rawValue
        )
    }

    // MARK: - Loading

    /// The courier, then the beacon and the option's devices standing at `depot`,
    /// in the order `loading` attaches them. Each type is capped at what the
    /// option asks for: the commit consumes exactly that many, so a surplus
    /// flown out is abandoned at the event site.
    static func loadPayload(
        courier: Device, option: EventPlan.Option, depot: String, tag: FleetTag,
        in world: WorldSnapshot
    ) -> [Device] {
        let standing = world.devices.values
            .filter {
                $0.carries(tag, policy: .exact) && $0.location == depot
                    && ($0.deviceType == EventPlan.beaconDeviceType || option.devices[$0.deviceType] != nil)
            }
            .sorted { $0.deviceCode < $1.deviceCode }

        var room = option.devices
        room[EventPlan.beaconDeviceType] = max(room[EventPlan.beaconDeviceType] ?? 0, 1)
        // A device already on the carrier holds its berth however the rest of
        // the field sorts, so the choice cannot change mid-load.
        var chosen: Set<String> = []
        for device in standing.filter({ $0.attachedToDeviceCode != nil })
            + standing.filter({ $0.attachedToDeviceCode == nil })
        {
            guard let left = room[device.deviceType], left > 0 else { continue }
            room[device.deviceType] = left - 1
            chosen.insert(device.deviceCode)
        }
        return [courier] + standing.filter { chosen.contains($0.deviceCode) }
    }

    /// One freighter's share of the bill.
    struct Berth: Equatable, Sendable {
        let freighter: Device
        let take: [String: Int]
    }

    /// One hold's share of a bill, and what no hold could take.
    struct Division: Equatable, Sendable {
        let berths: [Berth]
        let unplaced: [String: Int]
    }

    /// A hold's whole capacity. The OUTBOUND measure: the launch gate leases
    /// hulls empty, and a share cut from capacity does not move as the
    /// collections land, so a plan recomputed mid-load names the same shares.
    static func wholeHold(_ freighter: Device) -> Int {
        freighter.cargoCapacity > 0 ? freighter.cargoCapacity : Int.max
    }

    /// What a hold has free. The HOMEWARD measure: a hull comes back carrying
    /// whatever the option did not ask for, so only free space can take a reward.
    static func freeHold(_ freighter: Device) -> Int {
        freighter.cargoCapacity > 0 ? freighter.cargoRemaining : Int.max
    }

    /// How `bill` divides across `freighters`, filling each in order. The ONE
    /// divider — load and sweep differ only in the `room` they measure and what
    /// they do with `unplaced`, never in how the shares are cut. A hold
    /// reporting no `cargo_capacity` is unbounded rather than empty: the field
    /// is absent, not zero, and the server judges what it takes.
    static func divide(
        _ bill: [String: Int], across freighters: [Device], room: (Device) -> Int
    ) -> Division {
        var remaining = bill
        var berths: [Berth] = []
        for freighter in freighters where !remaining.isEmpty {
            var free = room(freighter)
            var take: [String: Int] = [:]
            for type in remaining.keys.sorted() {
                guard free > 0, let need = remaining[type] else { continue }
                let units = min(need, free)
                take[type] = units
                free -= units
                remaining[type] = units == need ? nil : need - units
            }
            if !take.isEmpty { berths.append(Berth(freighter: freighter, take: take)) }
        }
        return Division(berths: berths, unplaced: remaining)
    }

    /// The outbound policy on `divide`: every unit travels or none does, because
    /// a convoy that cannot carry the option cannot finish the event.
    static func loadPlan(bill: [String: Int], across freighters: [Device]) -> [Berth]? {
        let division = divide(bill, across: freighters, room: wholeHold)
        return division.unplaced.isEmpty ? division.berths : nil
    }

    /// Total units the convoy's holds can take, for the stall that says so.
    static func convoyHold(_ freighters: [Device]) -> Int {
        freighters.reduce(0) { $0 + $1.cargoCapacity }
    }

    /// What a step answers when `loadPlan` cannot divide `bill`. Load and stage
    /// share it, so the same convoy cannot stall at one and improvise at the other.
    static func holdsCannotTake(_ bill: [String: Int], _ freighters: [Device]) -> MissionAction {
        .stall(
            .eventLoadExceedsHold,
            detail: "\(bill.values.reduce(0, +)) units, convoy holds \(convoyHold(freighters))"
        )
    }

    /// Attach the courier, the beacon and the option's devices one per round,
    /// then fill the freighters. `attach` moves one row at a time.
    private func loading(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let depot = world.theatreDepot(for: directive) else {
            return .stall(.unreachableDevice)
        }
        let option: EventPlan.Option
        switch Self.optionInForce(event, in: world) {
        case .decided(let decided): option = decided
        case .unresolved(let reason, let detail): return .stall(reason, detail: detail)
        }

        guard let courier = convoy.courier else {
            return .refreshFleet(tag: Self.rootTag, thenStall: .unreachableDevice)
        }
        guard !convoy.freighters.isEmpty else {
            return .refreshFleet(tag: Self.rootTag, thenStall: .unreachableDevice)
        }

        let carrier = convoy.carrier
        let payload = Self.loadPayload(
            courier: courier, option: option, depot: depot,
            tag: Self.fleetTag(forTheatre: depot), in: world
        )

        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let job = StowOrAttach(
            carrierCode: carrier.deviceCode, deviceCodes: payload.map(\.deviceCode),
            verb: .attach, confirmField: .attachedTo,
            confirmStep: Step.confirmingLoad.rawValue, sendsWholeList: false
        )
        switch job.next(ctx) {
        case let .action(action): return action
        case .noSubject: return .refreshFleet(tag: Self.rootTag, thenStall: .unreachableDevice)
        case .finished, .more: break
        }

        let bill = EventPlan.outstandingResources(option, in: event)
        if bill.isEmpty { return .advanceStep(nextStep: Step.departing.rawValue) }
        guard let plan = Self.loadPlan(bill: bill, across: convoy.freighters) else {
            return Self.holdsCannotTake(bill, convoy.freighters)
        }
        // A laden hull has already taken its share: `collect_resources` is the
        // only thing that puts cargo aboard on this leg.
        guard let berth = plan.first(where: { $0.freighter.cargoUsed == 0 }) else {
            return .advanceStep(nextStep: Step.departing.rawValue)
        }
        if world.openOperation(for: berth.freighter.deviceCode) != nil { return .wait }
        return .dispatch(
            kind: .collectResources, deviceCode: berth.freighter.deviceCode,
            params: CommandParams(resources: berth.take),
            nextStep: Step.confirmingLoad.rawValue
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
        landed += convoy.freighters.count { $0.cargoUsed > 0 }
        let rounds = MissionLogBudget.dispatchRounds(
            world, dispatch: Step.loading.rawValue, confirm: Step.confirmingLoad.rawValue
        )
        if landed >= rounds { return .advanceStep(nextStep: Step.loading.rawValue) }

        guard let depot = world.theatreDepot(for: directive), let courier = convoy.courier
        else { return .refreshFleet(tag: Self.rootTag, thenStall: .unreachableDevice) }
        let option: EventPlan.Option
        switch Self.optionInForce(event, in: world) {
        case .decided(let decided): option = decided
        case .unresolved(let reason, let detail): return .stall(reason, detail: detail)
        }

        let payload = Self.loadPayload(
            courier: courier, option: option, depot: depot,
            tag: Self.fleetTag(forTheatre: depot), in: world
        )
        let loose = payload.filter { $0.attachedToDeviceCode != carrier.deviceCode }
        // The hull just ordered to collect is the empty one the plan is waiting
        // on, so judge that row rather than whichever freighter leads the list.
        let awaited = convoy.freighters.first { $0.cargoUsed == 0 } ?? convoy.freighters.first
        guard let next = loose.first ?? awaited else {
            return .advanceStep(nextStep: Step.loading.rawValue)
        }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let ladder = ConfirmRow(deadline: Self.loadConfirmDeadline, onExpiry: .readThenStall(.commandRejected))
        return switch ladder.verdict([next], ctx) {
        case let .act(action): action
        case .judge: .wait
        }
    }

    // MARK: - Delivery

    /// Order the carrier, then every freighter. Each leg is its own dispatch —
    /// two hulls cannot share one travel command — but a hull already crossing
    /// is stepped over, so the convoy flies abreast rather than one at a time.
    private func departing(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        let destination = event.location
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        var underway = false

        let carrierLeg = TravelTo(
            deviceCode: convoy.carrier.deviceCode, destination: destination,
            arrivalTest: .exactLocation, confirmStep: nil
        )
        if carrierLeg.isUnderway(ctx) {
            underway = true
        } else {
            switch carrierLeg.next(ctx) {
            case let .action(action): return action
            case .more, .noSubject: return .stall(.unreachableDevice)
            case .finished: break   // carrier placed — the freighter legs follow
            }
        }

        guard !convoy.freighters.isEmpty else {
            // A fleet read that has not landed yet still has the whole crossing
            // to arrive in, so a carrier in the air waits rather than reading.
            return underway ? .wait : .refreshFleet(tag: Self.rootTag, thenStall: .unreachableDevice)
        }
        // One leg per hull, dispatched in-step like the carrier's: a confirm
        // step here would end the loop on the first hull, stranding the rest.
        for freighter in convoy.freighters {
            let leg = TravelTo(
                deviceCode: freighter.deviceCode, destination: destination,
                arrivalTest: .exactLocation, confirmStep: nil
            )
            if leg.isUnderway(ctx) {
                underway = true
                continue
            }
            switch leg.next(ctx) {
            case let .action(action): return action
            case .finished: continue
            case .more, .noSubject: return .stall(.unreachableDevice)
            }
        }
        // Every hull is either standing at the event or in the air toward it.
        return underway ? .wait : .advanceStep(nextStep: Step.confirmingArrival.rawValue)
    }

    /// Both hulls placed at the event, on rows read since the step began.
    private func confirmArrival(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        let rows = [convoy.carrier] + convoy.freighters
        let placed = rows.allSatisfy {
            world.isFresh($0, since: directive.stepStartedAt) && $0.location == event.location
        }
        if placed { return .advanceStep(nextStep: Step.staging.rawValue) }
        if rows.contains(where: { world.openOperation(for: $0.deviceCode) != nil }) { return .wait }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let ladder = ConfirmRow(
            deadline: Self.arrivalConfirmDeadline, onExpiry: .readThenStall(.vesselPositionUnconfirmed)
        )
        return switch ladder.verdict(rows, ctx) {
        case let .act(action): action
        case .judge: .wait
        }
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
            world, dispatch: Step.staging.rawValue, confirm: Step.confirmingStage.rawValue, kind: kind
        )
    }

    /// Set the load down and empty the hold, each leg ordered at most once. Both
    /// verbs are immediate, so the event's own progress judges the delivery.
    private func staging(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        let option: EventPlan.Option
        switch Self.optionInForce(event, in: world) {
        case .decided(let decided): option = decided
        case .unresolved(let reason, let detail): return .stall(reason, detail: detail)
        }

        let aboard = Self.staged(convoy, in: world)
        if !aboard.isEmpty, Self.stageRounds(world, .detach) < 1 {
            let ctx = StepContext(directive: directive, world: world, step: directive.step)
            let job = StowOrAttach(
                carrierCode: convoy.carrier.deviceCode, deviceCodes: aboard.map(\.deviceCode),
                verb: .detach, confirmField: .loose,
                confirmStep: Step.confirmingStage.rawValue, sendsWholeList: true
            )
            switch job.next(ctx) {
            case let .action(action): return action
            case .finished, .more, .noSubject: break
            }
        }

        guard !option.resources.isEmpty else { return .advanceStep(nextStep: Step.confirmingProgress.rawValue) }
        guard !convoy.freighters.isEmpty else {
            return .refreshFleet(tag: Self.rootTag, thenStall: .unreachableDevice)
        }
        // The shares the load was planned against, so each hull sets down what it
        // was filled with. Round-counted: the deposit proves the hold, not the row.
        let bill = EventPlan.outstandingResources(option, in: event)
        guard let plan = Self.loadPlan(bill: bill, across: convoy.freighters) else {
            return Self.holdsCannotTake(bill, convoy.freighters)
        }
        let rounds = Self.stageRounds(world, .depositResources)
        if rounds < plan.count {
            return .dispatch(
                kind: .depositResources, deviceCode: plan[rounds].freighter.deviceCode,
                params: CommandParams(resources: plan[rounds].take),
                nextStep: Step.confirmingStage.rawValue
            )
        }
        return .advanceStep(nextStep: Step.confirmingProgress.rawValue)
    }

    /// Judge a detach on the rows it moved. A deposit leaves no local proof — a
    /// hold may carry more than the option asked for — so it hands straight back.
    private func confirmStage(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard case .dispatched(let kind, _) = MissionLogBudget.lastDispatch(
            world, dispatch: Step.staging.rawValue, confirm: Step.confirmingStage.rawValue
        ), kind == OperationKind.detach.rawValue else {
            return .advanceStep(nextStep: Step.staging.rawValue)
        }
        let aboard = Self.staged(convoy, in: world)
        if aboard.isEmpty { return .advanceStep(nextStep: Step.staging.rawValue) }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let ladder = ConfirmRow(deadline: Self.stageConfirmDeadline, onExpiry: .readThenStall(.commandRejected))
        return switch ladder.verdict(aboard, ctx) {
        case let .act(action): action
        case .judge: .wait
        }
    }

    // MARK: - Commit

    /// The event's own live progress is the authority: met, and a replicant on
    /// site. A row read before the deposit landed proves nothing, so a stale
    /// ledger buys one read per cycle until the deadline.
    private func confirmProgress(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard event.isActive else { return .advanceStep(nextStep: Step.recovering.rawValue) }
        let detail = LocationEventDetail(event.detail)
        if detail?.met == true, detail?.replicantPresent == true {
            return .advanceStep(nextStep: Step.committing.rawValue)
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
        guard event.isActive else { return .advanceStep(nextStep: Step.collecting.rawValue) }
        return .completeEvent(
            location: event.location, designation: event.designation, nextStep: Step.collecting.rawValue
        )
    }

    /// What the closed event's reward is worth to the convoy standing on it.
    /// Three outcomes, not two: nothing paid and nothing liftable are the same
    /// step move but different facts, and only one of them loses resources.
    enum Sweep: Equatable, Sendable {
        /// The reward paid no resources — an XP-only event.
        case nothingPaid
        /// A real pile no hold in the convoy has room for. It stays for a haul.
        case willNotFit([String: Int])
        /// The berth taking the sweep, and what no hold could take.
        case lift(berth: Berth, unswept: [String: Int])
    }

    /// The homeward policy on `divide`: the roomiest hull takes what it can and
    /// the rest stays put, because a reward too big to lift is a haul's job
    /// rather than a stall. Ties go to the hull earlier in load order.
    static func sweep(_ event: LocationEvent, across freighters: [Device]) -> Sweep {
        let pile = rewardPile(event)
        if pile.isEmpty { return .nothingPaid }
        let roomiest = freighters.enumerated()
            .max { (freeHold($0.element), -$0.offset) < (freeHold($1.element), -$1.offset) }?
            .element
        guard let roomiest else { return .willNotFit(pile) }
        let division = divide(pile, across: [roomiest], room: freeHold)
        guard let berth = division.berths.first else { return .willNotFit(pile) }
        return .lift(berth: berth, unswept: division.unplaced)
    }

    /// What the completion paid, per resource type. An XP-only reward pays none.
    private static func rewardPile(_ event: LocationEvent) -> [String: Int] {
        let reward = LocationEventDetail(event.detail)?.rewardResources ?? []
        return Dictionary(
            reward.filter { $0.amount > 0 }.map { ($0.resourceType, $0.amount) },
            uniquingKeysWith: { first, _ in first }
        )
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
        guard !convoy.freighters.isEmpty else {
            return .refreshFleet(tag: Self.rootTag, thenStall: .unreachableDevice)
        }
        // Room is judged across the WHOLE convoy: a full lead hull is not the
        // convoy being full, and only the second fact leaves a reward behind.
        switch Self.sweep(event, across: convoy.freighters) {
        case .nothingPaid:
            return .advanceStep(nextStep: Step.recovering.rawValue)
        case .willNotFit(let pile):
            Self.logUnswept(pile, directive, event)
            return .advanceStep(nextStep: Step.recovering.rawValue)
        case .lift(let berth, let unswept):
            if world.openOperation(for: berth.freighter.deviceCode) != nil { return .wait }
            Self.logUnswept(unswept, directive, event)
            return .dispatch(
                kind: .collectResources, deviceCode: berth.freighter.deviceCode,
                params: CommandParams(resources: berth.take),
                nextStep: Step.recovering.rawValue
            )
        }
    }

    private static func logUnswept(
        _ pile: [String: Int], _ directive: Directive, _ event: LocationEvent
    ) {
        guard !pile.isEmpty else { return }
        let left = pile.keys.sorted().map { "\($0) \(pile[$0] ?? 0)" }.joined(separator: ", ")
        logger.notice("event run \(directive.id, privacy: .public): convoy full at \(event.location, privacy: .public) — reward left for a haul: \(left, privacy: .public)")
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
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let job = StowOrAttach(
            carrierCode: convoy.carrier.deviceCode, deviceCodes: [courier.deviceCode],
            verb: .attach, confirmField: .attachedTo,
            confirmStep: Step.confirmingRecovery.rawValue, sendsWholeList: false
        )
        return switch job.next(ctx) {
        case let .action(action):
            world.openOperation(for: convoy.carrier.deviceCode) != nil ? .wait : action
        case .finished, .more: .advanceStep(nextStep: Step.returning.rawValue)
        case .noSubject: .refreshFleet(tag: Self.rootTag, thenStall: .unreachableDevice)
        }
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
            return .advanceStep(nextStep: Step.recovering.rawValue)
        }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let ladder = ConfirmRow(deadline: Self.recoveryConfirmDeadline, onExpiry: .readThenStall(.commandRejected))
        return switch ladder.verdict([courier], ctx) {
        case let .act(action): action
        case .judge: .wait
        }
    }

    /// Both hulls to the depot, resolved through the row's own theatre — never
    /// `originDesignation`, a bare system that travels to an entry point rather
    /// than to the depot where the printer stands.
    private func returning(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let hulls = ([convoy.carrier] + convoy.freighters).map(\.deviceCode)
        let home = ReturnHome(deviceCodes: hulls, destination: .theatreDepot)
        // A statement switch, not an expression one: the `.noSubject` arm logs
        // before it answers, and an expression arm has nowhere to put that.
        switch home.next(ctx) {
        case let .action(action):
            return action
        case .finished, .more:
            return .advanceStep(nextStep: Step.depositing.rawValue)
        case .noSubject:
            logger.notice("event run \(directive.id, privacy: .public): no depot to return to — leaving the convoy where it stands")
            return .done
        }
    }

    // MARK: - Unloading

    private static func depositRounds(_ world: WorldSnapshot) -> Int {
        MissionLogBudget.dispatchRounds(
            world, dispatch: Step.depositing.rawValue, confirm: Step.confirmingDeposit.rawValue,
            kind: .depositResources
        )
    }

    /// Empty every laden hold at the depot, one hull per round. Nil resources
    /// unload a hull whole, which is its own sweep and nothing else: the launch
    /// gate leased it empty.
    private func depositing(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let freighter = convoy.freighters.first(where: { $0.cargoUsed > 0 })
        else { return .done }
        if world.openOperation(for: freighter.deviceCode) != nil { return .wait }
        // One round per hull, counted against the WHOLE convoy: a bound read off
        // the laden ones shrinks as they empty and retires the loop mid-convoy.
        guard Self.depositRounds(world) < convoy.freighters.count else { return .done }
        return .dispatch(
            kind: .depositResources, deviceCode: freighter.deviceCode,
            params: CommandParams(), nextStep: Step.confirmingDeposit.rawValue
        )
    }

    /// Judge the unload on the hull that was ordered, then hand back for the
    /// next laden one. A hold left full parks the hull outside the next convoy's
    /// empty-hold gate, so it is worth a stall.
    private func confirmDeposit(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard !convoy.freighters.isEmpty else { return .done }
        // The hull just ordered, or — with nothing sent this cycle — whatever
        // still reads laden, so a hold nobody ordered is still not forgotten.
        let ordered: Device?
        if case let .dispatched(_, code) = MissionLogBudget.lastDispatch(
            world, dispatch: Step.depositing.rawValue, confirm: Step.confirmingDeposit.rawValue
        ) {
            ordered = convoy.freighters.first { $0.deviceCode == code }
        } else {
            ordered = nil
        }
        guard let awaited = ordered ?? convoy.freighters.first(where: { $0.cargoUsed > 0 })
        else { return .advanceStep(nextStep: Step.depositing.rawValue) }
        if world.isFresh(awaited, since: directive.stepStartedAt), awaited.cargoUsed == 0 {
            return .advanceStep(nextStep: Step.depositing.rawValue)
        }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let ladder = ConfirmRow(deadline: Self.depositConfirmDeadline, onExpiry: .readThenStall(.commandRejected))
        return switch ladder.verdict([awaited], ctx) {
        case let .act(action): action
        case .judge: .wait
        }
    }

    /// The run never roams.
    public func plan(_ context: RoamContext) -> RoamPlan { .exhausted }
}
