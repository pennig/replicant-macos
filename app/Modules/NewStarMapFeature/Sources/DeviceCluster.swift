//
//  DeviceCluster.swift
//  NewStarMapFeature
//
//  The device-presence overlay's data types. Devices at an orrery location are merged
//  from two sources — the live `Device` roster (the player's own, authoritative, with
//  live status) and the persisted system-scan blob (other players', coarse + possibly
//  stale) — deduped by device code (own wins) and grouped by the anchor the current
//  focus level draws them at (a moon rolls up to its planet at system level, see
//  `OrreryLayout.anchor`). The renderer projects each anchor to screen every frame and
//  pushes `[ProjectedCluster]` to the overlay, mirroring the ship projection path.
//

import CoreGraphics
import SwiftUI

/// One device present at an orrery location. `isOwn` (from the live roster) drives
/// whether tapping can open the Devices inspector; others are read-only.
struct ClusterDevice: Equatable, Identifiable {
    var deviceCode: String
    var deviceType: String
    var status: String?
    var isOwn: Bool
    var id: String { deviceCode }
}

/// The devices grouped at one orrery anchor (the designation the current level renders).
/// Own devices sort first. Drives a single badge-with-count, not one icon per device, so
/// the on-screen icon count stays ≈ occupied locations however many devices sit there.
struct DeviceCluster: Equatable, Identifiable {
    var anchorCode: String
    var devices: [ClusterDevice]
    var id: String { anchorCode }

    var count: Int { devices.count }
    var hasOwn: Bool { devices.contains { $0.isOwn } }
    /// The device type whose glyph represents the cluster — the first own device, else
    /// the first device.
    var primaryType: String { (devices.first { $0.isOwn } ?? devices.first)?.deviceType ?? "" }
}

/// One cluster's on-screen placement for the SwiftUI overlay (view POINTS, top-left
/// origin, matching SwiftUI's local space), with an opacity that tracks the orrery
/// reveal so badges fade in with the drill and out on zoom-back.
struct ProjectedCluster: Equatable, Identifiable {
    var anchorCode: String
    var point: CGPoint
    var count: Int
    var primaryType: String
    var hasOwn: Bool
    var opacity: Double
    var id: String { anchorCode }
}

/// The observable the renderer pushes projected clusters to each frame; read only by
/// `LocationClusterLayer` so a per-frame update re-renders just that overlay.
@MainActor
@Observable
final class DeviceClusterProjectionModel {
    var clusters: [ProjectedCluster] = []
}

/// The pure merge/group step, factored out of the view so it's unit-testable: dedup by
/// device code (own wins — it's fed first), group by the anchor the layer draws, own
/// devices first within each. Foreign devices duplicating an own code are dropped.
enum DeviceClustering {
    /// One device to place: its identity + type/status and its full location code.
    struct Input: Equatable {
        var deviceCode: String
        var deviceType: String
        var status: String?
        var location: String
    }

    /// Group `own` (authoritative) then `others` into clusters via `layout`. A device
    /// whose location doesn't resolve in this layer (e.g. a sibling planet at body level)
    /// is dropped. Returns clusters in no particular order (the caller/renderer places
    /// them); devices within each are own-first then by code.
    static func clusters(own: [Input], others: [Input], layout: OrreryLayout) -> [DeviceCluster] {
        var byAnchor: [String: [ClusterDevice]] = [:]
        var seen: Set<String> = []
        func add(_ i: Input, isOwn: Bool) {
            guard !seen.contains(i.deviceCode), let anchor = layout.anchor(ofLocation: i.location)?.code
            else { return }
            seen.insert(i.deviceCode)
            byAnchor[anchor, default: []].append(
                ClusterDevice(deviceCode: i.deviceCode, deviceType: i.deviceType,
                              status: i.status, isOwn: isOwn))
        }
        for i in own { add(i, isOwn: true) }
        for i in others { add(i, isOwn: false) }
        return byAnchor.map { code, devs in
            DeviceCluster(anchorCode: code, devices: devs.sorted {
                ($0.isOwn ? 0 : 1, $0.deviceCode) < ($1.isOwn ? 0 : 1, $1.deviceCode)
            })
        }
        .sorted { $0.anchorCode < $1.anchorCode }   // deterministic order (no spurious diffs)
    }
}
