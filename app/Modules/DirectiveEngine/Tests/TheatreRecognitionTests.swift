//
//  TheatreRecognitionTests.swift
//  Replicould — DirectiveEngine
//
//  The `Theatre` vocabulary; the recognition rule that produces it lands later.
//

import Foundation
import GameModels
import Testing
import UniverseModels
@testable import DirectiveEngine

@Suite("Theatre vocabulary")
struct TheatreVocabularyTests {
    @Test("Identity is the depot location")
    func identityIsDepot() {
        let theatre = Theatre(
            depot: "AINALRAM-BELT-1", system: "AINALRAM",
            origin: .derived, readiness: .operational, stock: 12_000
        )
        #expect(theatre.id == "AINALRAM-BELT-1")
        #expect(theatre.system == "AINALRAM")
        #expect(theatre.isOperational)
    }

    @Test("A claimed theatre names every clause it fails, and is not operational")
    func claimedNamesShortfalls() {
        let theatre = Theatre(
            depot: "OMEROPE-BELT-1", system: "OMEROPE", origin: .pinned,
            readiness: .claimed(missing: [.noPrintCapableDevice, .noStock]),
            stock: 0
        )
        #expect(!theatre.isOperational)
        #expect(theatre.readiness == .claimed(missing: [.noPrintCapableDevice, .noStock]))
    }

    @Test("A hub-claimed theatre carries the claiming device code")
    func hubOriginCarriesCode() {
        let theatre = Theatre(
            depot: "DENEBED-BELT-1", system: "DENEBED",
            origin: .systemHub("SH8C2A1F"), readiness: .operational, stock: 500
        )
        #expect(theatre.origin == .systemHub("SH8C2A1F"))
    }
}
