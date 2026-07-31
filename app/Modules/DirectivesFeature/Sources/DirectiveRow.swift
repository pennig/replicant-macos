//
//  DirectiveRow.swift
//  Replicould — Directives feature
//
//  The unified list's row model. Two sources, one view model: custom missions
//  come from the `Directive` table, built-in AMI directives are DERIVED from
//  `Device` rows and never persisted — the server owns that state, so a derived
//  row is structurally incapable of drifting from it.
//
//  Deliberately SwiftUI-free: this is the list's only real logic, and pure
//  logic hanging off a SwiftUI View traps under `swift test`.
//

import Foundation
import GameModels
import Utils

/// The custom mission currently driving a built-in AMI directive. Present only
/// while that mission is live — the engine set the directive, so the user must
/// not Reconfigure or Clear it out from under a step that is waiting on it.
public struct DirectiveOwner: Equatable, Sendable {
    public let directiveID: String
    /// The mission's display title, e.g. "Survey Run" — what the badge says.
    public let kindTitle: String

    public init(directiveID: String, kindTitle: String) {
        self.directiveID = directiveID
        self.kindTitle = kindTitle
    }
}

/// An AMI directive currently in force on a device, projected for the list.
public struct BuiltInDirective: Equatable, Identifiable, Sendable {
    public let deviceCode: String
    public let deviceType: String
    /// The directive's backend name, e.g. `survey_system`.
    public let directive: String
    /// Its in-force configuration, or nil for directives that take none.
    public let config: JSONValue?
    /// The drones this controller is running, with their live status.
    public let controlledDevices: [Device.ControlledDevice]
    /// Set when a live mission is driving this directive (see `DirectiveOwner`).
    public let drivenBy: DirectiveOwner?

    public var id: String { deviceCode }

    public init(
        deviceCode: String,
        deviceType: String,
        directive: String,
        config: JSONValue?,
        controlledDevices: [Device.ControlledDevice],
        drivenBy: DirectiveOwner? = nil
    ) {
        self.deviceCode = deviceCode
        self.deviceType = deviceType
        self.directive = directive
        self.config = config
        self.controlledDevices = controlledDevices
        self.drivenBy = drivenBy
    }
}

/// One row of the Directives list — either kind.
public enum DirectiveRow: Equatable, Identifiable, Sendable {
    case custom(Directive)
    case builtIn(BuiltInDirective)

    /// Namespaced so a device code and a directive id can never collide in the
    /// list's selection.
    public var id: String {
        switch self {
        case let .custom(directive): "custom:\(directive.id)"
        case let .builtIn(builtIn): "builtin:\(builtIn.deviceCode)"
        }
    }

    /// The device the row is about — the vessel for a mission, the controller
    /// for a built-in directive.
    public var deviceCode: String {
        switch self {
        case let .custom(directive): directive.deviceCode
        case let .builtIn(builtIn): builtIn.deviceCode
        }
    }

    /// The row's headline, **without** any designation — see
    /// `headlineDesignation`. Split because a designation must render in a mono
    /// token (house rule) and a single interpolated string forces one font on
    /// the whole line.
    public var headline: String {
        switch self {
        case let .custom(directive): directive.kind.title
        case let .builtIn(builtIn): BlueprintPresentation.displayName(builtIn.directive)
        }
    }

    /// The designation half of the headline — a mission's current target, or nil
    /// (built-in rows name a directive, never a place).
    public var headlineDesignation: String? {
        switch self {
        case let .custom(directive): directive.currentTarget
        case .builtIn: nil
        }
    }

    /// The whole headline as one string, for `navigationTitle` and
    /// accessibility, where a single `String` is all the API accepts. Anywhere
    /// that can render two runs should use `headline` + `headlineDesignation`.
    public var title: String {
        guard let designation = headlineDesignation else { return headline }
        return "\(headline) → \(designation)"
    }

    /// The row's second line: progress for a mission, the controlled-drone count
    /// for a built-in — or, when the engine owns it, the mission driving it.
    ///
    /// Lives here rather than on `DirectiveRowView` because this type is the
    /// list's SwiftUI-free logic (pure logic hanging off a View traps under
    /// `swift test`), which is what makes the continuous-run branch below
    /// testable at all.
    public var subtitle: String? {
        switch self {
        case let .custom(directive):
            // A continuous run EXTENDS its queue instead of completing it, so
            // `targetIndex == targets.count` for the whole window between
            // finishing one system and planning the next — and "n/n" reads as a
            // finished run. Count what is done instead. The current target is
            // not repeated here; `headlineDesignation` already renders it.
            if directive.roamCentre != nil {
                switch directive.kind {
                case .salvageRun:
                    let count = directive.targetIndex
                    return "\(count) system\(count == 1 ? "" : "s") drained"
                case .surveyRun, .relayRun:
                    return "\(directive.targetIndex) surveyed"
                case .haulRun:
                    // A Haul Run never stamps `roamCentre` — its launcher
                    // anchors on the tagged fleet, not a queue/frontier, and
                    // its subtitle (design spec §9) reads live off the
                    // controllers' in-force config rather than a drained-pile
                    // count. Unreachable in practice; fall back to the same
                    // m/n readout the non-continuous path below uses so this
                    // stays honest until that subtitle logic is built.
                    let progress = directive.progress
                    return "\(progress.completed)/\(progress.total)"
                }
            }
            let progress = directive.progress
            return "\(progress.completed)/\(progress.total)"
        case let .builtIn(builtIn):
            if let owner = builtIn.drivenBy { return "driven by \(owner.kindTitle)" }
            let count = builtIn.controlledDevices.count
            return count > 0 ? "\(count) controlled" : nil
        }
    }

    /// Statuses that still hold a controller. `paused` and `needsAttention`
    /// KEEP ownership: the directive is still in force server-side, and a user
    /// resolving a stall expects to find it intact. Only a finished mission
    /// gives the row back.
    static let owningStatuses: Set<DirectiveStatus> = [.running, .needsAttention, .paused]

    /// Merge the two sources into one ordered list. `devices` contributes a row
    /// for each device with a directive in force; `directives` contributes one
    /// per custom mission. A built-in row whose controller a live mission is
    /// driving carries that mission as `drivenBy`.
    public static func merge(devices: [Device], directives: [Directive]) -> [DirectiveRow] {
        let owners: [String: DirectiveOwner] = directives.reduce(into: [:]) { owners, directive in
            guard let controller = directive.controllerCode,
                  owningStatuses.contains(directive.status)
            else { return }
            owners[controller] = DirectiveOwner(
                directiveID: directive.id,
                kindTitle: directive.kind.title
            )
        }
        let custom = directives.map { DirectiveRow.custom($0) }
        let builtIn = devices.compactMap { device -> DirectiveRow? in
            guard let directive = device.currentDirective, !directive.isEmpty else { return nil }
            return .builtIn(
                BuiltInDirective(
                    deviceCode: device.deviceCode,
                    deviceType: device.deviceType,
                    directive: directive,
                    config: device.currentDirectiveConfig,
                    controlledDevices: device.controlledDevices,
                    drivenBy: owners[device.deviceCode]
                )
            )
        }
        return custom + builtIn
    }
}
