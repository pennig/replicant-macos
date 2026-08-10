//
//  HaulYieldMachine.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The pickup/delivery decision, pure over the fleet's carried total.
//

import Foundation

public enum HaulYieldStep: Equatable, Sendable {
    case none
    case pickup(units: Int, source: String, deviceCode: String)
    case delivery(units: Int, destination: String)
}

public enum HaulYieldMachine {
    /// `openUnits` is the controller's live open-row total (0 when there are
    /// none) — a nonzero hold at zero history is recorded at first sight, on
    /// the theory that the units are real even though the moment was missed.
    public static func step(openUnits: Int, digest: TransportDigest) -> HaulYieldStep {
        let delta = digest.cargoCarried - openUnits
        if delta > 0 {
            guard let source = digest.collect, let deviceCode = digest.activeDeviceCode else {
                return .none
            }
            return .pickup(units: delta, source: source, deviceCode: deviceCode)
        }
        if delta < 0 {
            guard let destination = digest.deliver else { return .none }
            return .delivery(units: -delta, destination: destination)
        }
        return .none
    }
}
