//
//  ResourceHeadroomTests.swift
//  Replicould — DirectiveEngine
//

import Foundation
import Testing
@testable import DirectiveEngine

private let now = Date(timeIntervalSince1970: 1_750_000_000)

@Suite("ResourceHeadroom — stock over demand")
struct ResourceHeadroomTests {
    @Test("the two least-covered types take the bonus slots")
    func leastCoveredTakeTheSlots() {
        let headroom = ResourceHeadroom.derive(
            stock: ["silicates": 12777, "conductive": 19161, "volatiles": 6538, "structural": 78590],
            demand: ["silicates": 4140, "conductive": 4450, "volatiles": 590, "structural": 3890],
            freshness: now,
            now: now
        )
        #expect(headroom.weights == ["silicates": 2, "conductive": 1])
        #expect(headroom.isFallback == false)
    }

    @Test("a type with no demand never takes a slot")
    func zeroDemandRanksLast() {
        let headroom = ResourceHeadroom.derive(
            stock: ["rares": 1, "conductive": 1000, "volatiles": 2000],
            demand: ["conductive": 10, "volatiles": 10],
            freshness: now,
            now: now
        )
        #expect(headroom.weights == ["conductive": 2, "volatiles": 1])
    }

    @Test("a type with demand and no stock is the most bound")
    func missingStockIsZeroCoverage() {
        let headroom = ResourceHeadroom.derive(
            stock: ["conductive": 1000],
            demand: ["silicates": 100, "conductive": 10],
            freshness: now,
            now: now
        )
        #expect(headroom.weights["silicates"] == 2)
        #expect(headroom.coverage["silicates"] == 0)
    }

    @Test("empty stock falls back to the static weights")
    func emptyStockFallsBack() {
        let headroom = ResourceHeadroom.derive(
            stock: [:], demand: ["silicates": 100], freshness: now, now: now
        )
        #expect(headroom.weights == ResourceHeadroom.staticWeights)
        #expect(headroom.isFallback)
    }

    @Test("stock older than the bound falls back to the static weights")
    func staleStockFallsBack() {
        let headroom = ResourceHeadroom.derive(
            stock: ["silicates": 10, "conductive": 1000],
            demand: ["silicates": 100, "conductive": 10],
            freshness: now.addingTimeInterval(-ResourceHeadroom.stalenessBound - 1),
            now: now
        )
        #expect(headroom.weights == ResourceHeadroom.staticWeights)
        #expect(headroom.isFallback)
    }

    @Test("stock with no freshness stamp falls back")
    func missingFreshnessFallsBack() {
        let headroom = ResourceHeadroom.derive(
            stock: ["silicates": 10], demand: ["silicates": 100], freshness: nil, now: now
        )
        #expect(headroom.weights == ResourceHeadroom.staticWeights)
        #expect(headroom.isFallback)
    }

    @Test("no demand at all falls back rather than ranking on nothing")
    func noDemandFallsBack() {
        let headroom = ResourceHeadroom.derive(
            stock: ["silicates": 10], demand: [:], freshness: now, now: now
        )
        #expect(headroom.weights == ResourceHeadroom.staticWeights)
        #expect(headroom.isFallback)
    }

    @Test("ties break on the type name so the ranking is stable")
    func tiesBreakOnName() {
        let headroom = ResourceHeadroom.derive(
            stock: ["conductive": 100, "silicates": 100, "rares": 900],
            demand: ["conductive": 10, "silicates": 10, "rares": 10],
            freshness: now,
            now: now
        )
        #expect(headroom.weights == ["conductive": 2, "silicates": 1])
    }

    @Test("an explicit zero-demand entry never enters coverage or takes a slot")
    func zeroDemandEntryIsFiltered() {
        let headroom = ResourceHeadroom.derive(
            stock: ["conductive": 1000, "volatiles": 2000, "silicates": 500],
            demand: ["conductive": 10, "volatiles": 10, "silicates": 0, "structural": 0],
            freshness: now,
            now: now
        )
        #expect(headroom.weights == ["conductive": 2, "volatiles": 1])
        #expect(headroom.coverage == ["conductive": 100, "volatiles": 200])
        #expect(headroom.coverage["silicates"] == nil)
        #expect(headroom.coverage["structural"] == nil)
    }

    @Test("an unknown resource type never takes a slot or enters coverage")
    func unknownTypeIsFiltered() {
        let headroom = ResourceHeadroom.derive(
            stock: ["conductive": 1, "unobtainium": 999],
            demand: ["conductive": 1000, "unobtainium": 1],
            freshness: now,
            now: now
        )
        #expect(headroom.weights["unobtainium"] == nil)
        #expect(headroom.coverage["unobtainium"] == nil)
    }

    @Test("a reading exactly at the staleness bound still counts as fresh")
    func stalenessBoundIsInclusive() {
        let headroom = ResourceHeadroom.derive(
            stock: ["silicates": 500, "volatiles": 1000],
            demand: ["silicates": 50, "volatiles": 200],
            freshness: now.addingTimeInterval(-ResourceHeadroom.stalenessBound),
            now: now
        )
        #expect(headroom.isFallback == false)
        #expect(headroom.weights == ["volatiles": 2, "silicates": 1])
    }
}
