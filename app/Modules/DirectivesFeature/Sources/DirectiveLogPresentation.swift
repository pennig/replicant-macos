//
//  DirectiveLogPresentation.swift
//  Replicould — Directives feature
//
//  Timeline rendering choices, in a SwiftUI-free namespace — pure logic hanging
//  off a `View` traps under `swift test` (see the statics-in-tests memory note).
//

import Foundation
import GameModels

public enum DirectiveLogPresentation {
    /// The glyph for an entry kind. The timeline is scanned rather than read,
    /// so each kind gets a distinct one.
    public static func symbol(for kind: DirectiveLogKind) -> String {
        switch kind {
        case .stepStarted: "arrow.forward.circle"
        case .commandDispatched: "paperplane"
        case .opCompleted: "checkmark.circle"
        case .directiveCompleted: "flag.checkered"
        case .launchDeployedNothing: "tray"
        case .stalled: "exclamationmark.triangle.fill"
        case .resolved: "hand.raised"
        }
    }

    /// Whether an entry should stand out. A stall is the one thing in the
    /// timeline the user must act on; a completion is the one they're waiting
    /// for. An empty launch is the moment a run silently stopped being able to
    /// progress, so it belongs with them. Everything else is routine progress
    /// and should recede.
    public static func isProminent(_ kind: DirectiveLogKind) -> Bool {
        kind == .stalled || kind == .directiveCompleted || kind == .launchDeployedNothing
    }
}
