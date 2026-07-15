//
//  LocationClusterLayer.swift
//  NewStarMapFeature
//
//  The tappable SwiftUI layer that floats one device-presence badge over each occupied
//  orrery location. Like `ShipOverlayLayer`, it is a DEDICATED view whose `body` reads
//  `projection.clusters` (mutated every frame by the renderer) — so only this view
//  re-renders per frame, never the map view. One badge per location (not per device)
//  keeps the on-screen icon count ≈ occupied locations however many devices sit there.
//  Tapping a badge selects that location (surfacing the dossier's device list); empty
//  areas capture no hits, so map gestures pass through.
//

import SwiftUI
import UI

struct LocationClusterLayer: View {
    let projection: DeviceClusterProjectionModel
    /// The picked location, so the badge for it reads as selected.
    let selectedLocation: String?
    let onSelect: (String) -> Void

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(projection.clusters) { cluster in
                ClusterBadge(
                    symbolName: "device.\(cluster.primaryType)",
                    count: cluster.count,
                    hasOwn: cluster.hasOwn,
                    isSelected: cluster.anchorCode == selectedLocation,
                    action: { onSelect(cluster.anchorCode) }
                )
                .position(snapped(cluster.point))
                .opacity(cluster.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Snap to the physical pixel grid (see `ShipOverlayLayer.snapped`) so the flattened
    /// badge bitmap stays crisp as the anchor's projected point streams in fractionally.
    private func snapped(_ point: CGPoint) -> CGPoint {
        let scale = max(displayScale, 1)
        return CGPoint(x: (point.x * scale).rounded() / scale,
                       y: (point.y * scale).rounded() / scale)
    }
}

/// One location's badge: the representative device glyph plus a count when more than one
/// device is present. Own presence reads in the accent tint; others-only reads muted.
private struct ClusterBadge: View {
    let symbolName: String
    let count: Int
    let hasOwn: Bool
    let isSelected: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image.rcSymbol(symbolName)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 11, weight: .semibold))
                if count > 1 {
                    Text("\(count)")
                        .font(.rcMonoSmall)
                }
            }
            .foregroundStyle(hasOwn ? Color.rcAccent : .rcTextSecondary)
            .padding(.horizontal, count > 1 ? 6 : 4)
            .frame(minWidth: 20, minHeight: 20)
            .background(Capsule().fill(.rcSurfaceRaised))
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? Color.rcAccent : .white.opacity(hovered ? 0.35 : 0.10),
                    lineWidth: isSelected ? 1.5 : 0.5)
            )
            // Flatten glyph + count + capsule into one bitmap so they can't drift apart
            // at fractional positions; the layer snaps that bitmap to the pixel grid.
            .drawingGroup()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(count == 1 ? "1 device here" : "\(count) devices here")
    }
}
