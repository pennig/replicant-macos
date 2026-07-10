//
//  FTLLink.swift
//  Replicould — shared game models
//
//  The real FTL comms mesh, as the backend reports it. An `ftl_relay` device
//  exposes its live network view at `GET /v1/devices/{code}/network`
//  (`app_schemas_devices_DeviceNetworkSchema`): a `range_ly` and a list of
//  `connections`, each naming the star of a peer relay it can reach. The star
//  map renders that network directly rather than guessing links by proximity.
//

import Foundation

/// One relay device the player owns, reduced to what the mesh needs: its device
/// code (to query its network view) and the star system it sits in (a mesh node,
/// and one endpoint of every link the query returns).
public struct RelayNode: Equatable, Sendable, Hashable {
    /// The relay device's designation code.
    public let deviceCode: String
    /// The star system the relay is deployed in (e.g. `AINALRAM`) — the system
    /// designation, not the specific body/location code.
    public let star: String

    public init(deviceCode: String, star: String) {
        self.deviceCode = deviceCode
        self.star = star
    }
}

/// An undirected link in the FTL mesh, as a pair of star-system designations.
/// Endpoints are stored in a canonical order (`a <= b`) so the reciprocal links
/// two relays each report for the same connection collapse to one edge under
/// `Equatable`/`Hashable`.
public struct FTLLink: Equatable, Sendable, Hashable {
    public let a: String
    public let b: String

    public init(_ x: String, _ y: String) {
        if x <= y { a = x; b = y } else { a = y; b = x }
    }
}
