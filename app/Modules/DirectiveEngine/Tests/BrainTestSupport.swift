//
//  BrainTestSupport.swift
//  Replicould — DirectiveEngine
//
//  Shared seed helpers for the automation-brain test suite. Every brain task
//  that needs a minimal device/star/assay/event row writes it here rather than
//  hand-rolling a private copy per test file — the fixtures are trivial, but
//  duplicating them across a dozen test files is exactly the kind of drift
//  that lets one file's `Device` init fall out of sync with the real schema.
//
//  Internal to the test target only: production `Sources/` must never carry
//  test fixtures (a review already caught and reversed exactly that mistake on
//  Task 3 — see `DevicePredicatesTests.swift`'s private `Device.fixture`).
//

import Foundation
import GameModels
import SQLiteData
import UniverseModels
@testable import DirectiveEngine

// MARK: - Device seeds

/// A minimal device row. Defaults read as an idle, undeployed device; override
/// only what a test cares about.
func seedDevice(
    _ db: Database,
    code: String,
    type: String = "heaven_vessel",
    location: String? = nil,
    status: String = "idle",
    features: [String] = [],
    availableCommands: [String] = []
) throws {
    try Device.insert {
        Device(
            deviceCode: code, deviceType: type, replicantCode: "R1", status: status,
            location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: availableCommands,
            features: features, tags: [], detail: .object([:]),
            updatedAt: Date(timeIntervalSince1970: 0), firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }.execute(db)
}

/// An FTL relay meshing its system — `features: ["relay"]` + `statusBase ==
/// "relaying"`, the exact predicate `SalvageTargetPlanner.meshSystems(in:)` and
/// `Device.isActiveRelay` both key off.
func seedRelay(_ db: Database, code: String, location: String, status: String = "relaying") throws {
    try seedDevice(db, code: code, type: "ftl_relay", location: location, status: status, features: ["relay"])
}

/// A print-capable device — `Device.isPrintHub` keys off `enqueue_print` in
/// `availableCommands`, not device type.
func seedPrintHub(_ db: Database, code: String, location: String) throws {
    try seedDevice(
        db, code: code, type: "autofactory", location: location,
        availableCommands: ["enqueue_print"]
    )
}

// MARK: - Star seeds

/// A census star at a given position. Only the fields `WorldView` reads are
/// exposed as parameters; everything else takes an inert default.
func seedStar(_ db: Database, designation: String, x: Double, y: Double, z: Double) throws {
    try Star.insert {
        Star(
            designation: designation, spectralType: "G", color: "yellow",
            positionX: x, positionY: y, positionZ: z, estimatedPlanets: 0,
            explored: false, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }.execute(db)
}

// MARK: - SiteAssay seeds

/// A salvage site's assayed totals. `siteType` is fixed to `"salvage"` since
/// that's the only kind the brain's `WorldView.salvageUnits` sums; a future
/// mining-assay seed would be a separate helper, not a parameter here.
func seedSalvageAssay(
    _ db: Database, id: String, system: String,
    totals: [String: Double], depleted: Bool = false
) throws {
    try SiteAssay.insert {
        // `body` isn't read by anything `WorldView` does; `system` is a fine
        // stand-in when a test has no reason to name the hosting body.
        SiteAssay(
            id: id, body: system, system: system,
            siteType: "salvage", totals: totals,
            assayedAt: Date(timeIntervalSince1970: 0), depleted: depleted
        )
    }.execute(db)
}

// MARK: - LocationEvent seeds

/// A live location event ("quest") sited at a location. `status` defaults to
/// `"active"` — the one `LocationEvent.isActive` matches.
func seedLocationEvent(
    _ db: Database, designation: String, location: String, status: String = "active"
) throws {
    try LocationEvent.insert {
        LocationEvent(
            designation: designation, location: location, status: status,
            firstSeenAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
    }.execute(db)
}

// MARK: - WorldView fixtures

/// Database-free `WorldView` fixtures for brain-logic tests (value ranking,
/// pathfinding) that reason purely over a snapshot and have no need to round
/// -trip through `GameDatabase` the way `WorldViewTests` does. Build one with
/// `.empty(meshSystems:)`, then layer in only the fields a test cares about
/// via `.with(...)`.
extension WorldView {
    /// An otherwise-blank snapshot — every collection empty, no hub, `now`
    /// pinned to the epoch for determinism. `meshSystems` is the one field
    /// worth defaulting at the call site since nearly every brain test names
    /// at least one already-meshed system.
    static func empty(meshSystems: Set<String> = []) -> WorldView {
        WorldView(
            devices: [:],
            starPositions: [:],
            meshSystems: meshSystems,
            salvageUnits: [:],
            eventSystems: [],
            hubLocation: nil,
            beltsBySystem: [:],
            now: Date(timeIntervalSince1970: 0)
        )
    }

    /// Returns a copy with the given fields overlaid; omitted parameters
    /// carry over from `self` unchanged. Only exposes the fields brain tests
    /// have needed so far — extend as later tasks need more.
    func with(
        salvageUnits: [String: Double]? = nil,
        eventSystems: Set<String>? = nil,
        starPositions: [String: Position]? = nil,
        beltsBySystem: [String: [BeltInfo]]? = nil
    ) -> WorldView {
        WorldView(
            devices: devices,
            starPositions: starPositions ?? self.starPositions,
            meshSystems: meshSystems,
            salvageUnits: salvageUnits ?? self.salvageUnits,
            eventSystems: eventSystems ?? self.eventSystems,
            hubLocation: hubLocation,
            beltsBySystem: beltsBySystem ?? self.beltsBySystem,
            now: now
        )
    }
}
