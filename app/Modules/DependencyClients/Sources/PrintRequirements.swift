//
//  PrintRequirements.swift
//  Replicould — shared printing preview model
//
//  The pre-flight resource check backing the `enqueue_print` confirmation shown
//  in both the Devices and Print Queue inspectors: for a chosen blueprint, what
//  each resource costs versus what's on hand at the device's current location
//  (refreshed live before the sheet opens). Kept here in `DependencyClients` so
//  both features share one model rather than each rolling its own.
//

import Foundation

/// One resource line in the print confirmation: how much the blueprint costs and
/// how much the location holds. `available` is nil when the location's inventory
/// couldn't be read (unexplored / offline) — the line then reads as "unknown".
public struct PrintResourceLine: Equatable, Sendable, Identifiable {
    /// Canonical resource key (`structural`, `conductive`, …) — matches the
    /// location inventory's `resourceType`.
    public var resource: String
    /// Display label (`Structural`, `Conductive`, …).
    public var label: String
    /// The blueprint's build cost for this resource.
    public var required: Double
    /// What the location holds, or nil when its inventory is unavailable.
    public var available: Double?

    public var id: String { resource }

    /// Whether the location holds enough of this resource to satisfy the cost.
    /// Unknown inventory reads as unmet so the sheet doesn't imply readiness.
    public var isMet: Bool { (available ?? 0) >= required }

    public init(resource: String, label: String, required: Double, available: Double? = nil) {
        self.resource = resource
        self.label = label
        self.required = required
        self.available = available
    }
}

/// The resolved requirements for a pending print: the target device type, where
/// it'll be built, and the per-resource cost-vs-stock breakdown.
public struct PrintRequirements: Equatable, Sendable {
    public var deviceType: String
    /// Human location name for the sheet header (falls back to the code).
    public var locationName: String?
    /// Whether the location's inventory was successfully read. When false, every
    /// line's `available` is nil and the sheet notes the stock is unknown.
    public var inventoryAvailable: Bool
    public var lines: [PrintResourceLine]

    public init(
        deviceType: String,
        locationName: String? = nil,
        inventoryAvailable: Bool,
        lines: [PrintResourceLine]
    ) {
        self.deviceType = deviceType
        self.locationName = locationName
        self.inventoryAvailable = inventoryAvailable
        self.lines = lines
    }

    /// Whether the location stocks enough of every required resource.
    public var allMet: Bool { inventoryAvailable && lines.allSatisfy(\.isMet) }

    /// Fill in each required line's `available` from a resolved inventory lookup
    /// (keyed by canonical resource). A nil lookup means the inventory couldn't be
    /// read, leaving every line unknown.
    public static func resolve(
        deviceType: String,
        locationName: String?,
        required: [PrintResourceLine],
        available: [String: Double]?
    ) -> PrintRequirements {
        let lines = required.map { line in
            PrintResourceLine(
                resource: line.resource,
                label: line.label,
                required: line.required,
                available: available?[line.resource]
            )
        }
        return PrintRequirements(
            deviceType: deviceType,
            locationName: locationName,
            inventoryAvailable: available != nil,
            lines: lines
        )
    }
}

/// The in-flight or resolved print confirmation backing the sheet: which device
/// prints what, and the current phase of the resource check.
public struct PrintPreview: Equatable, Identifiable, Sendable {
    public let deviceCode: String
    public let deviceType: String
    public var phase: Phase

    public var id: String { "\(deviceCode)>\(deviceType)" }

    public enum Phase: Equatable, Sendable {
        case loading
        case loaded(PrintRequirements)
        case failed(String)
    }

    public init(deviceCode: String, deviceType: String, phase: Phase = .loading) {
        self.deviceCode = deviceCode
        self.deviceType = deviceType
        self.phase = phase
    }
}
