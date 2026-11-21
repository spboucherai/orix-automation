// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXToolRegistry/Tests/ORIXToolRegistryTests/FilesystemToolsTests.swift
// Description      : Integration tests of every filesystem.* tool through the
//                    real executor, on real files in temp directories.
// Module           : ORIXToolRegistryTests
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
import Testing
import ORIXCore
import ORIXTestingSupport
@testable import ORIXToolRegistry

@Suite("filesystem.* tools (integration, real files)")
struct FilesystemToolsTests {
    @Test func listFlatRecursiveHiddenAndLimit() async throws {
        let h = try await Harness(); defer { h.tmp.remove() }
        try h.tmp.write("a.txt", "A"); try h.tmp.write("sub/b.txt", "BB"); try h.tmp.write("sub/deep/c.txt", "CCC"); try h.tmp.write(".hidden", "h")
        let flat = await h.call("filesystem.list", ["path": "."])
        let names = flat.output["entries"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(flat.status == .succeeded && names == ["a.txt", "sub"] && flat.untrusted)
        let recursive = await h.call("filesystem.list", ["path": ".", "recursive": true, "includeHidden": true])
        let all = Set(recursive.output["entries"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [])
        #expect(all == [".hidden", "a.txt", "sub", "sub/b.txt", "sub/deep", "sub/deep/c.txt"])
        let shallow = await h.call("filesystem.list", ["path": ".", "recursive": true, "maxDepth": 2])
        #expect(shallow.output["count"] == 4)
        let limited = await h.call("filesystem.list", ["path": ".", "recursive": true, "limit": 2])
        #expect(limited.output["count"] == 2 && limited.truncated && limited.output["truncated"] == true)
        let entry = flat.output["entries"]?[0]
        #expect(entry?["type"] == "file" && entry?["size"] == 1 && entry?["modified"]?.stringValue != nil)
        #expect(await h.call("filesystem.list", ["path": "missing"]).failure?.code == "not_found")
        #expect(await h.call("filesystem.list", ["path": "a.txt"]).status == .invalidInput)
    }

    @Test func searchByNameAndContent() async throws {
        let h = try await Harness(); defer { h.tmp.remove() }
        try h.tmp.write("notes/todo.md", "buy milk\nCall Alice\n"); try h.tmp.write("notes/done.md", "paid rent\n")
        try h.tmp.write("report.PDF", "x"); try h.tmp.write("src/main.swift", "let total = 42\n// TODO: refactor\n")
        try Data([0, 1, 2, 0x54, 0x4f, 0x44, 0x4f]).write(to: h.tmp.file("blob.bin"))
        let byName = await h.call("filesystem.search", ["path": ".", "pattern": "*.md"])
        #expect(byName.output["count"] == 2)
        #expect(await h.call("filesystem.search", ["path": ".", "pattern": "*.pdf"]).output["count"] == 1)
        let content = await h.call("filesystem.search", ["path": ".", "content": "todo"])
        let hit = content.output["matches"]?[0]
        #expect(content.output["count"] == 1 && hit?["line"] == 2 && hit?["path"]?.stringValue?.hasSuffix("main.swift") == true, "binary files are skipped, names are not content")
        #expect(await h.call("filesystem.search", ["path": ".", "content": "todo", "caseSensitive": true]).output["count"] == 0)
        let regex = await h.call("filesystem.search", ["path": ".", "content": "^let \\w+ = \\d+$", "regex": true, "pattern": "*.swift"])
        #expect(regex.output["count"] == 1)
        let bounded = await h.call("filesystem.search", ["path": ".", "content": "a", "maxResults": 1])
        #expect(bounded.output["count"] == 1 && bounded.truncated)
        #expect(await h.call("filesystem.search", ["path": "."]).status == .invalidInput)
        #expect(await h.call("filesystem.search", ["path": ".", "content": "(", "regex": true]).status == .invalidInput)
    }

    @Test func readTextWindowsAndBinary() async throws {
        let h = try await Harness(); defer { h.tmp.remove() }
        try h.tmp.write("t.txt", "héllo wörld — fin")
        let whole = await h.call("filesystem.read", ["path": "t.txt"])
        #expect(whole.output["content"] == "héllo wörld — fin" && whole.output["truncated"] == false && whole.untrusted)
        let head = await h.call("filesystem.read", ["path": "t.txt", "maxBytes": 2])
        #expect(head.output["content"] == "h" && head.truncated, "a cut inside é drops the partial character")
        let tail = await h.call("filesystem.read", ["path": "t.txt", "offset": 7, "maxBytes": 6])
        #expect(tail.output["content"] == "wörld")
        try Data([0xff, 0xfe, 0x00, 0x80, 0x01]).write(to: h.tmp.file("b.bin"))
        #expect(await h.call("filesystem.read", ["path": "b.bin"]).status == .unsupported)
        let b64 = await h.call("filesystem.read", ["path": "b.bin", "encoding": "base64"])
        #expect(b64.output["content"] == .string(Data([0xff, 0xfe, 0x00, 0x80, 0x01]).base64EncodedString()) && b64.output["bytesRead"] == 5)
        #expect(await h.call("filesystem.read", ["path": "nope.txt"]).failure?.code == "not_found")
    }

    @Test func writeCreateOverwriteWithBackupAppendAndDryRun() async throws {
        let h = try await Harness(); defer { h.tmp.remove() }
        let created = await h.call("filesystem.write", ["path": "out/new.txt", "content": "v1"])
        #expect(created.status == .succeeded && created.output["created"] == true && h.read("out/new.txt") == "v1")
        let refused = await h.call("filesystem.write", ["path": "out/new.txt", "content": "v2"])
        #expect(refused.status == .invalidInput && h.read("out/new.txt") == "v1")
        let dry = await h.call("filesystem.write", ["path": "out/new.txt", "content": "v2", "overwrite": true], dryRun: true)
        #expect(dry.status == .simulated && dry.output["wouldBackup"] == true && h.read("out/new.txt") == "v1")
        let replaced = await h.call("filesystem.write", ["path": "out/new.txt", "content": "v2", "overwrite": true])
        let backup = try #require(replaced.output["backupPath"]?.stringValue)
        try #expect(h.read("out/new.txt") == "v2" && (try String(contentsOfFile: backup, encoding: .utf8)) == "v1")
        #expect(backup.hasPrefix(h.path("artifacts/backups/")) && replaced.artifacts.first?.path == backup)
        let appended = await h.call("filesystem.write", ["path": "out/new.txt", "content": "+3", "mode": "append"])
        #expect(appended.status == .succeeded && h.read("out/new.txt") == "v2+3" && appended.output["backupPath"]?.stringValue != nil)
        let binary = await h.call("filesystem.write", ["path": "b.bin", "content": .string(Data([1, 2, 3]).base64EncodedString()), "encoding": "base64"])
        try #expect(binary.output["bytesWritten"] == 3 && (try Data(contentsOf: h.tmp.file("b.bin"))) == Data([1, 2, 3]))
        #expect(await h.call("filesystem.write", ["path": "b2.bin", "content": "%%%", "encoding": "base64"]).status == .invalidInput)
        #expect(await h.call("filesystem.write", ["path": "out", "content": "x", "overwrite": true]).status == .invalidInput)
    }

    @Test func mkdirCopyMove() async throws {
        let h = try await Harness(); defer { h.tmp.remove() }
        let made = await h.call("filesystem.mkdir", ["path": "a/b/c"])
        #expect(made.output["created"] == true && h.exists("a/b/c"))
        #expect(await h.call("filesystem.mkdir", ["path": "a/b/c"]).output["created"] == false)
        try h.tmp.write("a/file.txt", "payload"); try h.tmp.write("existing.txt", "old")
        #expect(await h.call("filesystem.copy", ["source": "a/file.txt", "destination": "copy.txt"]).status == .succeeded)
        #expect(h.read("copy.txt") == "payload" && h.exists("a/file.txt"))
        #expect(await h.call("filesystem.copy", ["source": "a/file.txt", "destination": "existing.txt"]).status == .invalidInput)
        #expect(h.read("existing.txt") == "old")
        let over = await h.call("filesystem.copy", ["source": "a/file.txt", "destination": "existing.txt", "overwrite": true])
        #expect(h.read("existing.txt") == "payload" && over.output["backupPath"]?.stringValue != nil)
        #expect(await h.call("filesystem.copy", ["source": "a", "destination": "tree-copy"]).status == .succeeded)
        #expect(h.read("tree-copy/file.txt") == "payload" && h.exists("tree-copy/b/c"))
        #expect(await h.call("filesystem.copy", ["source": "a", "destination": "a/inside"]).status == .invalidInput)

        let dry = await h.call("filesystem.move", ["source": "copy.txt", "destination": "moved/renamed.txt"], dryRun: true)
        #expect(dry.status == .simulated && h.exists("copy.txt"))
        #expect(await h.call("filesystem.move", ["source": "copy.txt", "destination": "moved/renamed.txt"]).status == .succeeded)
        #expect(!h.exists("copy.txt") && h.read("moved/renamed.txt") == "payload")
        try h.tmp.write("other.txt", "other")
        let clash = await h.call("filesystem.move", ["source": "other.txt", "destination": "existing.txt"])
        #expect(clash.status == .invalidInput && h.read("existing.txt") == "payload" && h.read("other.txt") == "other", "move never overwrites")
        #expect(await h.call("filesystem.move", ["source": "ghost.txt", "destination": "x.txt"]).failure?.code == "not_found")
    }

    @Test func metadataChecksumCompare() async throws {
        let h = try await Harness(); defer { h.tmp.remove() }
        try h.tmp.write("m.json", "{}"); try h.tmp.write("abc.txt", "abc")
        let meta = await h.call("filesystem.metadata", ["path": "m.json"])
        #expect(meta.output["type"] == "file" && meta.output["size"] == 2 && meta.output["contentType"] == "public.json" && meta.output["permissions"] == "644")
        #expect(await h.call("filesystem.metadata", ["path": "."]).output["type"] == "directory")
        let sum = await h.call("filesystem.checksum", ["path": "abc.txt"])
        #expect(sum.output["digest"] == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" && sum.output["bytes"] == 3)
        #expect(await h.call("filesystem.checksum", ["path": "."]).status == .invalidInput)

        try h.tmp.write("same.txt", "abc"); try h.tmp.write("diff.txt", "abd")
        #expect(await h.call("filesystem.compare", ["source": "abc.txt", "destination": "same.txt"]).output["identical"] == true)
        #expect(await h.call("filesystem.compare", ["source": "abc.txt", "destination": "diff.txt"]).output["identical"] == false)
        try h.tmp.write("L/keep.txt", "k"); try h.tmp.write("L/gone.txt", "g"); try h.tmp.write("L/mod.txt", "old!"); try h.tmp.write("L/d/n.txt", "n")
        try h.tmp.write("R/keep.txt", "k"); try h.tmp.write("R/new.txt", "n"); try h.tmp.write("R/mod.txt", "new!"); try h.tmp.write("R/d/n.txt", "n")
        let trees = await h.call("filesystem.compare", ["source": "L", "destination": "R"])
        #expect(trees.output["kind"] == "directories" && trees.output["identical"] == false)
        #expect(trees.output["added"] == ["new.txt"] && trees.output["removed"] == ["gone.txt"] && trees.output["changed"] == ["mod.txt"])
        #expect(await h.call("filesystem.compare", ["source": "L", "destination": "L"]).output["identical"] == true)
        #expect(await h.call("filesystem.compare", ["source": "L", "destination": "abc.txt"]).status == .invalidInput)
    }

    @Test func trashMovesToTheTrashAndReportsWhere() async throws {
        let h = try await Harness(); defer { h.tmp.remove() }
        try h.tmp.write("old-report.txt", "bye")
        let dry = await h.call("filesystem.trash", ["path": "old-report.txt"], dryRun: true)
        #expect(dry.status == .simulated && h.exists("old-report.txt"))
        let r = await h.call("filesystem.trash", ["path": "old-report.txt"])
        guard r.status == .succeeded else {
            print("SKIPPED(FileManager.trashItem is not available for the temp volume in this session: \(r.failure?.message ?? "?"))")
            #expect(r.failure?.code == "io")
            return
        }
        #expect(!h.exists("old-report.txt"))
        let trashed = try #require(r.output["trashPath"]?.stringValue)
        #expect(FileManager.default.fileExists(atPath: trashed) && trashed.contains("Trash"))
        try? FileManager.default.removeItem(atPath: trashed)  // remove the one item this test put in the Trash
        #expect(await h.call("filesystem.trash", ["path": "~"]).status == .unsupported)
        #expect(await h.call("filesystem.trash", ["path": "/"]).status == .unsupported)
    }

    @Test func deleteIsPermanentTierThreeAndGuarded() async throws {
        let policy = ApprovalPolicy()
        let h = try await Harness(policy: policy, approvals: ScriptedApprovalBroker(fallback: .approveOnce)); defer { h.tmp.remove() }
        try h.tmp.write("d/a.txt", "a"); try h.tmp.write("d/sub/b.txt", "b"); try h.tmp.write("single.txt", "s")
        let dry = await h.call("filesystem.delete", ["path": "d", "recursive": true], dryRun: true)
        #expect(dry.status == .simulated && dry.output["items"] == 4 && h.exists("d/a.txt"))
        #expect(await h.call("filesystem.delete", ["path": "d"]).status == .invalidInput)
        #expect(h.exists("d/a.txt"))
        #expect(await h.call("filesystem.delete", ["path": "d", "recursive": true]).status == .succeeded)
        #expect(!h.exists("d"))
        #expect(await h.call("filesystem.delete", ["path": "single.txt"]).output["deleted"] == true)
        let last = await policy.requests.last
        #expect(last?.tier == .highRisk && last?.sideEffect == .destructive && last?.capabilities == [.fileDelete(path: h.path("single.txt"))])
        for broad in ["/", "~", "~/Documents", "/Users", "/Applications"] {
            #expect(await h.call("filesystem.delete", ["path": .string(broad), "recursive": true]).status == .unsupported, "\(broad)")
        }
    }

    @Test func archiveAndUnarchiveRoundTrip() async throws {
        let h = try await Harness(); defer { h.tmp.remove() }
        try h.tmp.write("project/readme.md", "# hi"); try h.tmp.write("project/src/x.txt", "x"); try h.tmp.write("lonely.txt", "one")
        let zipped = await h.call("filesystem.archive", ["source": "project", "destination": "out/project.zip"])
        #expect(zipped.status == .succeeded && (zipped.output["bytes"]?.intValue ?? 0) > 0, "\(zipped.failure?.message ?? "")")
        #expect(await h.call("filesystem.archive", ["source": "project", "destination": "out/project.zip"]).status == .invalidInput)
        #expect(await h.call("filesystem.archive", ["source": "project", "destination": "out/project.tar"]).status == .invalidInput)
        let dry = await h.call("filesystem.unarchive", ["source": "out/project.zip", "destination": "restored"], dryRun: true)
        #expect(dry.status == .simulated && !h.exists("restored"))
        let unzipped = await h.call("filesystem.unarchive", ["source": "out/project.zip", "destination": "restored"])
        #expect(unzipped.status == .succeeded, "\(unzipped.failure?.message ?? "")")
        #expect(h.read("restored/project/readme.md") == "# hi" && h.read("restored/project/src/x.txt") == "x")
        #expect(await h.call("filesystem.compare", ["source": "project", "destination": "restored/project"]).output["identical"] == true)
        let again = await h.call("filesystem.unarchive", ["source": "out/project.zip", "destination": "restored"])
        #expect(again.status == .invalidInput, "extraction never replaces existing items")
        #expect(await h.call("filesystem.archive", ["source": "lonely.txt", "destination": "one.zip"]).status == .succeeded)
        #expect(await h.call("filesystem.unarchive", ["source": "one.zip", "destination": "single"]).status == .succeeded)
        #expect(h.read("single/lonely.txt") == "one")
        #expect(await h.call("filesystem.unarchive", ["source": "lonely.txt", "destination": "bad"]).status == .unsupported)
        // No staging leftovers next to the archive.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: h.path("out"))
        #expect(leftovers == ["project.zip"])
    }

    @Test func waitForChangeSeesDirectoryAndFileChangesAndTimesOut() async throws {
        let h = try await Harness(); defer { h.tmp.remove() }
        try h.tmp.write("watched/seed.txt", "s"); try h.tmp.write("single.txt", "1")
        let quiet = await h.call("filesystem.waitForChange", ["path": "watched", "timeoutSeconds": 0.4])
        #expect(quiet.status == .succeeded && quiet.output["changed"] == false && quiet.output["timedOut"] == true)

        // The writers keep producing changes until the watcher answers, so the test does not depend on how fast the
        // watcher starts on a busy machine.
        let tmp = h.tmp
        let dirWriter = Task {
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                n += 1
                _ = try? tmp.write("watched/sub/created-\(n).txt", "new")
            }
        }
        let dirResult = await h.call("filesystem.waitForChange", ["path": "watched", "timeoutSeconds": 30])
        dirWriter.cancel()
        let paths = dirResult.output["events"]?.arrayValue?.compactMap { $0["path"]?.stringValue } ?? []
        #expect(dirResult.output["changed"] == true && paths.contains { $0.contains("/watched/sub") }, "\(dirResult.output.serialized())")

        let fileWriter = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if let handle = try? FileHandle(forWritingTo: tmp.file("single.txt")) {
                    _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data("2".utf8)); try? handle.close()
                }
            }
        }
        let fileResult = await h.call("filesystem.waitForChange", ["path": "single.txt", "timeoutSeconds": 30])
        fileWriter.cancel()
        #expect(fileResult.output["changed"] == true && fileResult.output["events"]?[0]?["change"]?.stringValue?.contains("modified") == true)

        let task = Task { await h.call("filesystem.waitForChange", ["path": "watched", "timeoutSeconds": 60]) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        #expect(await task.value.status == .canceled)
    }
}
