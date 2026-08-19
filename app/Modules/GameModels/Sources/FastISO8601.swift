//
//  FastISO8601.swift
//  Replicould — GameModels
//
//  A drop-in column representation for `Date` that decodes the stored
//  timestamp by hand instead of through `Date.ISO8601FormatStyle`. Binding is
//  delegated to the library's own `.date` case, so the bytes written are
//  unchanged and only the read path differs.
//

import Foundation
import SQLiteData

extension Date {
    /// Decodes the same TEXT the default `Date` column writes, without
    /// building a `Date.ISO8601FormatStyle` per row.
    ///
    /// Anything the hand parser does not recognise falls through to Foundation,
    /// so this can never accept less than the default representation does.
    public struct FastISO8601Representation: QueryRepresentable, Sendable {
        public var queryOutput: Date

        public init(queryOutput: Date) {
            self.queryOutput = queryOutput
        }
    }
}

extension Date? {
    public typealias FastISO8601Representation = Date.FastISO8601Representation?
}

extension Date.FastISO8601Representation: QueryBindable {
    /// The library's own binding, so a column that adopts this representation
    /// writes bytes identical to one that does not.
    public var queryBinding: QueryBinding { .date(queryOutput) }
}

extension Date.FastISO8601Representation: QueryDecodable {
    public init(decoder: inout some QueryDecoder) throws {
        self.init(queryOutput: try Date(fastISO8601: String(decoder: &decoder)))
    }
}

extension Date.FastISO8601Representation: SQLiteType {
    public static var typeAffinity: SQLiteTypeAffinity { String.typeAffinity }
}

extension Date {
    /// `YYYY-MM-DD HH:MM:SS[.fff]` in GMT — the shape the default `Date` column
    /// writes. Falls back to Foundation for anything else.
    init(fastISO8601 text: String) throws {
        if let parsed = Date.fastISO8601(text) {
            self = parsed
            return
        }
        do {
            self = try Date(text, strategy: .iso8601.storedTimestamp(fractionalSeconds: true))
        } catch {
            self = try Date(text, strategy: .iso8601.storedTimestamp(fractionalSeconds: false))
        }
    }

    /// nil means "not the expected shape", never "invalid date" — the caller
    /// falls back rather than failing, so a stricter reading here is safe.
    static func fastISO8601(_ text: String) -> Date? {
        var text = text
        return text.withUTF8 { buffer -> Date? in
            // 19 bytes of `YYYY-MM-DD HH:MM:SS`, then an optional `.` and at
            // least one fractional digit.
            guard buffer.count >= 19 else { return nil }
            guard buffer[4] == UInt8(ascii: "-"), buffer[7] == UInt8(ascii: "-"),
                  buffer[10] == UInt8(ascii: " "),
                  buffer[13] == UInt8(ascii: ":"), buffer[16] == UInt8(ascii: ":")
            else { return nil }

            // Written flat — no nested helper, no `Range.contains` — because
            // this runs unoptimized in debug builds, where both cost more than
            // the parse. Digits are `UInt8`, so a non-digit wraps above 9.
            let y0 = buffer[0] &- 48, y1 = buffer[1] &- 48
            let y2 = buffer[2] &- 48, y3 = buffer[3] &- 48
            let mo0 = buffer[5] &- 48, mo1 = buffer[6] &- 48
            let d0 = buffer[8] &- 48, d1 = buffer[9] &- 48
            let h0 = buffer[11] &- 48, h1 = buffer[12] &- 48
            let mi0 = buffer[14] &- 48, mi1 = buffer[15] &- 48
            let s0 = buffer[17] &- 48, s1 = buffer[18] &- 48
            guard y0 <= 9, y1 <= 9, y2 <= 9, y3 <= 9, mo0 <= 9, mo1 <= 9,
                  d0 <= 9, d1 <= 9, h0 <= 9, h1 <= 9, mi0 <= 9, mi1 <= 9,
                  s0 <= 9, s1 <= 9
            else { return nil }

            let year = Int(y0) * 1000 + Int(y1) * 100 + Int(y2) * 10 + Int(y3)
            let month = Int(mo0) * 10 + Int(mo1)
            let day = Int(d0) * 10 + Int(d1)
            let hour = Int(h0) * 10 + Int(h1)
            let minute = Int(mi0) * 10 + Int(mi1)
            let second = Int(s0) * 10 + Int(s1)

            // Foundation's Gregorian calendar is a hybrid that runs Julian
            // before the 1582 cutover, where this proleptic arithmetic is two
            // days out. `.distantPast` lands there and is a live sentinel, so
            // anything that old goes to Foundation.
            guard year >= 1583, month >= 1, month <= 12, day >= 1, day <= 31,
                  hour < 24, minute < 60, second < 60
            else { return nil }

            // Accumulated as an integer and divided once: summing
            // `digit / scale` term by term rounds at every digit and drifts
            // from Foundation in the last bits.
            var fraction = 0.0
            if buffer.count > 19 {
                guard buffer[19] == UInt8(ascii: "."), buffer.count > 20 else { return nil }
                var numerator = 0
                var denominator = 1.0
                var index = 20
                while index < buffer.count {
                    let digit = buffer[index] &- 48
                    guard digit <= 9 else { return nil }
                    numerator = numerator * 10 + Int(digit)
                    denominator *= 10
                    index += 1
                }
                fraction = Double(numerator) / denominator
            }

            let days = Date.daysFromCivil(year: year, month: month, day: day)
            let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second
            // Built against the reference date rather than 1970: `Date` stores
            // the former, so adding the fraction after the epoch shift is what
            // matches Foundation's own association order.
            return Date(
                timeIntervalSinceReferenceDate: Double(seconds - 978_307_200) + fraction
            )
        }
    }

    /// Days between the Unix epoch and the given proleptic Gregorian date,
    /// after Howard Hinnant's `days_from_civil`.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

extension Date.ISO8601FormatStyle {
    /// The exact component set the default `Date` column round-trips through.
    fileprivate func storedTimestamp(fractionalSeconds: Bool) -> Self {
        year().month().day()
            .dateTimeSeparator(.space)
            .time(includingFractionalSeconds: fractionalSeconds)
    }
}
