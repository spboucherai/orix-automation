// ORIX OS Automation
// File: Packages/ORIXAppleAutomation/Sources/ORIXAppleAutomation/ScreenTools.swift
// Description: screen.capture (ScreenCaptureKit screenshots of a display, window or region), screen.ocr (Vision text recognition on an image file) and screen.compare (pixel difference of two image files).
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import ORIXCore
@preconcurrency import ScreenCaptureKit
import Vision

// MARK: Image helpers

enum ImageIOHelper {
    static func load(_ path: String) throws -> CGImage {
        guard FileManager.default.fileExists(atPath: path) else { throw ToolError.notFound("No file at \(path)") }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ToolError.invalidInput("\(path) is not an image this Mac can decode")
        }
        return image
    }

    static func writePNG(_ image: CGImage, to path: String, overwrite: Bool = true) throws -> Artifact {
        let url = URL(fileURLWithPath: path)
        if !overwrite, FileManager.default.fileExists(atPath: path) { throw ToolError.io("\(path) already exists") }
        do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { throw ToolError.io("Could not create \(url.deletingLastPathComponent().path): \(error.localizedDescription)") }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw ToolError.io("Could not create \(path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ToolError.io("Could not write the PNG to \(path)") }
        let data = (try? Data(contentsOf: url)) ?? Data()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Artifact(path: path, kind: "screenshot", bytes: data.count, sha256: hash)
    }

    /// Decodes an image into tightly packed RGBA8 (sRGB, premultiplied) so two images can be compared byte for byte.
    static func rgba(_ image: CGImage) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w * h <= 120_000_000 else { throw ToolError.invalidInput("Image is empty or larger than 120 megapixels") }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw ToolError.internalError("Could not decode the image into a bitmap") }
        return (pixels, w, h)
    }
}

enum Displays {
    /// Active displays, main display first: the index used by `screen.capture` and `system.windows`.
    static func active() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func scale(_ id: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return 1 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    /// Index of the display containing the centre of `rect` (global coordinates, origin at the top-left of the main display).
    static func index(containing rect: CGRect) -> Int? {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        return active().firstIndex { CGDisplayBounds($0).contains(centre) }
    }
}

// MARK: screen.capture

public struct ScreenCaptureTool: ORIXTool {
    /// Applications whose windows are never captured: password managers and the system credential stores.
    public static let defaultSensitiveBundleIDs: Set<String> = [
        "com.apple.keychainaccess", "com.apple.passwords", "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.lastpass.lastpass", "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc", "in.sinew.enpass-desktop",
        "com.apple.securityagent", "com.apple.localauthentication.ui", "ai.spboucher.spvault", "ai.spboucher.sp-vault",
    ]

    public let sensitiveBundleIDs: Set<String>

    public init(additionalSensitiveBundleIDs: Set<String> = []) {
        sensitiveBundleIDs = Self.defaultSensitiveBundleIDs.union(additionalSensitiveBundleIDs.map { $0.lowercased() })
    }

    public var manifest: ToolManifest {
        ToolManifest(
            identifier: "screen.capture", name: "Capture the screen",
            summary: "Takes a PNG screenshot of one display, of an application's frontmost window, or of a rectangular region. Windows of password managers are left out, and nothing is captured while secure keyboard input is active.",
            family: "screen",
            inputSchema: .object([
                "scope": .string("What to capture.", enum: ["display", "window", "region"]),
                "displayIndex": .integer("Display to capture for scope display (0 is the main display).", minimum: 0, maximum: 15),
                "bundleID": .string("Application whose frontmost window is captured, for scope window."),
                "region": .object(["x": .number(), "y": .number(), "width": .number(), "height": .number()], required: ["x", "y", "width", "height"],
                                  description: "Rectangle in global screen points (origin top-left of the main display), for scope region."),
                "path": .string("Where to write the PNG (default: the run's artifacts directory)."),
                "overwrite": .boolean("Replace an existing file at path (default false)."),
            ], required: ["scope"]),
            outputSchema: outputObject(["path": .string(), "pixelWidth": .integer(), "pixelHeight": .integer(), "scale": .number(), "scope": .string()],
                                       required: ["path", "pixelWidth", "pixelHeight", "scale", "scope"]),
            sideEffect: .write, defaultTier: .reversibleWrite, macPermissions: [.screenRecording], defaultTimeoutSeconds: 30,
            concurrency: .serial, idempotent: false, outputIsUntrusted: false,
            examples: [["scope": "window", "bundleID": "com.apple.finder"]])
    }

    struct Plan: Sendable {
        var scope: String
        var displayIndex = 0
        var bundleID: String?
        var region: CGRect?
        var path: String
        var overwrite: Bool
        var capabilityScope: String
    }

    func plan(_ input: ToolInput, context: ToolExecutionContext) throws -> Plan {
        let scope = try input.string("scope")
        let raw = input.optionalString("path") ?? context.artifactsDirectory.appendingPathComponent("screenshot-\(context.callID).png").path
        let path = try PathResolver.canonical(raw, relativeTo: context.workingDirectory)
        guard path.lowercased().hasSuffix(".png") else { throw ToolError.invalidInput("path must end in .png") }
        var plan = Plan(scope: scope, path: path, overwrite: input.bool("overwrite", default: input.optionalString("path") == nil), capabilityScope: scope)
        switch scope {
        case "display":
            plan.displayIndex = input.int("displayIndex", default: 0)
        case "window":
            guard input.optionalString("bundleID") != nil else { throw ToolError.invalidInput("bundleID is required for scope window") }
            let id = try input.bundleID()
            guard !sensitiveBundleIDs.contains(id.lowercased()) else {
                throw ToolError.permissionDenied("Windows of \(AppResolver.displayName(id)) are never captured: it holds passwords or credentials.")
            }
            plan.bundleID = id
            plan.capabilityScope = "window:\(id)"
        case "region":
            guard let r = input.arguments["region"], let x = r["x"]?.doubleValue, let y = r["y"]?.doubleValue,
                  let w = r["width"]?.doubleValue, let h = r["height"]?.doubleValue else { throw ToolError.invalidInput("region {x, y, width, height} is required for scope region") }
            guard w >= 1, h >= 1, w <= 20_000, h <= 20_000 else { throw ToolError.invalidInput("region width and height must be between 1 and 20000 points") }
            plan.region = CGRect(x: x, y: y, width: w, height: h)
        default:
            throw ToolError.invalidInput("scope must be display, window or region")
        }
        return plan
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let p = try plan(input, context: context)
        let what: String
        switch p.scope {
        case "display": what = "display \(p.displayIndex)"
        case "window": what = "the frontmost window of \(AppResolver.displayName(p.bundleID ?? ""))"
        default: what = "a \(Int(p.region?.width ?? 0))×\(Int(p.region?.height ?? 0)) point region of the screen"
        }
        return ToolRequirements(capabilities: [.screenCapture(scope: p.capabilityScope), .fileWrite(path: p.path)], tier: .reversibleWrite,
                                summary: "Capture \(what) to \(PathResolver.display(p.path))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let p = try plan(input, context: context)
        guard CGPreflightScreenCaptureAccess() else {
            throw ToolError.tccBlocked(.screenRecording, "Screen Recording access is not enabled for this app. " + MacPermissions.howToEnable(.screenRecording))
        }
        guard !IsSecureEventInputEnabled() else {
            throw ToolError.permissionDenied("Secure keyboard input is active: a password field has focus. Nothing is captured until it is dismissed.")
        }
        if !p.overwrite, FileManager.default.fileExists(atPath: p.path) { throw ToolError.io("\(p.path) already exists (pass overwrite: true to replace it)") }

        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw Self.map(error) }
        let hiddenApps = content.applications.filter { sensitiveBundleIDs.contains($0.bundleIdentifier.lowercased()) }
        let config = SCStreamConfiguration()
        config.showsCursor = false
        var details: [String: JSONValue] = ["scope": .string(p.scope), "excludedApplications": .array(hiddenApps.map { .string($0.bundleIdentifier) })]
        let filter: SCContentFilter
        var scale = 1.0

        func display(at index: Int) throws -> SCDisplay {
            let ids = Displays.active()
            guard ids.indices.contains(index), let d = content.displays.first(where: { $0.displayID == ids[index] }) else {
                throw ToolError.notFound("There is no display \(index) (\(ids.count) display(s) connected)")
            }
            return d
        }

        switch p.scope {
        case "display":
            let d = try display(at: p.displayIndex)
            scale = Displays.scale(d.displayID)
            filter = SCContentFilter(display: d, excludingApplications: hiddenApps, exceptingWindows: [])
            config.width = Int((Double(d.width) * scale).rounded())
            config.height = Int((Double(d.height) * scale).rounded())
            details["displayIndex"] = .int(p.displayIndex)
        case "region":
            let rect = p.region!
            guard let index = Displays.index(containing: rect) else { throw ToolError.invalidInput("The region is not on any connected display") }
            let d = try display(at: index)
            scale = Displays.scale(d.displayID)
            let local = rect.offsetBy(dx: -d.frame.origin.x, dy: -d.frame.origin.y).intersection(CGRect(x: 0, y: 0, width: d.width, height: d.height))
            guard local.width >= 1, local.height >= 1 else { throw ToolError.invalidInput("The region is not on any connected display") }
            filter = SCContentFilter(display: d, excludingApplications: hiddenApps, exceptingWindows: [])
            config.sourceRect = local
            config.width = Int((Double(local.width) * scale).rounded())
            config.height = Int((Double(local.height) * scale).rounded())
            details["displayIndex"] = .int(index)
            details["region"] = rectJSON(local.offsetBy(dx: d.frame.origin.x, dy: d.frame.origin.y))
        default:
            let id = p.bundleID!
            let pids = Set(AppResolver.running(id).map(\.processIdentifier))
            guard !pids.isEmpty else {
                return TypedFailure(code: "app_not_running", message: "\(AppResolver.displayName(id)) is not running.", recovery: "Launch it with system.launchApp.", retryable: true).result
            }
            // CGWindowList is ordered front to back: the first normal-layer window of the app is its frontmost one.
            let ordered = WindowList.onScreen().filter { pids.contains($0.pid) && $0.layer == 0 && $0.bounds.width > 1 && $0.bounds.height > 1 }
            guard let front = ordered.first, let window = content.windows.first(where: { $0.windowID == front.id }) else {
                return TypedFailure(code: "window_not_found", message: "\(AppResolver.displayName(id)) has no window on screen.", retryable: true).result
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            scale = Double(filter.pointPixelScale)
            config.width = Int((Double(window.frame.width) * scale).rounded())
            config.height = Int((Double(window.frame.height) * scale).rounded())
            config.ignoreShadowsSingleWindow = true
            details["windowTitle"] = .string(window.title ?? "")
            details["windowID"] = .int(Int(window.windowID))
            details["frame"] = rectJSON(window.frame)
        }

        try Task.checkCancellation()
        let image: CGImage
        do { image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) }
        catch { throw Self.map(error) }
        // Re-check after the capture: if a password field took focus meanwhile, the image is discarded.
        guard !IsSecureEventInputEnabled() else {
            throw ToolError.permissionDenied("Secure keyboard input became active during the capture; the image was discarded.")
        }
        var artifact = try ImageIOHelper.writePNG(image, to: p.path, overwrite: p.overwrite)
        artifact.note = "Screenshot (\(p.scope)) \(image.width)×\(image.height) px at \(scale)x"
        details["path"] = .string(p.path)
        details["pixelWidth"] = .int(image.width)
        details["pixelHeight"] = .int(image.height)
        details["scale"] = .number(scale)
        details["bytes"] = .int(artifact.bytes)
        return .success(.object(details), summary: "Captured \(p.scope) \(image.width)×\(image.height) px to \(PathResolver.display(p.path))", artifacts: [artifact])
    }

    static func map(_ error: Error) -> ToolError {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain, ns.code == SCStreamError.userDeclined.rawValue {
            return .tccBlocked(.screenRecording, "macOS refused the capture: Screen Recording access is not enabled for this app. " + MacPermissions.howToEnable(.screenRecording))
        }
        return .io("Screen capture failed: \(ns.localizedDescription) (\(ns.domain) \(ns.code))")
    }
}

// MARK: screen.ocr

public struct ScreenOCRTool: ORIXTool {
    public init() {}
    public var manifest: ToolManifest {
        ToolManifest(
            identifier: "screen.ocr", name: "Recognise text in an image",
            summary: "Recognises text in an image file (PNG, JPEG, TIFF, HEIC …) on this Mac with Vision and returns text blocks with confidence and bounding boxes (top-left origin, normalised and in pixels).",
            family: "screen",
            inputSchema: .object([
                "path": .string("Image file."),
                "languages": .array(of: .string(), "Preferred recognition languages, for example [\"en-US\", \"fr-FR\"] (default: automatic)."),
                "fast": .boolean("Use the fast recogniser instead of the accurate one (default false)."),
                "maxBlocks": .integer("Maximum text blocks returned (default 400).", minimum: 1, maximum: 5000),
            ], required: ["path"]),
            outputSchema: outputObject([
                "text": .string(), "imageWidth": .integer(), "imageHeight": .integer(),
                "blocks": .array(of: outputObject(["text": .string(), "confidence": .number(), "normalized": .any, "pixels": .any], required: ["text", "confidence", "normalized", "pixels"])),
            ], required: ["text", "blocks", "imageWidth", "imageHeight"]),
            sideEffect: .read, defaultTier: .readOnly, defaultTimeoutSeconds: 120, idempotent: true, outputIsUntrusted: true,
            examples: [["path": "artifacts/screenshot.png"]])
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let path = try PathResolver.canonical(try input.string("path"), relativeTo: context.workingDirectory)
        return ToolRequirements(capabilities: [.fileRead(path: path)], tier: .readOnly, summary: "Recognise the text in \(PathResolver.display(path))")
    }

    struct Block: Sendable { var text: String; var confidence: Double; var box: CGRect }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let path = try PathResolver.canonical(try input.string("path"), relativeTo: context.workingDirectory)
        let languages = input.strings("languages"), fast = input.bool("fast", default: false), maxBlocks = input.int("maxBlocks", default: 400)
        let (blocks, width, height) = try await runBlocking { () -> ([Block], Int, Int) in
            let image = try ImageIOHelper.load(path)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = fast ? .fast : .accurate
            request.usesLanguageCorrection = true
            if languages.isEmpty { request.automaticallyDetectsLanguage = true } else { request.recognitionLanguages = languages }
            do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
            catch { throw ToolError.internalError("Text recognition failed: \(error.localizedDescription)") }
            let blocks = (request.results ?? []).compactMap { observation -> Block? in
                guard let best = observation.topCandidates(1).first else { return nil }
                // Vision's origin is bottom-left: flip to top-left.
                let b = observation.boundingBox
                return Block(text: best.string, confidence: Double(best.confidence), box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
            }
            return (blocks, image.width, image.height)
        }
        try Task.checkCancellation()
        let kept = blocks.prefix(maxBlocks)
        let (text, cut) = kept.map(\.text).joined(separator: "\n").truncated(maxBytes: 150_000)
        let json = kept.map { b -> JSONValue in
            let px = CGRect(x: (b.box.minX * Double(width)).rounded(), y: (b.box.minY * Double(height)).rounded(),
                            width: (b.box.width * Double(width)).rounded(), height: (b.box.height * Double(height)).rounded())
            return ["text": .string(b.text), "confidence": .number((b.confidence * 1000).rounded() / 1000), "normalized": rectJSON(b.box), "pixels": rectJSON(px)]
        }
        var result = ToolResult.success(["text": .string(text), "blocks": .array(json), "imageWidth": .int(width), "imageHeight": .int(height),
                                         "blockCount": .int(blocks.count)],
                                        summary: "Recognised \(blocks.count) text block(s) in \(PathResolver.display(path))")
        result.truncated = cut || blocks.count > maxBlocks
        result.untrusted = true
        return result
    }
}

// MARK: screen.compare

public struct ScreenCompareTool: ORIXTool {
    public init() {}
    public var manifest: ToolManifest {
        ToolManifest(
            identifier: "screen.compare", name: "Compare two images",
            summary: "Compares two image files of the same pixel size and returns the ratio of changed pixels and the bounding box of the difference; can write an annotated PNG showing what changed.",
            family: "screen",
            inputSchema: .object([
                "before": .string("First image file."),
                "after": .string("Second image file."),
                "tolerance": .integer("Per-channel difference (0–255) below which a pixel counts as unchanged (default 8).", minimum: 0, maximum: 255),
                "diffPath": .string("Optional PNG to write: the second image with changed pixels tinted red and the difference outlined."),
                "overwrite": .boolean("Replace an existing file at diffPath (default false)."),
            ], required: ["before", "after"]),
            outputSchema: outputObject(["identical": .boolean(), "changedPixels": .integer(), "totalPixels": .integer(), "changedRatio": .number(),
                                        "width": .integer(), "height": .integer()],
                                       required: ["identical", "changedPixels", "totalPixels", "changedRatio", "width", "height"]),
            sideEffect: .write, defaultTier: .reversibleWrite, defaultTimeoutSeconds: 120, idempotent: true)
    }

    struct Plan: Sendable { var before: String; var after: String; var diffPath: String?; var tolerance: Int; var overwrite: Bool }

    func plan(_ input: ToolInput, context: ToolExecutionContext) throws -> Plan {
        let diff = try input.optionalString("diffPath").map { try PathResolver.canonical($0, relativeTo: context.workingDirectory) }
        if let diff, !diff.lowercased().hasSuffix(".png") { throw ToolError.invalidInput("diffPath must end in .png") }
        return Plan(before: try PathResolver.canonical(try input.string("before"), relativeTo: context.workingDirectory),
                    after: try PathResolver.canonical(try input.string("after"), relativeTo: context.workingDirectory),
                    diffPath: diff, tolerance: input.int("tolerance", default: 8), overwrite: input.bool("overwrite", default: false))
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let p = try plan(input, context: context)
        var caps: [Capability] = [.fileRead(path: p.before), .fileRead(path: p.after)]
        if let d = p.diffPath { caps.append(.fileWrite(path: d)) }
        return ToolRequirements(capabilities: caps, tier: p.diffPath == nil ? .readOnly : .reversibleWrite,
                                summary: "Compare \(PathResolver.display(p.before)) with \(PathResolver.display(p.after))" + (p.diffPath.map { " and write the difference to \(PathResolver.display($0))" } ?? ""))
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let p = try plan(input, context: context)
        return try await catchingTypedFailures {
            try await runBlocking {
                let a = try ImageIOHelper.rgba(try ImageIOHelper.load(p.before))
                let afterImage = try ImageIOHelper.load(p.after)
                var b = try ImageIOHelper.rgba(afterImage)
                guard a.width == b.width, a.height == b.height else {
                    throw TypedFailure(code: "size_mismatch", message: "The images differ in size (\(a.width)×\(a.height) and \(b.width)×\(b.height) px) and cannot be compared pixel by pixel.",
                                       output: ["before": ["width": .int(a.width), "height": .int(a.height)], "after": ["width": .int(b.width), "height": .int(b.height)]])
                }
                let w = a.width, h = a.height
                var changed = 0, minX = w, minY = h, maxX = -1, maxY = -1
                let annotate = p.diffPath != nil
                for y in 0..<h {
                    if y % 256 == 0, Task.isCancelled { throw ToolError.canceled }
                    let row = y * w * 4
                    for x in 0..<w {
                        let i = row + x * 4
                        let d = max(abs(Int(a.pixels[i]) - Int(b.pixels[i])), abs(Int(a.pixels[i + 1]) - Int(b.pixels[i + 1])),
                                    abs(Int(a.pixels[i + 2]) - Int(b.pixels[i + 2])), abs(Int(a.pixels[i + 3]) - Int(b.pixels[i + 3])))
                        if d > p.tolerance {
                            changed += 1
                            if x < minX { minX = x }; if x > maxX { maxX = x }
                            if y < minY { minY = y }; if y > maxY { maxY = y }
                            if annotate {
                                b.pixels[i] = UInt8(min(255, Int(b.pixels[i]) / 2 + 128)); b.pixels[i + 1] /= 2; b.pixels[i + 2] /= 2; b.pixels[i + 3] = 255
                            }
                        }
                    }
                }
                let total = w * h
                var out: [String: JSONValue] = [
                    "identical": .bool(changed == 0), "changedPixels": .int(changed), "totalPixels": .int(total),
                    "changedRatio": .number(Double(changed) / Double(total)), "width": .int(w), "height": .int(h), "tolerance": .int(p.tolerance),
                ]
                let box = changed > 0 ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) : nil
                if let box { out["boundingBox"] = rectJSON(box) }
                var artifacts: [Artifact] = []
                if let diffPath = p.diffPath {
                    let image = try Self.annotated(pixels: &b.pixels, width: w, height: h, box: box)
                    var artifact = try ImageIOHelper.writePNG(image, to: diffPath, overwrite: p.overwrite)
                    artifact.kind = "file"
                    artifact.note = "Difference image: changed pixels tinted red"
                    artifacts.append(artifact)
                    out["diffPath"] = .string(diffPath)
                }
                let percent = String(format: "%.2f", 100 * Double(changed) / Double(total))
                return .success(.object(out), summary: changed == 0 ? "The images are identical (tolerance \(p.tolerance))" : "\(percent) % of pixels differ", artifacts: artifacts)
            }
        }
    }

    /// Builds the annotated image: the tinted bitmap with a 2-pixel red outline around the bounding box of the difference.
    static func annotated(pixels: inout [UInt8], width: Int, height: Int, box: CGRect?) throws -> CGImage {
        let image: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            if let box {
                // Bitmap rows are top-down, the context's coordinates bottom-up.
                let flipped = CGRect(x: box.minX, y: CGFloat(height) - box.maxY, width: box.width, height: box.height).insetBy(dx: -3, dy: -3)
                ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
                ctx.setLineWidth(2)
                ctx.stroke(flipped)
            }
            return ctx.makeImage()
        }
        guard let image else { throw ToolError.internalError("Could not render the difference image") }
        return image
    }
}
