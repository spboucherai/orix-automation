// ORIX OS Automation
// File: Packages/ORIXFeatureRuns/Sources/ORIXFeatureRuns/TriggerDescription.swift
// Description: Turns a trigger (cron expression, interval, file watcher, system event) into a plain sentence, and describes missed-run and concurrency policies.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import Foundation
import ORIXAppUI

/// Plain-language descriptions of triggers and policies. Pure functions: the same input always gives the same sentence.
public enum TriggerDescriber {
    /// The language the app is shown in (not the system region), so day and month names match the sentence around them.
    public static var appLocale: Locale { Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en") }

    /// A sentence such as "Every Monday at 09:00 (America/Toronto)" or "When files change in ~/Documents/Research".
    public static func describe(_ trigger: TriggerSpec, locale: Locale = TriggerDescriber.appLocale) -> String {
        switch trigger {
        case .cron(let expression, let timezone):
            let zone = timezone ?? String(localized: "this Mac's time zone")
            guard let sentence = describeCron(expression, locale: locale) else {
                return String(localized: "Invalid schedule “\(expression)”")
            }
            return "\(sentence) (\(zone))"
        case .once(let at):
            return String(localized: "Once, on \(at.formatted(date: .abbreviated, time: .shortened))")
        case .interval(let seconds):
            return describeInterval(seconds)
        case .fileChange(let path, let recursive, let glob, _):
            let shown = PathResolver.display(path)
            let base: String
            if let glob, !glob.isEmpty { base = String(localized: "When files matching \(glob) change in \(shown)") }
            else { base = String(localized: "When files change in \(shown)") }
            return recursive ? base : String(localized: "\(base) (top level only)")
        case .login:
            return String(localized: "When you log in")
        case .appLaunch(let bundleID):
            return String(localized: "When \(appName(bundleID: bundleID)) opens")
        case .powerConnected:
            return String(localized: "When the power adapter is connected")
        case .networkAvailable:
            return String(localized: "When the network becomes available")
        case .manual:
            return String(localized: "Only when started by hand")
        }
    }

    public static func symbol(_ trigger: TriggerSpec) -> String {
        switch trigger {
        case .cron: return "calendar.badge.clock"
        case .once: return "1.circle"
        case .interval: return "timer"
        case .fileChange: return "folder.badge.gearshape"
        case .login: return "person.crop.circle.badge.checkmark"
        case .appLaunch: return "macwindow.badge.plus"
        case .powerConnected: return "powerplug"
        case .networkAvailable: return "wifi"
        case .manual: return "hand.tap"
        }
    }

    /// The display name of an installed application, or the bundle identifier when it is not installed.
    public static func appName(bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    public static func describeInterval(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 86_400, s % 86_400 == 0 { let n = s / 86_400; return n == 1 ? String(localized: "Every day (24 hours after the previous run time)") : String(localized: "Every \(n) days") }
        if s >= 3600, s % 3600 == 0 { let n = s / 3600; return n == 1 ? String(localized: "Every hour") : String(localized: "Every \(n) hours") }
        if s >= 60, s % 60 == 0 { let n = s / 60; return n == 1 ? String(localized: "Every minute") : String(localized: "Every \(n) minutes") }
        return s == 1 ? String(localized: "Every second") : String(localized: "Every \(s) seconds")
    }

    public static func describe(_ policy: MissedRunPolicy) -> String {
        switch policy {
        case .skip: return String(localized: "Skip missed runs")
        case .runOnce: return String(localized: "Run once for the latest missed time")
        case .runAll(let max): return String(localized: "Catch up, at most \(max) missed runs")
        }
    }

    public static func describe(_ policy: ConcurrencyPolicy) -> String {
        switch policy {
        case .skipIfRunning: return String(localized: "Skip if still running")
        case .queue: return String(localized: "Wait for the running one")
        case .parallel(let max): return String(localized: "Up to \(max) at the same time")
        }
    }

    // MARK: Cron

    /// One parsed cron field: a wildcard, a step over the whole range, or an explicit sorted set of values.
    enum Field: Equatable {
        case any
        case step(Int)
        case values([Int])
    }

    static let macros: [String: String] = [
        "@hourly": "0 * * * *", "@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@weekly": "0 0 * * 0",
        "@monthly": "0 0 1 * *", "@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *",
    ]
    static let monthNames = ["JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6, "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12]
    static let dayNames = ["SUN": 0, "MON": 1, "TUE": 2, "WED": 3, "THU": 4, "FRI": 5, "SAT": 6]

    static func parseField(_ text: String, min: Int, max: Int, names: [String: Int] = [:], wrapSeven: Bool = false) -> Field? {
        if text == "*" { return .any }
        if text.hasPrefix("*/"), let n = Int(text.dropFirst(2)), n > 0 { return n == 1 ? .any : .step(n) }
        func number(_ s: Substring) -> Int? {
            if let v = names[s.uppercased()] { return v }
            guard let v = Int(s) else { return nil }
            return wrapSeven && v == 7 ? 0 : v
        }
        var out = Set<Int>()
        for part in text.split(separator: ",") {
            let pieces = part.split(separator: "/", maxSplits: 1)
            let step = pieces.count == 2 ? Int(pieces[1]) : 1
            guard let step, step > 0, let rangeText = pieces.first else { return nil }
            let bounds = rangeText.split(separator: "-", maxSplits: 1)
            var lo: Int, hi: Int
            if rangeText == "*" { lo = min; hi = max }
            else if bounds.count == 2, let a = number(bounds[0]), let b = number(bounds[1]) {
                lo = a; hi = b
                if wrapSeven, bounds[1] == "7" { hi = 7 }
            } else if let a = number(bounds[0]) { lo = a; hi = pieces.count == 2 ? max : a }
            else { return nil }
            guard lo <= hi else { return nil }
            var v = lo
            while v <= hi { out.insert(wrapSeven && v == 7 ? 0 : v); v += step }
        }
        return out.isEmpty ? nil : .values(out.sorted())
    }

    static func clock(_ hour: Int, _ minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }

    static func list(_ items: [String], locale: Locale) -> String {
        let f = ListFormatter(); f.locale = locale
        return f.string(from: items) ?? items.joined(separator: ", ")
    }

    /// A sentence for a 5-field cron expression (or macro), without the time zone. Nil when the expression is not valid.
    public static func describeCron(_ expression: String, locale: Locale = TriggerDescriber.appLocale) -> String? {
        guard (try? CronExpression(expression)) != nil else { return nil }
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        let source = macros[trimmed.lowercased()] ?? trimmed
        let f = source.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard f.count == 5,
              let minute = parseField(f[0], min: 0, max: 59), let hour = parseField(f[1], min: 0, max: 23),
              let dom = parseField(f[2], min: 1, max: 31), let month = parseField(f[3], min: 1, max: 12, names: monthNames),
              let dow = parseField(f[4], min: 0, max: 6, names: dayNames, wrapSeven: true)
        else { return String(localized: "On the schedule “\(trimmed)”") }

        var calendar = Calendar(identifier: .gregorian); calendar.locale = locale
        let weekdays = calendar.weekdaySymbols, months = calendar.monthSymbols

        // Time of day.
        var time: String
        var periodic = true   // true when the time part is "every …" rather than fixed clock times
        switch (minute, hour) {
        case (.any, .any): time = String(localized: "every minute")
        case (.step(let n), .any): time = String(localized: "every \(n) minutes")
        case (.values(let m), .any) where m.count == 1:
            time = m[0] == 0 ? String(localized: "every hour, on the hour") : String(localized: "every hour at minute \(m[0])")
        case (.values(let m), .step(let n)) where m.count == 1:
            time = String(localized: "every \(n) hours at minute \(m[0])")
        case (.values(let m), .values(let h)) where m.count * h.count <= 4:
            let times = h.flatMap { hh in m.map { clock(hh, $0) } }
            time = String(localized: "at \(list(times, locale: locale))"); periodic = false
        case (.values(let m), .values(let h)) where m.count == 1 && isContiguous(h):
            time = String(localized: "every hour from \(clock(h.first!, m[0])) to \(clock(h.last!, m[0]))")
        case (.any, .values(let h)) where isContiguous(h):
            time = String(localized: "every minute from \(clock(h.first!, 0)) to \(clock(h.last!, 59))")
        case (.step(let n), .values(let h)) where isContiguous(h):
            time = String(localized: "every \(n) minutes from \(clock(h.first!, 0)) to \(clock(h.last!, 59))")
        default:
            return String(localized: "On the schedule “\(trimmed)”")
        }

        // Days.
        func dayNamesList(_ d: [Int]) -> String { list(d.map { weekdays[$0] }, locale: locale) }
        func numbers(_ d: [Int]) -> String { list(d.map(String.init), locale: locale) }
        var day: String
        var everyDay = false
        switch (dom, dow) {
        case (.any, .any): day = String(localized: "Every day"); everyDay = true
        case (.any, .values(let d)) where d == [1, 2, 3, 4, 5]: day = String(localized: "Every weekday")
        case (.any, .values(let d)) where d.count == 7: day = String(localized: "Every day"); everyDay = true
        case (.any, .values(let d)): day = String(localized: "Every \(dayNamesList(d))")
        case (.values(let d), .any):
            if case .values(let m) = month, m.count == 1, d.count == 1 {
                day = String(localized: "Every year on \(months[m[0] - 1]) \(d[0])")
                return String(localized: "\(day) \(time)")
            }
            day = d.count == 1 ? String(localized: "On day \(d[0]) of every month") : String(localized: "On days \(numbers(d)) of every month")
        case (.step(let n), .any): day = String(localized: "Every \(n) days of the month")
        case (.values(let d), .values(let w)):
            day = String(localized: "On day \(numbers(d)) of the month or every \(dayNamesList(w))")
        default:
            return String(localized: "On the schedule “\(trimmed)”")
        }
        switch month {
        case .any: break
        case .values(let m): day = String(localized: "\(day) in \(list(m.map { months[$0 - 1] }, locale: locale))")
        case .step(let n): day = String(localized: "\(day), every \(n) months")
        }
        if everyDay, periodic, month == .any { return time.prefix(1).uppercased() + time.dropFirst() }
        return periodic ? String(localized: "\(day), \(time)") : String(localized: "\(day) \(time)")
    }

    static func isContiguous(_ v: [Int]) -> Bool { v.count > 1 && v.last! - v.first! == v.count - 1 }
}

/// The friendly cron builder: common cases a person can pick without knowing cron syntax.
public enum CronPreset: Equatable, Sendable {
    case everyMinutes(Int)
    case hourly(minute: Int)
    case daily(hour: Int, minute: Int)
    case weekdays(hour: Int, minute: Int)
    /// Days use cron numbering: 0 = Sunday … 6 = Saturday.
    case weekly(days: Set<Int>, hour: Int, minute: Int)
    case monthly(day: Int, hour: Int, minute: Int)

    public var expression: String {
        switch self {
        case .everyMinutes(let n): return n <= 1 ? "* * * * *" : "*/\(n) * * * *"
        case .hourly(let m): return "\(m) * * * *"
        case .daily(let h, let m): return "\(m) \(h) * * *"
        case .weekdays(let h, let m): return "\(m) \(h) * * 1-5"
        case .weekly(let days, let h, let m): return "\(m) \(h) * * \(days.isEmpty ? "*" : days.sorted().map(String.init).joined(separator: ","))"
        case .monthly(let d, let h, let m): return "\(m) \(h) \(d) * *"
        }
    }

    /// Recognises an expression the builder can show; nil means "use the raw field".
    public static func match(_ expression: String) -> CronPreset? {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        let f = (TriggerDescriber.macros[trimmed.lowercased()] ?? trimmed).split(separator: " ").map(String.init)
        guard f.count == 5, f[3] == "*" else { return nil }
        let minute = Int(f[0]), hour = Int(f[1])
        if f[1] == "*", f[2] == "*", f[4] == "*" {
            if f[0] == "*" { return .everyMinutes(1) }
            if f[0].hasPrefix("*/"), let n = Int(f[0].dropFirst(2)), n > 0 { return .everyMinutes(n) }
            if let minute { return .hourly(minute: minute) }
            return nil
        }
        guard let minute, let hour else { return nil }
        if f[2] == "*", f[4] == "*" { return .daily(hour: hour, minute: minute) }
        if f[2] == "*" {
            if f[4] == "1-5" || f[4].uppercased() == "MON-FRI" { return .weekdays(hour: hour, minute: minute) }
            guard case .values(let d)? = TriggerDescriber.parseField(f[4], min: 0, max: 6, names: TriggerDescriber.dayNames, wrapSeven: true) else { return nil }
            return .weekly(days: Set(d), hour: hour, minute: minute)
        }
        if f[4] == "*", let d = Int(f[2]) { return .monthly(day: d, hour: hour, minute: minute) }
        return nil
    }
}
