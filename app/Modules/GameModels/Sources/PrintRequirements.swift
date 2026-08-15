//
//  PrintRequirements.swift
//  Replicould — shared printing preview model
//
//  The pre-flight resource check backing the `enqueue_print` confirmation, shared by the Devices and Print Queue inspectors rather than each rolling its own.
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

/// One component line in the print confirmation: a device the blueprint
/// consumes, and how many stand where the print will run.
public struct PrintComponentLine: Equatable, Sendable, Identifiable {
    public var deviceType: String
    public var label: String
    public var required: Int
    public var available: Int?

    public var id: String { deviceType }

    /// Unknown availability reads as unmet so the sheet doesn't imply readiness.
    public var isMet: Bool { (available ?? 0) >= required }

    public init(deviceType: String, label: String, required: Int, available: Int? = nil) {
        self.deviceType = deviceType
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
    /// Component devices the blueprint consumes. Empty for most blueprints.
    public var components: [PrintComponentLine]

    public init(
        deviceType: String,
        locationName: String? = nil,
        inventoryAvailable: Bool,
        lines: [PrintResourceLine],
        components: [PrintComponentLine] = []
    ) {
        self.deviceType = deviceType
        self.locationName = locationName
        self.inventoryAvailable = inventoryAvailable
        self.lines = lines
        self.components = components
    }

    /// Whether the location stocks enough of every resource AND component.
    public var allMet: Bool {
        inventoryAvailable && lines.allSatisfy(\.isMet) && components.allSatisfy(\.isMet)
    }

    /// Fill in each line's availability from a resolved inventory lookup and a
    /// count of the devices standing where the print will run. A nil inventory
    /// means it couldn't be read, leaving every resource line unknown.
    public static func resolve(
        deviceType: String,
        locationName: String?,
        required: [PrintResourceLine],
        requiredComponents: [PrintComponentLine] = [],
        available: [String: Double]?,
        heldComponents: [String: Int] = [:]
    ) -> PrintRequirements {
        let lines = required.map { line in
            PrintResourceLine(
                resource: line.resource, label: line.label,
                required: line.required, available: available?[line.resource]
            )
        }
        let components = requiredComponents.map { line in
            PrintComponentLine(
                deviceType: line.deviceType, label: line.label,
                required: line.required, available: heldComponents[line.deviceType] ?? 0
            )
        }
        return PrintRequirements(
            deviceType: deviceType, locationName: locationName,
            inventoryAvailable: available != nil, lines: lines, components: components
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
