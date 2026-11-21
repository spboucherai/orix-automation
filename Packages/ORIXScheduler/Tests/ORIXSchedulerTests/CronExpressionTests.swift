// ORIX OS Automation
// File: Packages/ORIXScheduler/Tests/ORIXSchedulerTests/CronExpressionTests.swift
// Description: Unit tests for cron parsing, day matching, calendar edge cases, daylight-saving behaviour in America/Toronto and Europe/Paris, and a monotonicity property test.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import Testing
@testable import ORIXScheduler

/// Parses `2026-03-08T07:00:00Z`.
func utc(_ text: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    guard let d = f.date(from: text) else { fatalError("bad test date \(text)") }
    return d
}

let utcZone = TimeZone(identifier: "UTC")!
let toronto = TimeZone(identifier: "America/Toronto")!
let paris = TimeZone(identifier: "Europe/Paris")!

/// Deterministic generator for the property tests.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Cron parsing (unit)")
struct CronParsingTests {
    @Test(arguments: [
        ("", "empty"),
        ("* * * *", "expected 5 fields"),
        ("* * * * * *", "expected 5 fields"),
        ("60 * * * *", "minute: value 60 is out of range 0-59"),
        ("* 24 * * *", "hour: value 24 is out of range 0-23"),
        ("* * 0 * *", "day-of-month: value 0 is out of range 1-31"),
        ("* * 32 * *", "day-of-month: value 32 is out of range 1-31"),
        ("* * * 13 *", "month: value 13 is out of range 1-12"),
        ("* * * * 8", "day-of-week: value 8 is out of range 0-7"),
        ("*/0 * * * *", "step must be greater than 0"),
        ("*/61 * * * *", "exceeds the field range"),
        ("*/x * * * *", "is not a positive integer"),
        ("5-1 * * * *", "range start 5 is greater than range end 1"),
        ("1,,2 * * * *", "empty list element"),
        ("1/2/3 * * * *", "more than one '/'"),
        ("a * * * *", "minute: 'a' is not a valid value"),
        ("-5 * * * *", "malformed range"),
        ("* * * FOO *", "month: 'FOO' is not a valid value"),
        ("* * * * MONDAY", "day-of-week: 'MONDAY' is not a valid value"),
        ("* * ? * *", "day-of-month: '?' is not a valid value"),
        ("* * L * *", "day-of-month: 'L' is not a valid value"),
        ("@reboot", "unknown macro '@reboot'"),
        ("@every 5m", "unknown macro"),
    ])
    func rejectsInvalidInputWithAPreciseMessage(_ c: (String, String)) {
        do {
            _ = try CronExpression(c.0)
            Issue.record("'\(c.0)' should have been rejected")
        } catch let error as CronParseError {
            #expect(error.description.contains(c.1), "message for '\(c.0)' was: \(error.description)")
            #expect(error.errorDescription == error.description)
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    private func minutes(_ expr: String) throws -> [Int] {
        let cron = try CronExpression(expr)
        return cron.fireDates(between: utc("2026-01-01T00:00:00Z").addingTimeInterval(-1), and: utc("2026-01-01T00:59:59Z"), in: utcZone)
            .map { Int($0.timeIntervalSince(utc("2026-01-01T00:00:00Z"))) / 60 }
    }

    @Test func listsRangesAndSteps() throws {
        #expect(try minutes("*/15 * * * *") == [0, 15, 30, 45])
        #expect(try minutes("1,15,59 * * * *") == [1, 15, 59])
        #expect(try minutes("10-13 * * * *") == [10, 11, 12, 13])
        #expect(try minutes("10-40/10 * * * *") == [10, 20, 30, 40])
        #expect(try minutes("5/20 * * * *") == [5, 25, 45])
        #expect(try minutes("0-5,50-59/3,30 * * * *") == [0, 1, 2, 3, 4, 5, 30, 50, 53, 56, 59])
        #expect(try minutes("7 * * * *") == [7])
    }

    @Test func namesAreCaseInsensitiveAndEquivalentToNumbers() throws {
        let named = try CronExpression("0 9 * jan-MAR Mon-Fri")
        let numeric = try CronExpression("0 9 * 1-3 1-5")
        let start = utc("2026-01-01T00:00:00Z"), end = utc("2026-12-31T00:00:00Z")
        let a = named.fireDates(between: start, and: end, in: toronto, limit: 500)
        #expect(a == numeric.fireDates(between: start, and: end, in: toronto, limit: 500))
        #expect(a.count == 64) // weekdays in January–March 2026: 22 + 20 + 22
        #expect(named.months == numeric.months && named.daysOfWeek == numeric.daysOfWeek)
    }

    @Test func sundayIsZeroAndSeven() throws {
        let zero = try CronExpression("0 0 * * 0"), seven = try CronExpression("0 0 * * 7"), name = try CronExpression("0 0 * * SUN")
        #expect(zero.daysOfWeek == seven.daysOfWeek && zero.daysOfWeek == name.daysOfWeek)
        // 4 January 2026 is a Sunday.
        #expect(zero.nextFireDate(after: utc("2026-01-01T00:00:00Z"), in: utcZone) == utc("2026-01-04T00:00:00Z"))
        let weekend = try CronExpression("0 0 * * 6-7")
        #expect(weekend.fireDates(between: utc("2026-01-01T00:00:00Z"), and: utc("2026-01-12T00:00:00Z"), in: utcZone)
                == [utc("2026-01-03T00:00:00Z"), utc("2026-01-04T00:00:00Z"), utc("2026-01-10T00:00:00Z"), utc("2026-01-11T00:00:00Z")])
    }

    @Test func macros() throws {
        let cases = ["@hourly": "0 * * * *", "@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@weekly": "0 0 * * 0",
                     "@monthly": "0 0 1 * *", "@yearly": "0 0 1 1 *", "@ANNUALLY": "0 0 1 1 *"]
        let start = utc("2026-01-01T00:00:00Z"), end = utc("2028-01-01T00:00:00Z")
        for (macro, expansion) in cases {
            let a = try CronExpression(macro).fireDates(between: start, and: end, in: paris, limit: 50)
            let b = try CronExpression(expansion).fireDates(between: start, and: end, in: paris, limit: 50)
            #expect(a == b && !a.isEmpty, "\(macro)")
        }
    }

    @Test func codableRoundTripsAsAString() throws {
        let cron = try CronExpression("  */5 9-17 * * MON-FRI ")
        #expect(cron.source == "*/5 9-17 * * MON-FRI" && cron.description == cron.source)
        let data = try JSONEncoder().encode([cron])
        #expect(String(decoding: data, as: UTF8.self) == #"["*\/5 9-17 * * MON-FRI"]"#)
        #expect(try JSONDecoder().decode([CronExpression].self, from: data) == [cron])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([CronExpression].self, from: Data(#"["61 * * * *"]"#.utf8)) }
    }
}

@Suite("Cron calendar rules (unit)")
struct CronCalendarTests {
    @Test func dayOfMonthAndDayOfWeekAreOredWhenBothRestricted() throws {
        // 1 January 2026 is a Thursday: Fridays are 2, 9, 16…; the 13th is a Tuesday.
        let cron = try CronExpression("0 0 13 * FRI")
        let dates = cron.fireDates(between: utc("2026-01-01T00:00:00Z"), and: utc("2026-01-17T00:00:00Z"), in: utcZone)
        #expect(dates == ["2026-01-02", "2026-01-09", "2026-01-13", "2026-01-16"].map { utc($0 + "T00:00:00Z") })
    }

    @Test func aWildcardDayFieldMeansBothMustMatch() throws {
        let onlyFridays = try CronExpression("0 0 * * FRI")
        #expect(onlyFridays.fireDates(between: utc("2026-01-01T00:00:00Z"), and: utc("2026-01-17T00:00:00Z"), in: utcZone)
                == ["2026-01-02", "2026-01-09", "2026-01-16"].map { utc($0 + "T00:00:00Z") })
        let only13th = try CronExpression("0 0 13 * *")
        #expect(only13th.nextFireDate(after: utc("2026-01-01T00:00:00Z"), in: utcZone) == utc("2026-01-13T00:00:00Z"))
        // `*/2` starts with a star: odd days that are also Fridays.
        let oddFridays = try CronExpression("0 0 */2 * FRI")
        #expect(oddFridays.fireDates(between: utc("2026-01-01T00:00:00Z"), and: utc("2026-01-31T00:00:00Z"), in: utcZone)
                == ["2026-01-09", "2026-01-23"].map { utc($0 + "T00:00:00Z") })
    }

    @Test func february29OnlyFiresInLeapYears() throws {
        let cron = try CronExpression("0 0 29 2 *")
        let first = cron.nextFireDate(after: utc("2026-01-01T00:00:00Z"), in: utcZone)
        #expect(first == utc("2028-02-29T00:00:00Z"))
        #expect(cron.nextFireDate(after: first!, in: utcZone) == utc("2032-02-29T00:00:00Z"))
        // 2100 is not a leap year: the gap is eight years.
        #expect(cron.nextFireDate(after: utc("2096-03-01T00:00:00Z"), in: utcZone) == utc("2104-02-29T00:00:00Z"))
    }

    @Test func impossibleDatesNeverFire() throws {
        #expect(try CronExpression("0 0 30 2 *").nextFireDate(after: utc("2026-01-01T00:00:00Z"), in: utcZone) == nil)
        #expect(try CronExpression("0 0 31 4,6,9,11 *").nextFireDate(after: utc("2026-01-01T00:00:00Z"), in: toronto) == nil)
        #expect(try CronExpression("0 0 31 4 *").fireDates(between: utc("2026-01-01T00:00:00Z"), and: utc("2030-01-01T00:00:00Z"), in: utcZone).isEmpty)
    }

    @Test func the31stSkipsShortMonths() throws {
        let cron = try CronExpression("0 0 31 * *")
        let dates = cron.fireDates(between: utc("2026-01-31T00:00:00Z"), and: utc("2026-12-31T23:00:00Z"), in: utcZone)
        #expect(dates == ["2026-03-31", "2026-05-31", "2026-07-31", "2026-08-31", "2026-10-31", "2026-12-31"].map { utc($0 + "T00:00:00Z") })
        // Last days of February and the year boundary.
        let daily = try CronExpression("59 23 * * *")
        #expect(daily.nextFireDate(after: utc("2026-02-28T23:59:00Z"), in: utcZone) == utc("2026-03-01T23:59:00Z"))
        #expect(daily.nextFireDate(after: utc("2028-02-28T23:59:00Z"), in: utcZone) == utc("2028-02-29T23:59:00Z"))
        #expect(daily.nextFireDate(after: utc("2026-12-31T23:59:00Z"), in: utcZone) == utc("2027-01-01T23:59:00Z"))
    }

    @Test func nextIsStrictlyAfterAndHonoursSubSecondInput() throws {
        let cron = try CronExpression("0 9 * * *")
        let nine = utc("2026-06-01T09:00:00Z")
        #expect(cron.nextFireDate(after: nine.addingTimeInterval(-0.5), in: utcZone) == nine)
        #expect(cron.nextFireDate(after: nine, in: utcZone) == utc("2026-06-02T09:00:00Z"))
        #expect(cron.nextFireDate(after: nine.addingTimeInterval(0.5), in: utcZone) == utc("2026-06-02T09:00:00Z"))
        #expect(cron.fires(at: nine, in: utcZone) && !cron.fires(at: nine.addingTimeInterval(60), in: utcZone))
    }

    @Test func fireDatesHonoursBoundsAndLimit() throws {
        let cron = try CronExpression("* * * * *")
        let start = utc("2026-06-01T00:00:00Z")
        #expect(cron.fireDates(between: start, and: start.addingTimeInterval(600), in: utcZone).count == 10)
        #expect(cron.fireDates(between: start, and: start.addingTimeInterval(600), in: utcZone, limit: 3)
                == [60, 120, 180].map { start.addingTimeInterval($0) })
        #expect(cron.fireDates(between: start, and: start, in: utcZone).isEmpty)
    }

    @Test func civilDateArithmeticMatchesFoundation() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcZone
        var rng = SplitMix64(state: 42)
        for _ in 0..<2000 {
            let days = Int.random(in: -100_000...200_000, using: &rng)
            let date = Date(timeIntervalSince1970: TimeInterval(days) * 86_400)
            let c = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
            let (y, m, d) = CivilDate.civil(fromDays: days)
            #expect(y == c.year && m == c.month && d == c.day)
            #expect(CivilDate.weekday(ofDays: days) == c.weekday! - 1)
            #expect(CivilDate.days(year: y, month: m, day: d) == days)
        }
    }
}

@Suite("Cron daylight saving, America/Toronto and Europe/Paris (unit)")
struct CronDSTTests {
    /// (zone, day before the change at noon UTC, expected firing on the change day, expected firing the day after).
    static let springForward: [(String, String, String, String)] = [
        // Toronto: 02:00 EST → 03:00 EDT at 07:00Z. 02:30 does not exist; fire at 03:00 EDT.
        ("America/Toronto", "2026-03-07T12:00:00Z", "2026-03-08T07:00:00Z", "2026-03-09T06:30:00Z"),
        ("America/Toronto", "2027-03-13T12:00:00Z", "2027-03-14T07:00:00Z", "2027-03-15T06:30:00Z"),
        // Paris: 02:00 CET → 03:00 CEST at 01:00Z.
        ("Europe/Paris", "2026-03-28T12:00:00Z", "2026-03-29T01:00:00Z", "2026-03-30T00:30:00Z"),
        ("Europe/Paris", "2027-03-27T12:00:00Z", "2027-03-28T01:00:00Z", "2027-03-29T00:30:00Z"),
    ]

    @Test(arguments: springForward)
    func aSkippedLocalTimeFiresOnceAtTheFirstValidInstantAfterTheGap(_ c: (String, String, String, String)) throws {
        let zone = TimeZone(identifier: c.0)!
        let cron = try CronExpression("30 2 * * *")
        let onChangeDay = cron.nextFireDate(after: utc(c.1), in: zone)
        #expect(onChangeDay == utc(c.2))
        #expect(cron.nextFireDate(after: utc(c.2), in: zone) == utc(c.3))
        // Exactly one firing on the change day.
        #expect(cron.fireDates(between: utc(c.1), and: utc(c.3).addingTimeInterval(-1), in: zone) == [utc(c.2)])
        // The first valid instant is 03:00 local.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let local = calendar.dateComponents([.hour, .minute], from: utc(c.2))
        #expect(local.hour == 3 && local.minute == 0)
    }

    @Test(arguments: springForward)
    func severalTimesInsideTheGapCollapseIntoOneFiring(_ c: (String, String, String, String)) throws {
        let zone = TimeZone(identifier: c.0)!
        let end = utc(c.2).addingTimeInterval(3 * 3600)
        for expr in ["0,15,30,45 2 * * *", "0 2,3 * * *", "0-59 2 * * *", "30 2 * * *"] {
            let dates = try CronExpression(expr).fireDates(between: utc(c.1), and: end, in: zone)
            #expect(dates.filter { $0 >= utc(c.2).addingTimeInterval(-3600) } == [utc(c.2)], "\(expr) in \(c.0)")
        }
    }

    /// (zone, day before at noon UTC, first occurrence of the repeated time, same local time the day after, the second occurrence that must not fire).
    static let fallBack: [(String, String, String, String, String, String)] = [
        // Toronto: 02:00 EDT → 01:00 EST at 06:00Z; 01:30 happens at 05:30Z (EDT) and 06:30Z (EST).
        ("America/Toronto", "30 1 * * *", "2026-10-31T12:00:00Z", "2026-11-01T05:30:00Z", "2026-11-02T06:30:00Z", "2026-11-01T06:30:00Z"),
        ("America/Toronto", "30 1 * * *", "2027-11-06T12:00:00Z", "2027-11-07T05:30:00Z", "2027-11-08T06:30:00Z", "2027-11-07T06:30:00Z"),
        // Paris: 03:00 CEST → 02:00 CET at 01:00Z; 02:30 happens at 00:30Z (CEST) and 01:30Z (CET).
        ("Europe/Paris", "30 2 * * *", "2026-10-24T12:00:00Z", "2026-10-25T00:30:00Z", "2026-10-26T01:30:00Z", "2026-10-25T01:30:00Z"),
        ("Europe/Paris", "30 2 * * *", "2027-10-30T12:00:00Z", "2027-10-31T00:30:00Z", "2027-11-01T01:30:00Z", "2027-10-31T01:30:00Z"),
    ]

    @Test(arguments: fallBack)
    func aRepeatedLocalTimeFiresOnceOnTheFirstOccurrence(_ c: (String, String, String, String, String, String)) throws {
        let zone = TimeZone(identifier: c.0)!
        let cron = try CronExpression(c.1)
        #expect(cron.nextFireDate(after: utc(c.2), in: zone) == utc(c.3))
        #expect(cron.nextFireDate(after: utc(c.3), in: zone) == utc(c.4))
        let dates = cron.fireDates(between: utc(c.2), and: utc(c.4), in: zone)
        #expect(dates == [utc(c.3), utc(c.4)])
        #expect(!dates.contains(utc(c.5)))
        #expect(!cron.fires(at: utc(c.5), in: zone))
    }

    @Test(arguments: ["America/Toronto", "Europe/Paris"], [2026, 2027])
    func aDailyJobFiresExactlyOncePerLocalDayAllYear(_ zoneID: String, _ year: Int) throws {
        let zone = TimeZone(identifier: zoneID)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))!
        for expr in ["30 2 * * *", "30 1 * * *", "0 0 * * *", "59 23 * * *", "0 3 * * *"] {
            let dates = try CronExpression(expr).fireDates(between: start.addingTimeInterval(-1), and: end.addingTimeInterval(-1), in: zone, limit: 1000)
            #expect(dates.count == 365, "\(expr) \(zoneID) \(year): \(dates.count)")
            let days = Set(dates.map { calendar.dateComponents([.year, .month, .day], from: $0) })
            #expect(days.count == 365, "\(expr) \(zoneID) \(year): a day fired twice or was skipped")
            #expect(zip(dates, dates.dropFirst()).allSatisfy { $0 < $1 })
        }
    }

    @Test func hourlyStyleJobsKeepTheirElapsedTimeRhythm() throws {
        let halfPast = try CronExpression("30 * * * *")
        // Toronto spring forward: 01:30 EST, then 03:30 EDT — one real hour apart, nothing invented at 03:00.
        #expect(halfPast.fireDates(between: utc("2026-03-08T06:00:00Z"), and: utc("2026-03-08T09:00:00Z"), in: toronto)
                == ["2026-03-08T06:30:00Z", "2026-03-08T07:30:00Z", "2026-03-08T08:30:00Z"].map(utc))
        // Toronto fall back: 01:30 runs on both passes, so the job never goes silent for two hours.
        #expect(halfPast.fireDates(between: utc("2026-11-01T05:00:00Z"), and: utc("2026-11-01T08:00:00Z"), in: toronto)
                == ["2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z", "2026-11-01T07:30:00Z"].map(utc))
        // Every five minutes: 12 firings per real hour through both Paris changes.
        let fiveMinutes = try CronExpression("*/5 * * * *")
        for window in [("2026-03-29T00:00:00Z", "2026-03-29T03:00:00Z"), ("2026-10-25T00:00:00Z", "2026-10-25T03:00:00Z")] {
            let dates = fiveMinutes.fireDates(between: utc(window.0), and: utc(window.1), in: paris)
            #expect(dates.count == 36)
            #expect(zip(dates, dates.dropFirst()).allSatisfy { $1.timeIntervalSince($0) == 300 })
        }
    }

    @Test func localTimeResolutionClassifiesGapsAndOverlaps() {
        func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Int { CivilDate.days(year: y, month: m, day: d) * 86_400 + h * 3600 + min * 60 }
        #expect(LocalTime.resolve(local(2026, 3, 8, 2, 30), in: toronto) == .skipped(firstValidInstant: Int(utc("2026-03-08T07:00:00Z").timeIntervalSince1970)))
        #expect(LocalTime.resolve(local(2026, 3, 8, 3, 0), in: toronto) == .unique(Int(utc("2026-03-08T07:00:00Z").timeIntervalSince1970)))
        #expect(LocalTime.resolve(local(2026, 3, 8, 1, 59), in: toronto) == .unique(Int(utc("2026-03-08T06:59:00Z").timeIntervalSince1970)))
        #expect(LocalTime.resolve(local(2026, 11, 1, 1, 30), in: toronto)
                == .repeated(first: Int(utc("2026-11-01T05:30:00Z").timeIntervalSince1970), second: Int(utc("2026-11-01T06:30:00Z").timeIntervalSince1970)))
        #expect(LocalTime.resolve(local(2026, 11, 1, 2, 0), in: toronto) == .unique(Int(utc("2026-11-01T07:00:00Z").timeIntervalSince1970)))
        #expect(LocalTime.resolve(local(2026, 10, 25, 2, 59), in: paris)
                == .repeated(first: Int(utc("2026-10-25T00:59:00Z").timeIntervalSince1970), second: Int(utc("2026-10-25T01:59:00Z").timeIntervalSince1970)))
        #expect(LocalTime.resolve(local(2026, 7, 1, 12, 0), in: paris) == .unique(Int(utc("2026-07-01T10:00:00Z").timeIntervalSince1970)))
    }
}

@Suite("Cron properties over random expressions (unit)")
struct CronPropertyTests {
    static func randomField(_ range: ClosedRange<Int>, _ rng: inout SplitMix64) -> String {
        switch Int.random(in: 0..<6, using: &rng) {
        case 0: return "*"
        case 1: return "*/\(Int.random(in: 1...max(1, (range.upperBound - range.lowerBound) / 2), using: &rng))"
        case 2:
            let a = Int.random(in: range, using: &rng), b = Int.random(in: range, using: &rng)
            return "\(min(a, b))-\(max(a, b))"
        case 3:
            return (0..<Int.random(in: 1...4, using: &rng)).map { _ in String(Int.random(in: range, using: &rng)) }.joined(separator: ",")
        case 4:
            let a = Int.random(in: range, using: &rng)
            return "\(a)/\(Int.random(in: 1...max(1, (range.upperBound - range.lowerBound) / 3), using: &rng))"
        default: return String(Int.random(in: range, using: &rng))
        }
    }

    static func randomExpression(_ rng: inout SplitMix64) -> String {
        [randomField(0...59, &rng), randomField(0...23, &rng), randomField(1...31, &rng), randomField(1...12, &rng), randomField(0...7, &rng)]
            .joined(separator: " ")
    }

    @Test func nextFireDatesAreStrictlyIncreasingStableAndMatchTheFields() throws {
        var rng = SplitMix64(state: 20_261_121)
        let zones = [utcZone, toronto, paris, TimeZone(identifier: "Australia/Lord_Howe")!, TimeZone(identifier: "Asia/Kathmandu")!]
        var checked = 0
        for i in 0..<300 {
            let text = Self.randomExpression(&rng)
            let cron = try CronExpression(text)
            let zone = zones[i % zones.count]
            // Start anywhere in 2026–2027, including the hours around the DST changes.
            var cursor = utc("2026-01-01T00:00:00Z").addingTimeInterval(Double(Int.random(in: 0..<(730 * 86_400), using: &rng)))
            var previous: Date?
            for _ in 0..<12 {
                guard let next = cron.nextFireDate(after: cursor, in: zone) else { break }
                #expect(next > cursor, "\(text): not strictly after")
                if let previous { #expect(next > previous, "\(text): not increasing") }
                // Stable: asking again from just before gives the same instant, and nothing lies in between.
                #expect(cron.nextFireDate(after: next.addingTimeInterval(-1), in: zone) == next, "\(text): unstable")
                #expect(cron.nextFireDate(after: cursor.addingTimeInterval((next.timeIntervalSince(cursor)) / 2), in: zone) == next, "\(text): a firing was missed")
                #expect(next.timeIntervalSince1970 == next.timeIntervalSince1970.rounded(), "\(text): not a whole second")
                if zone == utcZone {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = zone
                    let c = calendar.dateComponents([.minute, .hour, .day, .month, .weekday, .second], from: next)
                    #expect(c.second == 0)
                    #expect(cron.minutes & (1 << UInt64(c.minute!)) != 0 && cron.hours & (1 << UInt64(c.hour!)) != 0, "\(text)")
                    #expect(cron.matchesDay(month: c.month!, day: c.day!, weekday: c.weekday! - 1), "\(text)")
                }
                previous = next
                cursor = next
                checked += 1
            }
        }
        #expect(checked > 2000)
    }

    @Test func latestFireDateAgreesWithForwardEnumeration() throws {
        var rng = SplitMix64(state: 7)
        for _ in 0..<60 {
            let text = Self.randomExpression(&rng)
            let trigger = TriggerSpec.cron(expression: text, timezone: "America/Toronto")
            let lower = utc("2026-10-30T00:00:00Z").addingTimeInterval(Double(Int.random(in: 0..<86_400, using: &rng)))
            let upper = lower.addingTimeInterval(Double(Int.random(in: 60..<(2 * 86_400), using: &rng)))
            let forward = try CronExpression(text).fireDates(between: lower, and: upper, in: toronto, limit: 100_000)
            #expect(trigger.latestFireDate(after: lower, atOrBefore: upper, anchor: lower) == forward.last, "\(text)")
        }
    }
}
