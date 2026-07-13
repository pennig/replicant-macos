import CoreGraphics
import SwiftUI

// The bridge that carries ship pip positions out of the Metal render loop and into
// the SwiftUI overlay, so tappable device icons can track the GPU-drawn comet heads
// per-frame. The renderer projects each ship's world position with the SAME camera
// matrices it feeds the GPU (in `draw`), so an icon is frame-locked to its pip even
// as the ship and the camera move.
//
// Only `ShipOverlayLayer` reads `ShipProjectionModel.ships`; the parent map view
// merely holds the model and hands it down, so a per-frame `ships` mutation
// invalidates just the overlay — never the map view (whose `body` builds the whole
// star terrain). Keeping that observation boundary is load-bearing for performance.

/// One ship's on-screen placement for the overlay: the device it represents, its
/// screen point (view POINTS, top-left origin — matching SwiftUI's local space),
/// and an opacity that tracks the pips' `overlayDim` so icons fade with them.
struct ProjectedShip: Equatable, Identifiable {
    let deviceCode: String
    let point: CGPoint
    let opacity: Double

    var id: String { deviceCode }
}

/// The observable the renderer pushes to each frame and `ShipOverlayLayer` reads.
@MainActor
@Observable
final class ShipProjectionModel {
    var ships: [ProjectedShip] = []
}
