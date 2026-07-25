//
//  MiningResourceTests.swift
//  Replicould — GameModels
//
//  The mining-resource vocabulary is a domain constant shared by the device
//  inspector and the directive composer, so it is pinned here rather than
//  living inside a feature module.
//

import Testing
@testable import GameModels

@Suite("Mining resources")
struct MiningResourceTests {
    /// The six mineable resource types, in the backend's canonical order.
    @Test func vocabularyIsTheSixBackendResources() {
        #expect(MiningResource.all == [
            "structural", "conductive", "silicates", "carbon", "volatiles", "rares",
        ])
    }
}
