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
    ///
    /// The one sanctioned exception is a baseline squash: replace a run of
    /// entries with a single `SchemaMigration(_:merging:migrate:)` whose
    /// `mergedIdentifiers` set equals exactly the identifiers it deletes from
    /// this list. That keeps `grdb_migrations` bookkeeping correct for
    /// databases that already applied the originals, without requiring every
    /// one of them to still be replayed individually forever.
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
        "Backfill 'fullyScannedAt' from systemDetails",
        "Add 'roamCentre' to 'directives'",
        "Add 'fleetTag' to 'directives'",
        "Add 'depleted' to 'siteAssays'",
        "Add link metrics to 'ftlLinks'",
        "Add 'sourceRelayCode' to 'directives'",
        "Add 'claimedRelayCode' to 'directives'",
        "Add 'summaryJSON' to 'systemDetails'",
        "Backfill 'summaryJSON' on 'systemDetails'",
        "Create 'haulYields' table",
        "Add index on 'haulYields.controllerCode'",
        "Add 'deletedAt' to 'directives'",
        "Create 'theatrePins'",
        "Add 'region' to 'stars'",
        "Add 'hasHub' to 'stars'",
        "Add 'theatreDepot' to 'directives'",
        "Create 'locationInventories' table",
        "Add index on 'eventLogs.receivedAt'",
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
