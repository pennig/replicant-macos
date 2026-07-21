//
//  CommandClient+Scan.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The scan family: `system_scan` (immediate synchronous read), `scan` (the
//  survey drone's long-running body scan, tracked with a back-filled
//  deadline), and `stellar_census`. A `system_scan` response carries a
//  `replicants` block, so the family also owns recording those sightings.
//

import API
import Dependencies
import Foundation
import GameModels
import OSLog
import SQLiteData
import Utils

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Command")

extension CommandClient {
    static func systemScanBody() -> Operations.PostV1DevicesDeviceCode.Input.Body {
        .json(.systemScan(.init(command: "system_scan")))
    }

    static func surveyScanBody() -> Operations.PostV1DevicesDeviceCode.Input.Body {
        .json(.scan(.init(command: "scan")))
    }

    static func censusBody() -> Operations.PostV1DevicesDeviceCode.Input.Body {
        .json(.stellarCensus(.init(command: "stellar_census")))
    }

    /// A `system_scan` response carries a `replicants` block — everyone detected
    /// in the scanned system, with a precise `location` and `last_active`. Record
    /// those sightings so player replicants (whose position the directory
    /// withholds) get an accurate last-known-location.
    static func recordScanSightings(from responseJSON: JSONValue) async {
        let sightings = KnownReplicant.scanSightings(from: responseJSON)
        guard !sightings.isEmpty else { return }
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date
        try? await database.write { db in
            try KnownReplicant.record(sightings: sightings, into: db, now: date.now)
        }
        logger.info("scan recorded \(sightings.count, privacy: .public) replicant sighting(s)")
    }
}
