import SwiftUI
import UI

// The tappable SwiftUI layer that floats a device icon over each in-transit ship's
// GPU-drawn pip. It is a DEDICATED view (not inlined into `NewStarMapView`) on
// purpose: its `body` reads `projection.ships`, which the renderer mutates every
// frame — keeping it separate means only this view re-renders per frame, never the
// map view (whose `body` builds the whole star terrain). Empty areas capture no
// hits, so clicks fall through to the Metal map exactly like the glass HUD does.

/// Floats a 20pt monochrome device glyph over each ship pip, tracking it per-frame.
struct ShipOverlayLayer: View {
    let projection: ShipProjectionModel
    /// deviceCode → deviceType, so each icon can resolve its `device.<type>` glyph.
    let deviceTypes: [String: String]
    let selectedDeviceCode: String?
    let onSelect: (String) -> Void

    /// The backing store's pixel density, so we can snap each icon to whole physical
    /// pixels (see `snapped`).
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(projection.ships) { ship in
                ShipIcon(
                    symbolName: "device.\(deviceTypes[ship.deviceCode] ?? "")",
                    isSelected: ship.deviceCode == selectedDeviceCode,
                    action: { onSelect(ship.deviceCode) }
                )
                .position(snapped(ship.point))
                .opacity(ship.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Snap a projected point to the physical pixel grid. The ship position streams
    /// in at continuously-fractional points; combined with `ShipIcon`'s
    /// `.drawingGroup()`, landing the flattened icon bitmap on exact pixels keeps it
    /// crisp and stops the disc and glyph from shimmering against each other as the
    /// ship moves. Sub-point stepping (one physical pixel) is imperceptible.
    private func snapped(_ point: CGPoint) -> CGPoint {
        let scale = max(displayScale, 1)
        return CGPoint(x: (point.x * scale).rounded() / scale,
                       y: (point.y * scale).rounded() / scale)
    }
}

/// One ship's marker: the device glyph, monochrome, in a 20pt disc. Selected/hover
/// states nudge the ring so it reads as a live, tappable control.
private struct ShipIcon: View {
    let symbolName: String
    let isSelected: Bool
    let action: () -> Void

    @State private var hovered = false

    private let diameter: CGFloat = 20

    var body: some View {
        Button(action: action) {
            Image.rcSymbol(symbolName)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? Color.rcAccent : .rcTextPrimary)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(.rcSurfaceRaised))
                .overlay(
                    Circle().strokeBorder(
                        isSelected ? Color.rcAccent : .white.opacity(hovered ? 0.35 : 0.10),
                        lineWidth: isSelected ? 1.5 : 0.5)
                )
                // Flatten disc + stroke + glyph into ONE bitmap so they can't drift
                // apart at fractional positions; the layer snaps that bitmap to the
                // pixel grid (see `ShipOverlayLayer.snapped`) to keep it crisp.
                .drawingGroup()
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("View device")
    }
}
