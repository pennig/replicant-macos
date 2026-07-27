//
//  EventLogView+Previews.swift
//  Replicould — EventLogFeature
//
//  Previews kept apart from the views they exercise. Each seeds a throwaway
//  in-memory database with a minimal `EventLog`-only schema, so the preview stands
//  alone without pulling in the full app schema composition.
//

import ComposableArchitecture
import Foundation
import GameModels
import SQLiteData
import SwiftUI

private func seededDatabase() -> any DatabaseWriter {
    let database = try! SQLiteData.defaultDatabase()
    var migrator = DatabaseMigrator()
    EventLog.createEventLogs.register(in: &migrator)
    try! migrator.migrate(database)
    try! database.write { db in
        try EventLog.insert { EventLog.previewRows }.execute(db)
    }
    return database
}

extension EventLog {
    fileprivate static let previewRows: [EventLog] = [
        EventLog(
            id: "1752681600000-0",
            event: "mining.started",
            category: "mining",
            replicantCode: "RPL-0001",
            deviceCode: "VES-7F3A2",
            deviceType: "vessel",
            star: "SOL",
            location: "SOL-3",
            version: 1,
            createdAt: "2026-07-20T09:00:00Z",
            receivedAt: Date(timeIntervalSince1970: 1_752_681_600),
            provenance: "stream",
            isHandled: true,
            matchedRoutes: "locations.scan",
            payload: .object([
                "resource": .string("iron_ore"),
                "rate_per_hour": .number(12.4),
                "target_device_code": .string("AST-44C19"),
            ])
        ),
        EventLog(
            id: "1752681599000-0",
            event: "anomaly.detected",
            category: "anomaly",
            star: "KRIOS",
            location: "KRIOS-2",
            version: 1,
            createdAt: "2026-07-20T08:59:59Z",
            receivedAt: Date(timeIntervalSince1970: 1_752_681_599),
            provenance: "stream",
            isHandled: false,
            matchedRoutes: nil,
            payload: .object([
                "severity": .string("high"),
                "kind": .string("gravitational"),
            ])
        ),
    ]
}

#Preview {
    let _ = prepareDependencies { $0.defaultDatabase = seededDatabase() }
    EventLogView(
        store: Store(initialState: EventLogFeature.State(selection: "1752681600000-0")) {
            EventLogFeature()
        }
    )
    .frame(width: 1000, height: 640)
}
