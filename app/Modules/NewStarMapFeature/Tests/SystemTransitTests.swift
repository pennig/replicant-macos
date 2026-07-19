import Testing
@testable import NewStarMapFeature

// The pure inbound/outbound transit resolver. `resolves` stands in for the renderer's
// "does this location code resolve to a visible anchor at the current layer?" — here a
// simple membership set, so the boundary/connector logic is tested with no GPU/orrery.

struct SystemTransitTests {
    /// SOL-3 → SOL-5-L4 → SHERATANON-6-L4 → SHERATANON-2, the running example.
    private let route = ["SOL-3", "SOL-5-L4", "SHERATANON-6-L4", "SHERATANON-2"]

    private func resolve(_ visible: Set<String>) -> (String) -> Bool { { visible.contains($0) } }

    @Test func viewingDestinationSystemShowsInboundBoundary() {
        // SHERATANON orrery: both SHERATANON locations resolve.
        let r = SystemTransit.resolve(
            orderedCodes: route, deviceCode: "AAAA",
            resolves: resolve(["SHERATANON-6-L4", "SHERATANON-2"]))

        #expect(r.connectorCodes == ["SHERATANON-6-L4", "SHERATANON-2"])
        #expect(r.boundaries == [
            TransitBoundary(deviceCode: "AAAA", anchorCode: "SHERATANON-6-L4",
                            direction: .inbound, endpointCode: "SOL-3", viaCode: "SOL-5-L4")
        ])
    }

    @Test func viewingOriginSystemShowsOutboundBoundary() {
        // SOL orrery: both SOL locations resolve.
        let r = SystemTransit.resolve(
            orderedCodes: route, deviceCode: "AAAA",
            resolves: resolve(["SOL-3", "SOL-5-L4"]))

        #expect(r.connectorCodes == ["SOL-3", "SOL-5-L4"])
        #expect(r.boundaries == [
            TransitBoundary(deviceCode: "AAAA", anchorCode: "SOL-5-L4",
                            direction: .outbound, endpointCode: "SHERATANON-2",
                            viaCode: "SHERATANON-6-L4")
        ])
    }

    @Test func viewingDestinationBodyPlantsRiserOnTheBodyAlone() {
        // SHERATANON-2 body view: only the focused body resolves; the entry Lagrange
        // rolls into the inbound `via`.
        let r = SystemTransit.resolve(
            orderedCodes: route, deviceCode: "AAAA",
            resolves: resolve(["SHERATANON-2"]))

        #expect(r.connectorCodes == ["SHERATANON-2"])   // single anchor → nothing to trace
        #expect(r.boundaries == [
            TransitBoundary(deviceCode: "AAAA", anchorCode: "SHERATANON-2",
                            direction: .inbound, endpointCode: "SOL-3",
                            viaCode: "SHERATANON-6-L4")
        ])
    }

    @Test func passThroughSystemShowsBothBoundaries() {
        // A route that enters and leaves the same viewed system.
        let through = ["A-1", "MID-3-L4", "MID-1", "MID-2-L5", "Z-9"]
        let r = SystemTransit.resolve(
            orderedCodes: through, deviceCode: "BBBB",
            resolves: resolve(["MID-3-L4", "MID-1", "MID-2-L5"]))

        #expect(r.connectorCodes == ["MID-3-L4", "MID-1", "MID-2-L5"])
        #expect(r.boundaries == [
            TransitBoundary(deviceCode: "BBBB", anchorCode: "MID-3-L4",
                            direction: .inbound, endpointCode: "A-1", viaCode: nil),
            TransitBoundary(deviceCode: "BBBB", anchorCode: "MID-2-L5",
                            direction: .outbound, endpointCode: "Z-9", viaCode: nil)
        ])
    }

    @Test func fullyInSystemRouteHasNoBoundaries() {
        let r = SystemTransit.resolve(
            orderedCodes: ["SOL-3", "SOL-5-L4"], deviceCode: "AAAA",
            resolves: resolve(["SOL-3", "SOL-5-L4"]))

        #expect(r.boundaries.isEmpty)
        #expect(r.connectorCodes == ["SOL-3", "SOL-5-L4"])
    }

    @Test func routeThatNeverResolvesYieldsNothing() {
        let r = SystemTransit.resolve(
            orderedCodes: route, deviceCode: "AAAA", resolves: resolve(["OTHER-1"]))
        #expect(r == .none)
    }

    @Test func viaOmittedWhenItEqualsTheEndpoint() {
        // Two-location hop: the immediate waypoint IS the endpoint, so via collapses.
        let r = SystemTransit.resolve(
            orderedCodes: ["SOL-3", "SHERATANON-2"], deviceCode: "AAAA",
            resolves: resolve(["SHERATANON-2"]))
        #expect(r.boundaries == [
            TransitBoundary(deviceCode: "AAAA", anchorCode: "SHERATANON-2",
                            direction: .inbound, endpointCode: "SOL-3", viaCode: nil)
        ])
    }
}
