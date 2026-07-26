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

    public var id: String { deviceCode }

    public init(
        deviceCode: String,
        deviceType: String,
        directive: String,
        config: JSONValue?,
        controlledDevices: [Device.ControlledDevice]
    ) {
        self.deviceCode = deviceCode
        self.deviceType = deviceType
        self.directive = directive
        self.config = config
        self.controlledDevices = controlledDevices
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

    /// Merge the two sources into one ordered list. `devices` contributes a row
    /// for each device with a directive in force; `directives` contributes one
    /// per custom mission.
    public static func merge(devices: [Device], directives: [Directive]) -> [DirectiveRow] {
        let custom = directives.map { DirectiveRow.custom($0) }
        let builtIn = devices.compactMap { device -> DirectiveRow? in
            guard let directive = device.currentDirective, !directive.isEmpty else { return nil }
            return .builtIn(
                BuiltInDirective(
                    deviceCode: device.deviceCode,
                    deviceType: device.deviceType,
                    directive: directive,
                    config: device.currentDirectiveConfig,
                    controlledDevices: device.controlledDevices
                )
            )
        }
        return custom + builtIn
    }
}
