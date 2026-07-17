//
//  Printing.swift
//  Replicould — shared dependency clients
//
//  A printer's fabrication state, mapped to display value types. A device with
//  the `print` feature reports its work in three tail blocks: the `printing`
//  block (the job under way — the device type being fabricated, its start /
//  completion times, and a server-authoritative `progress_percent`), the
//  `print_queue` array (jobs waiting their turn behind the active one), and the
//  `waiting_for` object (resources a queued job still needs before it can start,
//  as `{resource: {need, have}}`). The Print Queue feature renders straight from
//  these, so the readout reflects the device's own state rather than a locally
//  tracked operation. The `print_queue` item schema is undocumented server-side,
//  so parsing is deliberately lenient — the queue index (array position) is the
//  stable handle `dequeue_print` uses.
//

import Foundation
import Utils

/// The print job a device is actively fabricating, parsed from its `printing`
/// block. Progress is server-authoritative (`progress_percent`); `startedAt` /
/// `completesAt` let the UI interpolate a live bar between reads.
public struct PrintingSnapshot: Equatable, Sendable {
    /// The device type being fabricated (`autofactory`, `ftl_beacon`, …).
    public var deviceType: String?
    /// When the current job began (the progress-bar anchor).
    public var startedAt: Date?
    /// When the current job completes.
    public var completesAt: Date?
    /// Server-reported completion percent (0…100).
    public var progressPercent: Double?
    /// Seconds remaining, as reported by the server.
    public var etaSeconds: Double?

    public init(
        deviceType: String? = nil,
        startedAt: Date? = nil,
        completesAt: Date? = nil,
        progressPercent: Double? = nil,
        etaSeconds: Double? = nil
    ) {
        self.deviceType = deviceType
        self.startedAt = startedAt
        self.completesAt = completesAt
        self.progressPercent = progressPercent
        self.etaSeconds = etaSeconds
    }
}

extension PrintingSnapshot {
    /// Parse from a device's `printing` block. Nil when the value isn't an object
    /// (the device isn't printing).
    public init?(printingBlock value: JSONValue?) {
        guard case .object = value else { return nil }
        self.init(
            deviceType: value?["device_type"]?.stringValue,
            startedAt: value?["started_at"]?.stringValue.flatMap(DiversionSnapshot.parseDate),
            completesAt: value?["completes_at"]?.stringValue.flatMap(DiversionSnapshot.parseDate),
            progressPercent: value?["progress_percent"]?.numberValue,
            etaSeconds: value?["eta_seconds"]?.numberValue
        )
    }
}

/// One job waiting behind the active print, parsed from a `print_queue` entry.
/// The queue-item schema is undocumented, so only the fields we can rely on are
/// surfaced; `index` is the entry's position in the array, which is the handle
/// `dequeue_print` removes by.
public struct PrintQueueItem: Equatable, Sendable, Identifiable {
    /// Zero-based position in the queue — the `dequeue_print` index.
    public var index: Int
    /// The device type this queued job will fabricate.
    public var deviceType: String?
    /// A controller device the finished device should auto-adopt under, if the
    /// job carried one.
    public var controller: String?
    /// Tags to apply to the finished device.
    public var tags: [String]

    public var id: Int { index }

    public init(index: Int, deviceType: String? = nil, controller: String? = nil, tags: [String] = []) {
        self.index = index
        self.deviceType = deviceType
        self.controller = controller
        self.tags = tags
    }
}

/// A resource a queued print still needs before it can start, parsed from a
/// `waiting_for` entry (`{resource: {need, have}}`).
public struct WaitingResource: Equatable, Sendable, Identifiable {
    public var resource: String
    public var need: Double?
    public var have: Double?

    public var id: String { resource }

    /// Whether the location already holds enough of this resource.
    public var isMet: Bool { (have ?? 0) >= (need ?? 0) }

    public init(resource: String, need: Double? = nil, have: Double? = nil) {
        self.resource = resource
        self.need = need
        self.have = have
    }
}

extension Device {
    /// Whether this device can print (has the `print` feature). The Print Queue
    /// gate — an idle printer with an empty queue is excluded, but the feature
    /// flag is what distinguishes a printer from any other busy device.
    public var canPrint: Bool { features.contains("print") }

    /// The job the device is actively fabricating, parsed from its `printing`
    /// block. Nil when the device isn't printing.
    public var printingSnapshot: PrintingSnapshot? {
        PrintingSnapshot(printingBlock: detail["printing"])
    }

    /// The jobs queued behind the active print, in order. Empty when the device
    /// carries no `print_queue` array (or an empty one). This is the authoritative
    /// source for what's queued — the `queueSize` column is the queue *capacity*
    /// (e.g. 10 for an idle autofactory), not the number of jobs waiting.
    public var printQueueItems: [PrintQueueItem] {
        guard let items = detail["print_queue"]?.arrayValue else { return [] }
        return items.enumerated().map { offset, item in
            PrintQueueItem(
                index: offset,
                deviceType: item["device_type"]?.stringValue,
                controller: item["controller"]?.stringValue,
                tags: item["tags"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
        }
    }

    /// The number of jobs actually waiting behind the active print — the length of
    /// the `print_queue` array. Distinct from `queueSize`, which is the queue's
    /// *capacity*.
    public var queuedJobCount: Int { printQueueItems.count }

    /// Resources a queued print is still waiting on before it can start, parsed
    /// from the `waiting_for` object (`{resource: {need, have}}`). Empty when the
    /// device isn't blocked on resources. Sorted by resource name for a stable
    /// readout.
    public var waitingForResources: [WaitingResource] {
        guard case let .object(dict)? = detail["waiting_for"] else { return [] }
        return dict.map { resource, amounts in
            WaitingResource(
                resource: resource,
                need: amounts["need"]?.numberValue,
                have: amounts["have"]?.numberValue
            )
        }
        .sorted { $0.resource < $1.resource }
    }

    /// Whether this device belongs in the Print Queue: it can print and is either
    /// actively printing or holding queued jobs. Idle printers with an empty queue
    /// are excluded.
    public var isPrintingOrQueued: Bool {
        canPrint && (printingSnapshot != nil || queuedJobCount > 0)
    }
}
