// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXToolRegistry/Sources/ORIXToolRegistry/ORIXToolRegistryTools.swift
// Description      : The list of built-in tools shipped by this package and
//                    their canonical identifiers.
// Module           : ORIXToolRegistry
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

public enum ORIXToolRegistryTools {
    /// Canonical identifiers of every tool of this package, as fixed by `docs/architecture/module-contracts.md`.
    public static let canonicalIdentifiers: [String] =
        ["list", "search", "read", "write", "mkdir", "copy", "move", "metadata", "checksum", "compare", "trash", "delete", "archive", "unarchive", "waitForChange"]
            .map { "filesystem." + $0 }
        + ["shell.run", "shell.script"]
        + ["status", "diff", "log", "branches", "commit", "createPatch", "push"].map { "git." + $0 }
        + ["http.request"]
        + ["csvRead", "csvWrite", "jsonQuery", "pdfText", "pdfInfo", "renderPDF", "imageInfo", "imageConvert", "xlsxRead", "textStats"].map { "documents." + $0 }
        + ["python.run", "python.envInfo", "script.swift", "script.javascript"]
        + ["info", "processes", "diskUsage", "powerState", "networkState"].map { "system." + $0 }

    /// Every built-in tool. `pythonEnvRoot` overrides where the managed Python environment lives (tests).
    public static func all(pythonEnvRoot: URL? = nil) -> [any ORIXTool] {
        all(pythonEnvRoot: pythonEnvRoot, runner: .shared)
    }

    /// Same list with a specific `ProcessRunner` (so an owner can `killAll()` exactly the processes of its tools).
    public static func all(pythonEnvRoot: URL?, runner: ProcessRunner) -> [any ORIXTool] {
        [
            FilesystemListTool(), FilesystemSearchTool(), FilesystemReadTool(), FilesystemWriteTool(), FilesystemMkdirTool(),
            FilesystemCopyTool(), FilesystemMoveTool(), FilesystemMetadataTool(), FilesystemChecksumTool(), FilesystemCompareTool(),
            FilesystemTrashTool(), FilesystemDeleteTool(), FilesystemArchiveTool(), FilesystemUnarchiveTool(), FilesystemWaitForChangeTool(),
            ShellRunTool(runner: runner), ShellScriptTool(runner: runner),
            GitStatusTool(runner: runner), GitDiffTool(runner: runner), GitLogTool(runner: runner), GitBranchesTool(runner: runner),
            GitCommitTool(runner: runner), GitCreatePatchTool(runner: runner), GitPushTool(runner: runner),
            HTTPRequestTool(),
            DocumentsCSVReadTool(), DocumentsCSVWriteTool(), DocumentsJSONQueryTool(), DocumentsPDFTextTool(), DocumentsPDFInfoTool(),
            DocumentsRenderPDFTool(), DocumentsImageInfoTool(), DocumentsImageConvertTool(), DocumentsXLSXReadTool(runner: runner), DocumentsTextStatsTool(),
            PythonRunTool(envRoot: pythonEnvRoot, runner: runner), PythonEnvInfoTool(envRoot: pythonEnvRoot, runner: runner),
            ScriptSwiftTool(runner: runner), ScriptJavaScriptTool(runner: runner),
            SystemInfoTool(), SystemProcessesTool(runner: runner), SystemDiskUsageTool(), SystemPowerStateTool(), SystemNetworkStateTool(),
        ]
    }
}
