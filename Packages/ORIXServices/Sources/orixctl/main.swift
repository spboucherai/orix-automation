// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXServices/Sources/orixctl/main.swift
// Description      : Command-line front end to the same services as the app:
//                    tools, agent runs, workflows, runs, providers, skills, and
//                    the headless scheduler loop.
// Module           : orixctl
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
import ORIXCore
import ORIXServices
import ORIXWorkflowEngine

struct Args {
    var positional: [String] = []
    var options: [String: [String]] = [:]
    init(_ raw: [String]) {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if i + 1 < raw.count, !raw[i + 1].hasPrefix("--") { options[name, default: []].append(raw[i + 1]); i += 1 }
                else { options[name, default: []].append("true") }
            } else { positional.append(a) }
            i += 1
        }
    }
    func value(_ name: String) -> String? { options[name]?.last }
    func flag(_ name: String) -> Bool { options[name] != nil }
    func values(_ name: String) -> [String] { options[name] ?? [] }
}

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data(("orixctl: " + message + "\n").utf8)); exit(1) }

let usage = """
orixctl — ORIX OS Automation from the command line

  orixctl tools [--family F] [--markdown]
  orixctl permissions
  orixctl providers [--test provider:model]
  orixctl agent run --objective TEXT --dir FOLDER [--mode quick|guided|autonomous|review] [--model provider:model]
                    [--agent NAME] [--access none|read|readWrite] [--approve all] [--expect kind:path[:text]] [--max-cost USD]
  orixctl workflow templates | list | validate FILE | save FILE | install SLUG | show ID
  orixctl workflow run ID [--param name=json] [--dry-run] [--accept-permissions] [--approve all] [--mode MODE]
  orixctl workflow draft --objective TEXT [--model provider:model]
  orixctl runs [--limit N] | orixctl run ID [--events]
  orixctl skills
  orixctl daemon                      run the scheduler until interrupted (what the background agent does)

Global: --data DIR (data folder; default is the app's), --dev-keys (Debug builds: take provider keys from ORIX_DEV_*_API_KEY)
Without --approve all, anything that needs approval is left unanswered and does not run.
"""

func modelRef(_ s: String?) -> ModelRef? {
    guard let s, let i = s.firstIndex(of: ":") else { return nil }
    return ModelRef(provider: ProviderID(rawValue: String(s[..<i])), model: String(s[s.index(after: i)...]))
}

func printRun(_ services: ORIXServices, _ id: String, events: Bool) async {
    guard let r = try? await services.store.run(id: id) else { fail("no run \(id)") }
    if events {
        for e in (try? await services.store.events(runID: id, afterSeq: 0, limit: 5000)) ?? [] {
            print("\(e.seq)\t\(e.kind.rawValue)\t\(e.stepID ?? "-")\t\(e.text.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(200))")
        }
    }
    if let receipt = try? await services.store.receipt(runID: id) { print(receipt.markdown()) }
    else { print("\(r.id)  \(r.status.rawValue)  \(r.title)") }
}

func autoApprove(_ services: ORIXServices) {
    Task {
        for await pending in services.approvals.updates() {
            for p in pending {
                FileHandle.standardError.write(Data("approve[--approve all]: \(p.access.toolID) \(p.access.tier.label) — \(p.access.summary)\n".utf8))
                await services.approvals.resolve(id: p.id, response: .approveOnce)
            }
        }
    }
    Task {
        for await items in services.interaction.updates() {
            for item in items {
                switch item {
                case .plan(let p): await services.interaction.review(planID: p.id, .approved)
                case .question(let q): await services.interaction.answer(questionID: q.id, nil)
                }
            }
        }
    }
}

@Sendable func main() async {
    let args = Args(Array(CommandLine.arguments.dropFirst()))
    guard let command = args.positional.first else { print(usage); exit(0) }
    var options = ServiceOptions()
    options.interactive = args.flag("approve")
    options.allowDevelopmentCredentials = args.flag("dev-keys")
    let paths = args.value("data").map { ORIXPaths(root: URL(fileURLWithPath: $0)) } ?? .default
    let services: ORIXServices
    do { services = try await ORIXServices.bootstrap(paths: paths, options: options) } catch { fail("cannot start: \(error.localizedDescription)") }
    if args.value("approve") == "all" { autoApprove(services) }
    let sub = args.positional.dropFirst().first

    switch command {
    case "tools" where args.flag("markdown"):
        // Reference documentation generated from the live manifests, so it cannot drift from the code.
        let manifests = await services.executor.manifests()
        print("<!--\nORIX OS Automation\nFile: docs/api/tools.md\nAuthor: Simon-Pierre Boucher\nContact: contact@spboucher.ai\n-->\n# Tool reference\n")
        print("Generated by `orixctl tools --markdown` from the registered tool manifests (\(manifests.count) tools). Do not edit by hand.\n")
        for family in Array(Set(manifests.map(\.family))).sorted() {
            print("## \(family)\n")
            for m in manifests where m.family == family {
                print("### `\(m.identifier)`\n\n\(m.summary)\n")
                var facts = ["side effect: \(m.sideEffect.rawValue)", "default tier: \(m.defaultTier.rawValue)", "timeout: \(Int(m.defaultTimeoutSeconds)) s"]
                if m.supportsDryRun { facts.append("dry run: yes") }
                if m.idempotent { facts.append("idempotent") }
                if m.outputIsUntrusted { facts.append("output is untrusted data") }
                if !m.macPermissions.isEmpty { facts.append("macOS permission: " + m.macPermissions.map(\.rawValue).joined(separator: ", ")) }
                print(facts.map { "- \($0)" }.joined(separator: "\n") + "\n")
                let props = m.inputSchema.raw["properties"]?.objectValue ?? [:]
                let required = Set(m.inputSchema.raw["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                if !props.isEmpty {
                    print("| Argument | Type | Required | Description |\n|---|---|---|---|")
                    for k in props.keys.sorted() {
                        let t = props[k]?["type"]?.stringValue ?? (props[k]?["type"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " or ") ?? "any")
                        let d = (props[k]?["description"]?.stringValue ?? "").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
                        print("| `\(k)` | \(t) | \(required.contains(k) ? "yes" : "") | \(d) |")
                    }
                    print("")
                }
                let outs = (m.outputSchema.raw["properties"]?.objectValue ?? [:]).keys.sorted()
                if !outs.isEmpty { print("Output fields: " + outs.map { "`\($0)`" }.joined(separator: ", ") + "\n") }
            }
        }
    case "tools":
        for m in await services.executor.manifests() where args.value("family") == nil || m.family == args.value("family") {
            print("\(m.identifier)\t\(m.sideEffect.rawValue)\ttier \(m.defaultTier.rawValue)\t\(m.summary.prefix(90))")
        }
    case "permissions":
        for (p, s) in services.permissionSnapshot().sorted(by: { $0.key.rawValue < $1.key.rawValue }) { print("\(p.rawValue)\t\(s.rawValue)") }
    case "providers":
        for p in ProviderID.all { print("\(p.rawValue)\tkey: \(await services.providers.keySource(for: p).rawValue)") }
        if let ref = modelRef(args.value("test")) {
            let r = await services.providers.test(ref)
            print("\(ref.displayString): \(r.ok ? "ok" : "FAILED") in \(r.latencyMs) ms" + (r.message.map { " — \($0)" } ?? ""))
            if !r.ok { exit(2) }
        }
    case "agent":
        guard sub == "run", let objective = args.value("objective"), let dir = args.value("dir") else { fail("usage: agent run --objective TEXT --dir FOLDER") }
        var req = AgentRunRequest(objective: objective, workingDirectory: dir)
        req.mode = ExecutionMode(rawValue: args.value("mode") ?? "autonomous") ?? .autonomous
        req.model = modelRef(args.value("model"))
        req.agent = args.value("agent") ?? "general"
        req.workspaceAccess = WorkspaceAccess(rawValue: args.value("access") ?? "readWrite") ?? .readWrite
        if let c = args.value("max-cost").flatMap(Double.init) { var b = Budget.standard; b.maxCostUSD = c; req.budget = b }
        for e in args.values("expect") {
            let parts = e.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { fail("--expect kind:path[:text]") }
            req.expectations.append(Expectation(kind: parts[0], path: parts[1], text: parts.count > 2 ? parts[2] : nil))
        }
        do {
            let id = try await services.runs.startAgentRun(req)
            Task { for await u in services.runs.live.subscribe(runID: id) {
                if case .toolFinished(let c, let r) = u { FileHandle.standardError.write(Data("  tool \(c.toolID): \(r.status.rawValue) — \(r.summary.prefix(120))\n".utf8)) }
            } }
            let final = await services.runs.wait(runID: id)
            await printRun(services, id, events: false)
            exit(final?.status == .succeeded ? 0 : 3)
        } catch { fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
    case "workflow":
        do {
            switch sub {
            case "templates": for b in BuiltInWorkflows.all() { print("\(b.slug)\t\(b.title)\t\(b.summary.prefix(80))") }
            case "list": for w in await services.workflows.list() { print("\(w.id)\tv\(w.currentVersion)\t\(w.name)") }
            case "validate", "save":
                guard let file = args.positional.dropFirst(2).first, let src = try? String(contentsOfFile: file, encoding: .utf8) else { fail("give a readable file") }
                let format: WorkflowFormat = file.hasSuffix(".json") ? .json : .yaml
                let (_, diags) = await services.workflows.diagnose(src, format: format)
                for d in diags { print("\(d.severity)\tline \(d.line)\t\(d.stepID ?? "-")\t\(d.message)") }
                if diags.contains(where: { $0.severity == .error }) { exit(2) }
                if sub == "save" { let s = try await services.workflows.save(source: src, format: format); print("saved \(s.id) v\(s.version)") } else { print("valid") }
            case "install":
                guard let slug = args.positional.dropFirst(2).first else { fail("give a template slug") }
                let s = try await services.workflows.installBuiltIn(slug: slug); print("installed \(s.id) v\(s.version)")
            case "show":
                guard let id = args.positional.dropFirst(2).first else { fail("give a workflow id") }
                print(try await services.workflows.source(workflowID: id))
            case "draft":
                guard let objective = args.value("objective") else { fail("--objective TEXT") }
                let r = try await services.workflows.generate(objective: objective, model: modelRef(args.value("model")))
                print(r.source)
                for d in r.diagnostics { FileHandle.standardError.write(Data("\(d.severity) line \(d.line): \(d.message)\n".utf8)) }
            case "run":
                guard let id = args.positional.dropFirst(2).first else { fail("give a workflow id") }
                var req = WorkflowRunRequest(workflowID: id)
                req.dryRun = args.flag("dry-run")
                req.mode = ExecutionMode(rawValue: args.value("mode") ?? "guided") ?? .guided
                for p in args.values("param") {
                    guard let i = p.firstIndex(of: "=") else { fail("--param name=json") }
                    let raw = String(p[p.index(after: i)...])
                    req.parameters[String(p[..<i])] = (try? JSONValue.parse(raw)) ?? .string(raw)
                }
                if args.flag("accept-permissions") { try await services.workflows.acceptPermissions(workflowID: id, parameters: req.parameters) }
                let runID = try await services.workflows.startRun(req)
                let final = await services.runs.wait(runID: runID)
                await printRun(services, runID, events: args.flag("events"))
                exit(final?.status == .succeeded ? 0 : 3)
            default: fail("unknown workflow command")
            }
        } catch { fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
    case "runs":
        for r in (try? await services.store.runs(limit: Int(args.value("limit") ?? "20") ?? 20)) ?? [] {
            print("\(r.id)\t\(r.status.rawValue)\t\(r.kind)\t\(r.title.prefix(60))")
        }
    case "run":
        guard let id = sub else { fail("give a run id") }
        await printRun(services, id, events: args.flag("events"))
    case "skills":
        for s in await services.skills.installed() { print("\(s.id)\t\(s.package.manifest.version)\t\(s.enabled ? "enabled" : "disabled")\t\(s.package.manifest.summary.prefix(70))") }
    case "daemon":
        _ = await services.runs.recoverInterrupted(startedAt: services.processStart)
        await services.workflows.startScheduler(owner: "orixctl-\(ProcessInfo.processInfo.processIdentifier)")
        print("scheduler running; interrupt to stop")
        while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
    default:
        print(usage); exit(64)
    }
    exit(0)
}

Task { await main() }
RunLoop.main.run()
