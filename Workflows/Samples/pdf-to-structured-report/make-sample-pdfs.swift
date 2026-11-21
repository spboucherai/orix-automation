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
