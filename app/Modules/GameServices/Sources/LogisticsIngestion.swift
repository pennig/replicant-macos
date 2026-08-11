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
    /// Below this many remaining reads, skip the `.high` device read rather
    /// than let `RateLimitGovernor.acquire` sleep the router's dispatch path.
    /// Matches `PollCoordinator`'s own budget floor.
    static let readsBudgetFloor = 12

    /// Raised by `gapRepair`, lowered by the first row that carries it.
    private let pendingGap = LockIsolated(false)

    public init() {}

    /// Captures `pendingGap` by value, never `self` — a route must outlive
    /// whoever constructed this instance.
    public var eventRoutes: [EventRoute] {
        let pendingGap = pendingGap
        return [
            EventRoute(
                id: "logistics.transportDigest",
                match: .event("ami.transport.digest"),
                apply: { envelope in await Self.ingest(envelope, pendingGap: pendingGap) },
                gapRepair: { pendingGap.setValue(true) }
            )
        ]
    }

    private static func ingest(_ envelope: GameEventEnvelope, pendingGap: LockIsolated<Bool>) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date.now) var now
        guard let digest = TransportDigest(envelope: envelope, now: now) else {
            logger.debug("ami.transport.digest failed to parse")
            return
        }

        let open: [HaulYield]
        do {
            open = try await database.read { db in
                try HaulYield
                    .where { $0.controllerCode.eq(digest.controllerCode).and($0.deliveredAt.is(nil)) }
                    .fetchAll(db)
            }
        } catch {
            logger.error("ledger read failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let openUnits = open.reduce(0) { $0 + $1.unitsCollected }
        switch HaulYieldMachine.step(openUnits: openUnits, digest: digest) {
        case .none:
            return
        case let .pickup(units, source, deviceCode):
            await recordPickup(
                digest: digest, units: units, source: source, deviceCode: deviceCode,
                open: open, pendingGap: pendingGap
            )
        case let .delivery(units, destination):
            await recordDelivery(digest: digest, units: units, destination: destination, open: open)
        }
    }

    private static func recordPickup(
        digest: TransportDigest,
        units: Int,
        source: String,
        deviceCode: String,
        open: [HaulYield],
        pendingGap: LockIsolated<Bool>
    ) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.deviceRefresher) var deviceRefresher
        @Dependency(\.gameClient) var gameClient
        @Dependency(\.uuid) var uuid

        // `.high` bypasses the coordinator's own floor into a sleeping
        // `RateLimitGovernor.acquire` — check first so pressure skips the read, not the router.
        let budget = await gameClient.budget(.reads)
        let device: Device?
        if budget.remaining <= Self.readsBudgetFloor {
            logger.notice("pickup at \(source, privacy: .public): reads budget \(budget.remaining) at/below floor \(Self.readsBudgetFloor) — skipping device read")
            device = nil
        } else {
            device = await deviceRefresher.refresh(deviceCode, .high)
        }
        let hold = device.map { ResourceCost(wire: Dictionary($0.cargoItems.map { ($0.resourceType, $0.quantity) }, uniquingKeysWith: +)) }
        let previousHold = open.reduce(into: ResourceCost()) { $0.add($1.perType) }

        // A fleet of >1 nets several holds into one `cargo_carried` figure.
        // A failed count must not default toward an unearned `.exact`.
        let fleetSize = (try? await database.read { db in
            try Device
                .where { $0.controllerDeviceCode.eq(digest.controllerCode) }
                .fetchCount(db)
        }) ?? 2

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

        // `deviceCode`, not `controllerCode` (launch-only stamp) or `fleetTag`
        // (worn by no device). Newest in-force run — a finished one persists.
        let directiveID = (try? await database.read { db in
            try Directive
                .where {
                    $0.kind.eq(DirectiveKind.haulRun)
                        .and($0.deviceCode.eq(digest.controllerCode))
                        .and($0.status.in(DirectiveStatus.openCases))
                }
                .order { $0.createdAt.desc() }
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

    private static func recordDelivery(
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
                    if !reconciles && row.breakdownState == .exact { row.breakdownState = .partial }
                    try HaulYield.upsert { row }.execute(db)
                }
            }
        } catch {
            logger.error("delivery write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
