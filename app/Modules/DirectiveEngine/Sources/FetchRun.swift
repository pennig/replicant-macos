//
//  FetchRun.swift
//  Replicould — DirectiveEngine
//
//  One device moved from where it stands to a location the operator named, on
//  a surge plate. User-launched only. Pure — every effect is the returned
//  `MissionAction`, and time comes from `world.now`.
//

import Foundation
import GameModels
import GameServices
import OSLog
import UniverseModels

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

public struct FetchRun: MissionStepMachine {
    public let kind: DirectiveKind = .fetchRun
    public var firstStep: String { Step.preflight.rawValue }

    public init() {}

    /// This mission's step vocabulary, as `Directive.step` holds it.
    public enum Step: String, CaseIterable, Sendable {
        /// Prove the plate and the payload before anything is commanded.
        case preflight
        /// Compact the payload and fly the plate to it, concurrently.
        case staging
        case attaching
        case confirmingAttach
        case delivering
        case detaching
        case confirmingDetach
        /// Park the plate at a theatre near where it dropped the payload.
        case homing
    }

    /// The hull this run flies. Not `surge_carrier`, which is a larger type
    /// with its own fleet queries.
    public static let plateDeviceType = "surge_plate"

    /// A bare tag, not a `FleetTag`: `FleetTag` parses `auto:<goal>` forms and
    /// would not match what an operator types into the device inspector.
    public static let fetchTag = "fetch"

    /// How stale a row may be and still be believed at preflight.
    public static let stagingFreshness: TimeInterval = 5 * 60

    /// How long an unconfirmed attach or detach is tolerated.
    public static let containmentDeadline: TimeInterval = 5 * 60

    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        guard let step = Step(rawValue: directive.step) else {
            logger.notice("\(kind.rawValue, privacy: .public) \(directive.id, privacy: .public): unknown step \(directive.step, privacy: .public) — waiting")
            return .wait
        }
        switch step {
        case .preflight: return preflight(directive, world)
        case .staging: return stage(directive, world)
        case .attaching: return attach(directive, world)
        case .confirmingAttach: return confirmAttach(directive, world)
        case .delivering: return deliver(directive, world)
        case .detaching: return detach(directive, world)
        case .confirmingDetach: return confirmDetach(directive, world)
        case .homing: return home(directive, world)
        }
    }

    /// A fetch run has no roam, and must never finish itself through the
    /// queue-extension path.
    public func plan(_ context: RoamContext) -> RoamPlan { .idle }

    // MARK: - Reading the row

    /// Where the payload is collected. Pinned at launch, because the payload's
    /// own `location` goes nil the moment it is attached.
    public static func pickup(of directive: Directive) -> String? {
        directive.targets.count == 2 ? directive.targets[0] : nil
    }

    /// Where the payload is going.
    public static func destination(of directive: Directive) -> String? {
        directive.targets.count == 2 ? directive.targets[1] : nil
    }

    // MARK: - Plate selection

    /// The plate to fly to `pickup`: tagged, unleased, with a free attach slot.
    /// Nearest first, device code as the tie-break — a TOTAL order, so the
    /// answer cannot flicker with dictionary iteration.
    public static func plate(
        for pickup: String,
        in devices: some Sequence<Device>,
        reserved: Set<String>,
        positions: [String: Position]
    ) -> Device? {
        let origin = positions[SiteAssay.system(of: pickup)]
        return devices
            .filter { isEligible($0, reserved: reserved) }
            .min { lhs, rhs in
                let left = distance(from: origin, to: lhs, positions)
                let right = distance(from: origin, to: rhs, positions)
                return left == right ? lhs.deviceCode < rhs.deviceCode : left < right
            }
    }

    /// The predicate `plate(for:in:reserved:positions:)` ranks. Exposed so
    /// preflight re-validates the plate it was launched with by the same rule
    /// the picker offered it under.
    public static func isEligible(_ device: Device, reserved: Set<String>) -> Bool {
        device.deviceType == plateDeviceType
            && device.tags.contains(fetchTag)
            && !reserved.contains(device.deviceCode)
            && device.attachCapacity > device.attachedDeviceCodes.count
            && device.location != nil
    }

    /// A plate whose system the census has not placed sorts last rather than
    /// being excluded — it is still a usable hull.
    private static func distance(
        from origin: Position?, to device: Device, _ positions: [String: Position]
    ) -> Double {
        guard let origin, let location = device.location,
              let position = positions[SiteAssay.system(of: location)]
        else { return .infinity }
        return origin.distance(to: position)
    }

    /// Whether `payload` still has to pack down. `statusBase`, not `status` — a
    /// status can carry a suffix, and every other check in `Device` goes through it.
    static func needsCompacting(_ payload: Device, _ world: WorldSnapshot) -> Bool {
        world.modularDeviceTypes.contains(payload.deviceType) && payload.statusBase != "compacted"
    }

    // MARK: - Steps

    /// Prove the plate and the payload before anything is commanded. The plate
    /// is never re-picked here: `deviceCode` is the lease, and moving it would
    /// leave the run holding nothing for a tick.
    private func preflight(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let payloadCode = directive.payloadCode,
              let destination = Self.destination(of: directive)
        else { return .stall(.unreachableDevice) }
        let codes = [directive.deviceCode, payloadCode]
        guard let plate = world.device(directive.deviceCode),
              let payload = world.device(payloadCode)
        else { return .refreshDevices(deviceCodes: codes, thenStall: .unreachableDevice) }

        let stale = [plate, payload].contains {
            world.now.timeIntervalSince($0.updatedAt) > Self.stagingFreshness
        }
        if stale { return .refreshDevices(deviceCodes: codes, thenStall: nil) }

        // Moved by hand between launch and now: the job is already done.
        if payload.location == destination { return .done }

        let ownership = Ownership.resolve(
            directives: world.peers, devices: world.devices, theatres: world.theatres
        )
        // `peers` carries this run's own row, so its own claim must not count.
        if let rival = ownership.holders(of: payloadCode)
            .first(where: { $0.directiveID != directive.id })
        {
            return .stall(.fetchPayloadLeased, detail: rival.directiveID)
        }
        // Empty `reserved`: this plate is SUPPOSED to be leased, by this run.
        guard Self.isEligible(plate, reserved: []) else { return .stall(.noFetchPlateAvailable) }
        return .advanceStep(nextStep: Step.staging.rawValue)
    }

    /// Compaction and the plate's inbound flight, overlapped. The engine takes
    /// one action per evaluation, so this is a priority ladder, not a sequence:
    /// the compaction goes out first and the plate launches under it.
    private func stage(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let payloadCode = directive.payloadCode,
              let plate = world.device(directive.deviceCode),
              let payload = world.device(payloadCode),
              let pickup = Self.pickup(of: directive)
        else { return .stall(.unreachableDevice) }

        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let payloadBusy = ctx.openOperation(for: payloadCode) != nil
        let plateBusy = ctx.openOperation(for: plate.deviceCode) != nil

        if Self.needsCompacting(payload, world), !payloadBusy {
            return .dispatch(
                kind: .compact, deviceCode: payloadCode,
                params: CommandParams(), nextStep: Step.staging.rawValue
            )
        }

        let leg = TravelTo(
            deviceCode: plate.deviceCode, destination: pickup,
            arrivalTest: .exactLocation, confirmStep: Step.staging.rawValue
        )
        if !leg.hasArrived(plate), !plateBusy, case let .action(action) = leg.next(ctx) {
            return action
        }

        // Both halves, not just the plate: a payload mid-travel of its own
        // would otherwise reach an attach the server refuses.
        let settled = leg.hasArrived(plate) && !plateBusy
            && !Self.needsCompacting(payload, world) && !payloadBusy
        return settled ? .advanceStep(nextStep: Step.attaching.rawValue) : .wait
    }

    /// Put the payload on the plate's attach grid.
    private func attach(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let payloadCode = directive.payloadCode else { return .stall(.unreachableDevice) }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let job = StowOrAttach(
            carrierCode: directive.deviceCode, deviceCodes: [payloadCode], verb: .attach,
            confirmField: .attachedTo, confirmStep: Step.confirmingAttach.rawValue,
            sendsWholeList: false
        )
        switch job.next(ctx) {
        case let .action(action): return action
        case .finished: return .advanceStep(nextStep: Step.delivering.rawValue)
        case .more: return .wait
        case .noSubject: return .stall(.unreachableDevice)
        }
    }

    /// Judge the attach on the payload's own row. Every path that stays in this
    /// step returns `.wait` — the one action that does not re-stamp
    /// `stepStartedAt`, so anything else makes the deadline unreachable.
    private func confirmAttach(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let payloadCode = directive.payloadCode,
              let payload = world.device(payloadCode)
        else { return .stall(.unreachableDevice) }
        if payload.attachedToDeviceCode == directive.deviceCode {
            return .advanceStep(nextStep: Step.delivering.rawValue)
        }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let ladder = ConfirmRow(
            deadline: Self.containmentDeadline, onExpiry: .readThenStall(.commandRejected)
        )
        return switch ladder.verdict([payload], ctx) {
        case let .act(action): action
        case .judge: .wait
        }
    }

    /// The loaded leg. A same-step loop, guarded by the tracked travel op.
    private func deliver(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let destination = Self.destination(of: directive) else {
            return .stall(.unreachableDevice)
        }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let leg = TravelTo(
            deviceCode: directive.deviceCode, destination: destination,
            arrivalTest: .exactLocation, confirmStep: nil
        )
        switch leg.next(ctx) {
        case let .action(action): return action
        case .finished: return .advanceStep(nextStep: Step.detaching.rawValue)
        case .more: return .wait
        case .noSubject: return .stall(.unreachableDevice)
        }
    }

    private func detach(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let payloadCode = directive.payloadCode else { return .stall(.unreachableDevice) }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let job = StowOrAttach(
            carrierCode: directive.deviceCode, deviceCodes: [payloadCode], verb: .detach,
            confirmField: .loose, confirmStep: Step.confirmingDetach.rawValue,
            sendsWholeList: false
        )
        switch job.next(ctx) {
        case let .action(action): return action
        case .finished: return .advanceStep(nextStep: Step.confirmingDetach.rawValue)
        case .more: return .wait
        case .noSubject: return .stall(.unreachableDevice)
        }
    }

    /// Loose AND standing where it was asked for. Either test alone would
    /// report a device dropped in the wrong place as a delivery.
    private func confirmDetach(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let payloadCode = directive.payloadCode,
              let payload = world.device(payloadCode),
              let destination = Self.destination(of: directive)
        else { return .stall(.unreachableDevice) }
        if payload.attachedToDeviceCode == nil, payload.location == destination {
            return .releasePayload(nextStep: Step.homing.rawValue)
        }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let ladder = ConfirmRow(
            deadline: Self.containmentDeadline, onExpiry: .readThenStall(.commandRejected)
        )
        return switch ladder.verdict([payload], ctx) {
        case let .act(action): action
        case .judge: .wait
        }
    }

    /// Park the plate near where it dropped the payload. Resolved fresh rather
    /// than from the row's launch stamp: a flight is long enough for a theatre
    /// to stop being operational.
    private func home(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let destination = Self.destination(of: directive) else { return .done }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let leg = ReturnHome(
            deviceCodes: [directive.deviceCode],
            destination: .nearestTo(system: SiteAssay.system(of: destination))
        )
        switch leg.next(ctx) {
        case let .action(action): return action
        case .finished: return .done
        case .more: return .wait
        case .noSubject:
            // The run's own job is complete and the plate is loose and idle at
            // the destination; stalling here would be noise, not a fault.
            logger.notice("fetch run \(directive.id, privacy: .public): no operational theatre near \(destination, privacy: .public) — leaving the plate there")
            return .done
        }
    }
}
