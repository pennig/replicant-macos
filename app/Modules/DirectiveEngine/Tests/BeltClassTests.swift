//
//  BeltClassTests.swift
//  Replicould — DirectiveEngine
//
//  Task 9 (VERIFICATION): the three-class belt-richness classification, per
//  the mapping confirmed against the live API + a 141-system/56-belt local
//  aggregate on 2026-08-03 (see app/.claude/memory/belt-value-vocabulary.md).
//  `density` has exactly three observed values (sparse/moderate/dense); an
//  unrecognised or absent `density` falls back to folding `richness`'s five
//  real qualifiers (scarce/low/moderate/high/rich); when neither resolves,
//  the class is unknown (`nil`), never guessed.
//

import Testing
@testable import DirectiveEngine

@Suite("BeltClass")
struct BeltClassTests {
    /// The exact three live `density` values, mapped onto the locked tier
    /// ordering. `"rich"`/`"abundant"`/`"medium"`/`"thin"` are NOT real
    /// density values — only `sparse`/`moderate`/`dense` ever appear.
    @Test func densityMapsToLockedClasses() {
        #expect(BeltClass.classify(density: "dense", richness: [:]) == .rich)
        #expect(BeltClass.classify(density: "moderate", richness: [:]) == .moderate)
        #expect(BeltClass.classify(density: "sparse", richness: [:]) == .sparse)
    }

    @Test func densityMatchIsCaseInsensitive() {
        #expect(BeltClass.classify(density: "DENSE", richness: [:]) == .rich)
        #expect(BeltClass.classify(density: "Sparse", richness: [:]) == .sparse)
    }

    /// `density` absent falls back to folding `richness` — the real
    /// resource-type keys (`carbon`, `conductive`, `rares`, `silicates`,
    /// `structural`, `volatiles`), not the brief's fictional `"metal"`.
    @Test func fallsBackToRichnessWhenDensityMissing() {
        #expect(BeltClass.classify(density: nil, richness: ["rares": "rich"]) == .rich)
        #expect(BeltClass.classify(density: nil, richness: ["rares": "high"]) == .rich)
        #expect(BeltClass.classify(density: nil, richness: ["rares": "moderate"]) == .moderate)
        #expect(BeltClass.classify(density: nil, richness: ["rares": "low"]) == .sparse)
        #expect(BeltClass.classify(density: nil, richness: ["rares": "scarce"]) == .sparse)
    }

    /// An unrecognised `density` string (not one of the three live values)
    /// also falls back to `richness` — it isn't treated as "absent" only.
    @Test func fallsBackToRichnessWhenDensityUnrecognised() {
        #expect(BeltClass.classify(density: "bogus-value", richness: ["carbon": "rich"]) == .rich)
    }

    /// A belt with several assayed resources ranks on the richest qualifier
    /// present, not the first or the average.
    @Test func takesTheRichestQualifierAcrossMultipleResources() {
        #expect(
            BeltClass.classify(density: nil, richness: ["carbon": "low", "rares": "rich"]) == .rich
        )
        #expect(
            BeltClass.classify(density: nil, richness: ["carbon": "low", "rares": "moderate"])
                == .moderate
        )
    }

    @Test func richnessMatchIsCaseInsensitive() {
        #expect(BeltClass.classify(density: nil, richness: ["rares": "RICH"]) == .rich)
    }

    /// "Unknown" must stay unknown — no default guess. Both an entirely
    /// empty belt and one carrying only unrecognised strings resolve to nil.
    @Test func unknownWhenNeitherDensityNorRichnessResolve() {
        #expect(BeltClass.classify(density: nil, richness: [:]) == nil)
        #expect(BeltClass.classify(density: "bogus", richness: ["carbon": "bogus"]) == nil)
    }

    @Test func classIsOrdered() {
        #expect(BeltClass.sparse < BeltClass.moderate)
        #expect(BeltClass.moderate < BeltClass.rich)
        #expect(BeltClass.sparse < BeltClass.rich)
    }
}

@Suite("BeltInfo")
struct BeltInfoTests {
    @Test func holdsDesignationAndClass() {
        let info = BeltInfo(designation: "SOL-BELT-1", beltClass: .rich)
        #expect(info.designation == "SOL-BELT-1")
        #expect(info.beltClass == .rich)
    }

    @Test func equalityIsFieldwise() {
        let a = BeltInfo(designation: "SOL-BELT-1", beltClass: .rich)
        let b = BeltInfo(designation: "SOL-BELT-1", beltClass: .rich)
        let c = BeltInfo(designation: "SOL-BELT-1", beltClass: .sparse)
        #expect(a == b)
        #expect(a != c)
    }
}
