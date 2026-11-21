// ORIX OS Automation
// File: Packages/ORIXCore/Sources/ORIXCore/PathResolver.swift
// Description: Explicit path resolution: tilde expansion, relative paths against a stated directory, `..` removal and symlink resolution, so capability checks see the real target.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation

public enum PathResolver {
    /// Returns the absolute, canonical path for `raw`.
    /// - `~` and `~/` expand to the current user's home; `~other` is rejected.
    /// - Relative paths resolve against `base` (never the process working directory).
    /// - `.` and `..` are removed lexically, then symlinks are resolved on the longest existing ancestor, so a link inside an
    ///   allowed folder that points outside it resolves to the outside path and is checked as such.
    public static func canonical(_ raw: String, relativeTo base: URL) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ToolError.invalidInput("path is empty") }
        guard !trimmed.contains("\0") else { throw ToolError.invalidInput("path contains a NUL byte") }
        var path: String
        if trimmed == "~" { path = NSHomeDirectory() }
        else if trimmed.hasPrefix("~/") { path = NSHomeDirectory() + String(trimmed.dropFirst(1)) }
        else if trimmed.hasPrefix("~") { throw ToolError.invalidInput("~user paths are not supported") }
        else if trimmed.hasPrefix("/") { path = trimmed }
        else { path = base.path + "/" + trimmed }

        var parts: [String] = []
        for comp in path.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." { continue }
            if comp == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(String(comp))
        }
        return resolveSymlinks("/" + parts.joined(separator: "/"))
    }

    /// Resolves symlinks on the longest existing prefix of `path` and re-appends the non-existing remainder.
    public static func resolveSymlinks(_ path: String) -> String {
        let fm = FileManager.default
        var existing = path
        var tail: [String] = []
        while existing != "/" && !fm.fileExists(atPath: existing) && (try? fm.destinationOfSymbolicLink(atPath: existing)) == nil {
            tail.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
            if existing.isEmpty { existing = "/" }
        }
        var resolved = existing
        if let real = realpath(existing, nil) {
            resolved = String(cString: real)
            free(real)
        }
        if tail.isEmpty { return resolved }
        return (resolved == "/" ? "" : resolved) + "/" + tail.joined(separator: "/")
    }

    /// Shortens a path under the home directory to `~/…` for display.
    public static func display(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Locations no grant can cover: credential stores and system security state. Checked by the policy engine before grants.
    public static func isProtected(_ canonicalPath: String) -> Bool {
        let home = NSHomeDirectory()
        let roots = [
            home + "/Library/Keychains", home + "/.ssh", home + "/.gnupg", home + "/.aws", home + "/.config/gcloud",
            home + "/Library/Application Support/com.apple.TCC", "/Library/Application Support/com.apple.TCC",
            "/Library/Keychains", "/private/var/db", "/private/etc/sudoers", "/private/etc/sudoers.d", "/System",
            home + "/Library/Cookies", home + "/.netrc", home + "/.docker/config.json", home + "/.kube",
        ]
        return roots.contains { canonicalPath == $0 || canonicalPath.hasPrefix($0 + "/") }
    }
}
