//
//  MissionRegistry.swift
//  Replicould — DirectiveEngine
//
//  The one place mission machines are registered. Both the engine (which
//  machine runs a directive) and resolution (which step a skipped target
//  restarts at) resolve through here, so a kind registered once is registered
//  for both.
//

import Foundation
import GameModels

/// The registered mission machines, and the two lookups over them.
public enum MissionRegistry {
    /// Every mission the app can run.
    public static let machines: [any MissionStepMachine] = [
        SurveyRun(), SalvageRun(), HaulRun(), RelayRun(), RestockRun(), MineFleetPrint(),
        MineRun(), EventRun(), EventCourierPrint(),
    ]

    /// The machine registered for `kind`, or nil when none is — which the
    /// engine reads as "leave every row of that kind alone".
    public static func machine(for kind: DirectiveKind) -> (any MissionStepMachine)? {
        machines.first { $0.kind == kind }
    }

    /// The step a freshly-started target of `kind` begins on, or nil for a kind
    /// with no registered machine — which the engine leaves alone anyway.
    public static func firstStep(for kind: DirectiveKind) -> String? {
        machine(for: kind)?.firstStep
    }
}
