//
//  FlowLayout.swift
//  Replicould — Devices feature
//
//  A minimal flow layout that lays subviews left-to-right, wrapping to the
//  next row when the proposed width is exceeded — used to wrap the tag chips
//  in `TagsEditor` and the dispatch buttons in `CommandGrid`.
//

import SwiftUI

/// A minimal flow layout: lays subviews left-to-right, wrapping to the next row
/// when the proposed width is exceeded.
///
/// Each subview is laid out at its natural width, floored to an effective
/// minimum of `max(minItemWidth, minItemWidthFraction × container width)`,
/// itself capped at `maxItemWidth` — so items share a uniform width that flexes
/// between the floor and the cap, yet any whose content needs more room still
/// grow past the cap (unlike a `LazyVGrid`'s fixed adaptive cells, which clip
/// wider content). The default zero/infinite bounds make items size purely to
/// content, matching the tag-chip use.
struct FlowLayout: Layout {
    var spacing: CGFloat
    /// A hard floor on each item's width, in points.
    var minItemWidth: CGFloat = 0
    /// A floor expressed as a fraction of the container's width (e.g. `0.2` for
    /// 20%, targeting five items per row). The fraction is solved *net of* the
    /// inter-item spacing, so the implied column count actually tiles the row
    /// rather than overflowing once the gaps are counted. Ignored when the
    /// container width is unbounded.
    var minItemWidthFraction: CGFloat = 0
    /// A cap on the *flexible* width — the uniform floor never grows past this.
    /// Items whose natural content is wider still exceed it; this only bounds
    /// the shared floor, not content.
    var maxItemWidth: CGFloat = .infinity

    /// Slack, in points, granted to the wrap test. The fractional floor is built
    /// so a row's items sum to exactly the container width, but the multiply/
    /// subtract accumulates sub-pixel float error — without this tolerance a
    /// last item that lands a hair over the edge wraps, and slowly resizing the
    /// window makes it flicker in and out of the trailing row. Half a point is
    /// far below any real item width, so it never lets genuine content overflow.
    private static let wrapTolerance: CGFloat = 0.5

    /// The flexible width floor for the current container: the larger of the
    /// fixed minimum and the fractional one, clamped to `maxItemWidth`.
    ///
    /// The fractional floor is derived so that, if every item sat exactly at it,
    /// `1 / minItemWidthFraction` of them would tile the row *including* the
    /// spacing between them — solving `(W − (k−1)·spacing) / k` for `k =
    /// 1/fraction` yields the closed form below. Without the spacing term a 0.2
    /// fraction would only fit four per row (five columns leave no room for the
    /// four gaps). Falls back to the fixed minimum when the container width is
    /// unbounded (the fraction has nothing to resolve against).
    private func minWidth(inContainer width: CGFloat) -> CGFloat {
        let fractionFloor = width.isFinite && minItemWidthFraction > 0
            ? width * minItemWidthFraction - (1 - minItemWidthFraction) * spacing
            : 0
        return min(max(minItemWidth, fractionFloor), maxItemWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let floor = minWidth(inContainer: maxWidth)
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let width = max(floor, size.width)
            if rowWidth > 0, rowWidth + spacing + width > maxWidth + Self.wrapTolerance {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: maxWidth == .infinity ? totalWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        let floor = minWidth(inContainer: maxWidth)
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let width = max(floor, size.width)
            if x > bounds.minX, x + width - bounds.minX > maxWidth + Self.wrapTolerance {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: size.height))
            x += width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
