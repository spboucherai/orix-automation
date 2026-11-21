import Foundation
import Testing
import ORIXCore
@testable import ORIXServices

@Test func scratchDumpManifests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("orix-dump-\(UUID().uuidString)")
    let s = try await ORIXServices.bootstrap(paths: ORIXPaths(root: root))
    var out = ""
    func compact(_ v: JSONValue, _ depth: Int = 0) -> String {
        guard let o = v.objectValue else { return "?" }
        let t = o["type"]?.stringValue ?? "any"
        if t == "object", let p = o["properties"]?.objectValue {
            let req = Set(o["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            return "{" + p.keys.sorted().map { "\($0)\(req.contains($0) ? "*" : ""):\(compact(p[$0]!, depth + 1))" }.joined(separator: ", ") + "}"
        }
        if t == "array", let i = o["items"] { return "[" + compact(i, depth + 1) + "]" }
        if let e = o["enum"]?.arrayValue { return t + "(" + e.compactMap(\.stringValue).joined(separator: "|") + ")" }
        return t
    }
    for m in await s.executor.manifests() {
        out += "### \(m.identifier) tier=\(m.defaultTier.rawValue) dry=\(m.supportsDryRun) idem=\(m.idempotent) mac=\(m.macPermissions.map(\.rawValue))\n  IN  \(compact(m.inputSchema.raw))\n  OUT \(compact(m.outputSchema.raw))\n"
    }
    try out.write(toFile: "/tmp/orix-manifests.txt", atomically: true, encoding: .utf8)
}
