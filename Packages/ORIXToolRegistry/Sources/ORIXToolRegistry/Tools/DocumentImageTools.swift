// ORIX OS Automation
// File: Packages/ORIXToolRegistry/Sources/ORIXToolRegistry/Tools/DocumentImageTools.swift
// Description: documents.imageInfo and documents.imageConvert (ImageIO): format, pixel size and metadata; conversion with a maximum dimension and quality, one file or a validated batch.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import ORIXCore

private var fm: FileManager { FileManager.default }
private func show(_ path: String) -> String { PathResolver.display(path) }

public struct DocumentsImageInfoTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "documents.imageInfo", name: "Image information",
        summary: "Returns the format, pixel size, resolution, colour model, alpha, orientation and frame count of an image file.",
        family: "documents",
        inputSchema: Schema.input(["path": Schema.path], required: ["path"]),
        outputSchema: Schema.output(["width": .integer(), "height": .integer(), "format": .string(), "bytes": .integer()], required: ["width", "height", "format", "bytes"]),
        sideEffect: .read, defaultTier: .readOnly, idempotent: true, outputIsUntrusted: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let path = try input.path("path", context)
        return ToolRequirements(capabilities: [.fileRead(path: path)], tier: .readOnly, summary: "Inspect the image \(show(path))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let path = try input.path("path", context)
        try ToolSupport.requireFile(path)
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int else {
            throw ToolError.unsupported("\(show(path)) is not an image ImageIO can read")
        }
        let uti = (CGImageSourceGetType(source) as String?) ?? "unknown"
        var out: [String: JSONValue] = [
            "path": .string(path), "width": .int(width), "height": .int(height), "format": .string(UTType(uti)?.preferredFilenameExtension ?? uti),
            "typeIdentifier": .string(uti), "bytes": .int(ToolSupport.fileSize(path)), "frames": .int(CGImageSourceGetCount(source)),
            "hasAlpha": .bool(props[kCGImagePropertyHasAlpha] as? Bool ?? false),
        ]
        if let v = props[kCGImagePropertyColorModel] as? String { out["colorModel"] = .string(v) }
        if let v = props[kCGImagePropertyDepth] as? Int { out["bitsPerComponent"] = .int(v) }
        if let v = props[kCGImagePropertyDPIWidth] as? Double { out["dpi"] = .number(v) }
        if let v = props[kCGImagePropertyOrientation] as? Int { out["orientation"] = .int(v) }
        if let v = props[kCGImagePropertyProfileName] as? String { out["colorProfile"] = .string(v) }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any], let d = exif[kCGImagePropertyExifDateTimeOriginal] as? String { out["captured"] = .string(d) }
        return .success(.object(out), summary: "\(show(path)): \(width)×\(height) \(out["format"]?.stringValue ?? "")")
    }
}

public struct DocumentsImageConvertTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "documents.imageConvert", name: "Convert images",
        summary: "Converts one image (source → destination file) or a batch (paths → destination folder) to png, jpeg, heic, tiff, gif or bmp, optionally scaled down to a maximum dimension. Sources are never modified and existing files are not replaced unless overwrite is true.",
        family: "documents",
        inputSchema: Schema.input([
            "source": .string("Single image to convert."), "paths": .array(of: .string(), "Images to convert as a batch."),
            "destination": .string("Output file (single) or output folder (batch)."),
            "format": .string("Required for a batch; inferred from the destination extension otherwise.", enum: ["png", "jpeg", "jpg", "heic", "tiff", "gif", "bmp"]),
            "maxDimension": .integer("Longest side in pixels; images are only ever scaled down.", minimum: 1, maximum: 30_000),
            "quality": JSONSchema(raw: ["type": "number", "minimum": 0.01, "maximum": 1, "description": "Lossy formats only (default 0.85)."]),
            "overwrite": .boolean(),
        ], required: ["destination"]),
        outputSchema: Schema.output(["converted": .array(of: .any), "count": .integer()], required: ["converted", "count"]),
        sideEffect: .write, defaultTier: .reversibleWrite, defaultTimeoutSeconds: 600, supportsDryRun: true)

    static let types: [String: UTType] = ["png": .png, "jpeg": .jpeg, "jpg": .jpeg, "heic": .heic, "tiff": .tiff, "gif": .gif, "bmp": .bmp]

    struct Job { let source: String; let destination: String }

    func plan(_ input: ToolInput, _ context: ToolExecutionContext) throws -> (jobs: [Job], type: UTType) {
        let destination = try input.path("destination", context)
        let single = try input.optionalPath("source", context)
        let batch = try input.strings("paths").map { try PathResolver.canonical($0, relativeTo: context.workingDirectory) }
        guard (single != nil) != !batch.isEmpty else { throw ToolError.invalidInput("give source (one image) or paths (a batch), not both") }
        let format = input.optionalString("format")
        if let single {
            let ext = (format ?? (destination as NSString).pathExtension).lowercased()
            guard let type = Self.types[ext] else { throw ToolError.invalidInput("cannot infer the output format; set format or use a known extension") }
            guard single != destination else { throw ToolError.invalidInput("destination is the source file") }
            return ([Job(source: single, destination: destination)], type)
        }
        guard let format, let type = Self.types[format] else { throw ToolError.invalidInput("format is required for a batch") }
        let ext = format == "jpg" ? "jpg" : (type.preferredFilenameExtension ?? format)
        var seen = Set<String>()
        let jobs: [Job] = try batch.map { source in
            let name = ((source as NSString).lastPathComponent as NSString).deletingPathExtension + "." + ext
            let target = destination + "/" + name
            guard seen.insert(target.lowercased()).inserted else { throw ToolError.invalidInput("two sources would produce the same output name \(name)") }
            guard target != source else { throw ToolError.invalidInput("\(name) would replace its own source; choose another destination folder") }
            return Job(source: source, destination: target)
        }
        return (jobs, type)
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let p = try plan(input, context)
        let caps = p.jobs.map { Capability.fileRead(path: $0.source) } + p.jobs.map { Capability.fileWrite(path: $0.destination) }
        let summary = p.jobs.count == 1 ? "Convert \(show(p.jobs[0].source)) to \(show(p.jobs[0].destination))"
            : "Convert \(p.jobs.count) images to \(p.type.preferredFilenameExtension ?? "images") in \(show((p.jobs[0].destination as NSString).deletingLastPathComponent))"
        return ToolRequirements(capabilities: caps, tier: .reversibleWrite, summary: summary)
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let p = try plan(input, context)
        let overwrite = input.bool("overwrite", default: false)
        let supported = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        guard supported.contains(p.type.identifier) else { throw ToolError.unsupported("This Mac cannot write \(p.type.identifier) images") }
        // Validate the whole batch before writing anything.
        for job in p.jobs {
            try ToolSupport.requireFile(job.source)
            let k = ToolSupport.kind(of: job.destination)
            if k.isDirectory { throw ToolError.invalidInput("\(show(job.destination)) is a directory") }
            if k.exists && !overwrite { throw ToolError.invalidInput("\(show(job.destination)) already exists; pass overwrite: true (a backup is kept) or choose another destination") }
        }
        if input.dryRun {
            return .simulated(["wouldConvert": .array(p.jobs.map { ["source": .string($0.source), "destination": .string($0.destination)] }), "count": .int(p.jobs.count)],
                              summary: "Would convert \(ToolSupport.plural(p.jobs.count, "image"))")
        }
        let maxDimension = input.arguments["maxDimension"]?.intValue
        let quality = input.double("quality", default: 0.85)
        var converted: [JSONValue] = []
        var artifacts: [Artifact] = []
        for job in p.jobs {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: job.source) as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
                throw ToolError.unsupported("\(show(job.source)) is not an image ImageIO can read")
            }
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let longest = max(props?[kCGImagePropertyPixelWidth] as? Int ?? 0, props?[kCGImagePropertyPixelHeight] as? Int ?? 0)
            let image: CGImage?
            if let maxDimension, longest > maxDimension {
                image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                ] as CFDictionary)
            } else {
                image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            }
            guard let image else { throw ToolError.unsupported("\(show(job.source)) cannot be decoded") }
            let parent = (job.destination as NSString).deletingLastPathComponent
            let staging = parent + "/.orix-image-" + UUID().uuidString.prefix(8)
            var backup: String?
            try ToolSupport.io("Writing \(show(job.destination))") {
                try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
                defer { try? fm.removeItem(atPath: staging) }
                guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: staging) as CFURL, p.type.identifier as CFString, 1, nil) else {
                    throw ToolError.io("Cannot create \(show(job.destination))")
                }
                var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
                // Keep the orientation when the pixels were not re-oriented by the thumbnail path.
                if maxDimension == nil || longest <= (maxDimension ?? 0), let o = props?[kCGImagePropertyOrientation] { options[kCGImagePropertyOrientation] = o }
                CGImageDestinationAddImage(dest, image, options as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { throw ToolError.io("Encoding \(show(job.destination)) failed") }
                if ToolSupport.kind(of: job.destination).exists {
                    backup = try ToolSupport.backup(job.destination, context: context)
                    try fm.removeItem(atPath: job.destination)
                }
                try fm.moveItem(atPath: staging, toPath: job.destination)
            }
            converted.append(["source": .string(job.source), "destination": .string(job.destination), "width": .int(image.width), "height": .int(image.height),
                              "bytes": .int(ToolSupport.fileSize(job.destination)), "backupPath": backup.map(JSONValue.string) ?? .null])
            if let backup { artifacts.append(ToolSupport.artifact(backup, note: "Backup of \(show(job.destination)) before it was replaced")) }
        }
        return .success(["converted": .array(converted), "count": .int(converted.count)],
                        summary: "Converted \(ToolSupport.plural(converted.count, "image")) to \(p.type.preferredFilenameExtension ?? "image")", artifacts: artifacts)
    }
}
