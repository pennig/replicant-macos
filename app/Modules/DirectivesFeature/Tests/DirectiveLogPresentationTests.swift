//
//  DirectiveLogPresentationTests.swift
//  Replicould — Directives feature
//
//  The timeline's rendering choices, exercised directly — they live in a
//  SwiftUI-free namespace precisely so they can be.
//

import GameModels
import Testing
@testable import DirectivesFeature

@Suite("Directive log presentation")
struct DirectiveLogPresentationTests {
    /// Every kind has a distinct glyph — the timeline is scanned, not read, so
    /// two kinds sharing a symbol would make it unreadable at a glance.
    @Test func everyKindHasADistinctSymbol() {
        let symbols = DirectiveLogKind.allCases.map(DirectiveLogPresentation.symbol(for:))
        #expect(symbols.allSatisfy { !$0.isEmpty })
        #expect(Set(symbols).count == DirectiveLogKind.allCases.count)
    }

    /// The two kinds that mean "look at me" are prominent; routine progress
    /// recedes.
    @Test func onlyNotableKindsAreProminent() {
        #expect(DirectiveLogPresentation.isProminent(.stalled))
        #expect(DirectiveLogPresentation.isProminent(.directiveCompleted))
        #expect(!DirectiveLogPresentation.isProminent(.stepStarted))
        #expect(!DirectiveLogPresentation.isProminent(.commandDispatched))
        #expect(!DirectiveLogPresentation.isProminent(.opCompleted))
        #expect(!DirectiveLogPresentation.isProminent(.resolved))
    }
}
