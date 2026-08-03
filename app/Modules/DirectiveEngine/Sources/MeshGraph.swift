//
//  MeshGraph.swift
//  Replicould — DirectiveEngine
//
//  Task 7: the spatial grid + hop adjacency. A pure graph over census star
//  systems where two systems are adjacent iff they are within FTL relay
//  range (SalvageTargetPlanner.relayRangeLY). No I/O, no clock, no mutable
//  state — the brain rebuilds this from a fresh WorldView on every 5-second
//  tick, so `neighbours(of:)` must stay far from O(n²) even at the full
//  ~14,000-system census. A uniform spatial grid (cell size == hopRange)
//  gets a query down to scanning the 27 cells around the point, since no
//  system within hopRange of a query point can ever land outside them (see
//  the reasoning on `cell(for:hopRange:)` below).
//
//  Deliberately NOT more than adjacency: no traversal, no `reach`, no
//  Dijkstra. That is the next task's job, layered on top of this one.
//

import Foundation
import UniverseModels

/// A pure adjacency graph over star systems: two systems are neighbours iff
/// their positions are within `hopRange` light-years of each other.
///
/// Stateless value type — holds only the positions it was built from and a
/// grid derived from them, never a database reference or a query cache.
public struct MeshGraph: Sendable {
    private let positions: [String: Position]
    private let hopRange: Double
    private let cells: [Cell: [String]]

    struct Cell: Hashable {
        let x: Int
        let y: Int
        let z: Int
    }

    public init(positions: [String: Position], hopRange: Double = SalvageTargetPlanner.relayRangeLY) {
        self.positions = positions
        self.hopRange = hopRange
        var cells: [Cell: [String]] = [:]
        for (name, p) in positions {
            cells[Self.cell(for: p, hopRange: hopRange), default: []].append(name)
        }
        self.cells = cells
    }

    /// Buckets a position into the grid cell containing it, cell size ==
    /// `hopRange`. Uses `.rounded(.down)` (floor), not truncation: floor
    /// gives every cell the same width on both sides of zero, which is what
    /// keeps the galaxy's negative-coordinate half exactly as fast as its
    /// positive half. (Truncation toward zero would still be *correct* here —
    /// the 27-cell coverage argument below only needs adjacent-cell-index
    /// deltas bounded by 1, which truncation also happens to satisfy — but it
    /// would double the width of the single cell straddling zero on each
    /// axis, concentrating points there and locally degrading the grid's
    /// flat per-cell cost. Floor avoids that degenerate cell entirely.)
    static func cell(for p: Position, hopRange: Double) -> Cell {
        Cell(
            x: Int((p.x / hopRange).rounded(.down)),
            y: Int((p.y / hopRange).rounded(.down)),
            z: Int((p.z / hopRange).rounded(.down))
        )
    }

    /// The systems within `hopRange` of `system`. Empty (not an error) if
    /// `system` isn't in the graph at all.
    ///
    /// Correctness of the 27-cell scan: bucketing uses `floor(coord /
    /// hopRange)` per axis, so each cell spans exactly one unit of
    /// `coord / hopRange`. For any two positions p, q with distance(p, q) <=
    /// hopRange, each axis individually satisfies |p.axis - q.axis| <=
    /// hopRange (an axis delta can never exceed the full 3D distance), i.e.
    /// |a - b| <= 1 where a = p.axis / hopRange, b = q.axis / hopRange. Since
    /// floor(a) <= a and floor(b) > b - 1, floor(a) - floor(b) < (a - b) + 1
    /// <= 2, so the two floor values differ by at most 1 (they're integers,
    /// and the bound is strict). That holds independently on x, y, and z, so
    /// q's cell is always within {-1, 0, +1} of p's cell on every axis — i.e.
    /// inside the 27-cell block scanned below. No in-range system can ever
    /// fall outside it.
    public func neighbours(of system: String) -> [String] {
        guard let p = positions[system] else { return [] }
        let base = Self.cell(for: p, hopRange: hopRange)
        var out: [String] = []
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    let c = Cell(x: base.x + dx, y: base.y + dy, z: base.z + dz)
                    for other in cells[c] ?? [] where other != system {
                        if let q = positions[other], q.distance(to: p) <= hopRange {
                            out.append(other)
                        }
                    }
                }
            }
        }
        return out
    }
}
