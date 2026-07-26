//
//  SchemaManifestTests.swift
//  GameDatabaseTests
//
//  Freezes the migration manifest. Migrations are append-only: an identifier
//  that has shipped is recorded in real databases, so renaming or reordering
//  one silently changes what those databases will do. This test makes either
//  mistake a build failure rather than a data-loss report.
//

import Foundation
import Testing

@testable import GameDatabase

@Suite struct SchemaManifestTests {
    /// Every shipped migration identifier, in order. ONLY ever append to this
    /// list — never reorder, rename, or delete an entry.
    static let frozenIdentifiers = [
        "Create 'messages' table",
        "Add category/subcategory to 'messages'",
        "Create 'blueprints' table",
        "Create 'civilisations' table",
        "Create 'stars' table",
        "Create 'systemDetails' table",
        "Create 'locationFootprints' table",
        "Create 'siteAssays' table",
        "Create 'locationEvents' table",
        "Add 'objectivesMet' to locationEvents",
        "Create 'replicants' table",
        "Create 'knownReplicants' table",
        "Create 'devices' table",
        "Create 'directives' table",
        "Add 'controllerCode' to 'directives'",
        "Create 'directiveLogEntries' table",
        "Create 'ftlLinks' table",
        "Create 'bobnetMessages' table",
        "Create 'bobnetChannels' table",
        "Create 'operations' table",
        "Create 'eventLogs' table",
    ]

    @Test func manifestMatchesTheFrozenList() {
        #expect(GameDatabase.manifest.map(\.identifier) == Self.frozenIdentifiers)
    }

    /// GRDB itself `precondition`-fails on a duplicate identifier at
    /// registration, which would crash the app at launch rather than fail a
    /// test. Catch it here first.
    @Test func identifiersAreUnique() {
        let identifiers = GameDatabase.manifest.map(\.identifier)
        #expect(Set(identifiers).count == identifiers.count)
    }
}
