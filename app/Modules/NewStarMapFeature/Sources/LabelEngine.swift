import simd

// The label subsystem's brain — pure screen-space layout, no text, no GPU.
//
// Labels are the CURATED annotation layer over the complete terrain (HANDOFF §3):
// only a few systems are ever named (focus + context — selected, nearest-to-
// camera, and later search hits), and their labels must not overlap. This decides
// which survive: priority-ordered greedy placement with collision rejection. The
// renderer supplies projected anchors and measured label sizes (in pixels); this
// returns the rects to draw. Being pure, it's exhaustively testable.

enum LabelEngine {

    /// A star that would like a label, already projected to screen pixels.
    struct Candidate {
        var id: Int                 // star index
        var anchor: SIMD2<Float>    // projected star position (pixels, top-left origin)
        var size: SIMD2<Float>      // measured label size (pixels)
        var priority: Float         // higher wins the contest for space
    }

    /// An accepted label and where to draw it.
    struct Placement: Equatable {
        var id: Int
        var origin: SIMD2<Float>    // top-left of the label rect (pixels)
        var size: SIMD2<Float>
    }

    /// Greedy, highest-priority-first placement. Each label sits `gap` from its
    /// anchor and is dropped if its (padded) rect overlaps one already placed —
    /// so the selected star always gets its label, then the nearest, and so on.
    ///
    /// `anchor` is the top-CENTRE point where the label wants to sit (the renderer
    /// puts it just below the star, clear of the reticle-ring radius); the label is
    /// centred horizontally on it.
    static func layout(_ candidates: [Candidate], padding: Float = 3) -> [Placement] {
        var placed: [Placement] = []
        for c in candidates.sorted(by: { $0.priority > $1.priority }) {
            let origin = SIMD2<Float>(c.anchor.x - c.size.x * 0.5, c.anchor.y)
            let rect = Placement(id: c.id, origin: origin, size: c.size)
            if placed.allSatisfy({ !overlaps($0, rect, padding: padding) }) {
                placed.append(rect)
            }
        }
        return placed
    }

    /// AABB overlap test, expanding `a` by `padding` on all sides.
    static func overlaps(_ a: Placement, _ b: Placement, padding: Float) -> Bool {
        let ax0 = a.origin.x - padding, ay0 = a.origin.y - padding
        let ax1 = a.origin.x + a.size.x + padding, ay1 = a.origin.y + a.size.y + padding
        let bx1 = b.origin.x + b.size.x, by1 = b.origin.y + b.size.y
        return ax0 < bx1 && b.origin.x < ax1 && ay0 < by1 && b.origin.y < ay1
    }
}
