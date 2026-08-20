//
//  DeviceDetailOperationsTests.swift
//  Replicould — DevicesFeature
//
//  Which of a bench's live operations the Active Task card shows, and how
//  many wait behind it — regression coverage for C10 (a later-started
//  enqueued job beating the active one under a `startedAt DESC` fetch).
//

import Foundation
import GameModels
import Testing
@testable import DevicesFeature

private typealias Operation = GameModels.Operation
private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func op(on device: String, id: String, status: OperationStatus, startedAt: Date = now) -> Operation {
    Operation(
        id: id, entityCode: device, kind: OperationKind.print.rawValue,
        status: status, source: .poll, startedAt: startedAt, completesAt: nil,
        lastConfirmedAt: startedAt, detail: .object([:])
    )
}

@Suite("Device detail — which operation the card shows")
struct DeviceDetailOperationsTests {

    /// The enqueued job started later, so a `startedAt DESC` fetch put it
    /// first and the card said "Queued" over a running printer.
    @Test("the card shows the active job, not the newest open one")
    func cardShowsTheActiveJob() {
        let active = op(on: "B1", id: "OP-1", status: .active, startedAt: now.addingTimeInterval(-120))
        let queued = op(on: "B1", id: "OP-2", status: .enqueued, startedAt: now.addingTimeInterval(-30))

        #expect(DeviceOperations.card(for: "B1", in: [queued, active])?.id == "OP-1")
    }

    @Test("a bench with only queued jobs shows the oldest of them")
    func queuedOnlyShowsTheOldest() {
        let first = op(on: "B1", id: "OP-1", status: .enqueued, startedAt: now.addingTimeInterval(-120))
        let second = op(on: "B1", id: "OP-2", status: .enqueued, startedAt: now.addingTimeInterval(-30))

        #expect(DeviceOperations.card(for: "B1", in: [second, first])?.id == "OP-1")
    }

    @Test("the queued-behind count excludes the job on the card")
    func queuedBehindExcludesTheCard() {
        let active = op(on: "B1", id: "OP-1", status: .active, startedAt: now.addingTimeInterval(-120))
        let a = op(on: "B1", id: "OP-2", status: .enqueued, startedAt: now.addingTimeInterval(-60))
        let b = op(on: "B1", id: "OP-3", status: .enqueued, startedAt: now.addingTimeInterval(-30))

        #expect(DeviceOperations.queuedBehind(for: "B1", in: [active, a, b]) == 2)
    }

    /// A closed op on the same device must not count as queued behind, and
    /// a live op on a different device must not win the pick.
    @Test("closed and other-device operations are excluded from both")
    func closedAndOtherDeviceOperationsAreExcluded() {
        let active = op(on: "B1", id: "OP-1", status: .active, startedAt: now.addingTimeInterval(-120))
        let closed = op(on: "B1", id: "OP-2", status: .completed, startedAt: now.addingTimeInterval(-30))
        let elsewhere = op(on: "B2", id: "OP-3", status: .enqueued, startedAt: now.addingTimeInterval(-10))

        #expect(DeviceOperations.card(for: "B1", in: [active, closed, elsewhere])?.id == "OP-1")
        #expect(DeviceOperations.queuedBehind(for: "B1", in: [active, closed, elsewhere]) == 0)
    }

    @Test("no live operations on the device yields no card")
    func noLiveOperationsYieldsNoCard() {
        #expect(DeviceOperations.card(for: "B1", in: []) == nil)
        #expect(DeviceOperations.queuedBehind(for: "B1", in: []) == 0)
    }
}
