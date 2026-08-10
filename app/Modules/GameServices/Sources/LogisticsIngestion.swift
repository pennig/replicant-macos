//
//  LogisticsIngestion.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  Ingestion policy: a pickup is a rise in the digest's carried total.
//

import API
import Dependencies
import Foundation
import GameModels
import OSLog
import SQLiteData
import Utils

private let logger = Logger(subsystem: "name.pennig.replicould", category: "LogisticsIngestion")

public final class LogisticsIngestion: Sendable {
    /// Raised by `gapRepair`, lowered by the first row that carries it.
    private let pendingGap = LockIsolated(false)

    public init() {}

    public var eventRoutes: [EventRoute] {
        [
            EventRoute(
                id: "logistics.transportDigest",
                match: .event("ami.transport.digest"),
                apply: { [weak self] envelope in await self?.ingest(envelope) },
                gapRepair: { [weak self] in self?.pendingGap.setValue(true) }
            )
        ]
    }

    private func ingest(_ envelope: GameEventEnvelope) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date.now) var now
        guard let digest = TransportDigest(envelope: envelope, now: now) else {
            logger.debug("ami.transport.digest failed to parse")
            return
        }

        let open: [HaulYield]
        let hasHistory: Bool
        do {
            (open, hasHistory) = try await database.read { db in
                let all = try HaulYield
                    .where { $0.controllerCode.eq(digest.controllerCode) }
                    .fetchAll(db)
                return (all.filter(\.isOpen), !all.isEmpty)
            }
        } catch {
            logger.error("ledger read failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let openUnits = hasHistory ? open.reduce(0) { $0 + $1.unitsCollected } : nil
        switch HaulYieldMachine.step(openUnits: openUnits, digest: digest) {
        case .none:
            return
        case let .pickup(units, source, deviceCode):
            await recordPickup(digest: digest, units: units, source: source, deviceCode: deviceCode, open: open)
        case let .delivery(units, destination):
            await recordDelivery(digest: digest, units: units, destination: destination, open: open)
        }
    }

    private func recordPickup(
        digest: TransportDigest,
        units: Int,
        source: String,
        deviceCode: String,
        open: [HaulYield]
    ) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.deviceRefresher) var deviceRefresher
        @Dependency(\.uuid) var uuid

        let device = await deviceRefresher.refresh(deviceCode, .high)
        let hold = device.map { ResourceCost(wire: Dictionary($0.cargoItems.map { ($0.resourceType, $0.quantity) }, uniquingKeysWith: +)) }
        let previousHold = open.reduce(into: ResourceCost()) { $0.add($1.perType) }

        // `cargo_carried` sums the controller's whole fleet, so a second
        // freighter nets two devices into one figure. Degrade rather than
        // report it as measured.
        let fleetSize = (try? await database.read { db in
            try Device
                .where { $0.controllerDeviceCode.eq(digest.controllerCode) }
                .fetchCount(db)
        }) ?? 1

        let breakdown: ResourceCost
        let state: HaulYield.BreakdownState
        if let hold {
            let taken = hold.subtracting(previousHold)
            breakdown = taken
            state = (taken.total == units && fleetSize <= 1) ? .exact : .partial
        } else {
            breakdown = ResourceCost()
            state = .unavailable
        }

        // Attribute on `deviceCode`, never `controllerCode` or `fleetTag`:
        // `controllerCode` is stamped only at launch (a pinned row created
        // earlier still carries nil), and `fleetTag` is worn by no device.
        let directiveID = (try? await database.read { db in
            try Directive
                .where { $0.kind.eq(DirectiveKind.haulRun).and($0.deviceCode.eq(digest.controllerCode)) }
                .fetchOne(db)?
                .id
        }) ?? nil

        let row = HaulYield(
            id: uuid(),
            directiveID: directiveID ?? "",
            controllerCode: digest.controllerCode,
            deviceCode: deviceCode,
            sourceDesignation: source,
            collectedAt: digest.observedAt,
            unitsCollected: units,
            perType: breakdown,
            breakdownState: state,
            followsGap: pendingGap.value
        )
        do {
            try await database.write { db in try HaulYield.upsert { row }.execute(db) }
            pendingGap.setValue(false)
            logger.notice("pickup \(units) at \(source, privacy: .public) [\(state.rawValue, privacy: .public)]")
        } catch {
            logger.error("pickup write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func recordDelivery(
        digest: TransportDigest,
        units: Int,
        destination: String,
        open: [HaulYield]
    ) async {
        @Dependency(\.defaultDatabase) var database
        guard !open.isEmpty else {
            logger.notice("delivery of \(units) with no open pickup — discarded")
            return
        }
        let reconciles = open.reduce(0) { $0 + $1.unitsCollected } == units
        do {
            try await database.write { db in
                for var row in open {
                    row.destinationDesignation = destination
                    row.deliveredAt = digest.observedAt
                    row.unitsDelivered = row.unitsCollected
                    if !reconciles { row.breakdownState = .partial }
                    try HaulYield.upsert { row }.execute(db)
                }
            }
        } catch {
            logger.error("delivery write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
