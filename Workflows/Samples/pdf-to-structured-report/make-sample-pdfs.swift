// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Workflows/Samples/pdf-to-structured-report/make-sample-pdfs.swift
// Module           : Workflows
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

// ORIX OS Automation
// File: Workflows/Samples/pdf-to-structured-report/make-sample-pdfs.swift
// Description: Regenerates the synthetic sample PDFs of the "PDF to structured data and report" example with CoreGraphics and CoreText.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
//
// Usage: swift make-sample-pdfs.swift <output folder>      (the committed files were made with: swift make-sample-pdfs.swift Input)
import CoreGraphics
import CoreText
import Foundation

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Input")
try FileManager.default.createDirectory(at: out.appendingPathComponent("archive"), withIntermediateDirectories: true)

/// Writes one PDF: each element of `pages` is the text of one page; nil draws shapes only (a page without a text layer).
func makePDF(_ name: String, title: String?, pages: [String?]) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    var info: [CFString: Any] = [kCGPDFContextCreator: "ORIX sample generator"]
    if let title { info[kCGPDFContextTitle] = title; info[kCGPDFContextAuthor] = "ORIX samples" }
    guard let ctx = CGContext(out.appendingPathComponent(name) as CFURL, mediaBox: &box, info as CFDictionary) else { fatalError("cannot create \(name)") }
    for text in pages {
        ctx.beginPDFPage(nil)
        if let text {
            let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
            let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(location: 0, length: 0),
                                                 CGPath(rect: box.insetBy(dx: 72, dy: 72), transform: nil), nil)
            CTFrameDraw(frame, ctx)
        } else {
            ctx.setFillColor(CGColor(gray: 0.85, alpha: 1)); ctx.fill(CGRect(x: 72, y: 500, width: 468, height: 200))
            ctx.setStrokeColor(CGColor(gray: 0.3, alpha: 1)); ctx.setLineWidth(3)
            for i in 0..<6 { ctx.stroke(CGRect(x: 90 + Double(i) * 70, y: 200, width: 50, height: 180)) }
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
    print("wrote \(name)")
}

makePDF("quarterly-summary.pdf", title: "Quarterly summary Q3", pages: [
    "Quarterly summary — third quarter (synthetic sample)\n\nRevenue grew by four percent. Support tickets fell by a tenth.\nThe team shipped the CSV export and postponed the PDF export.",
])
makePDF("field-notes.pdf", title: "Field notes", pages: [
    "Field notes, page one (synthetic sample)\n\nSite A: two battery containers, both online.\nSite B: one inverter replaced in October.",
    "Field notes, page two\n\nOpen questions: spare inverter contract, recycling rates.",
    "Field notes, page three\n\nNext visit planned for the first week of December.",
])
makePDF("untitled-memo.pdf", title: nil, pages: ["Memo without a title property (synthetic sample).\n\nPlease read before Friday."])
makePDF("archive/scan-without-text.pdf", title: "Scanned page", pages: [nil])
