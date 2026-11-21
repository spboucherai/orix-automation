// ORIX OS Automation
// File: Scripts/tools/dmg-background.swift
// Description: Draws the disk-image window background (660 × 440 pt, rendered at 2x): ORIX canvas, arrow and install hint.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-background.png"
let size = CGSize(width: 660, height: 440), scale: CGFloat = 2
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let c = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
c.scaleBy(x: scale, y: scale)
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a) }
c.drawLinearGradient(CGGradient(colorsSpace: space, colors: [rgb(0x1D2440), rgb(0x0A0D18)] as CFArray, locations: nil)!, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: 0), options: [])
c.drawRadialGradient(CGGradient(colorsSpace: space, colors: [rgb(0x22D3EE, 0.16), rgb(0x22D3EE, 0)] as CFArray, locations: nil)!, startCenter: CGPoint(x: 170, y: 250), startRadius: 0, endCenter: CGPoint(x: 170, y: 250), endRadius: 320, options: [])
// Arrow from the app icon (170, 240 from the bottom) to the Applications alias (490).
c.setStrokeColor(rgb(0x22D3EE, 0.9)); c.setLineWidth(5); c.setLineCap(.round); c.setLineJoin(.round)
c.move(to: CGPoint(x: 272, y: 240)); c.addLine(to: CGPoint(x: 388, y: 240))
c.move(to: CGPoint(x: 368, y: 258)); c.addLine(to: CGPoint(x: 388, y: 240)); c.addLine(to: CGPoint(x: 368, y: 222))
c.strokePath()
NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
func draw(_ text: String, _ font: NSFont, _ color: NSColor, y: CGFloat) {
    let a = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    a.draw(at: CGPoint(x: (size.width - a.size().width) / 2, y: y))
}
draw("ORIX OS Automation", .systemFont(ofSize: 24, weight: .bold), .white, y: 372)
draw("Understand Every Pulse of Your Mac.", .systemFont(ofSize: 13, weight: .regular), NSColor(white: 1, alpha: 0.65), y: 348)
draw("Drag ORIX OS Automation to the Applications folder", .systemFont(ofSize: 13, weight: .medium), NSColor(white: 1, alpha: 0.8), y: 52)
let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
rep.size = size   // 144 dpi: Finder shows it at 660 × 440 pt
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
