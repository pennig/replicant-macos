//
//  TransportDigest.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  A typed read of `ami.transport.digest` — an AMI transport's only channel.
//

import API
import Foundation
import Utils

public struct TransportDigest: Equatable, Sendable {
    public let controllerCode: String
    public let collect: String?
    public let deliver: String?
    public let cargoCarried: Int
    public let cargoCapacity: Int
    public let collectedCount: Int
    public let deliveredCount: Int
    /// The device whose `last_event` names a transport action this window.
    public let activeDeviceCode: String?
    public let observedAt: Date

    public init?(envelope: GameEventEnvelope, now: Date) {
        guard let controllerCode = envelope.deviceCode else { return nil }
        let payload = envelope.payload ?? [:]
        let report = payload["report"]
        let counts = payload["activity"]?["counts"]

        self.controllerCode = controllerCode
        self.collect = report?["collect"]?.stringValue
        self.deliver = report?["deliver"]?.stringValue
        self.cargoCarried = report?["cargo_carried"]?.numberValue.map(Int.init) ?? 0
        self.cargoCapacity = report?["cargo_capacity"]?.numberValue.map(Int.init) ?? 0
        self.collectedCount = counts?["transport.collected"]?.numberValue.map(Int.init) ?? 0
        self.deliveredCount = counts?["transport.delivered"]?.numberValue.map(Int.init) ?? 0
        self.activeDeviceCode = payload["devices"]?.arrayValue?.first { entry in
            (entry["last_event"]?.stringValue ?? "").hasPrefix("transport.")
        }?["device_code"]?.stringValue
        self.observedAt = envelope.date ?? now
    }

    public init(
        controllerCode: String,
        collect: String?,
        deliver: String?,
        cargoCarried: Int,
        cargoCapacity: Int,
        collectedCount: Int,
        deliveredCount: Int,
        activeDeviceCode: String?,
        observedAt: Date
    ) {
        self.controllerCode = controllerCode
        self.collect = collect
        self.deliver = deliver
        self.cargoCarried = cargoCarried
        self.cargoCapacity = cargoCapacity
        self.collectedCount = collectedCount
        self.deliveredCount = deliveredCount
        self.activeDeviceCode = activeDeviceCode
        self.observedAt = observedAt
    }
}
