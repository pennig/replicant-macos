//
//  ReconcilerOperationTests.swift
//  Replicould — GameServices
//
//  A completion event (`print.completed`) closes the device's open operation and
//  folds its result (the `new_device_code` the dispatch response withheld) into
//  the op's detail — §4.4 "the event is closer to truth than to a hint."
//

import API
import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import Utils
@testable import GameServices

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = GameModels.Operation

@Suite struct ReconcilerOperationTests {

    /// A device snapshot mid-`printing`, with the `started_at`/`completes_at`
    /// block the backend attaches to an in-progress device.
    private func printingDevice(_ code: String) -> Device {
        Device(
            deviceCode: code, deviceType: "heaven_vessel", replicantCode: "R1",
            status: "printing (ami_survey_controller)",
            location: "ATIANFU-BELT-1", locationName: nil, operationalCapacity: 100,
            queueSize: 0, stowedInDeviceCode: nil, controllerDeviceCode: nil,
            attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: [], tags: [],
            detail: .object([
                "printing": .object([
                    "started_at": .string("2026-06-28T23:52:27-05:00"),
                    "completes_at": .string("2026-06-29T00:17:27-05:00"),
                    "device_type": .string("ami_survey_controller"),
                ])
            ]),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            firstSeenAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    /// A survey drone mid-`searching`, with the `scan` activity block the backend
    /// attaches: a `target`, a `started_at`, and an `eta_seconds` countdown (no
    /// absolute `completes_at`).
    private func searchingDevice(_ code: String) -> Device {
        Device(
            deviceCode: code, deviceType: "survey_drone", replicantCode: "R1",
            status: "searching",
            location: "ATIANFU-BELT-1", locationName: nil, operationalCapacity: 100,
            queueSize: 0, stowedInDeviceCode: nil, controllerDeviceCode: nil,
            attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: [], tags: [],
            detail: .object([
                "scan": .object([
                    "target": .string("ATIANFU-BELT-1"),
                    "started_at": .string("1970-01-01T00:10:00Z"),
                    "progress_percent": .number(29.5),
                    "eta_seconds": .number(200),
                ])
            ]),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            firstSeenAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    /// A vessel mid-flight on a *multi-leg* route: the `travel` block carries the
    /// active leg's arrival (`arrives_at`) and the whole route's end
    /// (`final_arrives_at`, ~2.5 min later), with two legs in `route`. Mirrors a
    /// real in-transit payload.
    private func travellingDevice(_ code: String) -> Device {
        Device(
            deviceCode: code, deviceType: "heaven_vessel", replicantCode: "R1",
            status: "travelling",
            location: nil, locationName: nil, operationalCapacity: 100,
            queueSize: 0, stowedInDeviceCode: nil, controllerDeviceCode: nil,
            attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: [], tags: [],
            detail: .object([
                "travel": .object([
                    "departed_at": .string("2026-06-29T01:33:04-05:00"),
                    "arrives_at": .string("2026-06-29T01:33:54-05:00"),         // leg 1
                    "final_arrives_at": .string("2026-06-29T01:36:22-05:00"),   // route
                    "final_destination": .string("BETSU-7-L4"),
                    "route": .array([
                        .object(["leg": .number(1), "active": .bool(true), "to": .string("ATIANFU-1-L4")]),
                        .object(["leg": .number(2), "to": .string("BETSU-7-L4")]),
                    ]),
                ])
            ]),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            firstSeenAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func idleDevice(_ code: String) -> Device {
        Device(
            deviceCode: code, deviceType: "mining_drone", replicantCode: "R1", status: "idle",
            location: nil, locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: [], tags: [],
            detail: .object([:]), updatedAt: Date(timeIntervalSince1970: 1_000),
            firstSeenAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    @Test func printCompleteClosesOpenOpAndRecordsResult() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert {
                Operation(
                    id: "op1", entityCode: "965AC2C3", kind: OperationKind.print.rawValue,
                    status: OperationStatus.enqueued, source: OperationSource.poll,
                    startedAt: Date(timeIntervalSince1970: 0), completesAt: nil,
                    lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:])
                )
            }.execute(db)
        }

        let event = GameEventEnvelope(
            id: "1-0", category: "print", event: "print.completed",
            deviceCode: "965AC2C3",
            payload: ["new_device_code": .string("1F63E913"), "device_type": .string("ftl_beacon")],
            createdAt: "2026-06-26T01:00:00Z"
        )

        await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            await Reconciler().applyOperationEvent(event)
        }

        let stored = try await database.read { db in
            try Operation.where { $0.id.eq("op1") }.fetchOne(db)
        }
        #expect(stored?.status == OperationStatus.completed)
        #expect(stored?.source == OperationSource.event)
        #expect(stored?.detail["result"]?["new_device_code"]?.stringValue == "1F63E913")
    }

    /// Kind guard (V3.3-S4): a replayed completion event for one action family
    /// must not close an open op of a *different* family — the op the event
    /// completed is long gone (e.g. the server re-tasked the device from mining
    /// to travel while the app was away, then catch-up replayed the old
    /// `site.depleted`).
    @Test func crossFamilyCompletionEventLeavesOpenOpAlone() async throws {
        let database = try GameDatabase.bootstrap()
        let travelStart = Date(timeIntervalSince1970: 1_782_000_000)
        try await database.write { db in
            try Operation.insert {
                Operation(
                    id: "op-travel", entityCode: "D1", kind: OperationKind.travel.rawValue,
                    status: OperationStatus.active, source: OperationSource.poll,
                    startedAt: travelStart, completesAt: travelStart.addingTimeInterval(600),
                    lastConfirmedAt: travelStart, detail: .object([:])
                )
            }.execute(db)
        }

        // A mining completion, stamped comfortably after the travel op started —
        // only the kind guard can reject it.
        let event = GameEventEnvelope(
            id: "9-0", category: "site", event: "site.depleted",
            deviceCode: "D1", payload: nil,
            createdAt: travelStart.addingTimeInterval(60).ISO8601Format()
        )

        let closed = await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            await Reconciler().applyOperationEvent(event)
        }

        let stored = try await database.read { db in
            try Operation.where { $0.id.eq("op-travel") }.fetchOne(db)
        }
        #expect(closed == false)
        #expect(stored?.status == OperationStatus.active, "the travel op must survive a mining completion")
    }

    /// Event-time guard (V3.3-S4): a completion stamped before the open op even
    /// started belongs to an *earlier* action of the same family — replayed
    /// history must not close the current op.
    @Test func completionEventPredatingTheOpIsIgnored() async throws {
        let database = try GameDatabase.bootstrap()
        let opStart = Date(timeIntervalSince1970: 1_782_000_000)
        try await database.write { db in
            try Operation.insert {
                Operation(
                    id: "op-print", entityCode: "D1", kind: OperationKind.print.rawValue,
                    status: OperationStatus.enqueued, source: OperationSource.optimistic,
                    startedAt: opStart, completesAt: nil,
                    lastConfirmedAt: opStart, detail: .object([:])
                )
            }.execute(db)
        }

        // The previous print job's completion, replayed from catch-up: right
        // family, but stamped an hour before this op existed.
        let event = GameEventEnvelope(
            id: "8-0", category: "print", event: "print.completed",
            deviceCode: "D1",
            payload: ["new_device_code": .string("OLD1")],
            createdAt: opStart.addingTimeInterval(-3_600).ISO8601Format()
        )

        let closed = await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            await Reconciler().applyOperationEvent(event)
        }

        let stored = try await database.read { db in
            try Operation.where { $0.id.eq("op-print") }.fetchOne(db)
        }
        #expect(closed == false)
        #expect(stored?.status == OperationStatus.enqueued, "an earlier action's completion must not close the new op")
        #expect(stored?.detail["result"] == nil)
    }

    /// A completion stamped *within* the skew tolerance of the op's start (small
    /// client/server clock disagreement) still completes — the guard only
    /// refuses genuinely earlier actions, not honest skew.
    @Test func completionEventWithinSkewToleranceStillCompletes() async throws {
        let database = try GameDatabase.bootstrap()
        let opStart = Date(timeIntervalSince1970: 1_782_000_000)
        try await database.write { db in
            try Operation.insert {
                Operation(
                    id: "op-mine", entityCode: "D1", kind: OperationKind.mine.rawValue,
                    status: OperationStatus.active, source: OperationSource.optimistic,
                    startedAt: opStart, completesAt: nil,
                    lastConfirmedAt: opStart, detail: .object([:])
                )
            }.execute(db)
        }

        let event = GameEventEnvelope(
            id: "11-0", category: "site", event: "site.depleted",
            deviceCode: "D1", payload: nil,
            createdAt: opStart.addingTimeInterval(-3).ISO8601Format()   // 3s "before" — skew, not history
        )

        let closed = await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            await Reconciler().applyOperationEvent(event)
        }

        let stored = try await database.read { db in
            try Operation.where { $0.id.eq("op-mine") }.fetchOne(db)
        }
        #expect(closed == true)
        #expect(stored?.status == OperationStatus.completed)
    }

    /// `travel.arrived` also closes a recall — the same cruise shape, homeward.
    @Test func travelArrivedClosesRecallOp() async throws {
        let database = try GameDatabase.bootstrap()
        let start = Date(timeIntervalSince1970: 1_782_000_000)
        try await database.write { db in
            try Operation.insert {
                Operation(
                    id: "op-recall", entityCode: "D1", kind: OperationKind.simple("recall").rawValue,
                    status: OperationStatus.active, source: OperationSource.poll,
                    startedAt: start, completesAt: start.addingTimeInterval(300),
                    lastConfirmedAt: start, detail: .object([:])
                )
            }.execute(db)
        }

        let event = GameEventEnvelope(
            id: "10-0", category: "travel", event: "travel.arrived",
            deviceCode: "D1", payload: nil,
            createdAt: start.addingTimeInterval(290).ISO8601Format()
        )

        let closed = await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            await Reconciler().applyOperationEvent(event)
        }

        let stored = try await database.read { db in
            try Operation.where { $0.id.eq("op-recall") }.fetchOne(db)
        }
        #expect(closed == true)
        #expect(stored?.status == OperationStatus.completed)
    }

    /// No open op on the device → the event is a harmless no-op.
    @Test func printCompleteWithNoOpenOpIsNoOp() async throws {
        let database = try GameDatabase.bootstrap()
        let event = GameEventEnvelope(
            id: "1-0", category: "print", event: "print.completed",
            deviceCode: "NOPE", payload: nil, createdAt: "2026-06-26T01:00:00Z"
        )

        await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            await Reconciler().applyOperationEvent(event)
        }

        let count = try await database.read { db in try Operation.fetchCount(db) }
        #expect(count == 0)
    }

    /// Ingesting a device that is already in-progress, with no operation of its
    /// own, adopts an active op carrying the snapshot's start/completion — so a
    /// cold-load or relaunch surfaces the running task and its progress bar.
    @Test func inProgressSnapshotAdoptsActiveOp() async throws {
        let database = try GameDatabase.bootstrap()

        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await Reconciler().ingest(printingDevice("965AC2C3"))
        }

        let op = try await database.read { db in
            try Operation.where { $0.entityCode.eq("965AC2C3") }.fetchOne(db)
        }
        #expect(op?.kind == OperationKind.print.rawValue)
        #expect(op?.status == OperationStatus.active)
        #expect(op?.source == OperationSource.poll)
        #expect(op?.completesAt != nil)
        // The bar needs a positive span: completes_at is 25 min after started_at.
        if let op, let completesAt = op.completesAt {
            #expect(completesAt > op.startedAt)
        }
    }

    /// A queued print op (no deadline) is promoted to active — not duplicated —
    /// once the snapshot shows it has actually started, so its progress bar can
    /// draw. Same row (id preserved), now carrying the snapshot's deadline/start.
    @Test func queuedOpPromotedToActiveWhenPrintingStarts() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert {
                Operation(
                    id: "existing", entityCode: "965AC2C3", kind: OperationKind.print.rawValue,
                    status: OperationStatus.enqueued, source: OperationSource.optimistic,
                    startedAt: Date(timeIntervalSince1970: 0), completesAt: nil,
                    lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:])
                )
            }.execute(db)
        }

        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await Reconciler().ingest(printingDevice("965AC2C3"))
        }

        let ops = try await database.read { db in
            try Operation.where { $0.entityCode.eq("965AC2C3") }.fetchAll(db)
        }
        #expect(ops.count == 1)
        let op = ops.first
        #expect(op?.id == "existing")
        #expect(op?.status == OperationStatus.active)
        #expect(op?.completesAt != nil)
        if let op, let completesAt = op.completesAt {
            #expect(completesAt > op.startedAt)
        }
    }

    /// An `optimistic` op (dispatch still in flight) is left untouched — dispatch
    /// owns its confirmation; reconcile must not race it.
    @Test func optimisticOpLeftForDispatchToConfirm() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert {
                Operation(
                    id: "staging", entityCode: "965AC2C3", kind: OperationKind.print.rawValue,
                    status: OperationStatus.optimistic, source: OperationSource.optimistic,
                    startedAt: Date(timeIntervalSince1970: 0), completesAt: nil,
                    lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:])
                )
            }.execute(db)
        }

        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await Reconciler().ingest(printingDevice("965AC2C3"))
        }

        let ops = try await database.read { db in
            try Operation.where { $0.entityCode.eq("965AC2C3") }.fetchAll(db)
        }
        #expect(ops.count == 1)
        #expect(ops.first?.status == OperationStatus.optimistic)
    }

    /// Meeting a survey drone mid-search (a `scan` block with an `eta_seconds`
    /// countdown and no `completes_at`) adopts an active `search` op whose
    /// deadline is the fetch event-time plus the remaining ETA — so a cold-load
    /// surfaces the search and its progress bar.
    @Test func searchingSnapshotAdoptsActiveSearchOpWithDeadline() async throws {
        let database = try GameDatabase.bootstrap()

        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await Reconciler().ingest(searchingDevice("2586E328"))
        }

        let op = try await database.read { db in
            try Operation.where { $0.entityCode.eq("2586E328") }.fetchOne(db)
        }
        #expect(op?.kind == OperationKind.search.rawValue)
        #expect(op?.status == OperationStatus.active)
        #expect(op?.source == OperationSource.poll)
        // updatedAt (1_000) + eta_seconds (200): eta is *remaining* time, so the
        // deadline anchors on the fetch time, not started_at.
        #expect(op?.completesAt == Date(timeIntervalSince1970: 1_200))
    }

    /// A `scan_complete` event closes the drone's open search op — the search
    /// found a site and the drone now *tracks* it (it never settles to idle), so
    /// the event, not a settled status, is the completion signal.
    @Test func scanCompleteClosesOpenSearchOp() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert {
                Operation(
                    id: "s1", entityCode: "2586E328", kind: OperationKind.search.rawValue,
                    status: OperationStatus.active, source: OperationSource.poll,
                    startedAt: Date(timeIntervalSince1970: 0), completesAt: Date(timeIntervalSince1970: 1_200),
                    lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:])
                )
            }.execute(db)
        }

        let event = GameEventEnvelope(
            id: "1-0", category: "scan", event: "scan.completed",
            deviceCode: "2586E328", payload: nil, createdAt: "2026-06-29T00:16:14Z"
        )

        await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            await Reconciler().applyOperationEvent(event)
        }

        let stored = try await database.read { db in
            try Operation.where { $0.id.eq("s1") }.fetchOne(db)
        }
        #expect(stored?.status == OperationStatus.completed)
        #expect(stored?.source == OperationSource.event)
    }

    /// Meeting a vessel mid-multi-leg-travel adopts a travel op whose deadline is
    /// the *route's* end (`final_arrives_at`), not the active leg's arrival
    /// (`arrives_at`). Regression: keying off `arrives_at` ended the trip a leg
    /// early.
    @Test func multiLegTravelSnapshotAdoptsOpWithRouteDeadline() async throws {
        let database = try GameDatabase.bootstrap()

        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await Reconciler().ingest(travellingDevice("965AC2C3"))
        }

        let op = try await database.read { db in
            try Operation.where { $0.entityCode.eq("965AC2C3") }.fetchOne(db)
        }
        #expect(op?.kind == OperationKind.travel.rawValue)
        #expect(op?.status == OperationStatus.active)
        let routeEnd = try Date("2026-06-29T01:36:22-05:00", strategy: Date.ISO8601FormatStyle())
        let leg1End = try Date("2026-06-29T01:33:54-05:00", strategy: Date.ISO8601FormatStyle())
        #expect(op?.completesAt == routeEnd)
        #expect(op?.completesAt != leg1End)
    }

    /// A *per-leg* arrival event must not complete an open travel op — those fire
    /// on every leg. Only the whole-route `travel.arrived` closes the trip.
    /// Regression: completing on the leg event ended a multi-leg trip after its
    /// first leg.
    @Test func legArrivalDoesNotCompleteTravelButRouteArrivalDoes() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert {
                Operation(
                    id: "t1", entityCode: "965AC2C3", kind: OperationKind.travel.rawValue,
                    status: OperationStatus.active, source: OperationSource.poll,
                    startedAt: Date(timeIntervalSince1970: 0), completesAt: Date(timeIntervalSince1970: 1_200),
                    lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:])
                )
            }.execute(db)
        }

        let legEvent = GameEventEnvelope(
            id: "1-0", category: "travel", event: "travel.cruise_arrived",
            deviceCode: "965AC2C3", payload: ["location": .string("ATIANFU-1-L4")],
            createdAt: "2026-06-29T01:33:54-05:00"
        )
        let routeEvent = GameEventEnvelope(
            id: "2-0", category: "travel", event: "travel.arrived",
            deviceCode: "965AC2C3", payload: ["location": .string("BETSU-7-L4"), "star": .string("BETSU")],
            createdAt: "2026-06-29T01:36:23-05:00"
        )

        try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            await Reconciler().applyOperationEvent(legEvent)
            let afterLeg = try await database.read { db in
                try Operation.where { $0.id.eq("t1") }.fetchOne(db)
            }
            #expect(afterLeg?.status == OperationStatus.active)  // still in transit

            await Reconciler().applyOperationEvent(routeEvent)
            let afterRoute = try await database.read { db in
                try Operation.where { $0.id.eq("t1") }.fetchOne(db)
            }
            #expect(afterRoute?.status == OperationStatus.completed)
            #expect(afterRoute?.source == OperationSource.event)
        }
    }

    /// Ingesting a now-settled device completes its open deadline-bearing op
    /// directly — the robust travel-completion path, since a simple single-leg
    /// trip only emits a per-leg `device_cruise_arrived` (no whole-route event)
    /// and an early arrival can beat the estimated ETA. Mirrors the
    /// DeadlineScheduler's `isSettled → complete`, but on the confirm-read.
    @Test func settledDeviceCompletesOpenTravelOp() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert {
                Operation(
                    id: "t1", entityCode: "965AC2C3", kind: OperationKind.travel.rawValue,
                    status: OperationStatus.active, source: OperationSource.poll,
                    startedAt: Date(timeIntervalSince1970: 0),
                    completesAt: Date(timeIntervalSince1970: 5_000),  // ETA still in the "future"
                    lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:])
                )
            }.execute(db)
        }

        // The vessel arrived (idle) — even though its op's ETA hasn't elapsed.
        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await Reconciler().ingest(idleDevice("965AC2C3"))
        }

        let op = try await database.read { db in
            try Operation.where { $0.id.eq("t1") }.fetchOne(db)
        }
        #expect(op?.status == OperationStatus.completed)
        #expect(op?.source == OperationSource.poll)
    }

    /// A settled device does *not* complete a continuous op with no deadline
    /// (mining runs until stopped by its own signals), so the open op survives.
    @Test func settledDeviceLeavesDeadlinelessOpOpen() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert {
                Operation(
                    id: "m1", entityCode: "304F6EC1", kind: OperationKind.mine.rawValue,
                    status: OperationStatus.active, source: OperationSource.poll,
                    startedAt: Date(timeIntervalSince1970: 0), completesAt: nil,
                    lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:])
                )
            }.execute(db)
        }

        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await Reconciler().ingest(idleDevice("304F6EC1"))
        }

        let op = try await database.read { db in
            try Operation.where { $0.id.eq("m1") }.fetchOne(db)
        }
        #expect(op?.status == OperationStatus.active)
    }

    /// The reconciliation guard (§5.3) orders device snapshots by their
    /// synthesized event-time (`updatedAt` = request-issue time), not by arrival:
    /// a read that was *issued* earlier must not overwrite a newer one that
    /// already landed, even though it arrives afterwards. Regression for the
    /// "slow poll clobbers a fresh event's confirm-read" hazard.
    @Test func staleIssuedSnapshotDoesNotClobberNewer() async throws {
        let database = try GameDatabase.bootstrap()

        // The newer read (issued at t=2_000) lands first: device is travelling.
        var newer = travellingDevice("965AC2C3")
        newer.updatedAt = Date(timeIntervalSince1970: 2_000)
        // A slower read that was issued *earlier* (t=1_000) arrives afterwards,
        // carrying the older "idle" state.
        var staleButLate = idleDevice("965AC2C3")
        staleButLate.updatedAt = Date(timeIntervalSince1970: 1_000)

        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await Reconciler().ingest(newer)
            await Reconciler().ingest(staleButLate)
        }

        let stored = try await database.read { db in
            try Device.where { $0.deviceCode.eq("965AC2C3") }.fetchOne(db)
        }
        // The stale-but-late read was dropped; the newer snapshot stands.
        #expect(stored?.status == "travelling")
        #expect(stored?.updatedAt == Date(timeIntervalSince1970: 2_000))
    }

    /// A newer read (later issue-time) overwrites the stored snapshot, and the
    /// local-only `firstSeenAt` provenance survives the upsert.
    @Test func newerSnapshotOverwritesAndPreservesFirstSeen() async throws {
        let database = try GameDatabase.bootstrap()

        var first = travellingDevice("965AC2C3")
        first.updatedAt = Date(timeIntervalSince1970: 1_000)
        first.firstSeenAt = Date(timeIntervalSince1970: 1_000)

        var later = idleDevice("965AC2C3")
        later.updatedAt = Date(timeIntervalSince1970: 3_000)
        later.firstSeenAt = Date(timeIntervalSince1970: 3_000)  // ignored on upsert

        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await Reconciler().ingest(first)
            await Reconciler().ingest(later)
        }

        let stored = try await database.read { db in
            try Device.where { $0.deviceCode.eq("965AC2C3") }.fetchOne(db)
        }
        #expect(stored?.status == "idle")
        #expect(stored?.updatedAt == Date(timeIntervalSince1970: 3_000))
        #expect(stored?.firstSeenAt == Date(timeIntervalSince1970: 1_000))  // preserved
    }

    /// A settled (idle) device carries no activity block, so nothing is adopted.
    @Test func settledDeviceAdoptsNothing() async throws {
        let database = try GameDatabase.bootstrap()

        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await Reconciler().ingest(idleDevice("304F6EC1"))
        }

        let count = try await database.read { db in try Operation.fetchCount(db) }
        #expect(count == 0)
    }
}
