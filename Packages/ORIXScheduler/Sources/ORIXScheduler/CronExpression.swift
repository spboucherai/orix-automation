// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXScheduler/Sources/ORIXScheduler/CronExpression.swift
// Description      : Strict 5-field cron parser and next-fire computation with
//                    explicit, tested daylight-saving behaviour.
// Module           : ORIXScheduler
// Repository       : https://git.spboucher.ai/orix-automation
// Created          : 2026-11-21
// Last Modified    : 2026-11-21
//
// =============================================================================
// AUTHOR & PROFESSIONAL AFFILIATION
// =============================================================================
//
// Author           : Simon-Pierre Boucher
// Position         : Professor of Finance
// Institution      : Université du Québec en Outaouais (UQO)
// Department       : Département des sciences administratives
// Organization     : SP Boucher
//
// Website          : https://spboucher.ai
// Git              : https://git.spboucher.ai
//
// =============================================================================
// OFFICIAL CONTACT DIRECTORY
// =============================================================================
//
// General          : info@spboucher.ai
// Professional     : contact@spboucher.ai
// Direct           : simon@spboucher.ai
// Research         : research@spboucher.ai
// Development      : dev@spboucher.ai
// Support          : support@spboucher.ai
// Security/Admin   : admin@spboucher.ai
// Notifications    : notifications@spboucher.ai
//
// Preferred Contact: support@spboucher.ai
//
// =============================================================================
// COPYRIGHT & INTELLECTUAL PROPERTY
// =============================================================================
//
// Copyright (c) 2026
// Simon-Pierre Boucher
//
// All rights reserved where applicable.
//
// This file is governed by the applicable project license,
// copyright notices, institutional agreements and relevant law.
//
// Unless expressly authorized by the applicable license or
// rights holder, copying, redistribution, sublicensing,
// publication and commercial exploitation are not permitted.
//
// Existing third-party rights and notices remain unaffected.
//
// =============================================================================
// CONFIDENTIALITY & SECURITY
// =============================================================================
//
// Classification   : Public
// Distribution     : Public repository; use is governed by the project license
// Security Contact : admin@spboucher.ai
//
// Access to this source does not independently grant permission
// to redistribute or disclose confidential materials.
//
// Do not embed credentials, private keys, access tokens,
// certificates or confidential personal information.
//
// =============================================================================
// LICENSE & MAINTENANCE
// =============================================================================
//
// License          : Proprietary, all rights reserved (see license file)
// License File     : LICENSE
// Maintainer       : Simon-Pierre Boucher
// Technical Contact: dev@spboucher.ai
//
// =============================================================================
// END OF SP BOUCHER SOURCE HEADER
// =============================================================================

import Foundation

/// Why a cron expression was rejected. `field` is nil for whole-expression problems.
public struct CronParseError: Error, Sendable, Hashable, LocalizedError, CustomStringConvertible {
    public let field: String?
    public let message: String
    public init(field: String?, message: String) { self.field = field; self.message = message }
    public var description: String { field.map { "cron \($0): \(message)" } ?? "cron: \(message)" }
    public var errorDescription: String? { description }
}

/// A 5-field cron expression: `minute hour day-of-month month day-of-week`.
///
/// Syntax: `*`, single values, lists (`1,15`), ranges (`MON-FRI`), steps (`*/5`, `10-40/10`, `5/15` = from 5 to the
/// field maximum), month names (`JAN`…`DEC`) and weekday names (`SUN`…`SAT`), both case-insensitive. Day-of-week accepts
/// 0–7 where 0 and 7 are Sunday. Macros: `@hourly`, `@daily` (`@midnight`), `@weekly`, `@monthly`, `@yearly`
/// (`@annually`). `@reboot`, seconds fields, `?`, `L`, `W` and `#` are not supported and are rejected.
///
/// Day matching follows the standard (Vixie) rule: when **both** day-of-month and day-of-week are restricted (neither
/// starts with `*`), a day matches when **either** field matches; otherwise both must match.
///
/// ## Daylight-saving behaviour
///
/// A cron expression describes local wall-clock times. On the two days a year when the wall clock is not continuous:
///
/// - **Spring forward** (a local time that does not exist, e.g. 02:30 on 2026-03-08 in `America/Toronto`): a job
///   scheduled at a skipped time fires **once, at the first valid instant after the gap** (03:00 local). Several
///   scheduled times inside the same gap collapse into that single firing, and a firing scheduled exactly at the end
///   of the gap is not doubled.
/// - **Fall back** (a local time that happens twice, e.g. 01:30 on 2026-11-01 in `America/Toronto`): a job scheduled
///   at a repeated time fires **once, on the first occurrence**.
/// - **Exception, hourly-style jobs**: when the hour field is a wildcard (`*` or `*/n`), the expression means "every
///   n hours of elapsed time", not "at this wall-clock hour". Such a job keeps its elapsed-time rhythm: nothing is
///   added for a skipped hour and the repeated hour runs on both passes (`*/5 * * * *` keeps firing every 5 real
///   minutes through the change instead of going silent for an hour).
///
/// A fixed-time job therefore never fires twice for one scheduled local time and never skips a day.
public struct CronExpression: Sendable, Hashable, Codable, CustomStringConvertible {
    /// The text the expression was parsed from (trimmed).
    public let source: String

    let minutes: UInt64       // bits 0…59
    let hours: UInt64         // bits 0…23
    let daysOfMonth: UInt64   // bits 1…31
    let months: UInt64        // bits 1…12
    let daysOfWeek: UInt64    // bits 0…6, 0 = Sunday
    let dayOfMonthIsWildcard: Bool
    let dayOfWeekIsWildcard: Bool
    let hourIsWildcard: Bool

    public var description: String { source }

    // MARK: Parsing

    private struct FieldSpec {
        let name: String
        let min: Int
        let max: Int
        let names: [String: Int]
    }

    private static let monthNames: [String: Int] = [
        "JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6, "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12,
    ]
    private static let weekdayNames: [String: Int] = ["SUN": 0, "MON": 1, "TUE": 2, "WED": 3, "THU": 4, "FRI": 5, "SAT": 6]
    private static let macros: [String: String] = [
        "@hourly": "0 * * * *", "@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@weekly": "0 0 * * 0",
        "@monthly": "0 0 1 * *", "@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *",
    ]

    public init(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CronParseError(field: nil, message: "expression is empty") }
        var body = trimmed
        if trimmed.hasPrefix("@") {
            guard let expansion = Self.macros[trimmed.lowercased()] else {
                throw CronParseError(field: nil, message: "unknown macro '\(trimmed)' (supported: @hourly, @daily, @midnight, @weekly, @monthly, @yearly, @annually)")
            }
            body = expansion
        }
        let parts = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count == 5 else {
            throw CronParseError(field: nil, message: "expected 5 fields (minute hour day-of-month month day-of-week), found \(parts.count)")
        }
        let minute = try Self.parseField(parts[0], FieldSpec(name: "minute", min: 0, max: 59, names: [:]))
        let hour = try Self.parseField(parts[1], FieldSpec(name: "hour", min: 0, max: 23, names: [:]))
        let dom = try Self.parseField(parts[2], FieldSpec(name: "day-of-month", min: 1, max: 31, names: [:]))
        let month = try Self.parseField(parts[3], FieldSpec(name: "month", min: 1, max: 12, names: Self.monthNames))
        let dow = try Self.parseField(parts[4], FieldSpec(name: "day-of-week", min: 0, max: 7, names: Self.weekdayNames))
        source = trimmed
        minutes = minute.bits
        hours = hour.bits
        daysOfMonth = dom.bits
        months = month.bits
        // 7 is Sunday too.
        daysOfWeek = (dow.bits & 0x7F) | ((dow.bits >> 7) & 1)
        dayOfMonthIsWildcard = dom.wildcard
        dayOfWeekIsWildcard = dow.wildcard
        hourIsWildcard = hour.wildcard
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        do { try self.init(text) } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "\(error)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(source)
    }

    private static func parseField(_ text: String, _ spec: FieldSpec) throws -> (bits: UInt64, wildcard: Bool) {
        var bits: UInt64 = 0
        var wildcard = false
        let elements = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        for element in elements {
            guard !element.isEmpty else {
                throw CronParseError(field: spec.name, message: "empty list element in '\(text)'")
            }
            let stepParts = element.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard stepParts.count <= 2 else {
                throw CronParseError(field: spec.name, message: "more than one '/' in '\(element)'")
            }
            let base = stepParts[0]
            var step = 1
            if stepParts.count == 2 {
                guard let s = Int(stepParts[1]), stepParts[1].allSatisfy(\.isNumber) else {
                    throw CronParseError(field: spec.name, message: "step '\(stepParts[1])' in '\(element)' is not a positive integer")
                }
                guard s > 0 else { throw CronParseError(field: spec.name, message: "step must be greater than 0 in '\(element)'") }
                guard s <= spec.max - spec.min else {
                    throw CronParseError(field: spec.name, message: "step \(s) in '\(element)' exceeds the field range \(spec.min)-\(spec.max)")
                }
                step = s
            }
            var lower: Int, upper: Int
            if base == "*" {
                wildcard = true
                lower = spec.min
                upper = spec.max
            } else if base.contains("-") {
                let bounds = base.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
                guard bounds.count == 2, !bounds[0].isEmpty, !bounds[1].isEmpty else {
                    throw CronParseError(field: spec.name, message: "malformed range '\(base)'")
                }
                lower = try value(bounds[0], spec)
                upper = try value(bounds[1], spec)
                guard lower <= upper else {
                    throw CronParseError(field: spec.name, message: "range start \(lower) is greater than range end \(upper) in '\(base)'")
                }
            } else {
                guard !base.isEmpty else { throw CronParseError(field: spec.name, message: "missing value before '/' in '\(element)'") }
                lower = try value(base, spec)
                // `5/15` means "from 5 to the maximum, every 15".
                upper = stepParts.count == 2 ? spec.max : lower
            }
            var v = lower
            while v <= upper {
                bits |= UInt64(1) << UInt64(v)
                v += step
            }
        }
        return (bits, wildcard)
    }

    private static func value(_ token: String, _ spec: FieldSpec) throws -> Int {
        if let named = spec.names[token.uppercased()] { return named }
        guard !token.isEmpty, token.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(token) else {
            let hint = spec.names.isEmpty ? "" : " (numbers or three-letter names such as \(spec.names.keys.sorted().prefix(2).joined(separator: ", ")))"
            throw CronParseError(field: spec.name, message: "'\(token)' is not a valid value\(hint)")
        }
        guard n >= spec.min, n <= spec.max else {
            throw CronParseError(field: spec.name, message: "value \(n) is out of range \(spec.min)-\(spec.max)")
        }
        return n
    }

    // MARK: Matching

    private static func has(_ bits: UInt64, _ value: Int) -> Bool { bits & (UInt64(1) << UInt64(value)) != 0 }

    /// True when the calendar day matches the month, day-of-month and day-of-week fields. `weekday` is 0 for Sunday.
    func matchesDay(month: Int, day: Int, weekday: Int) -> Bool {
        guard Self.has(months, month) else { return false }
        let dom = Self.has(daysOfMonth, day)
        let dow = Self.has(daysOfWeek, weekday)
        if dayOfMonthIsWildcard || dayOfWeekIsWildcard { return dom && dow }
        return dom || dow
    }

    /// True when the expression fires at the instant `date` (which must fall on a whole minute, or on the first
    /// second after a daylight-saving gap) in `timeZone`.
    public func fires(at date: Date, in timeZone: TimeZone) -> Bool {
        let s = date.timeIntervalSince1970
        guard s == s.rounded(.down) else { return false }
        return nextFireDate(after: Date(timeIntervalSince1970: s - 1), in: timeZone) == date
    }

    // MARK: Next fire date

    /// How many calendar days are scanned before giving up. Eight years covers every satisfiable expression,
    /// including `0 0 29 2 *` across a non-leap century year.
    static let scanDays = 366 * 8 + 3

    /// The first instant strictly after `date` at which the expression fires in `timeZone`, or nil when the expression
    /// can never fire (for example `0 0 30 2 *`). See the type documentation for the daylight-saving rules.
    public func nextFireDate(after date: Date, in timeZone: TimeZone) -> Date? {
        let afterSec = Int(date.timeIntervalSince1970.rounded(.down))
        let localNow = afterSec + timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(afterSec)))
        let startDay = CivilDate.floorDiv(localNow, 86_400) - 1
        for day in startDay...(startDay + Self.scanDays) {
            let (_, m, d) = CivilDate.civil(fromDays: day)
            guard matchesDay(month: m, day: d, weekday: CivilDate.weekday(ofDays: day)) else { continue }
            if let t = firstInstant(onDay: day, after: afterSec, timeZone: timeZone) {
                return Date(timeIntervalSince1970: TimeInterval(t))
            }
        }
        return nil
    }

    /// Fire dates `d` with `start < d <= end`, in ascending order, at most `limit` of them.
    public func fireDates(between start: Date, and end: Date, in timeZone: TimeZone, limit: Int = 1000) -> [Date] {
        var out: [Date] = []
        var cursor = start
        while out.count < limit, let next = nextFireDate(after: cursor, in: timeZone), next <= end {
            out.append(next)
            cursor = next
        }
        return out
    }

    private func firstInstant(onDay day: Int, after afterSec: Int, timeZone tz: TimeZone) -> Int? {
        let dayStart = day * 86_400
        func offset(_ t: Int) -> Int { tz.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(t))) }
        let o = offset(dayStart)
        let uniform = offset(dayStart - 86_400) == o && offset(dayStart + 86_400) == o && offset(dayStart + 172_800) == o
        if uniform {
            // No transition near this local day: every wall-clock time maps to exactly one instant.
            guard dayStart + 86_400 - o > afterSec else { return nil }
            for h in 0..<24 where Self.has(hours, h) {
                let hourStart = dayStart + h * 3600 - o
                guard hourStart + 3600 > afterSec else { continue }
                for m in 0..<60 where Self.has(minutes, m) {
                    let t = hourStart + m * 60
                    if t > afterSec { return t }
                }
            }
            return nil
        }
        var best: Int?
        func consider(_ t: Int) {
            if t > afterSec, best.map({ t < $0 }) ?? true { best = t }
        }
        for h in 0..<24 where Self.has(hours, h) {
            for m in 0..<60 where Self.has(minutes, m) {
                switch LocalTime.resolve(dayStart + h * 3600 + m * 60, in: tz) {
                case .unique(let t):
                    consider(t)
                case .skipped(let firstValid):
                    if !hourIsWildcard { consider(firstValid) }
                case .repeated(let first, let second):
                    consider(first)
                    if hourIsWildcard { consider(second) }
                }
            }
        }
        return best
    }
}

/// Maps a wall-clock time to instants without going through `Calendar`, so gaps and overlaps are explicit.
enum LocalTime {
    enum Resolution: Equatable {
        /// The local time exists exactly once.
        case unique(Int)
        /// The local time does not exist (spring forward); the value is the first valid instant after the gap.
        case skipped(firstValidInstant: Int)
        /// The local time exists twice (fall back).
        case repeated(first: Int, second: Int)
    }

    /// `local` is the wall-clock time expressed as seconds since 1970-01-01 00:00 **local**.
    static func resolve(_ local: Int, in tz: TimeZone) -> Resolution {
        func offset(_ t: Int) -> Int { tz.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(t))) }
        var offsets: [Int] = []
        for sample in [local - 86_400, local, local + 86_400] {
            let o = offset(sample)
            if !offsets.contains(o) { offsets.append(o) }
        }
        let valid = offsets.map { local - $0 }.filter { offset($0) == local - $0 }.sorted()
        if valid.count == 1 { return .unique(valid[0]) }
        if valid.count >= 2 { return .repeated(first: valid[0], second: valid[valid.count - 1]) }
        guard offsets.count >= 2, let maxOffset = offsets.max(), let minOffset = offsets.min() else {
            return .unique(local - offsets[0])
        }
        // In a gap: `lo` is before the transition, `hi` is at or after it. Find the transition instant.
        var lo = local - maxOffset
        var hi = local - minOffset
        let before = offset(lo)
        guard offset(hi) != before else { return .unique(hi) }
        while hi - lo > 1 {
            let mid = lo + (hi - lo) / 2
            if offset(mid) == before { lo = mid } else { hi = mid }
        }
        return .skipped(firstValidInstant: hi)
    }
}

/// Proleptic Gregorian day arithmetic (days since 1970-01-01).
enum CivilDate {
    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    static func days(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = floorDiv(y, 400)
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(fromDays days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = floorDiv(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    /// 0 = Sunday. 1970-01-01 was a Thursday.
    static func weekday(ofDays days: Int) -> Int {
        let r = (days + 4) % 7
        return r < 0 ? r + 7 : r
    }
}
