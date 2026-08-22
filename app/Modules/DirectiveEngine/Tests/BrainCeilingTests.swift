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
//  constrains `K` under the live mix. Volatiles is both the cheapest bill line
//  and the scarcest live stock, which reads as "obviously bites first," but
//  bind order depends on stock RELATIVE TO CONSUMPTION, not either alone.
//  See `brain-relay-reserve-floor.md`.
//

import Foundation
import Testing
import UniverseModels
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


    /// `shortTypes` names every type under its floor and nothing else, and is
    /// empty exactly when `printPermitted` says yes — the two are one decision
    /// reported two ways, so they must never disagree.
    @Test func shortTypesNamesEveryTypeUnderItsFloorAndAgreesWithPrintPermitted() {
        var stock = BrainCeiling.reserveFloors
        stock["conductive"] = BrainCeiling.reserveFloor(for: "conductive") - 1
        stock["rares"] = 0
        #expect(BrainCeiling.shortTypes(hubStock: stock) == ["conductive", "rares"])
        #expect(!BrainCeiling.printPermitted(hubStock: stock))
        #expect(BrainCeiling.shortTypes(hubStock: BrainCeiling.reserveFloors).isEmpty)
        #expect(BrainCeiling.printPermitted(hubStock: BrainCeiling.reserveFloors))
    }

    /// Injected floors override the rail's own — the seam `PrintRail` arms and
    /// every test that needs a cheaper bar relies on.
    @Test func injectedFloorsOverrideTheRailsOwn() {
        let stock = ["conductive": 10.0]
        #expect(!BrainCeiling.printPermitted(hubStock: stock))
        #expect(BrainCeiling.printPermitted(hubStock: stock, floors: ["conductive": 5]))
        #expect(BrainCeiling.shortTypes(hubStock: stock, floors: ["conductive": 20]) == ["conductive"])
    }
}

/// The why-view's reserve-floor readout mirrors the rail it reports on.
///
/// `BrainLimits.hubStockStanding(at:)` (the why-view's four-state verdict) and
/// `PrintRail.printStockIsShort(at:_:)` (the actual veto) cannot share an
/// implementation — they read different shapes, a per-type dictionary on a
/// report versus an inventory table on a `WorldSnapshot`. So the next best
/// thing is a test that fails the moment the two disagree.
@Suite("BrainLimits — hub stock standing")
struct HubStockStandingTests {
    static let now = Date(timeIntervalSince1970: 2_000_000)

    /// Floors with one type a single unit under — the smallest reading that
    /// can distinguish "short" from "clear".
    static var justShort: [String: Double] {
        var stock = BrainCeiling.reserveFloors
        stock["conductive"] = BrainCeiling.reserveFloor(for: "conductive") - 1
        return stock
    }

    static func limits(stock: [String: Double]?, fetchedAt: Date?) -> BrainLimits {
        BrainLimits(
            actionsRemaining: 54, actionsLimit: 60, actionsFloor: 6,
            readsRemaining: 108, readsLimit: 120, readsFloor: 12,
            hubStock: stock, hubStockFetchedAt: fetchedAt,
            reserveFloors: BrainCeiling.reserveFloors, rateLimitedAt: nil
        )
    }

    static func snapshot(stock: [String: Double]?, fetchedAt: Date?) -> WorldSnapshot {
        var inventories: [String: LocationStock] = [:]
        if let stock, let fetchedAt {
            inventories["SOL-3"] = LocationStock(quantities: stock, fetchedAt: fetchedAt)
        }
        return WorldSnapshot(devices: [:], openOperations: [:], inventories: inventories, now: now)
    }

    /// Every combination of (stock, age) that can distinguish the branches —
    /// including the exact `hubFreshness` boundary, where an off-by-one in
    /// either direction would show up as a disagreement.
    @Test func hubStockStandingAgreesWithTheRailItMirrors() {
        let ages: [TimeInterval] = [
            0,
            RelayRun.hubFreshness - 1,
            RelayRun.hubFreshness,
            RelayRun.hubFreshness + 1,
            3600,
        ]
        let rich = BrainCeiling.reserveFloors.mapValues { $0 * 1000 }
        let stocks: [[String: Double]?] = [nil, [:], Self.justShort, BrainCeiling.reserveFloors, rich]
        let run = PrintRail()

        for stock in stocks {
            for age in ages {
                let fetchedAt = stock.map { _ in Self.now.addingTimeInterval(-age) }
                let standing = Self.limits(stock: stock, fetchedAt: fetchedAt).hubStockStanding(at: Self.now)
                let railVetoes = run.printStockIsShort(at: "SOL-3", Self.snapshot(stock: stock, fetchedAt: fetchedAt))
                #expect(
                    (standing != .clear) == railVetoes,
                    "stock \(String(describing: stock)) at age \(age)s: report says \(standing), rail says \(railVetoes ? "veto" : "permit")"
                )
            }
        }
    }

    /// The verdicts are not merely "veto or not" — each veto names its own
    /// cause, because the operator's next action differs: refresh the reading,
    /// wait for one, or go find where THAT type went.
    @Test func eachVetoNamesItsOwnCause() {
        #expect(Self.limits(stock: nil, fetchedAt: nil).hubStockStanding(at: Self.now) == .unread)
        #expect(
            Self.limits(stock: BrainCeiling.reserveFloors, fetchedAt: Self.now.addingTimeInterval(-3600))
                .hubStockStanding(at: Self.now) == .stale(age: 3600)
        )
        #expect(
            Self.limits(stock: Self.justShort, fetchedAt: Self.now)
                .hubStockStanding(at: Self.now) == .belowFloor(shortTypes: ["conductive"])
        )
        #expect(
            Self.limits(stock: BrainCeiling.reserveFloors, fetchedAt: Self.now)
                .hubStockStanding(at: Self.now) == .clear
        )
    }

    /// A half-populated report fails CLOSED, matching the rail's own direction
    /// on an unreadable stock — silence is never permission to spend.
    @Test func aHalfPopulatedReadingFailsClosed() {
        #expect(
            Self.limits(stock: BrainCeiling.reserveFloors, fetchedAt: nil)
                .hubStockStanding(at: Self.now) == .unread
        )
        #expect(Self.limits(stock: nil, fetchedAt: Self.now).hubStockStanding(at: Self.now) == .unread)
    }
}
