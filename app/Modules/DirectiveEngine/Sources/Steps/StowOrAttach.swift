//
//  StowOrAttach.swift
//  Replicould — DirectiveEngine
//
//  Putting devices into and out of a carrier: pick the devices still to move,
//  then order them. The caller's list order is the dispatch order.
//

import Foundation
import GameModels
import GameServices

/// One containment order, as a pure value.
struct StowOrAttach: Equatable, Sendable {
    enum Verb: Equatable, Sendable {
        case attach, detach, adopt

        var kind: OperationKind {
            switch self {
            case .attach: .attach
            case .detach: .detach
            case .adopt: .adopt
            }
        }
    }

    /// Which column proves the order landed.
    enum ConfirmField: Equatable, Sendable {
        case attachedTo
        case controlledBy
        /// Detach's proof: the column is nil.
        case loose
    }

    /// The device the command is issued ON — the carrier, or the controller
    /// for `.adopt`.
    let carrierCode: String
    /// The subjects, in the order they should be moved.
    let deviceCodes: [String]
    let verb: Verb
    let confirmField: ConfirmField
    let confirmStep: String
    /// Whether one command carries the whole pending list, or one device rides
    /// each round so a partial failure shows in the timeline. A site property:
    /// the verb alone does not say which.
    let sendsWholeList: Bool

    init(
        carrierCode: String, deviceCodes: [String], verb: Verb,
        confirmField: ConfirmField, confirmStep: String, sendsWholeList: Bool
    ) {
        self.carrierCode = carrierCode
        self.deviceCodes = deviceCodes
        self.verb = verb
        self.confirmField = confirmField
        self.confirmStep = confirmStep
        self.sendsWholeList = sendsWholeList
    }

    func next(_ ctx: StepContext) -> StepResult {
        let rows = deviceCodes.compactMap { ctx.world.device($0) }
        guard rows.count == deviceCodes.count else { return .noSubject }
        let pending = rows.filter { !isPlaced($0) }
        guard let first = pending.first else { return .finished }
        let sending = sendsWholeList ? pending : [first]
        return .action(.dispatch(
            kind: verb.kind, deviceCode: carrierCode,
            params: CommandParams(devices: sending.map(\.deviceCode)),
            nextStep: confirmStep
        ))
    }

    private func isPlaced(_ device: Device) -> Bool {
        switch confirmField {
        case .attachedTo: device.attachedToDeviceCode == carrierCode
        case .controlledBy: device.controllerDeviceCode == carrierCode
        case .loose: device.attachedToDeviceCode == nil
        }
    }
}
