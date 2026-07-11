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

/// The FTL mesh persisted locally — one row per undirected edge between two star
/// systems, so the map draws the mesh instantly on launch (no empty-state flash
/// while the per-relay network reads land) and survives a moment where those
/// reads fail. The mesh is small and always recomputed wholesale from every
/// relay's live network view, so it's rewritten in full (see `replace`) whenever
/// the relay roster changes or a relay's liveness flips (`relay_activated` /
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

    public init(a: String, b: String, updatedAt: Date) {
        self.id = "\(a)|\(b)"
        self.a = a
        self.b = b
        self.updatedAt = updatedAt
    }

    /// A record for a resolved link, stamped `now`.
    public init(link: FTLLink, now: Date) {
        self.init(a: link.a, b: link.b, updatedAt: now)
    }

    /// The render-domain link this row represents.
    public var link: FTLLink { FTLLink(a, b) }
}

extension FTLLinkRecord {
    /// Replace the whole persisted mesh with a freshly-resolved edge set. The mesh
    /// is always rebuilt in full (it's small and recomputed from every relay's live
    /// network view), so this clears the table and reinserts in one write — an
    /// empty `links` correctly leaves no edges (e.g. no relays, or all inactive).
    public static func replace(with links: [FTLLink], into db: Database, now: Date) throws {
        try FTLLinkRecord.delete().execute(db)
        for link in links {
            try FTLLinkRecord.insert { FTLLinkRecord(link: link, now: now) }.execute(db)
        }
    }
}

// MARK: - Schema

extension FTLLinkRecord {
    /// Registers the `ftlLinks` table migration. Kept beside the model so the
    /// schema and the type never drift; composed into `bootstrapDatabase`.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create 'ftlLinks' table") { db in
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
    }
}
