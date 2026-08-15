//
//  PrintingSnapshotTests.swift
//  Replicould — GameServices
//
//  `PrintingSnapshot(printingBlock:)` maps a printer's `printing` block to the
//  active-job readout, and the `Device` extensions surface the queue
//  (`print_queue`), the resources a job is blocked on (`waiting_for`), and the
//  `isPrintingOrQueued` gate the Print Queue list filters on. The `printing`
//  block here is a real payload captured from a live heaven vessel.
//

import Foundation
import GameModels
import Testing
import Utils
@testable import GameServices

@Suite struct PrintingSnapshotTests {

    /// A real `printing` block from a heaven vessel fabricating an autofactory.
    private var printingBlock: JSONValue {
        .object([
            "eta_seconds": .number(1983.5),
            "progress_percent": .number(17.4),
            "completes_at": .string("2026-07-02T08:38:25-05:00"),
            "started_at": .string("2026-07-02T07:58:25-05:00"),
            "device_type": .string("autofactory"),
        ])
    }

    @Test func parsesEveryField() throws {
        let p = try #require(PrintingSnapshot(printingBlock: printingBlock))
        #expect(p.deviceType == "autofactory")
        #expect(p.progressPercent == 17.4)
        #expect(p.etaSeconds == 1983.5)
    }

    @Test func parsesTimestampsAsOffset() throws {
        let p = try #require(PrintingSnapshot(printingBlock: printingBlock))
        #expect(p.startedAt == (try Date("2026-07-02T12:58:25Z", strategy: .iso8601)))
        #expect(p.completesAt == (try Date("2026-07-02T13:38:25Z", strategy: .iso8601)))
    }

    @Test func returnsNilForNonObject() {
        #expect(PrintingSnapshot(printingBlock: nil) == nil)
        #expect(PrintingSnapshot(printingBlock: .string("nope")) == nil)
    }

    @Test func deviceReadsPrintingBlock() throws {
        let device = makeDevice(detail: .object(["printing": printingBlock]))
        #expect(device.printingSnapshot?.deviceType == "autofactory")
    }

    // MARK: Queue

    @Test func parsesPrintQueueItemsInOrder() throws {
        let device = makeDevice(detail: .object([
            "print_queue": .array([
                .object(["device_type": .string("mining_drone"), "tags": .array([.string("alpha")])]),
                .object(["device_type": .string("survey_drone"), "controller": .string("CTRL1234")]),
            ]),
        ]))
        let items = device.printQueueItems
        #expect(items.count == 2)
        #expect(items[0].index == 0)
        #expect(items[0].deviceType == "mining_drone")
        #expect(items[0].tags == ["alpha"])
        #expect(items[1].index == 1)
        #expect(items[1].deviceType == "survey_drone")
        #expect(items[1].controller == "CTRL1234")
    }

    @Test func emptyQueueWhenNoBlock() {
        #expect(makeDevice(detail: .object([:])).printQueueItems.isEmpty)
    }

    // MARK: Waiting-for resources

    @Test func parsesWaitingForResourcesSortedByName() throws {
        let device = makeDevice(detail: .object([
            "waiting_for": .object([
                "structural": .object(["need": .number(10), "have": .number(4)]),
                "conductive": .object(["need": .number(2), "have": .number(2)]),
            ]),
        ]))
        let resources = device.waitingForResources
        #expect(resources.map(\.resource) == ["conductive", "structural"])
        #expect(resources[0].isMet)          // have 2 ≥ need 2
        #expect(resources[1].isMet == false) // have 4 < need 10
    }

    // MARK: isPrintingOrQueued gate

    @Test func gateRequiresPrintFeature() {
        // Printing block present but no `print` feature → excluded.
        let device = makeDevice(detail: .object(["printing": printingBlock]), features: [])
        #expect(device.isPrintingOrQueued == false)
    }

    @Test func gateIncludesActivePrinter() {
        let device = makeDevice(detail: .object(["printing": printingBlock]), features: ["print"])
        #expect(device.isPrintingOrQueued)
    }

    @Test func gateIncludesQueuedButIdlePrinter() {
        // Jobs waiting in `print_queue`, no active print → included.
        let queue = JSONValue.array([.object(["device_type": .string("mining_drone")])])
        let device = makeDevice(detail: .object(["print_queue": queue]), features: ["print"])
        #expect(device.isPrintingOrQueued)
    }

    @Test func gateExcludesIdleEmptyPrinter() {
        let device = makeDevice(detail: .object([:]), features: ["print"], queueSize: 0)
        #expect(device.isPrintingOrQueued == false)
    }

    // Regression: `queue_size` is the queue *capacity*, not the count of queued
    // jobs. An idle autofactory advertises a capacity (e.g. 10) with an empty
    // `print_queue`; it must not be treated as printing/queued.
    @Test func gateExcludesIdlePrinterWithCapacityButNoJobs() {
        let device = makeDevice(detail: .object([:]), features: ["print"], queueSize: 10)
        #expect(device.queuedJobCount == 0)
        #expect(device.isPrintingOrQueued == false)
    }

    @Test("a component blockage parses as component rows, not one nil row")
    func nestedComponents() {
        let device = makeDevice(detail: .object([
            "waiting_for": .object([
                "components": .object([
                    "filtration_array": .object(["have": .number(0), "need": .number(1)]),
                    "atmo_processor": .object(["have": .number(1), "need": .number(2)]),
                ])
            ]),
        ]))
        let rows = device.waitingForResources
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.kind == .component })
        #expect(rows.first?.resource == "atmo_processor")
        #expect(rows.first?.need == 2)
        #expect(rows.first?.have == 1)
        #expect(rows.allSatisfy { !$0.isMet })
    }

    @Test("a row with neither need nor have is unmet, never met")
    func unparseableRowIsUnmet() {
        let row = WaitingResource(resource: "components", need: nil, have: nil)
        #expect(!row.isMet)
    }

    @Test("the flat resource shape still parses")
    func flatResources() {
        let device = makeDevice(detail: .object([
            "waiting_for": .object([
                "structural": .object(["have": .number(10), "need": .number(80)])
            ]),
        ]))
        let rows = device.waitingForResources
        #expect(rows.count == 1)
        #expect(rows.first?.kind == .resource)
        #expect(rows.first?.need == 80)
    }

    @Test("a nested resources block parses as resource rows")
    func nestedResources() {
        let device = makeDevice(detail: .object([
            "waiting_for": .object([
                "resources": .object([
                    "structural": .object(["have": .number(10), "need": .number(80)])
                ])
            ]),
        ]))
        let rows = device.waitingForResources
        #expect(rows.count == 1)
        #expect(rows.first?.kind == .resource)
        #expect(rows.first?.resource == "structural")
    }

    private func makeDevice(
        detail: JSONValue,
        features: [String] = ["print"],
        queueSize: Int = 0
    ) -> Device {
        Device(
            deviceCode: "965AC2C3", deviceType: "heaven_vessel", replicantCode: "R1",
            status: "printing (autofactory)", location: "ATIANFU-1", locationName: nil,
            operationalCapacity: 100, queueSize: queueSize, stowedInDeviceCode: nil,
            controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: features,
            tags: [], detail: detail, updatedAt: Date(timeIntervalSince1970: 1_000),
            firstSeenAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}
