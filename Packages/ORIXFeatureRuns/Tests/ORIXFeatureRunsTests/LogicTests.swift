// ORIX OS Automation
// File: Packages/ORIXFeatureRuns/Tests/ORIXFeatureRunsTests/LogicTests.swift
// Description: Unit tests of the pure logic: trigger sentences, cron builder, agenda across daylight-saving changes, schedule drafts, console buffer and assembler, export formats, metric aggregation.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXAppUI
@testable import ORIXFeatureRuns
import Testing

private let en = Locale(identifier: "en_US")

@Suite("Unit · trigger descriptions")
struct TriggerDescriptionTests {
    @Test(arguments: [
        ("* * * * *", "Every minute"),
        ("*/5 * * * *", "Every 5 minutes"),
        ("0 * * * *", "Every hour, on the hour"),
        ("30 * * * *", "Every hour at minute 30"),
        ("@hourly", "Every hour, on the hour"),
        ("15 */2 * * *", "Every 2 hours at minute 15"),
        ("0 9 * * *", "Every day at 09:00"),
        ("@daily", "Every day at 00:00"),
        ("30 7,18 * * *", "Every day at 07:30 and 18:30"),
        ("0 9 * * MON", "Every Monday at 09:00"),
        ("0 9 * * 1", "Every Monday at 09:00"),
        ("0 9 * * 1-5", "Every weekday at 09:00"),
        ("0 9 * * MON-FRI", "Every weekday at 09:00"),
        ("0 8 * * 1,3,5", "Every Monday, Wednesday, and Friday at 08:00"),
        ("0 10 * * 6,0", "Every Sunday and Saturday at 10:00"),
        ("0 10 * * 7", "Every Sunday at 10:00"),
        ("@weekly", "Every Sunday at 00:00"),
        ("0 6 1 * *", "On day 1 of every month at 06:00"),
        ("0 6 1,15 * *", "On days 1 and 15 of every month at 06:00"),
        ("@monthly", "On day 1 of every month at 00:00"),
        ("0 0 1 1 *", "Every year on January 1 at 00:00"),
        ("0 12 25 DEC *", "Every year on December 25 at 12:00"),
        ("0 9 * 1,7 *", "Every day in January and July at 09:00"),
        ("0 9-17 * * 1-5", "Every weekday, every hour from 09:00 to 17:00"),
        ("*/15 9-17 * * *", "Every 15 minutes from 09:00 to 17:59"),
        ("0 9 13 * 5", "On day 13 of the month or every Friday at 09:00"),
        ("*/10 * * * 1-5", "Every weekday, every 10 minutes"),
    ])
    func cronShapes(expression: String, expected: String) {
        #expect(TriggerDescriber.describeCron(expression, locale: en) == expected)
    }

    @Test func invalidCronIsRefusedNotGuessed() {
        #expect(TriggerDescriber.describeCron("61 * * * *", locale: en) == nil)
        #expect(TriggerDescriber.describeCron("not cron", locale: en) == nil)
        #expect(TriggerDescriber.describe(.cron(expression: "bad", timezone: nil), locale: en).contains("Invalid schedule"))
    }

    @Test func fullSentencesCarryZoneAndPath() {
        #expect(TriggerDescriber.describe(.cron(expression: "0 9 * * MON", timezone: "America/Toronto"), locale: en) == "Every Monday at 09:00 (America/Toronto)")
        #expect(TriggerDescriber.describe(.cron(expression: "0 9 * * *", timezone: nil), locale: en) == "Every day at 09:00 (this Mac's time zone)")
        let folder = NSHomeDirectory() + "/Documents/Research"
        #expect(TriggerDescriber.describe(.fileChange(path: folder, recursive: true, glob: nil, debounceSeconds: 2), locale: en) == "When files change in ~/Documents/Research")
        #expect(TriggerDescriber.describe(.fileChange(path: folder, recursive: true, glob: "*.pdf", debounceSeconds: 2), locale: en) == "When files matching *.pdf change in ~/Documents/Research")
        #expect(TriggerDescriber.describe(.fileChange(path: folder, recursive: false, glob: nil, debounceSeconds: 2), locale: en).hasSuffix("(top level only)"))
        #expect(TriggerDescriber.describe(.login) == "When you log in")
        #expect(TriggerDescriber.describe(.powerConnected) == "When the power adapter is connected")
        #expect(TriggerDescriber.describe(.networkAvailable) == "When the network becomes available")
        #expect(TriggerDescriber.describe(.appLaunch(bundleID: "example.not.installed")) == "When example.not.installed opens")
    }

    @Test func intervalsUseTheLargestWholeUnit() {
        #expect(TriggerDescriber.describeInterval(45) == "Every 45 seconds")
        #expect(TriggerDescriber.describeInterval(60) == "Every minute")
        #expect(TriggerDescriber.describeInterval(1800) == "Every 30 minutes")
        #expect(TriggerDescriber.describeInterval(7200) == "Every 2 hours")
        #expect(TriggerDescriber.describeInterval(172_800) == "Every 2 days")
        #expect(TriggerDescriber.describeInterval(90) == "Every 90 seconds")
    }

    @Test func policiesInPlainWords() {
        #expect(TriggerDescriber.describe(MissedRunPolicy.runAll(max: 3)) == "Catch up, at most 3 missed runs")
        #expect(TriggerDescriber.describe(ConcurrencyPolicy.parallel(max: 2)) == "Up to 2 at the same time")
    }

    @Test func presetsRoundTripThroughCron() throws {
        let presets: [CronPreset] = [.everyMinutes(1), .everyMinutes(15), .hourly(minute: 20), .daily(hour: 9, minute: 5), .weekdays(hour: 8, minute: 0),
                                     .weekly(days: [1, 3], hour: 18, minute: 30), .monthly(day: 15, hour: 6, minute: 0)]
        for p in presets {
            _ = try CronExpression(p.expression)
            #expect(CronPreset.match(p.expression) == p, "\(p.expression)")
        }
        #expect(CronPreset.match("0 9 * * MON") == .weekly(days: [1], hour: 9, minute: 0))
        #expect(CronPreset.match("0 9 1 1 *") == nil)
        #expect(CronPreset.match("*/5 9-17 * * *") == nil)
    }
}

@Suite("Unit · agenda and schedule drafts")
struct AgendaTests {
    let toronto = TimeZone(identifier: "America/Toronto")!

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, zone: TimeZone) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = zone
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func dailyJobKeepsItsWallClockAcrossFallBack() {
        // America/Toronto leaves daylight time on 2026-11-01: 09:00 local is 13:00 UTC before and 14:00 UTC after.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = toronto
        let s = Schedule(id: "a", workflowID: "w", name: "Morning", trigger: .cron(expression: "0 9 * * *", timezone: "America/Toronto"))
        let (days, truncated) = AgendaBuilder.build(schedules: [s], from: date(2026, 10, 30, 12, zone: toronto), days: 7, calendar: cal)
        #expect(truncated.isEmpty)
        #expect(days.count == 7)
        #expect(days[0].items.isEmpty)   // 09:00 on the 30th already passed at noon
        let fires = days.flatMap(\.items).flatMap(\.times)
        #expect(fires.count == 6)
        for f in fires { #expect(AgendaBuilder.clock(f, in: toronto) == "09:00") }
        let gaps = zip(fires, fires.dropFirst()).map { $1.timeIntervalSince($0) / 3600 }
        #expect(gaps == [25, 24, 24, 24, 24])   // one 25-hour day: the clocks went back
    }

    @Test func springForwardFiresOnceAfterTheGap() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = toronto
        // 02:30 does not exist on 2026-03-08 in Toronto.
        let s = Schedule(id: "a", workflowID: "w", name: "Night", trigger: .cron(expression: "30 2 * * *", timezone: "America/Toronto"))
        let (days, _) = AgendaBuilder.build(schedules: [s], from: date(2026, 3, 7, 0, zone: toronto), days: 3, calendar: cal)
        #expect(days.map { $0.items.first?.total ?? 0 } == [1, 1, 1])
        #expect(days.map { $0.items.first.map { AgendaBuilder.clock($0.times[0], in: toronto) } ?? "" } == ["02:30", "03:00", "02:30"])
    }

    @Test func scheduleInAnotherZoneLandsOnTheLocalDayAndShowsBothClocks() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = toronto
        // 07:30 in Paris is 01:30 in Toronto the same day; 02:00 in Paris is 20:00 the day before.
        let paris = Schedule(id: "p", workflowID: "w", name: "Paris", trigger: .cron(expression: "30 7 * * *", timezone: "Europe/Paris"))
        let early = Schedule(id: "e", workflowID: "w", name: "Early", trigger: .cron(expression: "0 2 * * *", timezone: "Europe/Paris"))
        let (days, _) = AgendaBuilder.build(schedules: [paris, early], from: date(2026, 11, 21, 12, zone: toronto), days: 2, calendar: cal)
        #expect(days[0].items.map(\.name) == ["Early"])
        #expect(AgendaBuilder.clock(days[0].items[0].times[0], in: toronto) == "20:00")
        #expect(days[1].items.map(\.name) == ["Paris", "Early"])
        let item = days[1].items[0]
        #expect(AgendaBuilder.foreignZone(item, local: toronto)?.identifier == "Europe/Paris")
        let same = AgendaItem(scheduleID: "x", name: "x", timezone: "America/Toronto", times: item.times, total: 1, last: item.last)
        #expect(AgendaBuilder.foreignZone(same, local: toronto) == nil)
    }

    @Test func frequentAndDisabledSchedulesAreBounded() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = toronto
        let now = date(2026, 6, 1, 0, zone: toronto)
        let minute = Schedule(id: "m", workflowID: "w", name: "Minute", trigger: .cron(expression: "* * * * *", timezone: "America/Toronto"))
        let off = Schedule(id: "o", workflowID: "w", name: "Off", trigger: .cron(expression: "0 9 * * *", timezone: nil), enabled: false)
        let paused = Schedule(id: "p", workflowID: "w", name: "Paused", trigger: .cron(expression: "0 9 * * *", timezone: nil), paused: true)
        let event = Schedule(id: "l", workflowID: "w", name: "Login", trigger: .login)
        let interval = Schedule(id: "i", workflowID: "w", name: "Interval", trigger: .interval(seconds: 6 * 3600), createdAt: now)
        let once = Schedule(id: "1", workflowID: "w", name: "Once", trigger: .once(at: now.addingTimeInterval(30 * 3600)))
        let (days, truncated) = AgendaBuilder.build(schedules: [minute, off, paused, event, interval, once], from: now, days: 7, calendar: cal)
        #expect(truncated == ["Minute"])
        #expect(Set(days.flatMap(\.items).map(\.name)) == ["Minute", "Interval", "Once"])
        let first = days[0].items.first { $0.name == "Minute" }!
        #expect(first.times.count == AgendaBuilder.shownPerDay)
        #expect(first.total == 1439)
        #expect(days[0].items.first { $0.name == "Interval" }?.total == 3)   // 06:00, 12:00, 18:00 (midnight belongs to the next day)
        #expect(days[1].items.contains { $0.name == "Once" })
    }

    @Test func draftRoundTripsEveryTriggerKind() {
        let triggers: [TriggerSpec] = [
            .cron(expression: "0 9 * * 1", timezone: "America/Toronto"), .cron(expression: "*/7 3-5 * * *", timezone: nil),
            .once(at: Date(timeIntervalSince1970: 2_000_000_000)), .interval(seconds: 5400), .interval(seconds: 7200),
            .fileChange(path: "/tmp/x", recursive: false, glob: "*.csv", debounceSeconds: 4), .login, .appLaunch(bundleID: "com.apple.Safari"),
            .powerConnected, .networkAvailable,
        ]
        for t in triggers {
            let s = Schedule(id: "s", workflowID: "w", name: "n", trigger: t, enabled: true, missedRunPolicy: .runAll(max: 4), concurrency: .parallel(max: 3),
                             maxRetries: 2, retryBackoffSeconds: 45)
            let back = ScheduleDraft(schedule: s).makeSchedule(existing: s)
            #expect(back == s, "\(t)")
        }
        #expect(ScheduleDraft(schedule: Schedule(workflowID: "w", name: "n", trigger: .cron(expression: "*/7 3-5 * * *", timezone: nil))).useRawCron)
        #expect(!ScheduleDraft(schedule: Schedule(workflowID: "w", name: "n", trigger: .cron(expression: "0 9 * * 1", timezone: nil))).useRawCron)
    }

    @Test func draftValidationAndCronPreview() throws {
        var d = ScheduleDraft()
        #expect(d.problems().contains("Choose a workflow."))
        d.workflowID = "w"
        #expect(d.problems().isEmpty)
        d.timezone = "America/Toronto"; d.useRawCron = true; d.rawCron = "0 9 * * MON"
        let now = date(2026, 11, 21, 12, zone: toronto)
        let dates = try d.cronPreview(now: now).get()
        #expect(dates.count == 5)
        #expect(dates[0] == date(2026, 11, 23, 9, zone: toronto))
        #expect(dates[4] == date(2026, 12, 21, 9, zone: toronto))
        d.rawCron = "0 25 * * *"
        guard case .failure(let e) = d.cronPreview(now: now) else { Issue.record("an out-of-range hour must be refused"); return }
        #expect(e.description.contains("hour"))
        #expect(!d.problems(now: now).isEmpty)
        d.rawCron = "0 0 30 2 *"
        guard case .failure = d.cronPreview(now: now) else { Issue.record("a date that never exists must be reported"); return }
        d.rawCron = "0 9 * * *"; d.timezone = "Mars/Olympus"
        guard case .failure = d.cronPreview(now: now) else { Issue.record("an unknown zone must be refused"); return }
        var w = ScheduleDraft(); w.workflowID = "w"; w.shape = .weekly; w.weekdays = []
        #expect(w.problems().contains("Choose at least one day of the week."))
        var o = ScheduleDraft(); o.workflowID = "w"; o.kind = .once; o.onceAt = now.addingTimeInterval(-60)
        #expect(!o.problems(now: now).isEmpty)
        var f = ScheduleDraft(); f.workflowID = "w"; f.kind = .fileChange
        #expect(f.problems() == ["Choose the folder to watch."])
    }
}

@Suite("Unit · console buffer")
struct ConsoleBufferTests {
    @Test func keepsTheNewestLinesAndCountsTheRest() {
        var b = ConsoleBuffer(capacity: 100)
        for i in 0..<250 { b.append("line \(i)", level: i % 2 == 0 ? .stdout : .stderr) }
        #expect(b.lines.count == 100)
        #expect(b.dropped == 150)
        #expect(b.lines.first?.text == "line 150")
        #expect(b.lines.last?.text == "line 249")
        #expect(Set(b.lines.map(\.id)).count == 100)
        b.clear()
        #expect(b.lines.isEmpty && b.dropped == 0)
        b.append("after", level: .info)
        #expect(b.lines[0].id == 250)   // ids never repeat, even after clearing
    }

    @Test func splitsMultilineTextAndCutsOverlongLines() {
        var b = ConsoleBuffer()
        b.append("a\nb\r\nc", level: .stdout)
        #expect(b.lines.map(\.text) == ["a", "b", "c"])
        b.append("", level: .stdout)
        #expect(b.lines.count == 3)
        b.append(String(repeating: "x", count: 10_000), level: .stdout)
        #expect(b.lines.last!.text.hasSuffix("[line cut]"))
        #expect(b.lines.last!.text.count < 4100)
    }

    @Test func olderEventsAreInsertedInTimeOrder() {
        var b = ConsoleBuffer()
        let t = Date(timeIntervalSince1970: 1000)
        b.append("live 1", level: .stdout, time: t.addingTimeInterval(1))
        b.append("live 2", level: .stdout, time: t.addingTimeInterval(3))
        b.append("recorded", level: .approval, time: t.addingTimeInterval(2))
        b.append("same instant", level: .info, time: t.addingTimeInterval(3))
        #expect(b.lines.map(\.text) == ["live 1", "recorded", "live 2", "same instant"])
    }

    @Test func searchIsCaseInsensitiveAndRespectsLevels() {
        var b = ConsoleBuffer()
        b.append("Error: file not found", level: .stderr)
        b.append("no problem here", level: .stdout)
        b.append("an ERROR again, résumé", level: .stdout)
        #expect(b.search("error").count == 2)
        #expect(b.search("error", levels: [.stdout]).count == 1)
        #expect(b.search("resume").count == 1)
        #expect(b.search("   ").isEmpty)
        #expect(b.search("RÉSUMÉ").count == 1 && b.search("found").count == 1 && b.search("foundx").isEmpty && b.search("d").count == 1)
        let m = ConsoleBuffer.Matcher("ab")!
        #expect(m.matches("xxAB") && m.matches("aB") && !m.matches("a") && !m.matches("ba") && m.matches("aab") && !m.matches(""))
        #expect(b.visible(levels: [.stderr]).map(\.text) == ["Error: file not found"])
        #expect(ConsoleBuffer.render(b.lines[0]).contains("  ERR     Error: file not found"))
    }

    @Test func assemblerJoinsStreamingFragmentsIntoLines() {
        var a = ConsoleAssembler()
        #expect(a.lines(for: .text("Hel")).isEmpty)
        let first = a.lines(for: .text("lo\nwor"))
        #expect(first.map(\.text) == ["Hello"] && first[0].level == .agent)
        #expect(a.hasPartials)
        #expect(a.flushPartials().map(\.text) == ["wor"])
        #expect(!a.hasPartials)
        let out = a.lines(for: .toolProgress(callID: "c", ToolProgress(stream: .stdout, text: "one\ntwo\n")))
        #expect(out.map(\.text) == ["one", "two"] && out.allSatisfy { $0.level == .stdout })
        let err = a.lines(for: .toolProgress(callID: "c", ToolProgress(stream: .stderr, text: "bad\n")))
        #expect(err.first?.level == .stderr)
    }

    @Test func assemblerDoesNotShowTheSameThingTwice() {
        var a = ConsoleAssembler()
        let call = ToolCall(id: "call-1", toolID: "shell.script", arguments: ["script": "echo hi"])
        #expect(a.lines(for: .toolStarted(call)).count == 1)
        // The store records the same call a moment later.
        let requested = RunEvent(runID: "r", kind: .toolRequested, text: "shell.script", data: ["callID": "call-1", "toolID": "shell.script"])
        #expect(a.lines(for: requested).isEmpty)
        #expect(a.lines(for: .toolFinished(call, ToolResult(status: .succeeded, summary: "ok", durationMs: 12))).count == 1)
        let finished = RunEvent(runID: "r", kind: .toolFinished, text: "ok", data: ["callID": "call-1", "toolID": "shell.script", "status": "succeeded"])
        #expect(a.lines(for: finished).isEmpty)
        // A call seen only in the store is shown from the store.
        let other = RunEvent(runID: "r", kind: .toolFinished, text: "boom", data: ["callID": "call-2", "toolID": "filesystem.read", "status": "failed", "durationMs": 5])
        let shown = a.lines(for: other)
        #expect(shown.count == 1 && shown[0].level == .error && shown[0].text.contains("filesystem.read failed"))
        // Streamed text is not repeated when the full message is recorded.
        _ = a.lines(for: .text("Done.\n"))
        #expect(a.lines(for: RunEvent(runID: "r", kind: .assistantText, text: "Done.")).isEmpty)
        #expect(a.lines(for: RunEvent(runID: "r", kind: .assistantText, text: "Not streamed.")).map(\.text) == ["Not streamed."])
        // Status repeats collapse.
        #expect(a.lines(for: .status(.running)).count == 1)
        #expect(a.lines(for: RunEvent(runID: "r", kind: .statusChanged, text: "RUNNING", data: ["status": "RUNNING"])).isEmpty)
        #expect(a.lines(for: .finished(.succeeded)).map(\.text) == ["SUCCEEDED"])
    }
}

@Suite("Unit · runs logic and export")
struct RunsLogicTests {
    func run(_ id: String, status: RunStatus = .succeeded, kind: String = "agent", trigger: String = "manual", started: TimeInterval = 0, duration: Double? = 10,
             cost: Double = 0, complete: Bool = true) -> RunRecord {
        let s = Date(timeIntervalSince1970: started)
        var r = RunRecord(id: id, kind: kind, title: id, trigger: trigger, mode: .guided, status: status, queuedAt: s, startedAt: s, endedAt: duration.map { s.addingTimeInterval($0) })
        r.usage.costUSD = cost; r.usage.costIsComplete = complete
        return r
    }

    @Test func filterCombinesStatusKindTriggerAndDates() {
        var f = RunFilter()
        #expect(!f.isActive && f.matches(run("a")))
        f.statuses = [.failed, .timedOut]
        #expect(f.storeStatus == nil)
        #expect(f.matches(run("a", status: .failed)) && !f.matches(run("a")))
        f.statuses = [.failed]
        #expect(f.storeStatus == .failed)
        f = RunFilter(); f.kinds = ["workflow"]
        #expect(f.matches(run("a", kind: "workflow")) && !f.matches(run("a")))
        f = RunFilter(); f.triggers = [.schedule]
        #expect(f.matches(run("a", trigger: "cron")) && f.matches(run("a", trigger: "schedule")) && !f.matches(run("a")) && !f.matches(run("a", trigger: "something-else")))
        f = RunFilter(); f.from = Date(timeIntervalSince1970: 100); f.to = Date(timeIntervalSince1970: 200)
        #expect(f.matches(run("a", started: 150)) && !f.matches(run("a", started: 50)) && !f.matches(run("a", started: 250)))
        #expect(f.activeCount == 2)
        #expect(TriggerGroup.of("fileChange") == .fileChange && TriggerGroup.of("login") == .systemEvent && TriggerGroup.title(raw: "custom") == "custom")
    }

    @Test func metricsComeFromDaysAndRecords() {
        let day0 = Date(timeIntervalSince1970: 86_400 * 100), day1 = day0.addingTimeInterval(86_400)
        let days = [DailyUsage(date: day0.addingTimeInterval(-86_400), day: "old", runs: 9, succeeded: 9, tokens: 9, costUSD: 9),
                    DailyUsage(date: day0, day: "d0", runs: 3, succeeded: 2, failed: 1, tokens: 1000, costUSD: 0.5),
                    DailyUsage(date: day1, day: "d1", runs: 2, succeeded: 1, failed: 0, tokens: 500, costUSD: 0.25)]
        let runs = [run("a", started: day0.timeIntervalSince1970 + 10, duration: 10), run("b", status: .failed, started: day0.timeIntervalSince1970 + 20, duration: 30),
                    run("c", started: day0.timeIntervalSince1970 + 30, duration: 20, complete: false), run("d", started: day1.timeIntervalSince1970 + 5, duration: 40),
                    run("e", status: .running, started: day1.timeIntervalSince1970 + 6, duration: nil), run("old", started: day0.timeIntervalSince1970 - 50, duration: 1000)]
        let today = PeriodMetrics.aggregate(days: days, runs: runs, period: .today)
        #expect(today.runs == 2 && today.inFlight == 1 && today.succeeded == 1 && today.costUSD == 0.25 && today.costIsComplete)
        #expect(today.successRate == 1 && today.averageDuration == 40 && today.durationSample == 1)
        let week = PeriodMetrics.aggregate(days: days, runs: runs, period: .week)   // only 3 days exist: all of them
        #expect(week.runs == 14 && week.tokens == 1509)
        let two = PeriodMetrics.aggregate(days: Array(days.suffix(2)), runs: runs, period: .week)
        #expect(two.runs == 5 && two.succeeded == 3 && two.failed == 1 && two.tokens == 1500 && two.costUSD == 0.75)
        #expect(!two.costIsComplete)
        #expect(two.successRate == 0.75)             // 3 of the 4 finished runs
        #expect(two.averageDuration == 25 && two.durationSample == 4)
        let none = PeriodMetrics.aggregate(days: [DailyUsage(date: day0, day: "d0")], runs: [], period: .today)
        #expect(none.successRate == nil && none.averageDuration == nil)
    }

    @Test func toolUsageTotalsPerTool() {
        let calls = [ToolCallRecord(id: "1", toolID: "a.read", arguments: .null, status: .succeeded, summary: "", durationMs: 10),
                     ToolCallRecord(id: "2", toolID: "a.read", arguments: .null, status: .failed, summary: "", durationMs: 30),
                     ToolCallRecord(id: "3", toolID: "b.run", arguments: .null, status: .simulated, summary: "", durationMs: 500)]
        let rows = ToolUsageRow.aggregate(calls)
        #expect(rows.map(\.toolID) == ["b.run", "a.read"])
        #expect(rows[1].calls == 2 && rows[1].failed == 1 && rows[1].totalMs == 40 && rows[0].failed == 0)
        let events = [RunEvent(runID: "r", kind: .toolFinished, text: "x", data: ["callID": "9", "toolID": "c.go", "status": "succeeded", "durationMs": 7, "tier": 1]),
                      RunEvent(runID: "r", kind: .log, text: "ignored")]
        let rebuilt = ToolUsageRow.calls(from: events)
        #expect(rebuilt.count == 1 && rebuilt[0].toolID == "c.go" && rebuilt[0].durationMs == 7 && rebuilt[0].tier == .reversibleWrite)
    }

    @Test func receiptExportsAsMarkdownAndJSON() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var usage = RunUsage(); usage.turns = 3; usage.costUSD = 0.0123; usage.costIsComplete = false
        let receipt = RunReceipt(runID: "ABCDEF12-0000", title: "Weekly: Research / digest!", status: .partiallySucceeded, objective: "Summarise", model: nil,
                                 startedAt: start, endedAt: start.addingTimeInterval(60), usage: usage,
                                 toolCalls: [ToolCallRecord(id: "1", toolID: "filesystem.list", arguments: ["path": "~/x"], status: .succeeded, summary: "3 entries", durationMs: 4, startedAt: start)],
                                 artifacts: [Artifact(path: "/tmp/report.md", bytes: 10, sha256: String(repeating: "ab", count: 32), createdAt: start)],
                                 verifications: [VerificationResult(assertion: "report exists", kind: "file_exists", passed: false, evidence: "not found", checkedAt: start)],
                                 agentSummary: "All done!", limitations: ["Dry run"])
        let md = ReceiptExport.markdown(receipt)
        #expect(md.contains("# Execution receipt — Weekly: Research / digest!"))
        #expect(md.contains("FAIL — report exists — not found"))
        #expect(md.contains("≥ $0.0123"))
        #expect(md.contains("a claim, not evidence"))
        let data = try ReceiptExport.json(receipt)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(RunReceipt.self, from: data) == receipt)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"startedAt\" : \"2027-01-15T08:00:00Z\""))
        #expect(text.contains("/tmp/report.md"))   // slashes are not escaped
        #expect(ReceiptExport.fileName(receipt, ext: "md") == "receipt-weekly-research-digest-ABCDEF12.md")
        #expect(ReceiptExport.fileName(receipt, ext: "json").hasSuffix(".json"))
    }
}
