//
//  FastISO8601Tests.swift
//  Replicould — GameModels
//
//  The hand parser must agree with Foundation bit-for-bit on every string a
//  `Date` column can hold, or a column adopting it silently shifts its values.
//

import Foundation
import SQLiteData
import Testing
@testable import GameModels

/// The format the default `Date` column writes, spelled out here so the test
/// compares against the stored shape rather than against the parser's own idea
/// of it.
private func stored(_ date: Date, fractionalSeconds: Bool = true) -> String {
    date.formatted(
        .iso8601.year().month().day()
            .dateTimeSeparator(.space)
            .time(includingFractionalSeconds: fractionalSeconds)
    )
}

private func foundationParse(_ text: String) throws -> Date {
    do {
        return try Date(
            text,
            strategy: .iso8601.year().month().day()
                .dateTimeSeparator(.space).time(includingFractionalSeconds: true)
        )
    } catch {
        return try Date(
            text,
            strategy: .iso8601.year().month().day()
                .dateTimeSeparator(.space).time(includingFractionalSeconds: false)
        )
    }
}

@Suite("FastISO8601")
struct FastISO8601Tests {

    /// The dates the fleet actually stores, plus the boundaries a hand-rolled
    /// civil-date conversion gets wrong: leap days, century rules, year and
    /// month edges, and the epoch itself.
    static let landmarks: [Date] = [
        Date(timeIntervalSince1970: 0),
        Date(timeIntervalSince1970: 500),
        Date(timeIntervalSince1970: 1_000),
        Date(timeIntervalSince1970: -1),
        Date(timeIntervalSince1970: -86_400),
        Date(timeIntervalSince1970: 951_782_400),    // 2000-02-29, the century leap
        Date(timeIntervalSince1970: 4_107_542_400),  // 2100-02-28, the century non-leap
        Date(timeIntervalSince1970: 1_078_012_800),  // 2004-02-29
        Date(timeIntervalSince1970: 1_767_225_599),  // 2025-12-31 23:59:59
        Date(timeIntervalSince1970: 1_767_225_600),  // 2026-01-01 00:00:00
        Date(timeIntervalSince1970: 1_787_248_590.728),
        // `Directive` and friends use this as a sentinel, so it reaches the
        // column like any other value.
        .distantFuture,
    ]

    @Test(arguments: landmarks)
    func agreesWithFoundationOnLandmarkDates(date: Date) throws {
        let text = stored(date)
        let fast = try #require(Date.fastISO8601(text), "fast path rejected \(text)")
        #expect(fast == (try foundationParse(text)))
    }

    /// A parser that only agrees on round numbers is no use — this walks a
    /// wide span at an interval that lands on every millisecond value.
    @Test func agreesWithFoundationAcrossAWideSpan() throws {
        var mismatches: [(String, Date, Date)] = []
        var seconds = -2_000_000_000.0
        while seconds < 4_000_000_000 {
            let date = Date(timeIntervalSince1970: seconds)
            let text = stored(date)
            guard let fast = Date.fastISO8601(text) else {
                mismatches.append((text, date, date))
                seconds += 1_999_999.137
                continue
            }
            let slow = try foundationParse(text)
            if fast != slow { mismatches.append((text, fast, slow)) }
            seconds += 1_999_999.137
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) disagreements, first: \(mismatches.first as Any)")
    }

    /// Every millisecond value round-trips: the fractional part is where a
    /// hand-rolled division most easily drifts from Foundation's.
    @Test func everyMillisecondValueAgrees() throws {
        var mismatches: [String] = []
        for millisecond in 0..<1000 {
            let date = Date(timeIntervalSince1970: 1_787_248_590 + Double(millisecond) / 1000)
            let text = stored(date)
            guard let fast = Date.fastISO8601(text) else {
                mismatches.append("rejected \(text)")
                continue
            }
            let slow = try foundationParse(text)
            if fast != slow { mismatches.append("\(text): \(fast) vs \(slow)") }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) disagreements, first: \(mismatches.first ?? "")")
    }

    /// Foundation's Gregorian calendar runs Julian before the 1582 cutover, so
    /// the fast path declines everything that old. `.distantPast` is a live
    /// sentinel in `Directive`, and it lands squarely in that range.
    @Test func preGregorianDatesDeclineToTheFastPath() {
        #expect(Date.fastISO8601("0001-01-01 00:00:00.000") == nil)
        #expect(Date.fastISO8601("1582-10-15 00:00:00.000") == nil)
        #expect(Date.fastISO8601(stored(.distantPast)) == nil)
        #expect(Date.fastISO8601("1583-01-01 00:00:00.000") != nil)
    }

    /// Declining is only safe if the fallback still lands on the right instant
    /// — this is the round trip the sentinel actually takes.
    @Test(arguments: [Date.distantPast, Date(timeIntervalSince1970: -30_000_000_000)])
    func preGregorianDatesStillRoundTripThroughFoundation(date: Date) throws {
        let parsed = try Date(fastISO8601: stored(date))
        #expect(parsed == (try foundationParse(stored(date))))
    }

    /// A row written before fractional seconds were stored still reads, and
    /// reads the same as Foundation reads it.
    @Test func parsesATimestampWithNoFractionalPart() throws {
        let text = "2026-08-19 16:56:30"
        let fast = try #require(Date.fastISO8601(text))
        #expect(fast == (try foundationParse(text)))
    }

    /// Shapes the fast path must hand to Foundation rather than guess at —
    /// falling through is what keeps this from ever accepting less.
    @Test(arguments: [
        "",
        "2026-08-19",
        "2026-08-19T16:56:30.728",       // `T` separator, never written by this column
        "2026-08-19 16:56:30.",          // a point with no digits
        "2026-08-19 16:56:60.000",       // second out of range
        "2026-08-19 24:00:00.000",       // hour out of range
        "2026-13-19 16:56:30.000",       // month out of range
        "not a timestamp at all",
    ])
    func unrecognisedShapesFallThrough(text: String) {
        #expect(Date.fastISO8601(text) == nil)
    }

    /// The whole point of the representation: the bytes written are the
    /// library's own, so a column can adopt it without rewriting its rows.
    @Test func bindsThroughTheLibrarysOwnDateCase() {
        let date = Date(timeIntervalSince1970: 1_787_248_590.728)
        let representation = Date.FastISO8601Representation(queryOutput: date)
        #expect(representation.queryBinding == .date(date))
    }
}
