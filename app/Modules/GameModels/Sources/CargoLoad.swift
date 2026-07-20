//
//  CargoLoad.swift
//  Replicould — shared cargo-load picker model
//
//  The pre-flight state backing the `collect_resources` (Load Cargo) sheet in the
//  Devices inspector: which transport loads from where, how much free space its
//  hold has, and the current phase of the location-stockpile fetch. Kept here in
//  `GameModels` beside `PrintPreview`/`TravelPlan` so the feature state and the
//  sheet share one plain-value model.
//

import Foundation

/// One resource available to load at the transport's current location: its type
/// and how many units the local stockpile holds.
public struct CargoStock: Equatable, Sendable, Identifiable {
    /// Canonical resource key (`structural`, `conductive`, …).
    public var resourceType: String
    /// Units on hand in the location's stockpile.
    public var available: Int

    public var id: String { resourceType }

    public init(resourceType: String, available: Int) {
        self.resourceType = resourceType
        self.available = available
    }
}

/// The in-flight or resolved cargo-load picker backing the sheet: the transport
/// doing the loading, its hold's free space (the ceiling on the total that can be
/// taken), and the current phase of the stockpile fetch.
public struct CargoLoadPreview: Equatable, Identifiable, Sendable {
    public let deviceCode: String
    /// Human location name for the sheet header (falls back to the code).
    public let locationName: String?
    /// Free units in the hold — the ceiling on the total that can be loaded.
    public let capacityRemaining: Int
    public var phase: Phase

    public var id: String { deviceCode }

    public enum Phase: Equatable, Sendable {
        case loading
        /// The location's loadable stockpile (only resources with a positive
        /// quantity on hand).
        case loaded([CargoStock])
        case failed(String)
    }

    public init(
        deviceCode: String,
        locationName: String? = nil,
        capacityRemaining: Int,
        phase: Phase = .loading
    ) {
        self.deviceCode = deviceCode
        self.locationName = locationName
        self.capacityRemaining = capacityRemaining
        self.phase = phase
    }
}
