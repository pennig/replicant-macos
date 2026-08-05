//
//  DeviceListAttention.swift
//  Replicould — Devices feature
//
//  Which devices need the operator right now, and in what order they read.
//

import Foundation
import GameModels

extension DeviceListLayout {

    /// Below this operational capacity a device reads as damaged. 50 flags 3
    /// devices on the 2026-08-05 fleet; 100 would flag 17 and be noise.
    public static let damagedCapacityThreshold: Double = 50

    /// Every reason `device` needs attention, in display order.
    ///
    /// `directives` must already be filtered to `DirectiveStatus.needsAttention`
    /// — the caller's `@FetchAll` does that in SQL, and this function does not
    /// re-check, so passing unfiltered directives over-flags.
    public static func attentionFlags(
        for device: Device,
        directives: [Directive]
    ) -> [AttentionFlag] {
        var flags: [AttentionFlag] = []
        if device.isOutOfControlRange {
            flags.append(.outOfControlRange)
        }
        if device.operationalCapacity < damagedCapacityThreshold {
            flags.append(.damaged(capacity: device.operationalCapacity))
        }
        for directive in directives where covers(directive, device) {
            flags.append(.directive(directive.attentionReason))
        }
        return flags
    }

    /// The three join paths from a flagged directive to a device.
    static func covers(_ directive: Directive, _ device: Device) -> Bool {
        if directive.deviceCode == device.deviceCode { return true }
        if directive.controllerCode == device.deviceCode { return true }
        if let tag = directive.fleetTag, device.tags.contains(tag) { return true }
        return false
    }

    /// The Needs Attention section's own order: out-of-control-range (0),
    /// damaged (1), directive-flagged (2).
    static func attentionRank(_ flags: [AttentionFlag]) -> Int {
        if flags.contains(.outOfControlRange) { return 0 }
        if flags.contains(where: { if case .damaged = $0 { true } else { false } }) { return 1 }
        return 2
    }

    /// Out-of-control-range first, then damaged ascending by capacity (the worst
    /// device leads), then directive-flagged, then device code.
    static func attentionPrecedes(
        _ a: Device,
        _ b: Device,
        attention: [String: [AttentionFlag]]
    ) -> Bool {
        let rankA = attentionRank(attention[a.deviceCode] ?? [])
        let rankB = attentionRank(attention[b.deviceCode] ?? [])
        if rankA != rankB { return rankA < rankB }
        if rankA == 1, a.operationalCapacity != b.operationalCapacity {
            return a.operationalCapacity < b.operationalCapacity
        }
        return a.deviceCode < b.deviceCode
    }
}
