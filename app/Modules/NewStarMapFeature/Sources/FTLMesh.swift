import CStarMapShaderTypes
import GameModels
import simd

// The FTL comms mesh — the first REFERENCE overlay (HANDOFF §2): a toggleable
// network of links between relay-equipped systems, consulted on demand.
// Architecturally it's the first non-click WRITER to the relevance field, so it's
// the real test of the buffer-as-rendering-brain design: when active, on-mesh
// systems stay lit and the surrounding galaxy recedes, max-combined with any
// other active concern.
//
// The graph is the player's real relay network: nodes are the systems holding
// one of the player's relay devices, and links come straight from the backend's
// per-relay network view (`FTLLink` pairs), not a proximity guess. Orphan relays
// and separate sub-networks fall out naturally — which is why the relays are
// drawn as markers too, so a lone relay with no links is still visible. Stateless
// and symmetric; it renders as faint static links, never the bright directed
// comet of a ship.

struct FTLMesh {
    /// Indices (into the star array) of the relay systems — the mesh nodes.
    let nodes: [Int]
    /// Undirected links as ordered index pairs (a < b), resolved from the real
    /// `FTLLink` system pairs (endpoints absent from the terrain are dropped).
    let edges: [(a: Int, b: Int)]

    /// Build the mesh: relay-bearing systems as nodes, and the backend-reported
    /// `links` (system-designation pairs) resolved to index edges against `stars`.
    static func build(stars: [Star], links: [FTLLink]) -> FTLMesh {
        let nodes = stars.indices.filter { stars[$0].hasFTLRelay }   // ascending
        let indexByName = Dictionary(
            stars.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<Int> = []          // (i * count + j) keys, so a link isn't drawn twice
        var edges: [(a: Int, b: Int)] = []
        for link in links {
            guard let i = indexByName[link.a], let j = indexByName[link.b], i != j else { continue }
            let (a, b) = i < j ? (i, j) : (j, i)
            let key = a * stars.count + b
            if seen.insert(key).inserted { edges.append((a, b)) }
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
            let sharp = pow(t, 2.5)  // steep ease-in: lighting hugs the mesh, drops off fast
            out[i] = floor + (1 - floor) * sharp
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
