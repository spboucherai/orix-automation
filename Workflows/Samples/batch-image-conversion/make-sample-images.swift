// ORIX OS Automation
// File: Workflows/Samples/batch-image-conversion/make-sample-images.swift
// Description: Regenerates the synthetic sample images of the "Batch image conversion and naming" example with CoreGraphics and ImageIO.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
//
// Usage: swift make-sample-images.swift <output folder>    (the committed files were made with: swift make-sample-images.swift Originals)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Originals")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// A two-colour gradient with a few rectangles: enough structure to see that a conversion kept the picture.
func picture(width: Int, height: Int, from: [CGFloat], to: [CGFloat], alpha: Bool) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
    let gradient = CGGradient(colorSpace: space, colorComponents: from + [1] + to + [1], locations: [0, 1], count: 2)!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.8))
    for i in 0..<4 { ctx.fill(CGRect(x: width / 8 + i * width / 5, y: height / 3, width: width / 10, height: height / 3)) }
    if alpha { ctx.clear(CGRect(x: 0, y: 0, width: width / 6, height: height / 6)) }
    return ctx.makeImage()!
}

func write(_ image: CGImage, _ name: String, _ type: UTType) {
    let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(name)") }
    print("wrote \(name)")
}

write(picture(width: 320, height: 200, from: [0.42, 0.36, 0.91], to: [0.10, 0.60, 0.95], alpha: true), "diagram.png", .png)
write(picture(width: 640, height: 360, from: [0.95, 0.55, 0.10], to: [0.80, 0.10, 0.30], alpha: false), "sunset.jpg", .jpeg)
write(picture(width: 200, height: 200, from: [0.10, 0.70, 0.40], to: [0.05, 0.30, 0.20], alpha: false), "tile.tiff", .tiff)
write(picture(width: 120, height: 80, from: [0.20, 0.20, 0.20], to: [0.90, 0.90, 0.90], alpha: false), "badge.gif", .gif)
write(picture(width: 96, height: 96, from: [0.90, 0.85, 0.20], to: [0.95, 0.40, 0.10], alpha: false), "Icon Large.PNG", .png)
