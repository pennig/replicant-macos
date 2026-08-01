//
//  FTLLink.swift
//  Replicould — shared game models
//
//  The real FTL comms mesh, as the backend reports it. A relay-capable device
//  (an `ftl_relay`, or a `system_hub`'s integrated relay) exposes its live
//  network view at `GET /v1/devices/{code}/network`
//  (`app_schemas_devices_DeviceNetworkSchema`): a `range_ly` and a list of
//  `connections`, each naming a peer's star and its `distance_ly`.
//
//  What that returns is the CLOSURE of the relay's subgraph — within a connected
//  subgraph there are no hops, so every peer is reported however distant. These
//  rows store that closure verbatim, metrics and all; `DirectFTLLinks` is the one
//  place that reduces it to the links which are physically real. Do not read
//  drawable links off these rows directly.
//

import Foundation
import SQLiteData

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

// MARK: - Persistence

/// The FTL mesh persisted locally — one row per CLOSURE PAIR, not per physical
/// link. Most of these pairs are not edges: the backend reports every peer in a
/// relay's subgraph however distant, so a row's `distanceLy` can be several times
/// its endpoints' range. `DirectFTLLinks` is what turns these rows into drawable
/// links; nothing should read them as edges directly.
///
/// Persisting them means the map draws instantly on launch (no empty-state flash
/// while the per-relay network reads land) and survives a moment where those reads
/// fail. The one exception is the launch on which `addLinkMetrics` runs: it clears
/// the table, so the overlay is empty until the next rebuild.
///
/// The mesh is small and always recomputed wholesale from every relay's live
/// network view, so it's rewritten in full (see `replace`) whenever the relay
/// roster changes or a relay's liveness flips (`relay_activated` /
/// `relay_deactivated`). Endpoints keep `FTLLink`'s canonical order (`a <= b`),
/// and `id` is their joined pair so reciprocal reports collapse to one row.
@Table("ftlLinks")
public struct FTLLinkRecord: Identifiable, Equatable, Sendable {
    /// The canonical endpoint pair, joined — the natural primary key (`A|B`).
    @Column(primaryKey: true) public var id: String
    public var a: String
    public var b: String
    /// When this edge was last written by a mesh rebuild.
    public var updatedAt: Date
    /// The server's `distance_ly` for this pair, as reported on the connection.
    /// Nil when the read failed or the field was absent — see `DirectFTLLinks`'
    /// fail-open rule.
    public var distanceLy: Double?
    /// Relay range at endpoint `a`, merged in from that relay's own network view
    /// (a view knows its own range, never its peer's).
    public var rangeA: Double?
    /// Relay range at endpoint `b`.
    public var rangeB: Double?

    public init(
        a: String,
        b: String,
        updatedAt: Date,
        distanceLy: Double? = nil,
        rangeA: Double? = nil,
        rangeB: Double? = nil
    ) {
        self.id = "\(a)|\(b)"
        self.a = a
        self.b = b
        self.updatedAt = updatedAt
        self.distanceLy = distanceLy
        self.rangeA = rangeA
        self.rangeB = rangeB
    }

    /// The render-domain link this row represents.
    public var link: FTLLink { FTLLink(a, b) }
}

extension FTLLinkRecord {
    /// Replace the whole persisted mesh with a freshly-resolved row set. The mesh
    /// is always rebuilt in full (it's small and recomputed from every relay's live
    /// network view), so this clears the table and reinserts in one write — an
    /// empty `rows` correctly leaves no edges (e.g. no relays, or all inactive).
    public static func replace(rows: [FTLLinkRecord], into db: Database) throws {
        try FTLLinkRecord.delete().execute(db)
        for row in rows {
            try FTLLinkRecord.insert { row }.execute(db)
        }
    }
}

// MARK: - Schema

extension FTLLinkRecord {
    /// Creates the `ftlLinks` table. Kept beside the model so the schema and
    /// the type never drift.
    public static let createFTLLinks = SchemaMigration("Create 'ftlLinks' table") { db in
        try #sql(
            """
            CREATE TABLE "ftlLinks" (
              "id" TEXT PRIMARY KEY NOT NULL,
              "a" TEXT NOT NULL,
              "b" TEXT NOT NULL,
              "updatedAt" TEXT NOT NULL
            ) STRICT
            """
        )
        .execute(db)
    }

    /// Adds the metrics that let the read path tell a real link from a closure
    /// pair: the connection's distance, and each endpoint relay's range.
    ///
    /// The migration also CLEARS the table. Existing rows carry no metrics and
    /// would all classify as direct under the fail-open rule — reproducing the
    /// very hairball this change removes. The mesh is a wholesale-rebuilt cache,
    /// so dropping it costs only an empty overlay until the next refresh fires.
    public static let addLinkMetrics = SchemaMigration("Add link metrics to 'ftlLinks'") { db in
        try #sql(
            """
            ALTER TABLE "ftlLinks" ADD COLUMN "distanceLy" REAL
            """
        )
        .execute(db)
        try #sql(
            """
            ALTER TABLE "ftlLinks" ADD COLUMN "rangeA" REAL
            """
        )
        .execute(db)
        try #sql(
            """
            ALTER TABLE "ftlLinks" ADD COLUMN "rangeB" REAL
            """
        )
        .execute(db)
        try #sql(
            """
            DELETE FROM "ftlLinks"
            """
        )
        .execute(db)
    }
}
