//
//  DirectiveDetailViewTests.swift
//  Replicould — Directives feature
//
//  `configPairs`' recursive flattening: the built-in detail pane's only real
//  logic. Deliberately exercised directly (it's `static`, no `self`
//  dependency) rather than indirectly through the view.
//

import GameModels
import Testing
import Utils
@testable import DirectivesFeature

@Suite("Directive detail config flattening")
struct DirectiveDetailViewTests {
    /// A non-object top level (including `.null`, standing in for "no config")
    /// yields nil rather than a bogus single-row placeholder.
    @Test func nonObjectConfigYieldsNil() {
        #expect(DirectiveConfigFlattening.pairs(.null) == nil)
        #expect(DirectiveConfigFlattening.pairs(.string("x")) == nil)
    }

    /// An empty object is a real, empty configuration — `[]`, not `nil` — so
    /// the view's `!pairs.isEmpty` guard is what decides whether to render the
    /// section, not a nil sentinel doing double duty.
    @Test func emptyObjectYieldsEmptyArray() {
        #expect(DirectiveConfigFlattening.pairs(.object([:])) != nil)
        #expect(DirectiveConfigFlattening.pairs(.object([:]))?.isEmpty == true)
    }

    /// One level of nesting (the `delivery` route shape) flattens to a dotted
    /// key, matching the pre-existing behaviour.
    @Test func oneLevelOfNestingFlattensToADottedKey() {
        let config = JSONValue.object([
            "route": .object(["collect": .string("SOL-3"), "deliver": .string("SOL-4")]),
        ])
        let pairs = DirectiveConfigFlattening.pairs(config)
        #expect(pairs?.map(\.key) == ["route.collect", "route.deliver"])
        #expect(pairs?.map(\.value) == ["SOL-3", "SOL-4"])
    }

    /// Two levels of nesting — nothing in the app produces this today, but the
    /// flattening must not silently collapse a grandchild to a "—" placeholder.
    /// Sibling keys at every level are sorted, so the order is deterministic
    /// across renders regardless of dictionary iteration order.
    @Test func twoLevelsOfNestingFlattenToADeepDottedKeyInSortedOrder() {
        let config = JSONValue.object([
            "z_outer": .string("last"),
            "a": .object([
                "z_inner": .string("z"),
                "b": .object(["c": .string("deep"), "a": .number(3)]),
            ]),
        ])
        let pairs = DirectiveConfigFlattening.pairs(config)
        #expect(pairs?.map(\.key) == ["a.b.a", "a.b.c", "a.z_inner", "z_outer"])
        #expect(pairs?.map(\.value) == ["3", "deep", "z", "last"])
    }

    /// Sort order is deterministic across repeated calls on the same input —
    /// the rendered order must not reshuffle between renders.
    @Test func flatteningIsDeterministicAcrossRepeatedCalls() {
        let config = JSONValue.object([
            "b": .object(["y": .string("1"), "x": .string("2")]),
            "a": .string("3"),
        ])
        let first = DirectiveConfigFlattening.pairs(config)?.map(\.key)
        let second = DirectiveConfigFlattening.pairs(config)?.map(\.key)
        #expect(first == second)
        #expect(first == ["a", "b.x", "b.y"])
    }

    /// Config values that are designation codes render mono; prose does not.
    /// Keys can't drive this — each directive names its target differently
    /// (`location`, `target`, `destination`) — so the value's shape decides.
    @Test func designationDetection() {
        #expect(DirectiveConfigFlattening.isDesignation("SOL"))
        #expect(DirectiveConfigFlattening.isDesignation("SOL-3-1"))
        #expect(DirectiveConfigFlattening.isDesignation("TAU-4-SAL-2"))
        #expect(!DirectiveConfigFlattening.isDesignation("all"))
        #expect(!DirectiveConfigFlattening.isDesignation("Yes"))
        #expect(!DirectiveConfigFlattening.isDesignation("No"))
        #expect(!DirectiveConfigFlattening.isDesignation("SO"))
        #expect(!DirectiveConfigFlattening.isDesignation("SOL AND MORE"))
    }

    /// Every status has a display name — the detail pane must never print the
    /// raw case name (`needsAttention`) at the user.
    @Test func everyStatusHasADisplayName() {
        for status in DirectiveStatus.allCases {
            #expect(status.displayName != status.rawValue)
            #expect(!status.displayName.isEmpty)
        }
    }
}
