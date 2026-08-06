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

    /// Statuses whose out-of-range reading is expected, not actionable, so
    /// `.outOfControlRange` is suppressed for them. As a category: a device
    /// in transit on an FTL route it will complete, which has left the relay
    /// mesh *on purpose* and will rejoin on arrival, so the flag carries no
    /// information and would only put a healthy in-transit device into the
    /// operator's triage list.
    ///
    /// `travelling` and `surging` are the confirmed members — the app's
    /// owner confirmed `travelling` directly, and `surging` was the original
    /// status this constant was introduced for. `cruising` is an inference
    /// from the same mechanic, not separately confirmed: `travelling` is the
    /// whole-route status while `cruising` and `surging` are the *per-leg*
    /// statuses of that same trip (`device_cruise_arrived` and
    /// `device_surge_hop_arrived` each fire once per leg; `device_travel_arrived`
    /// fires only at the final destination). With `travelling` and `surging`
    /// both exempt, leaving `cruising` in would make a device mid-route
    /// appear and disappear from the triage list as its legs change — exactly
    /// the noise this constant exists to remove.
    ///
    /// `recalling` (a drone returning to its controller) is deliberately
    /// excluded — it's a different mechanic from FTL travel, and there is no
    /// live evidence it goes out of range; a genuinely cut-off recalling
    /// drone is worth surfacing.
    ///
    /// A `Set` so a future transit status can join without restructuring the
    /// check — but don't add one speculatively; confirm live evidence first
    /// (see the note this constant was introduced against).
    public static let rangeCheckExemptStatuses: Set<String> = ["surging", "travelling", "cruising"]

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
        if device.isOutOfControlRange && !rangeCheckExemptStatuses.contains(device.statusBase) {
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
