import CStarMapShaderTypes
import simd

// The FTL comms mesh — the first REFERENCE overlay (HANDOFF §2): a toggleable
// network of links between relay-equipped systems, consulted on demand.
// Architecturally it's the first non-click WRITER to the relevance field, so it's
// the real test of the buffer-as-rendering-brain design: when active, on-mesh
// systems stay lit and the surrounding galaxy recedes, max-combined with any
// other active concern.
//
// The graph model matches the game: nodes are systems with an FTL relay
// installed, and two relays share a link iff they are within `maxEdgeLength` ly
// of each other (a proximity graph). Orphan relays and separate sub-networks
// fall out naturally — which is why the relays are drawn as markers too, so a
// lone relay with no links is still visible. Stateless and symmetric; it renders
// as faint static links, never the bright directed comet of a ship.

struct FTLMesh {
    /// Indices (into the star array) of the relay systems — the mesh nodes.
    let nodes: [Int]
    /// Undirected links as ordered index pairs (a < b); relay pairs within range.
    let edges: [(a: Int, b: Int)]

    /// Build the proximity graph over the relay-equipped systems. `maxEdgeLength`
    /// is the FTL link range (7.5 ly in the game).
    static func build(stars: [Star], maxEdgeLength: Float = 7.5) -> FTLMesh {
        let nodes = stars.indices.filter { stars[$0].hasFTLRelay }   // ascending
        let maxSq = maxEdgeLength * maxEdgeLength
        var edges: [(a: Int, b: Int)] = []
        for x in 0..<nodes.count {
            let i = nodes[x]
            let pi = stars[i].position
            for y in (x + 1)..<nodes.count {
                let j = nodes[y]
                if simd_length_squared(stars[j].position - pi) <= maxSq {
                    edges.append((i, j))   // i < j since `nodes` is ascending
                }
            }
        }
        return FTLMesh(nodes: nodes, edges: edges)
    }

    /// Per-star relevance contribution: relay systems at 1.0, everything else
    /// attenuating toward `floor` by spatial distance to the nearest relay — so
    /// the network reads as embedded in a galaxy that fades away from it. This is
    /// position-based (from the actual relay positions), so it's independent of
    /// where the mesh sits in the field.
    func relevance(for stars: [Star], floor: Float, falloffRadius: Float) -> [Float] {
        var out = [Float](repeating: floor, count: stars.count)
        guard !nodes.isEmpty else { return out }
        let nodePositions = nodes.map { stars[$0].position }
        let nodeSet = Set(nodes)
        for i in stars.indices {
            if nodeSet.contains(i) { out[i] = 1; continue }
            let p = stars[i].position
            var nearestSq = Float.greatestFiniteMagnitude
            for np in nodePositions {
                nearestSq = min(nearestSq, simd_length_squared(np - p))
            }
            let t = 1 - min(sqrt(nearestSq) / falloffRadius, 1)
            out[i] = floor + (1 - floor) * (t * t)
        }
        return out
    }

    /// Link geometry as screen-space quad ribbons: 6 vertices per edge (two
    /// triangles), each carrying both endpoints plus `side`/`along` for the vertex
    /// shader to expand and for future dash/gradient effects.
    func lineVertices(for stars: [Star]) -> [MeshLineVertex] {
        edges.flatMap { MeshLineVertex.ribbon(stars[$0.a].position, stars[$0.b].position) }
    }

    /// World positions of the relay systems, for the marker (ring) pass.
    func nodePositions(for stars: [Star]) -> [SIMD3<Float>] {
        nodes.map { stars[$0].position }
    }
}

extension MeshLineVertex {
    /// The six vertices (two triangles) of a screen-space ribbon for a segment
    /// a→b. Shared by FTL links and ship trajectories; the vertex shader expands
    /// each by `side`, and `along` (0 at a, 1 at b) drives per-segment effects.
    static func ribbon(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> [MeshLineVertex] {
        [ MeshLineVertex(a: a, b: b, side: -1, along: 0),
          MeshLineVertex(a: a, b: b, side: -1, along: 1),
          MeshLineVertex(a: a, b: b, side:  1, along: 0),
          MeshLineVertex(a: a, b: b, side:  1, along: 0),
          MeshLineVertex(a: a, b: b, side: -1, along: 1),
          MeshLineVertex(a: a, b: b, side:  1, along: 1) ]
    }
}
