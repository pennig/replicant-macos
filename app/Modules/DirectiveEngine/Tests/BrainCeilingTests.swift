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
//  Binding-type note: conductive — NOT volatiles — is the type that actually
//  constrains `K` under the live mix (see `relaysUntilBindingTypeFloors`'s
//  test below and `brain-relay-reserve-floor.md`'s corrected arithmetic).
//  Volatiles is both the cheapest bill line and the scarcest live stock,
//  which reads as "obviously bites first," but bind order depends on stock
//  RELATIVE TO CONSUMPTION, not on either alone.
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

    /// A stock reading sitting EXACTLY on the floor still permits — the
    /// comparison is `>=`, so the floor itself is spendable-down-to, not a
    /// value that already trips the veto.
    @Test func printPermittedWhenStockIsExactlyAtTheFloor() {
        let stock = Dictionary(
            uniqueKeysWithValues: BrainCeiling.resourceTypes.map { ($0, BrainCeiling.reserveFloor(for: $0)) }
        )
        #expect(BrainCeiling.printPermitted(hubStock: stock))
    }

    /// The type that actually binds first under the live mix — conductive,
    /// NOT volatiles (see this file's header note) — dropping below its own
    /// floor vetoes on its own, even with every other type flush.
    @Test func printVetoedWhenConductiveAloneIsBelowFloor() {
        var stock = Dictionary(
            uniqueKeysWithValues: BrainCeiling.resourceTypes.map { ($0, 10_000.0) }
        )
        stock["conductive"] = BrainCeiling.reserveFloor(for: "conductive") - 1
        #expect(!BrainCeiling.printPermitted(hubStock: stock))
    }

    /// The per-type veto is independent per type, not just true for the
    /// binding one — volatiles alone below its floor vetoes too, even though
    /// (per the corrected arithmetic) it is the LAST type to bind in
    /// practice, not the first.
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

    /// `resourceTypes` is DERIVED from `relayBill`'s own keys, not a second,
    /// independently-maintained literal — pins that invariant directly so a
    /// future edit that reintroduces two separate lists (and can drift, or
    /// silently create an unchecked, unbilled type) is caught here rather
    /// than only by a fail-open hole nobody notices.
    @Test func resourceTypesIsExactlyRelayBillsKeys() {
        #expect(Set(BrainCeiling.resourceTypes) == Set(BrainCeiling.relayBill.keys))
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

    /// `reserveFloors` (the dictionary form `printPermitted` is actually built
    /// on) agrees with `reserveFloor(for:)` (the per-type function) for every
    /// type — so the two can never quietly disagree, and `reserveFloors`
    /// earns its keep as more than unread public API.
    @Test func reserveFloorsAgreesWithReserveFloorForEveryType() {
        for type in BrainCeiling.resourceTypes {
            #expect(BrainCeiling.reserveFloors[type] == BrainCeiling.reserveFloor(for: type))
        }
        #expect(BrainCeiling.reserveFloors.count == BrainCeiling.resourceTypes.count)
    }

    /// The relay bill sums to the verified total (370), and no single type's
    /// bill is anywhere near that total on its own — the fact that makes a
    /// flat 370-per-type floor incoherent.
    @Test func relayBillSumsToTheVerifiedTotal() {
        #expect(BrainCeiling.relayBill.values.reduce(0, +) == 370)
        #expect(BrainCeiling.relayBill["volatiles"] == 10)
        #expect(BrainCeiling.relayBill["conductive"] == 120)
    }

    // MARK: - The aggregate proxy `RelayRun` actually arms

    /// Conductive is the binding type under the live/reference mix — pinned
    /// directly, since this is exactly the fact the earlier draft of this
    /// note (and this file) got backwards. ~106.95 relays before conductive
    /// hits its own floor, computed from the reference snapshot, not
    /// hand-picked.
    @Test func conductiveIsTheBindingTypeUnderTheReferenceMix() {
        let conductiveHeadroom = (BrainCeiling.referenceHubStock["conductive"]! - BrainCeiling.reserveFloor(for: "conductive"))
            / BrainCeiling.relayBill["conductive"]!
        #expect(BrainCeiling.relaysUntilBindingTypeFloors == conductiveHeadroom)
        // And volatiles — the type an uncorrected intuition names as
        // "obviously first" — actually has roughly 4× the headroom.
        let volatilesHeadroom = (BrainCeiling.referenceHubStock["volatiles"]! - BrainCeiling.reserveFloor(for: "volatiles"))
            / BrainCeiling.relayBill["volatiles"]!
        #expect(volatilesHeadroom > conductiveHeadroom * 3)
    }

    /// Absolute pin (not a comparison against itself): the exact aggregate
    /// floor `RelayRun` arms with today, derived from the bill and the
    /// reference mix. Marked so any future recalibration of `reserveRelays`
    /// or `referenceHubStock` shows up as a diff here, which is the entire
    /// point of `K` being marked `// CALIBRATE`.
    @Test func aggregateSpendFloorIsPinnedToItsDerivedValue() {
        #expect(BrainCeiling.aggregateSpendFloor == 35_078)
    }

    /// The whole reason `aggregateSpendFloor` exists instead of the naive
    /// sum-of-floors: it must be MUCH larger, or it undershoots the true
    /// per-type floor by more than an order of magnitude (the naive sum
    /// permits printing all the way down to ~1,850 total stock, by which
    /// point conductive alone has been at zero for a long time).
    @Test func aggregateSpendFloorIsFarMoreConservativeThanTheNaiveSum() {
        let naiveSum = Int(BrainCeiling.reserveFloors.values.reduce(0, +))
        #expect(BrainCeiling.aggregateSpendFloor > naiveSum * 15)
    }
}
