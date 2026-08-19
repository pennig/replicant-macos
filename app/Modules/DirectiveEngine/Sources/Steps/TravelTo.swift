//
//  TravelTo.swift
//  Replicould — DirectiveEngine
//
//  Flying one device to one place: the already-there test, the busy guard, the
//  arrival watermark, the dispatch. Every travelling mission's frame.
//

import Foundation
import GameModels
import GameServices
import UniverseModels

/// One travel leg, as a pure value.
struct TravelTo: Equatable, Sendable {
    /// How close counts as arrived. A location is a SITE, so `SOL-3` is in
    /// `SOL` under `.system` and is not `SOL-3-1` under `.exactLocation`.
    enum ArrivalTest: Equatable, Sendable {
        case system
        case exactLocation
    }

    /// How long an unconfirmed arrival is tolerated before the read stalls.
    static let arrivalConfirmDeadline: TimeInterval = 5 * 60
    /// Floor between reads of a row that predates its own arrival.
    static let arrivalReadInterval: TimeInterval = 30

    let deviceCode: String
    let destination: String
    let arrivalTest: ArrivalTest
    /// The step the dispatch names. Nil is the same-step loop, where the
    /// tracked `.travel` op is the guard against re-issuing every tick.
    let confirmStep: String?

    init(
        deviceCode: String, destination: String, arrivalTest: ArrivalTest, confirmStep: String?
    ) {
        self.deviceCode = deviceCode
        self.destination = destination
        self.arrivalTest = arrivalTest
        self.confirmStep = confirmStep
    }

    func hasArrived(_ device: Device) -> Bool {
        switch arrivalTest {
        case .system: device.location.map { SiteAssay.system(of: $0) } == destination
        case .exactLocation: device.location == destination
        }
    }

    func next(_ ctx: StepContext) -> StepResult {
        guard let device = ctx.world.device(deviceCode) else { return .noSubject }
        if hasArrived(device) { return .finished }
        // An open op means the trip is under way; waiting stops a second
        // travel landing on top of the first.
        if ctx.openOperation(for: deviceCode) != nil { return .action(.wait) }
        // The equality check above misreads a row still lagging the arrival.
        if let unconfirmed = Self.positionUnconfirmed(device, ctx.world) { return .action(unconfirmed) }
        return .action(.dispatch(
            kind: .travel, deviceCode: deviceCode,
            params: CommandParams(destination: destination),
            nextStep: confirmStep ?? ctx.step
        ))
    }

    /// When the last travel this directive dispatched for `device` finished, or
    /// nil. Filters on `.completed` EXACTLY: `.superseded` and `.unknown` also
    /// stamp `lastConfirmedAt` on travels that never arrived.
    static func lastTravelCompletion(for device: Device, _ world: WorldSnapshot) -> Date? {
        world.dispatchedOperations.values
            .lazy
            .filter {
                $0.entityCode == device.deviceCode
                    && $0.kind == OperationKind.travel.rawValue
                    && $0.status == .completed
            }
            .map(\.lastConfirmedAt)
            .max()
    }

    /// What a dispatch site should do when `device`'s row cannot yet be
    /// trusted to say where it is; nil means dispatch may proceed. **Order is
    /// mandated:** deadline, throttled read, `.wait` — the ARRIVAL is the watermark.
    static func positionUnconfirmed(_ device: Device, _ world: WorldSnapshot) -> MissionAction? {
        // Nothing to post-date, so cold runs and first entries dispatch at once.
        guard let completion = lastTravelCompletion(for: device, world) else { return nil }
        guard device.updatedAt < completion else { return nil }
        if world.now.timeIntervalSince(completion) >= arrivalConfirmDeadline {
            return .refreshDevices(
                deviceCodes: [device.deviceCode], thenStall: .vesselPositionUnconfirmed
            )
        }
        if world.now.timeIntervalSince(device.updatedAt) > arrivalReadInterval {
            return .refreshDevices(deviceCodes: [device.deviceCode], thenStall: nil)
        }
        return .wait
    }
}
