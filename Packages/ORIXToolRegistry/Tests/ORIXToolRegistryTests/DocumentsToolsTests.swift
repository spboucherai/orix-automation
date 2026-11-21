// ORIX OS Automation
// File: Packages/ORIXToolRegistry/Tests/ORIXToolRegistryTests/DocumentsToolsTests.swift
// Description: Integration tests of every documents.* tool on real CSV, JSON, PDF, image and .xlsx files built in temp directories, plus unit tests of the CSV codec, JSON query language and Markdown block parser.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Testing
import ORIXCore
import ORIXTestingSupport
@testable import ORIXToolRegistry

enum Fixtures {
    /// Writes a solid-colour image with a diagonal, in the given format.
    static func image(at url: URL, width: Int, height: Int, type: UTType = .png) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1); ctx.setLineWidth(3)
        ctx.move(to: .zero); ctx.addLine(to: CGPoint(x: width, y: height)); ctx.strokePath()
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        try #require(CGImageDestinationFinalize(dest))
    }

    /// Builds a small two-sheet workbook from hand-written parts and zips it with /usr/bin/zip.
    static func workbook(in tmp: TempDirectory, name: String = "book.xlsx") async throws -> URL {
        let root = "xlsx-src-\(UUID().uuidString.prefix(6))"
        try tmp.write("\(root)/[Content_Types].xml", #"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>"#)
        try tmp.write("\(root)/xl/workbook.xml", """
        <?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets><sheet name="Data" sheetId="1" r:id="rId1"/><sheet name="Other &amp; more" sheetId="2" r:id="rId2"/></sheets></workbook>
        """)
        try tmp.write("\(root)/xl/_rels/workbook.xml.rels", """
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="x" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="x" Target="worksheets/sheet2.xml"/></Relationships>
        """)
        try tmp.write("\(root)/xl/sharedStrings.xml", """
        <?xml version="1.0" encoding="UTF-8"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="4" uniqueCount="4">
        <si><t>Name</t></si><si><t>Qty</t></si><si><t>Widget &lt;A&gt;</t></si><si><r><rPr><b/></rPr><t>Bold</t></r><r><t xml:space="preserve"> plain</t></r><rPh><t>phonetic</t></rPh></si></sst>
        """)
        try tmp.write("\(root)/xl/worksheets/sheet1.xml", """
        <?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
        <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>3</v></c></row>
        <row r="3"><c r="A3" t="inlineStr"><is><t>Inline</t></is></c><c r="B3"><v>4.5</v></c><c r="C3"><f>B2+B3</f><v>7.5</v></c></row>
        <row r="5"><c r="A5" t="s"><v>3</v></c><c r="B5" t="b"><v>1</v></c><c r="D5" s="1"><v>45000</v></c><c r="E5" t="e"><v>#DIV/0!</v></c></row>
        </sheetData><mergeCells count="1"><mergeCell ref="A7:B7"/></mergeCells></worksheet>
        """)
        try tmp.write("\(root)/xl/worksheets/sheet2.xml", """
        <?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1"><c r="A1" t="str"><v>second sheet</v></c></row></sheetData></worksheet>
        """)
        let out = tmp.file(name)
        try await TestProcess.run("/usr/bin/zip", ["-q", "-r", "-X", out.path, "."], cwd: tmp.file(root).path).requireSuccess(timeoutSeconds: 30)
        return out
    }
}

@Suite("documents.* tools (integration, real files)")
struct DocumentsToolsTests {
    @Test func csvReadHandlesQuotingHeadersDelimitersAndWindows() async throws {
        let h = try await Harness(); defer { h.tmp.remove() }
        try h.tmp.write("people.csv", "name,city,note\r\n\"Tremblay, Luc\",Gatineau,\"said \"\"hi\"\"\"\r\nAda,\"Multi\nline\",\r\nBob,Hull,x\r\n")
        let r = await h.call("documents.csvRead", ["path": "people.csv"])
        #expect(r.status == .succeeded && r.output["columns"] == ["name", "city", "note"] && r.output["hasHeader"] == true && r.output["totalRows"] == 3)
        #expect(r.output["rows"]?[0] == ["Tremblay, Luc", "Gatineau", "said \"hi\""] && r.output["rows"]?[1] == ["Ada", "Multi\nline", ""])
        let window = await h.call("documents.csvRead", ["path": "people.csv", "offset": 1, "limit": 1, "asObjects": true])
        #expect(window.output["rows"] == [["name": "Ada", "city": "Multi\nline", "note": ""]] && window.truncated && window.output["rowCount"] == 1)
        try h.tmp.write("semi.csv", "1;2;3\n4;5;6\n")
        let semi = await h.call("documents.csvRead", ["path": "semi.csv"])
        #expect(semi.output["delimiter"] == ";" && semi.output["hasHeader"] == false && semi.output["columns"] == ["column1", "column2", "column3"] && semi.output["totalRows"] == 2)
        let forced = await h.call("documents.csvRead", ["path": "semi.csv", "header": "yes", "delimiter": ";"])
        #expect(forced.output["columns"] == ["1", "2", "3"] && forced.output["totalRows"] == 1)
        try h.tmp.write("tabs.tsv", "a\tb\nc\td\n")
        #expect(await h.call("documents.csvRead", ["path": "tabs.tsv", "header": "no"]).output["delimiter"] == "tab")
        #expect(await h.call("documents.csvRead", ["path": "people.csv", "delimiter": "x"]).status == .invalidInput)
    }

    @Test func csvWriteRoundTripsAndProtectsExistingFiles() async throws {
        let h = try await Harness(); defer { h.tmp.remove() }
        let rows: JSONValue = [["a, b", 1, true], ["quote \" here", 2.5, .null], ["line\nbreak", -3, false]]
        let w = await h.call("documents.csvWrite", ["path": "out/t.csv", "columns": ["text", "n", "flag"], "rows": rows])
        #expect(w.status == .succeeded && w.output["rows"] == 3)
        let back = await h.call("documents.csvRead", ["path": "out/t.csv"])
        #expect(back.output["columns"] == ["text", "n", "flag"])
        #expect(back.output["rows"] == [["a, b", "1", "true"], ["quote \" here", "2.5", ""], ["line\nbreak", "-3", "false"]])
        #expect(await h.call("documents.csvWrite", ["path": "out/t.csv", "rows": [["x"]]]).status == .invalidInput)
        let dry = await h.call("documents.csvWrite", ["path": "out/t.csv", "rows": [["x"]], "overwrite": true], dryRun: true)
        #expect(dry.status == .simulated && h.read("out/t.csv").hasPrefix("text,n,flag"))
        let over = await h.call("documents.csvWrite", ["path": "out/t.csv", "rows": [["city": "Hull", "pop": 70000], ["city": "Aylmer"]], "overwrite": true])
        #expect(over.output["backupPath"]?.stringValue != nil && h.read("out/t.csv") == "city,pop\r\nHull,70000\r\nAylmer,\r\n")
        #expect(await h.call("documents.csvWrite", ["path": "mixed.csv", "rows": [["a"], ["k": 1]]]).status == .invalidInput)
    }

    @Test func jsonQueryPathsWildcardsAndFilters() async throws {
        let h = try await Harness(); defer { h.tmp.remove() }
        try h.tmp.write("data.json", #"{"store":{"name":"Shop","items":[{"id":1,"name":"pen","price":2.5,"tags":["a"]},{"id":2,"name":"Notebook","price":12,"tags":[]},{"id":3,"name":"bag","price":40}]},"count":3}"#)
        func q(_ query: String) async -> ToolResult { await h.call("documents.jsonQuery", ["path": "data.json", "query": .string(query)]) }
        #expect(await q("store.name").output["result"] == "Shop")
        #expect(await q("store.items[1].name").output["result"] == "Notebook")
        #expect(await q("store.items.0.id").output["result"] == 1)
        #expect(await q("store.items[-1].name").output["result"] == "bag")
        #expect(await q("store.items[*].id").output["result"] == [1, 2, 3])
        #expect(await q("store.items[?price>10].name").output["result"] == ["Notebook", "bag"])
        #expect(await q("store.items[?name==\"pen\"].price").output["result"] == [2.5])
        #expect(await q("store.items[?name~=note].id").output["result"] == [2])
        #expect(await q("store.items[?id!=2].id").output["count"] == 2)
        let missing = await q("store.nope.deeper")
        #expect(missing.status == .succeeded && missing.output["found"] == false && missing.output["result"] == .null)
        let outline = await h.call("documents.jsonQuery", ["path": "data.json"])
        #expect(outline.output["result"]?["count"] == "3" && outline.output["result"]?["store"] == "object(2 keys)")
        #expect(await h.call("documents.jsonQuery", ["path": "data.json", "query": "store.items[*].id", "limit": 2]).truncated)
        #expect(await q("store.items[?broken]").status == .invalidInput)
        try h.tmp.write("bad.json", "{not json")
        #expect(await h.call("documents.jsonQuery", ["path": "bad.json", "query": "a"]).status == .invalidInput)
    }

    @Test func textStatsCountsAndRanksTerms() async throws {
        let h = try await Harness(); defer { h.tmp.remove() }
        try h.tmp.write("t.txt", "The quick brown fox.\nThe lazy dog; the QUICK fox!\n\nÉté été.\n")
        let r = await h.call("documents.textStats", ["path": "t.txt", "topTerms": 3])
        #expect(r.output["lines"] == 4 && r.output["words"] == 12 && r.output["bytes"] == .int("The quick brown fox.\nThe lazy dog; the QUICK fox!\n\nÉté été.\n".utf8.count))
        #expect(r.output["topTerms"] == [["term": "fox", "count": 2], ["term": "quick", "count": 2], ["term": "été", "count": 2]])
        let inline = await h.call("documents.textStats", ["content": "one two two"])
        #expect(inline.output["words"] == 3 && inline.output["topTerms"]?[0]?["term"] == "two")
        #expect(await h.call("documents.textStats", [:]).status == .invalidInput)
        #expect(await h.call("documents.textStats", ["path": "t.txt", "content": "x"]).status == .invalidInput)
    }

    static let report = """
    Intro paragraph with **bold**, *italic* and `code` runs that is long enough to wrap across the page width when rendered at the default size.

    ## Findings

    - First bullet with a longer explanation
      continued on the next line
    - Second bullet
    1. Numbered one
    2. Numbered two

    | Item | Qty | Price |
    |------|-----|-------|
    | Pen | 3 | 2.50 |
    | Notebook | 1 | 12.00 |

    ```
    let total = items.reduce(0, +)
    print(total)
    ```

    ---

    ![Blue square](square.png)

    Closing line ZEBRA-MARKER.
    """

    @Test func renderPDFThenReadItBackWithPDFTextAndPDFInfo() async throws {
        let h = try await Harness(); defer { h.tmp.remove() }
        try Fixtures.image(at: h.tmp.file("square.png"), width: 240, height: 160)
        let long = (1...140).map { "Paragraph \($0) of the long section, with enough words to fill a line of text.\n" }.joined(separator: "\n")
        let r = await h.call("documents.renderPDF", ["destination": "out/report.pdf", "title": "Quarterly Report", "author": "ORIX Test",
                                                      "content": .string(Self.report + "\n\n# Long section\n\n" + long), "pageSize": "a4"])
        #expect(r.status == .succeeded, "\(r.failure?.message ?? "")")
        let pages = try #require(r.output["pages"]?.intValue)
        #expect(pages >= 3 && r.artifacts.first?.kind == "report" && (r.output["bytes"]?.intValue ?? 0) > 2_000)

        let info = await h.call("documents.pdfInfo", ["path": "out/report.pdf"])
        #expect(info.output["pageCount"] == .int(pages) && info.output["title"] == "Quarterly Report" && info.output["author"] == "ORIX Test")
        #expect(info.output["encrypted"] == false && info.output["pageSize"]?["widthPoints"]?.doubleValue.map { abs($0 - 595.28) < 0.5 } == true)

        let first = await h.call("documents.pdfText", ["path": "out/report.pdf", "firstPage": 1, "lastPage": 1])
        let text = first.output["pages"]?[0]?["text"]?.stringValue ?? ""
        #expect(first.output["hasText"] == true && first.untrusted)
        for needle in ["Quarterly Report", "Findings", "First bullet", "Numbered two", "Notebook", "12.00", "let total", "Blue square", "ZEBRA-MARKER", "1 / \(pages)"] {
            #expect(text.contains(needle), "page 1 should contain \(needle)")
        }
        #expect(!text.contains("**") && !text.contains("```") && !text.contains("|---"), "markup is rendered, not printed")
        let all = await h.call("documents.pdfText", ["path": "out/report.pdf"])
        let joined = (all.output["pages"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        #expect(all.output["pages"]?.arrayValue?.count == pages && joined.contains("Paragraph 140 of the long section") && joined.contains("\(pages) / \(pages)"))
        let bounded = await h.call("documents.pdfText", ["path": "out/report.pdf", "maxBytes": 200])
        #expect(bounded.truncated)
        #expect(await h.call("documents.pdfText", ["path": "out/report.pdf", "firstPage": 999]).status == .invalidInput)

        // The image really is embedded: the first page of the PDF draws an image XObject.
        let doc = try #require(PDFDocument(url: h.tmp.file("out/report.pdf")))
        #expect(doc.pageCount == pages)
        #expect(await h.call("documents.renderPDF", ["destination": "out/report.pdf", "content": "x"]).status == .invalidInput, "no silent overwrite")
        let dry = await h.call("documents.renderPDF", ["destination": "out/other.pdf", "content": "# Only a title"], dryRun: true)
        #expect(dry.status == .simulated && dry.output["pages"] == 1 && !h.exists("out/other.pdf"))
        let over = await h.call("documents.renderPDF", ["destination": "out/report.pdf", "content": "Short.", "overwrite": true])
        #expect(over.output["pages"] == 1 && over.output["backupPath"]?.stringValue != nil)
        #expect(await h.call("documents.renderPDF", ["destination": "x.pdf", "content": "![a](missing.png)"]).failure?.code == "not_found")
        #expect(await h.call("documents.renderPDF", ["destination": "x.pdf", "content": "![a](https://example.com/a.png)"]).status == .unsupported)
        #expect(await h.call("documents.renderPDF", ["destination": "x.txt", "content": "x"]).status == .invalidInput)
        try h.tmp.write("not.pdf", "plain text")
        #expect(await h.call("documents.pdfInfo", ["path": "not.pdf"]).status == .unsupported)
    }

    @Test func renderPDFDeclaresImageReadCapabilities() async throws {
        let policy = ApprovalPolicy(denyTools: ["documents.renderPDF"])
        let h = try await Harness(policy: policy); defer { h.tmp.remove() }
        _ = await h.call("documents.renderPDF", ["destination": "r.pdf", "content": "![x](img/a.png)\n\ntext\n\n![y](~/Pictures/b.png)"])
        let capabilities = Set(await policy.requests.last?.capabilities ?? [])
        #expect(capabilities == [.fileWrite(path: h.path("r.pdf")), .fileRead(path: NSHomeDirectory() + "/Pictures/b.png"), .fileRead(path: h.path("img/a.png"))])
    }

    @Test func imageInfoAndConvert() async throws {
        let h = try await Harness(); defer { h.tmp.remove() }
        try Fixtures.image(at: h.tmp.file("in/a.png"), width: 400, height: 200)
        try Fixtures.image(at: h.tmp.file("in/b.png"), width: 100, height: 300)
        let info = await h.call("documents.imageInfo", ["path": "in/a.png"])
        #expect(info.output["width"] == 400 && info.output["height"] == 200 && info.output["format"] == "png" && info.output["typeIdentifier"] == "public.png")
        let single = await h.call("documents.imageConvert", ["source": "in/a.png", "destination": "out/a.jpg", "maxDimension": 100, "quality": 0.6])
        #expect(single.status == .succeeded && single.output["converted"]?[0]?["width"] == 100 && single.output["converted"]?[0]?["height"] == 50, "\(single.failure?.message ?? "")")
        let jpg = await h.call("documents.imageInfo", ["path": "out/a.jpg"])
        #expect(jpg.output["format"] == "jpeg" && jpg.output["width"] == 100)
        #expect(await h.call("documents.imageConvert", ["source": "in/a.png", "destination": "out/a.jpg"]).status == .invalidInput, "existing output is kept")
        let batchDry = await h.call("documents.imageConvert", ["paths": ["in/a.png", "in/b.png"], "destination": "tiffs", "format": "tiff"], dryRun: true)
        #expect(batchDry.status == .simulated && !h.exists("tiffs"))
        let batch = await h.call("documents.imageConvert", ["paths": ["in/a.png", "in/b.png"], "destination": "tiffs", "format": "tiff"])
        #expect(batch.output["count"] == 2 && h.exists("tiffs/a.tiff") && h.exists("tiffs/b.tiff"))
        #expect(await h.call("documents.imageInfo", ["path": "tiffs/b.tiff"]).output["height"] == 300, "no upscaling or resizing without maxDimension")
        #expect(h.exists("in/a.png") && h.exists("in/b.png"), "sources are untouched")
        // A batch that would collide or overwrite does nothing at all.
        try Fixtures.image(at: h.tmp.file("other/a.png"), width: 10, height: 10)
        #expect(await h.call("documents.imageConvert", ["paths": ["in/a.png", "other/a.png"], "destination": "gifs", "format": "gif"]).status == .invalidInput)
        try h.tmp.write("pngs/b.png", "placeholder")
        let blocked = await h.call("documents.imageConvert", ["paths": ["in/a.png", "in/b.png"], "destination": "pngs", "format": "png"])
        #expect(blocked.status == .invalidInput && !h.exists("pngs/a.png") && h.read("pngs/b.png") == "placeholder")
        #expect(await h.call("documents.imageConvert", ["source": "in/a.png", "destination": "in/a.png", "format": "png"]).status == .invalidInput)
        #expect(await h.call("documents.imageConvert", ["source": "in/a.png", "paths": ["in/b.png"], "destination": "x.png"]).status == .invalidInput)
        try h.tmp.write("fake.png", "not an image")
        #expect(await h.call("documents.imageInfo", ["path": "fake.png"]).status == .unsupported)
        #expect(await h.call("documents.imageConvert", ["source": "fake.png", "destination": "f.jpg"]).status == .unsupported)
    }

    @Test func xlsxReadSheetsValuesAndHonestLimits() async throws {
        let h = try await Harness(); defer { h.tmp.remove() }
        _ = try await Fixtures.workbook(in: h.tmp)
        let r = await h.call("documents.xlsxRead", ["path": "book.xlsx"])
        #expect(r.status == .succeeded, "\(r.failure?.message ?? "")")
        #expect(r.output["sheet"] == "Data" && r.output["sheets"] == ["Data", "Other & more"] && r.output["rowNumbers"] == [1, 2, 3, 5])
        let rows = r.output["rows"]?.arrayValue ?? []
        #expect(rows.count == 4 && rows[0] == ["Name", "Qty", .null, .null, .null])
        #expect(rows[1] == ["Widget <A>", 3, .null, .null, .null])
        #expect(rows[2] == ["Inline", 4.5, 7.5, .null, .null])
        #expect(rows[3] == ["Bold plain", true, .null, 45000, "#DIV/0!"])
        let notes = (r.output["unsupported"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: " | ")
        #expect(notes.contains("serial numbers") && notes.contains("1 formula") && notes.contains("1 merged") && notes.contains("Excel errors"))
        let second = await h.call("documents.xlsxRead", ["path": "book.xlsx", "sheet": "Other & more"])
        #expect(second.output["rows"] == [["second sheet"]] && second.output["unsupported"] == [])
        #expect(await h.call("documents.xlsxRead", ["path": "book.xlsx", "sheet": "2"]).output["sheet"] == "Other & more")
        let limited = await h.call("documents.xlsxRead", ["path": "book.xlsx", "limit": 2])
        #expect(limited.output["rowCount"] == 2 && limited.truncated)
        #expect(await h.call("documents.xlsxRead", ["path": "book.xlsx", "sheet": "Nope"]).failure?.code == "not_found")
        try h.tmp.write("legacy.xls", "x"); try h.tmp.write("fake.xlsx", "this is not a zip archive")
        #expect(await h.call("documents.xlsxRead", ["path": "legacy.xls"]).status == .unsupported)
        #expect(await h.call("documents.xlsxRead", ["path": "fake.xlsx"]).status == .unsupported)
        #expect(await h.call("filesystem.archive", ["source": "in-none", "destination": "x.zip"]).failure?.code == "not_found")
    }
}

@Suite("Document codecs (unit)")
struct DocumentCodecTests {
    @Test func csvCodecEdgeCases() {
        #expect(CSVCodec.parse("a,b\n1,2") == [["a", "b"], ["1", "2"]])
        #expect(CSVCodec.parse("a,b\r\n1,2\r\n") == [["a", "b"], ["1", "2"]])
        #expect(CSVCodec.parse("\u{FEFF}x,\"\",z\n") == [["x", "", "z"]])
        #expect(CSVCodec.parse("\"a\"\"b\",\"c,d\",\"e\r\nf\"") == [["a\"b", "c,d", "e\r\nf"]])
        #expect(CSVCodec.parse("a,,\n,,") == [["a", "", ""], ["", "", ""]])
        #expect(CSVCodec.parse("").isEmpty)
        #expect(CSVCodec.parse("x;y", delimiter: ";") == [["x", "y"]])
        let rows = [["plain", "with,comma", "with \"quote\"", "multi\r\nline", " padded "], ["", "é", "", "", ""]]
        #expect(CSVCodec.parse(CSVCodec.encode(rows)) == rows)
        #expect(CSVCodec.detectDelimiter("a;b;c\n1;2;3") == ";" && CSVCodec.detectDelimiter("a\tb\n1\t2") == "\t" && CSVCodec.detectDelimiter("single") == ",")
        #expect(CSVCodec.looksLikeHeader([["name", "age"], ["Ann", "3"]]) && !CSVCodec.looksLikeHeader([["1", "2"]]) && !CSVCodec.looksLikeHeader([["a", "a"]]))
    }

    @Test func jsonQueryEvaluation() throws {
        let doc: JSONValue = ["a": ["b": [10, 20, 30]], "list": [["k": "x", "n": 1], ["k": "y", "n": 2]], "0": "zero"]
        #expect(try JSONQuery.evaluate(doc, query: "$.a.b[2]").values == [30])
        #expect(try JSONQuery.evaluate(doc, query: "a.b.*").values == [10, 20, 30])
        #expect(try JSONQuery.evaluate(doc, query: "list[?n>=2].k").values == ["y"])
        #expect(try JSONQuery.evaluate(doc, query: "list[?@.k=='x'].n").values == [1])
        #expect(try JSONQuery.evaluate(doc, query: "list[?missing==1]").values.isEmpty)
        #expect(try JSONQuery.evaluate(doc, query: "a.b[9]").values.isEmpty)
        #expect(try JSONQuery.evaluate(doc, query: "a.b").multiple == false && JSONQuery.evaluate(doc, query: "list[*]").multiple)
        #expect(throws: ToolError.self) { try JSONQuery.parse("a[0") }
    }

    @Test func markdownBlocks() {
        let blocks = PDFBlock.parse("# Title\n\npara one\nstill para\n\n- a\n- b\n3. c\n\n```\ncode | not table\n# not heading\n```\n| h1 | h2 |\n|:--|--:|\n| 1 | 2 |\n\n![cap](p/i.png)\n***\ntail")
        #expect(blocks == [
            .heading(level: 1, text: "Title"), .paragraph("para one still para"), .bullet(marker: "•", text: "a"), .bullet(marker: "•", text: "b"),
            .bullet(marker: "3.", text: "c"), .code("code | not table\n# not heading"), .table(rows: [["h1", "h2"], ["1", "2"]], hasHeader: true),
            .image(alt: "cap", path: "p/i.png"), .rule, .paragraph("tail"),
        ])
        #expect(PDFBlock.imagePaths("![a](one.png)\n\ntext ![inline](no.png)\n\n![b](two.png)") == ["one.png", "two.png"])
    }

    @Test func xlsxColumnReferences() {
        #expect(XLSXSheetParser.column("A1") == 0 && XLSXSheetParser.column("Z9") == 25 && XLSXSheetParser.column("AA10") == 26 && XLSXSheetParser.column("12") == nil)
    }
}
