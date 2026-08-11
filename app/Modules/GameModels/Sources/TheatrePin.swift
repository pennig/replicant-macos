//
//  TheatrePin.swift
//  Replicould — GameModels
//
//  An operator's pin: the only theatre state that persists.
//

import Foundation
import SQLiteData

@Table
public struct TheatrePin: Identifiable, Equatable, Sendable {
    @Column(primaryKey: true) public var location: String
    public var createdAt: Date

    public var id: String { location }

    public init(location: String, createdAt: Date) {
        self.location = location
        self.createdAt = createdAt
    }

    public static let createTheatrePins = SchemaMigration("Create 'theatrePins'") { db in
        try #sql(
            """
            CREATE TABLE "theatrePins" (
              "location" TEXT PRIMARY KEY NOT NULL,
              "createdAt" TEXT NOT NULL
            ) STRICT
            """
        )
        .execute(db)
    }
}
