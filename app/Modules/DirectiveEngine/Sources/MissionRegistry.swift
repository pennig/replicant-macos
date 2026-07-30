//
//  MissionRegistry.swift
//  Replicould — DirectiveEngine
//
//  The one place mission machines are registered. Both the engine (which
//  machine runs a directive) and resolution (which step a skipped target
//  restarts at) resolve through here, so adding Relay Run in Stage 5 is a
//  one-line edit rather than two.
//

import Foundation
import GameModels

public enum MissionRegistry {
    /// Every mission the app can run. Relay Run joins in Stage 5.
    public static let machines: [any MissionStepMachine] = [SurveyRun(), SalvageRun()]

    public static func machine(for kind: DirectiveKind) -> (any MissionStepMachine)? {
        machines.first { $0.kind == kind }
    }

    /// The step a freshly-started target begins on, or nil for a kind with no
    /// registered machine — which the engine leaves alone anyway.
    public static func firstStep(for kind: DirectiveKind) -> String? {
        machine(for: kind)?.firstStep
    }
}
