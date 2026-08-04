//
//  BrainCeilingTests.swift
//  Replicould — DirectiveEngine
//
//  The `R` reserve-floor rail: a pure per-resource-type predicate over the
//  hub's live stock, tested against the VERIFIED shapes (probed live
//  2026-08-03 — see `brain-tendmesh-worthiness.md`), not the brief's invented
//  `metal`/`silicon` dictionary. Real six types: carbon, conductive, rares,
//  silicates, structural, volatiles. Real relay bill totals 370 across those
//  six types (10–120 per type), never 370 per type.
//

import Testing
@testable import DirectiveEngine

@Suite("BrainCeiling")
struct BrainCeilingTests {
    /// Every type sitting comfortably above its floor permits the print.
    @Test func printPermittedWhenEveryTypeIsAboveItsFloor() {
        let stock = Dictionary(
            uniqueKeysWithValues: BrainCeiling.resourceTypes.map { ($0, 10_000.0) }
        )
        #expect(BrainCeiling.printPermitted(hubStock: stock))
    }

    /// The scarcest real type — volatiles, bill 10 — dropping below its floor
    /// vetoes on its own, even with every other type flush. This is the type
    /// that will bite first in practice (live hub stock 4,117 vs. 11k–27k for
    /// the others), so it is the one worth pinning explicitly rather than
    /// trusting a same-shaped stand-in.
    @Test func printVetoedWhenVolatilesAloneIsBelowFloor() {
        var stock = Dictionary(
            uniqueKeysWithValues: BrainCeiling.resourceTypes.map { ($0, 10_000.0) }
        )
        stock["volatiles"] = BrainCeiling.reserveFloor(for: "volatiles") - 1
        #expect(!BrainCeiling.printPermitted(hubStock: stock))
    }

    /// A type missing from the stock reading is not evidence the type is
    /// abundant — it is evidence nobody has told us. Fails CLOSED: a missing
    /// key reads as zero, which sits below every real floor and vetoes.
    @Test func missingTypeInTheStockReadingVetoes() {
        var stock = Dictionary(
            uniqueKeysWithValues: BrainCeiling.resourceTypes.map { ($0, 10_000.0) }
        )
        stock.removeValue(forKey: "rares")
        #expect(!BrainCeiling.printPermitted(hubStock: stock))
    }

    /// An entirely empty or unreadable stock reading is the limit case of the
    /// above — every type missing — and must veto, not permit. "We couldn't
    /// read the stock" is not the same as "the stock is fine."
    @Test func emptyStockReadingVetoes() {
        #expect(!BrainCeiling.printPermitted(hubStock: [:]))
    }

    /// The verified six type keys, exactly — no `metal`/`silicon` stand-ins.
    @Test func resourceTypesAreTheVerifiedSix() {
        #expect(Set(BrainCeiling.resourceTypes) == [
            "carbon", "conductive", "rares", "silicates", "structural", "volatiles",
        ])
    }

    /// Each per-type floor is `K` relays' worth of that type's real blueprint
    /// bill — never a flat literal shared across types (370 would be 37× the
    /// volatiles bill and only 3× the conductive bill).
    @Test func floorIsKRelaysWorthOfThatTypesRealBill() {
        for type in BrainCeiling.resourceTypes {
            let bill = BrainCeiling.relayBill[type] ?? 0
            #expect(BrainCeiling.reserveFloor(for: type) == bill * BrainCeiling.reserveRelays)
        }
    }

    /// The relay bill sums to the verified total (370), and no single type's
    /// bill is anywhere near that total on its own — the fact that makes a
    /// flat 370-per-type floor incoherent.
    @Test func relayBillSumsToTheVerifiedTotal() {
        #expect(BrainCeiling.relayBill.values.reduce(0, +) == 370)
        #expect(BrainCeiling.relayBill["volatiles"] == 10)
        #expect(BrainCeiling.relayBill["conductive"] == 120)
    }
}
