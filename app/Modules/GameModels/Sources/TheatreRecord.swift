//
//  TheatreRecord.swift
//  Replicould — GameModels
//
//  A system's established depot: the identity recognition reuses per system.
//

import Foundation
import SQLiteData

@Table("theatres")
public struct TheatreRecord: Identifiable, Equatable, Sendable {
    /// The depot designation — `Theatre.id`, and one row per system.
    @Column(primaryKey: true) public var depot: String
    public var system: String
    /// `Theatre.Origin`'s case name: `pinned`, `systemHub` or `derived`.
    public var origin: String
    public var establishedAt: Date

    public var id: String { depot }

    public init(depot: String, system: String, origin: String, establishedAt: Date) {
        self.depot = depot
        self.system = system
        self.origin = origin
        self.establishedAt = establishedAt
    }

    public static let createTheatres = SchemaMigration("Create 'theatres'") { db in
        try #sql(
            """
            CREATE TABLE "theatres" (
              "depot" TEXT PRIMARY KEY NOT NULL,
              "system" TEXT NOT NULL,
              "origin" TEXT NOT NULL,
              "establishedAt" TEXT NOT NULL
            ) STRICT
            """
        )
        .execute(db)
    }
}
