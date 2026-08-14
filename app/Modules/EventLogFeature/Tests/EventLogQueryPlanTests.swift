//
//  EventLogQueryPlanTests.swift
//  EventLogFeatureTests
//
//  The Event Log's display query runs on the WRITER connection (GRDB fetches a
//  non-constant-region observation there), so every event ingestion waits on it.
//  Without an index it full-scans and temp-b-tree-sorts the whole ledger.
//

import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing

@testable import EventLogFeature

@Suite struct EventLogQueryPlanTests {
    /// The SQL SQLiteData executes for a query, ready for `EXPLAIN`: the builder
    /// parenthesizes the whole statement, and a bound `LIMIT` becomes `NULL`
    /// (no limit) so the plan can be read without supplying arguments.
    private func sql(of statement: some StructuredQueriesCore.Statement) -> String {
        let text = statement.queryFragment.segments
            .map { segment in
                switch segment {
                case .sql(let text): text
                case .binding: "NULL"
                }
            }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("("), text.hasSuffix(")") else { return text }
        return String(text.dropFirst().dropLast())
    }

    @Test func theDisplayQueryIsServedByAnIndexRatherThanASort() throws {
        let database = try GameDatabase.bootstrap()
        let query = EventLog.order { $0.receivedAt.desc() }.limit(EventLogFeature.displayLimit)

        let plan = try database.read { db in
            try #sql(
                "EXPLAIN QUERY PLAN \(raw: sql(of: query))",
                as: (Int, Int, Int, String).self
            )
            .fetchAll(db)
            .map(\.3)
        }
        .joined(separator: "\n")

        #expect(
            !plan.uppercased().contains("TEMP B-TREE"),
            """
            The Event Log display query sorts the whole ledger on the writer connection:
            \(plan)
            """
        )
    }

    @Test func theLedgerCarriesAnIndexOnItsOrderingKey() throws {
        let database = try GameDatabase.bootstrap()
        let indexed = try database.read { db in
            try db.indexes(on: "eventLogs").contains { $0.columns == ["receivedAt"] }
        }
        #expect(indexed)
    }
}
