//
//  Diversion.swift
//  Replicould — shared dependency clients
//
//  A propulsor's `diverting` state is unusual: the device payload reports only
//  `status: "diverting"` with no activity block, no ETA, and no progress. All the
//  substance lives on the *object* the propulsor is attached to — an incoming
//  threat body fetched via `GET /v1/locations/{designation}`, whose `object`
//  block carries the impact target, impact ETA/likelihood, and the deflection
//  progress. `DiversionSnapshot` is that block mapped to a display value type, so
//  the inspector's active-task card can show the defense readout the device
//  itself withholds.
//

import Foundation
import Utils

/// The diversion defense a propulsor is performing: the threat object it's
/// nudging off course, where that object would otherwise strike, and how far the
/// deflection has progressed. Parsed from a `locations/{designation}` `object`
/// block (see `DevicesClient.diversion`).
public struct DiversionSnapshot: Equatable, Sendable {
    /// The object being diverted (`ATIANFU-OBJ-1`).
    public var objectDesignation: String
    /// The threat classification, e.g. `incoming_asteroid`.
    public var objectType: String?
    /// Rough scale, e.g. `small` / `medium` / `large`.
    public var sizeClass: String?
    /// The location this object is on course to strike if not diverted.
    public var impactTarget: String?
    /// When the object would strike, absent successful diversion.
    public var impactEta: Date?
    /// Percent chance of impact on the current trajectory (0…100).
    public var impactLikelihood: Double?
    /// How far the deflection has progressed (0…100).
    public var progressPct: Double?
    /// Total thrust-work needed to divert the object.
    public var requiredStrength: Double?
    /// Thrust currently applied per hour (across all attached propulsors).
    public var currentThrustPerHour: Double?
    /// Number of diverter plates engaged on the object.
    public var activePlates: Int?
    /// The object's orbital distance from its star, in AU.
    public var orbitalDistanceAu: Double?
    /// The object's own status, e.g. `active`.
    public var status: String?

    public init(
        objectDesignation: String,
        objectType: String? = nil,
        sizeClass: String? = nil,
        impactTarget: String? = nil,
        impactEta: Date? = nil,
        impactLikelihood: Double? = nil,
        progressPct: Double? = nil,
        requiredStrength: Double? = nil,
        currentThrustPerHour: Double? = nil,
        activePlates: Int? = nil,
        orbitalDistanceAu: Double? = nil,
        status: String? = nil
    ) {
        self.objectDesignation = objectDesignation
        self.objectType = objectType
        self.sizeClass = sizeClass
        self.impactTarget = impactTarget
        self.impactEta = impactEta
        self.impactLikelihood = impactLikelihood
        self.progressPct = progressPct
        self.requiredStrength = requiredStrength
        self.currentThrustPerHour = currentThrustPerHour
        self.activePlates = activePlates
        self.orbitalDistanceAu = orbitalDistanceAu
        self.status = status
    }
}

extension DiversionSnapshot {
    /// Parse from a `locations/{designation}` payload's `object` block. Nil when
    /// the value isn't an object (the location carries no diversion target — the
    /// propulsor isn't actually diverting anything there). `fallbackDesignation`
    /// seeds `objectDesignation` when the block omits its own `designation`.
    public init?(objectBlock value: JSONValue?, fallbackDesignation: String) {
        guard case .object = value else { return nil }
        self.init(
            objectDesignation: value?["designation"]?.stringValue ?? fallbackDesignation,
            objectType: value?["object_type"]?.stringValue,
            sizeClass: value?["size_class"]?.stringValue,
            impactTarget: value?["impact_target"]?.stringValue,
            impactEta: value?["impact_eta"]?.stringValue.flatMap(Self.parseDate),
            impactLikelihood: value?["impact_likelihood"]?.numberValue,
            progressPct: value?["progress_pct"]?.numberValue,
            requiredStrength: value?["required_strength"]?.numberValue,
            currentThrustPerHour: value?["current_thrust_per_hour"]?.numberValue,
            activePlates: value?["active_plates"]?.numberValue.map(Int.init),
            orbitalDistanceAu: value?["orbital_distance_au"]?.numberValue,
            status: value?["status"]?.stringValue
        )
    }

    /// ISO-8601 with or without fractional seconds (the server sends an offset
    /// timestamp, no fraction). Mirrors `Device.parseActivityDate`.
    static func parseDate(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle()) { return date }
        return nil
    }
}
