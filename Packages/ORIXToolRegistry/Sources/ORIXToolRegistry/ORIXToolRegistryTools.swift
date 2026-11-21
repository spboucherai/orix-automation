// ORIX OS Automation
// File: Packages/ORIXToolRegistry/Sources/ORIXToolRegistry/ORIXToolRegistryTools.swift
// Description: The list of built-in tools shipped by this package and their canonical identifiers.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
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
