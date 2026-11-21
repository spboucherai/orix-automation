// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Scripts/tools/make-icon.swift
// Description      : Draws the app icon (graphite squircle, violet-to-blue
//                    orbit with three workflow nodes) at every macOS size into
//                    the asset catalog.
// Module           : Scripts
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

import AppKit

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: s, height: s)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let inset = s * 0.1
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let cs = CGColorSpaceCreateDeviceRGB()
    let bg = CGGradient(colorsSpace: cs, colors: [NSColor(srgbRed: 0.13, green: 0.12, blue: 0.19, alpha: 1).cgColor, NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    let glow = CGGradient(colorsSpace: cs, colors: [NSColor(srgbRed: 0.56, green: 0.42, blue: 1, alpha: 0.45).cgColor, NSColor(srgbRed: 0.56, green: 0.42, blue: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: s * 0.36, y: s * 0.68), startRadius: 0, endCenter: CGPoint(x: s * 0.36, y: s * 0.68), endRadius: s * 0.5, options: [])
    ctx.restoreGState()
    // Orbit ring
    let c = CGPoint(x: s / 2, y: s / 2), r = s * 0.235, lw = s * 0.062
    ctx.saveGState()
    ctx.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.setLineWidth(lw); ctx.replacePathWithStrokedPath(); ctx.clip()
    let ring = CGGradient(colorsSpace: cs, colors: [NSColor(srgbRed: 0.62, green: 0.47, blue: 1, alpha: 1).cgColor, NSColor(srgbRed: 0.33, green: 0.55, blue: 1, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(ring, start: CGPoint(x: c.x - r, y: c.y + r), end: CGPoint(x: c.x + r, y: c.y - r), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
    // Three nodes on the orbit, linked to the centre: plan, act, verify
    for (i, a) in [CGFloat.pi * 0.5, .pi * 7 / 6, .pi * 11 / 6].enumerated() {
        let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(s * 0.012)
        ctx.move(to: c); ctx.addLine(to: p); ctx.strokePath()
        let nr = s * (i == 0 ? 0.062 : 0.052)
        ctx.setFillColor(NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - nr * 1.25, y: p.y - nr * 1.25, width: nr * 2.5, height: nr * 2.5))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - nr, y: p.y - nr, width: nr * 2, height: nr * 2))
    }
    ctx.setFillColor(NSColor.white.cgColor)
    let cr = s * 0.04
    ctx.fillEllipse(in: CGRect(x: c.x - cr, y: c.y - cr, width: cr * 2, height: cr * 2))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
var images: [[String: String]] = []
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    try draw(pt * scale).write(to: out.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
}
let json = try JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys])
try json.write(to: out.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icon images")
