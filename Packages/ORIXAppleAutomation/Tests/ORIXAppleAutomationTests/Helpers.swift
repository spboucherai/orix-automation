// ORIX OS Automation
// File: Packages/ORIXAppleAutomation/Tests/ORIXAppleAutomationTests/Helpers.swift
// Description: Test helpers: an executor-like invocation (schema validation, requirements, execute, error conversion), skip reporting and image rendering.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import ORIXCore
import ORIXTestingSupport
import Testing
@testable import ORIXAppleAutomation

struct Outcome {
    var result: ToolResult
    var error: ToolError?
    var requirements: ToolRequirements?
}

/// Mirrors the first steps of the real ToolExecutor: input schema, requirements, execute, ToolError conversion, output schema.
func invoke(_ tool: any ORIXTool, _ arguments: JSONValue, in dir: TempDirectory, dryRun: Bool = false, timeout: Double = 30) async -> Outcome {
    let violations = tool.manifest.inputSchema.validate(arguments)
    if !violations.isEmpty {
        let e = ToolError.invalidInput(violations.map(\.description).joined(separator: "; "))
        return Outcome(result: .failure(e.status, e.failure), error: e)
    }
    var context = dir.toolContext()
    context.timeoutSeconds = timeout
    let input = ToolInput(arguments: arguments, dryRun: dryRun)
    var requirements: ToolRequirements?
    do {
        requirements = try tool.requirements(for: input, context: context)
        let result = try await tool.execute(input: input, context: context)
        if result.status == .succeeded {
            let bad = tool.manifest.outputSchema.validate(result.output)
            #expect(bad.isEmpty, "output of \(tool.identifier) violates its schema: \(bad)")
        }
        return Outcome(result: result, requirements: requirements)
    } catch let e as ToolError {
        return Outcome(result: .failure(e.status, e.failure), error: e, requirements: requirements)
    } catch {
        Issue.record("\(tool.identifier) threw a non-ToolError: \(error)")
        return Outcome(result: .failure(.failed, ToolFailure(code: "internal", message: "\(error)")))
    }
}

func skipped(_ reason: String) {
    print("SKIPPED(\(reason))")
}

func verified(_ what: String) {
    print("VERIFIED(\(what))")
}

enum TestImages {
    /// White canvas with black text lines, written as PNG.
    static func text(_ lines: [String], to url: URL, width: Int = 1100, height: Int = 320, fontSize: CGFloat = 56) throws {
        let ctx = try context(width: width, height: height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        for (i, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            ctx.textPosition = CGPoint(x: 40, y: CGFloat(height) - CGFloat(i + 1) * (fontSize * 1.6))
            CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
        }
        try write(ctx, to: url)
    }

    /// Solid background with optional filled rectangles (top-left origin, pixels).
    static func blocks(width: Int, height: Int, background: CGFloat, rects: [(CGRect, CGFloat)], to url: URL) throws {
        let ctx = try context(width: width, height: height)
        ctx.setFillColor(CGColor(gray: background, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (r, gray) in rects {
            ctx.setFillColor(CGColor(gray: gray, alpha: 1))
            ctx.fill(CGRect(x: r.minX, y: CGFloat(height) - r.maxY, width: r.width, height: r.height))
        }
        try write(ctx, to: url)
    }

    private static func context(width: Int, height: Int) throws -> CGContext {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ToolError.internalError("no bitmap context") }
        return ctx
    }

    private static func write(_ ctx: CGContext, to url: URL) throws {
        guard let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw ToolError.internalError("no image")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ToolError.io("could not write \(url.path)") }
    }
}
