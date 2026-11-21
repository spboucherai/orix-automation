// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureRuns/Sources/ORIXFeatureRuns/SchedulerLogic.swift
// Description      : Scheduler view logic without UI: the seven-day agenda
//                    computed from each schedule's own time zone, and the
//                    editable draft behind the schedule editor.
// Module           : ORIXFeatureRuns
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
import ORIXAppUI

/// What one schedule does on one day of the agenda.
public struct AgendaItem: Identifiable, Sendable, Hashable {
    public var scheduleID: String
    public var name: String
    /// Zone the schedule is evaluated in (nil: the Mac's zone).
    public var timezone: String?
    /// The first fire times of the day (at most `AgendaBuilder.shownPerDay`).
    public var times: [Date]
    /// How many times it fires that day in total.
    public var total: Int
    public var last: Date
    public var id: String { "\(scheduleID)@\(times.first?.timeIntervalSince1970 ?? 0)" }
}

public struct AgendaDay: Identifiable, Sendable, Hashable {
    public var start: Date
    public var items: [AgendaItem]
    public var id: Date { start }
}

public enum AgendaBuilder {
    public static let shownPerDay = 4
    /// Upper bound of fire times computed per schedule, so "every minute" cannot stall the screen.
    public static let perScheduleCap = 3000

    /// Every fire time of one schedule in `start < t <= end`, computed in the schedule's own zone (DST rules of `CronExpression`).
    public static func fireDates(_ schedule: Schedule, after start: Date, through end: Date, cap: Int = perScheduleCap) -> (dates: [Date], truncated: Bool) {
        switch schedule.trigger {
        case .cron(let expression, let timezone):
            guard let cron = try? CronExpression(expression), let zone = timezone.map({ TimeZone(identifier: $0) }) ?? TimeZone.current else { return ([], false) }
            let dates = cron.fireDates(between: start, and: end, in: zone, limit: cap + 1)
            return (Array(dates.prefix(cap)), dates.count > cap)
        case .once, .interval:
            var out: [Date] = []
            var cursor = start
            while let next = schedule.trigger.nextFireDate(after: cursor, anchor: schedule.createdAt), next <= end {
                if out.count == cap { return (out, true) }
                out.append(next); cursor = next
            }
            return (out, false)
        default:
            return ([], false)
        }
    }

    /// A day-by-day agenda for the `days` days starting at `now`. Days are those of `calendar` (the Mac's zone in the app);
    /// the instants themselves come from each schedule's zone. Only enabled, unpaused, time-based schedules appear.
    public static func build(schedules: [Schedule], from now: Date, days: Int = 7, calendar: Calendar = .current) -> (days: [AgendaDay], truncated: [String]) {
        let firstDay = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: days, to: firstDay) else { return ([], []) }
        var buckets: [Date: [AgendaItem]] = [:]
        var truncated: [String] = []
        for s in schedules where s.enabled && !s.paused && s.trigger.isTimeBased {
            let (dates, cut) = fireDates(s, after: now, through: end.addingTimeInterval(-1))
            if cut { truncated.append(s.name) }
            var zone: String?
            if case .cron(_, let tz) = s.trigger { zone = tz }
            for (day, group) in Dictionary(grouping: dates, by: { calendar.startOfDay(for: $0) }) {
                let sorted = group.sorted()
                buckets[day, default: []].append(AgendaItem(scheduleID: s.id, name: s.name, timezone: zone, times: Array(sorted.prefix(shownPerDay)),
                                                            total: sorted.count, last: sorted.last ?? day))
            }
        }
        var out: [AgendaDay] = []
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { continue }
            let start = calendar.startOfDay(for: day)
            out.append(AgendaDay(start: start, items: (buckets[start] ?? []).sorted { ($0.times.first ?? .distantFuture, $0.name) < ($1.times.first ?? .distantFuture, $1.name) }))
        }
        return (out, truncated)
    }

    /// "09:00": the wall-clock time of an instant in a zone (24-hour, so columns line up).
    public static func clock(_ date: Date, in zone: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "HH:mm"; f.timeZone = zone
        return f.string(from: date)
    }

    /// The schedule's own zone when its clock differs from the local one at that instant; nil when they agree.
    public static func foreignZone(_ item: AgendaItem, local: TimeZone = .current) -> TimeZone? {
        guard let id = item.timezone, let tz = TimeZone(identifier: id), let first = item.times.first,
              tz.secondsFromGMT(for: first) != local.secondsFromGMT(for: first) else { return nil }
        return tz
    }
}

/// Everything the schedule editor edits, as plain values. `makeSchedule` produces the record to save.
public struct ScheduleDraft: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case cron, once, interval, fileChange, login, appLaunch, powerConnected, networkAvailable
        public var id: String { rawValue }
    }
    public enum BuilderShape: String, CaseIterable, Identifiable, Sendable {
        case minutes, hourly, daily, weekdays, weekly, monthly
        public var id: String { rawValue }
    }
    public enum IntervalUnit: Double, CaseIterable, Identifiable, Sendable {
        case seconds = 1, minutes = 60, hours = 3600, days = 86_400
        public var id: Double { rawValue }
    }
    public enum Missed: String, CaseIterable, Identifiable, Sendable { case skip, runOnce, runAll; public var id: String { rawValue } }
    public enum Concurrency: String, CaseIterable, Identifiable, Sendable { case skipIfRunning, queue, parallel; public var id: String { rawValue } }

    public var workflowID = ""
    public var name = ""
    public var kind: Kind = .cron
    public var useRawCron = false
    public var rawCron = "0 9 * * 1"
    public var shape: BuilderShape = .weekly
    public var everyMinutes = 15
    public var hour = 9
    public var minute = 0
    public var weekdays: Set<Int> = [1]
    public var dayOfMonth = 1
    /// Empty means the Mac's current time zone.
    public var timezone = ""
    public var onceAt = Date().addingTimeInterval(3600)
    public var intervalValue: Double = 30
    public var intervalUnit: IntervalUnit = .minutes
    public var path = ""
    public var glob = ""
    public var recursive = true
    public var debounce: Double = 2
    public var bundleID = ""
    public var missed: Missed = .skip
    public var missedMax = 3
    public var concurrency: Concurrency = .skipIfRunning
    public var parallelMax = 2
    public var maxRetries = 0
    public var backoff: Double = 30
    public var enabled = false

    public init() {}

    public init(schedule s: Schedule) {
        workflowID = s.workflowID; name = s.name; enabled = s.enabled
        maxRetries = s.maxRetries; backoff = s.retryBackoffSeconds
        switch s.missedRunPolicy {
        case .skip: missed = .skip
        case .runOnce: missed = .runOnce
        case .runAll(let m): missed = .runAll; missedMax = m
        }
        switch s.concurrency {
        case .skipIfRunning: concurrency = .skipIfRunning
        case .queue: concurrency = .queue
        case .parallel(let m): concurrency = .parallel; parallelMax = m
        }
        switch s.trigger {
        case .cron(let e, let tz):
            kind = .cron; rawCron = e; timezone = tz ?? ""
            if let preset = CronPreset.match(e) { apply(preset) } else { useRawCron = true }
        case .once(let at): kind = .once; onceAt = at
        case .interval(let seconds):
            kind = .interval
            let unit = IntervalUnit.allCases.reversed().first { seconds >= $0.rawValue && seconds.truncatingRemainder(dividingBy: $0.rawValue) == 0 } ?? .seconds
            intervalUnit = unit; intervalValue = seconds / unit.rawValue
        case .fileChange(let p, let r, let g, let d): kind = .fileChange; path = p; recursive = r; glob = g ?? ""; debounce = d
        case .login: kind = .login
        case .appLaunch(let b): kind = .appLaunch; bundleID = b
        case .powerConnected: kind = .powerConnected
        case .networkAvailable: kind = .networkAvailable
        case .manual: kind = .cron
        }
    }

    mutating func apply(_ preset: CronPreset) {
        useRawCron = false
        switch preset {
        case .everyMinutes(let n): shape = .minutes; everyMinutes = n
        case .hourly(let m): shape = .hourly; minute = m
        case .daily(let h, let m): shape = .daily; hour = h; minute = m
        case .weekdays(let h, let m): shape = .weekdays; hour = h; minute = m
        case .weekly(let d, let h, let m): shape = .weekly; weekdays = d; hour = h; minute = m
        case .monthly(let d, let h, let m): shape = .monthly; dayOfMonth = d; hour = h; minute = m
        }
    }

    public var preset: CronPreset {
        switch shape {
        case .minutes: return .everyMinutes(everyMinutes)
        case .hourly: return .hourly(minute: minute)
        case .daily: return .daily(hour: hour, minute: minute)
        case .weekdays: return .weekdays(hour: hour, minute: minute)
        case .weekly: return .weekly(days: weekdays, hour: hour, minute: minute)
        case .monthly: return .monthly(day: dayOfMonth, hour: hour, minute: minute)
        }
    }

    /// The cron text that will be saved: the raw field, or what the builder produces.
    public var cronExpression: String { useRawCron ? rawCron.trimmingCharacters(in: .whitespaces) : preset.expression }

    public var trigger: TriggerSpec {
        switch kind {
        case .cron: return .cron(expression: cronExpression, timezone: timezone.isEmpty ? nil : timezone)
        case .once: return .once(at: onceAt)
        case .interval: return .interval(seconds: intervalValue * intervalUnit.rawValue)
        case .fileChange: return .fileChange(path: path, recursive: recursive, glob: glob.isEmpty ? nil : glob, debounceSeconds: debounce)
        case .login: return .login
        case .appLaunch: return .appLaunch(bundleID: bundleID.trimmingCharacters(in: .whitespaces))
        case .powerConnected: return .powerConnected
        case .networkAvailable: return .networkAvailable
        }
    }

    public func makeSchedule(existing: Schedule?) -> Schedule {
        var s = existing ?? Schedule(workflowID: workflowID, name: name, trigger: trigger, enabled: enabled)
        s.workflowID = workflowID; s.name = name; s.trigger = trigger; s.enabled = enabled
        s.maxRetries = maxRetries; s.retryBackoffSeconds = backoff
        switch missed {
        case .skip: s.missedRunPolicy = .skip
        case .runOnce: s.missedRunPolicy = .runOnce
        case .runAll: s.missedRunPolicy = .runAll(max: missedMax)
        }
        switch concurrency {
        case .skipIfRunning: s.concurrency = .skipIfRunning
        case .queue: s.concurrency = .queue
        case .parallel: s.concurrency = .parallel(max: parallelMax)
        }
        return s
    }

    /// Why the draft cannot be saved yet, in plain words. Empty means it can.
    public func problems(now: Date = Date()) -> [String] {
        var out: [String] = []
        if workflowID.isEmpty { out.append(String(localized: "Choose a workflow.")) }
        switch kind {
        case .cron:
            if case .failure(let message) = cronPreview(now: now) { out.append(message) }
            if !useRawCron, shape == .weekly, weekdays.isEmpty { out.append(String(localized: "Choose at least one day of the week.")) }
        case .once:
            if onceAt <= now { out.append(String(localized: "The date is in the past: it would never run.")) }
        case .interval:
            if intervalValue * intervalUnit.rawValue < 1 { out.append(String(localized: "The interval must be at least one second.")) }
        case .fileChange:
            if path.trimmingCharacters(in: .whitespaces).isEmpty { out.append(String(localized: "Choose the folder to watch.")) }
        case .appLaunch:
            if bundleID.trimmingCharacters(in: .whitespaces).isEmpty { out.append(String(localized: "Choose the application.")) }
        case .login, .powerConnected, .networkAvailable: break
        }
        if case .runAll = makeSchedule(existing: nil).missedRunPolicy, missedMax < 1 { out.append(String(localized: "Catch-up needs at least one run.")) }
        return out
    }

    /// The next `count` fire times of the cron expression in the chosen zone, or the parser's message.
    public func cronPreview(now: Date = Date(), count: Int = 5) -> Result<[Date], CronPreviewError> {
        let zone: TimeZone
        if timezone.isEmpty { zone = .current }
        else if let z = TimeZone(identifier: timezone) { zone = z }
        else { return .failure(CronPreviewError(String(localized: "Unknown time zone “\(timezone)”."))) }
        do {
            let cron = try CronExpression(cronExpression)
            var out: [Date] = []
            var cursor = now
            while out.count < count, let next = cron.nextFireDate(after: cursor, in: zone) { out.append(next); cursor = next }
            if out.isEmpty { return .failure(CronPreviewError(String(localized: "This schedule never fires (the date does not exist)."))) }
            return .success(out)
        } catch let e as CronParseError {
            return .failure(CronPreviewError(e.field.map { String(localized: "Problem in the \($0) field: \(e.message)") } ?? e.message))
        } catch {
            return .failure(CronPreviewError(error.localizedDescription))
        }
    }
}

public struct CronPreviewError: Error, Equatable, Sendable, CustomStringConvertible {
    public let description: String
    init(_ text: String) { description = text }
}

extension Array where Element == String {
    mutating func append(_ e: CronPreviewError) { append(e.description) }
}
