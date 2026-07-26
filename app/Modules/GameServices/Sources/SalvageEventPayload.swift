//
//  SalvageEventPayload.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  Reads the salvage event family's targets out of the event PAYLOAD.
//
//  This is deliberately not `event.location ?? payload["location"]`. On a live
//  `salvage.discovered` the envelope's `location` is `TAANSI-5-L4` — where the
//  AMI survey controller that found the site is parked — while the payload's
//  `location` is `TAANSI-6`, the body actually holding the wreck. Preferring the
//  envelope targets the wrong body.
//

import API
import Foundation
import UniverseModels
import Utils

/// A `salvage.discovered` payload: which site, on which body, and how much of
/// each resource was found (absolute units, at 100% remaining).
public struct SalvageEventPayload: Equatable, Sendable {
    public let designation: String
    public let body: String
    public let name: String?
    public let salvageType: String?
    /// Resource name → absolute unit count.
    public let resources: [String: Double]

    public init(
        designation: String, body: String, name: String? = nil,
        salvageType: String? = nil, resources: [String: Double] = [:]
    ) {
        self.designation = designation
        self.body = body
        self.name = name
        self.salvageType = salvageType
        self.resources = resources
    }

    /// Parse a `salvage.discovered` payload. Nil without a site designation —
    /// there is nothing to key an assay on.
    public static func discovery(from payload: [String: JSONValue]) -> SalvageEventPayload? {
        guard let designation = payload["designation"]?.stringValue, !designation.isEmpty else {
            return nil
        }
        var resources: [String: Double] = [:]
        if case .object(let map)? = payload["resources"] {
            for (resource, value) in map {
                if let amount = value.numberValue { resources[resource] = amount }
            }
        }
        return SalvageEventPayload(
            designation: designation,
            body: payload["location"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                ?? Self.body(ofSite: designation),
            name: payload["name"]?.stringValue,
            salvageType: payload["salvage_type"]?.stringValue,
            resources: resources
        )
    }

    /// The site a `salvage.depleted` event names. The documented key is `site`;
    /// `designation` and `location` are accepted as fallbacks because that key
    /// comes from the docs catalogue rather than a live capture.
    ///
    /// The `location` fallback is the shaky one: on the sibling
    /// `salvage.discovered` — the only member of this family captured live —
    /// payload `location` is the BODY, so if depletion keys on `location` too,
    /// this returns a body designation and nothing downstream will match it.
    /// Kept as a fallback anyway (a wrong key is no worse than no key), but
    /// `LocationsIngestion.catalogRoute` logs both a nil result here and a
    /// no-match downstream so the guess is falsifiable from the event log
    /// rather than failing silently.
    public static func depletedSite(from payload: [String: JSONValue]) -> String? {
        for key in ["site", "designation", "location"] {
            if let value = payload[key]?.stringValue, !value.isEmpty { return value }
        }
        return nil
    }

    /// The body hosting a site. Thin forwarder to `SalvageSite`'s static —
    /// that's the one place the `-SAL-N` stripping convention is encoded, so
    /// GameServices never keeps its own copy of the rule.
    static func body(ofSite designation: String) -> String {
        SalvageSite.bodyDesignation(ofSite: designation)
    }
}
