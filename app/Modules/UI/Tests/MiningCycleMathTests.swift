//
//  MiningCycleMathTests.swift
//  Replicould — UI
//
//  `MiningCycleView` draws a *repeating* bar — mining has no deadline, it loops
//  each cycle — so the geometry is `ProgressMath.cycleFraction` / `cycleText`:
//  where we are within the current cycle, wrapping at each boundary. Pure math, no
//  rendered view.
//

import Foundation
import Testing
@testable import UI

@Suite struct MiningCycleMathTests {

    private let start = Date(timeIntervalSince1970: 0)

    @Test func fractionIsZeroAtCycleStart() {
        #expect(ProgressMath.cycleFraction(now: start, start: start, cycle: 10) == 0)
    }

    @Test func fractionMidCycle() {
        #expect(ProgressMath.cycleFraction(now: Date(timeIntervalSince1970: 5), start: start, cycle: 10) == 0.5)
    }

    @Test func fractionWrapsAtBoundary() {
        // At exactly one full cycle the bar has reset to the next cycle's start.
        #expect(ProgressMath.cycleFraction(now: Date(timeIntervalSince1970: 10), start: start, cycle: 10) == 0)
        #expect(ProgressMath.cycleFraction(now: Date(timeIntervalSince1970: 13), start: start, cycle: 10) == 0.3)
    }

    @Test func fractionStaysInRangeBeforeStart() {
        // Clock skew (now before start) must not drive the fraction negative.
        let f = ProgressMath.cycleFraction(now: Date(timeIntervalSince1970: -2), start: start, cycle: 10)
        #expect(f == 0.8)
    }

    @Test func fractionIsZeroForNonPositiveCycle() {
        #expect(ProgressMath.cycleFraction(now: Date(timeIntervalSince1970: 5), start: start, cycle: 0) == 0)
    }

    @Test func textCountsDownWithinCycle() {
        #expect(ProgressMath.cycleText(now: Date(timeIntervalSince1970: 3), start: start, cycle: 10) == "next cycle 7s")
    }

    @Test func textResetsAtBoundary() {
        #expect(ProgressMath.cycleText(now: Date(timeIntervalSince1970: 10), start: start, cycle: 10) == "next cycle 10s")
    }
}
