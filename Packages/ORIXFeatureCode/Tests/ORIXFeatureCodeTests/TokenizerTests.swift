// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureCode/Tests/ORIXFeatureCodeTests/TokenizerTests.swift
// Description      : Unit tests of the syntax tokenizers: every language,
//                    strings, comments, heredocs, block scalars and workflow
//                    expressions.
// Module           : ORIXFeatureCodeTests
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

import Foundation
import Testing
@testable import ORIXFeatureCode

/// Token texts with their kinds, in order.
func lex(_ text: String, _ language: CodeLanguage) -> [(String, TokenKind)] {
    let ns = text as NSString
    return SyntaxTokenizer.tokenize(text, language: language).map { (ns.substring(with: $0.range), $0.kind) }
}

func has(_ tokens: [(String, TokenKind)], _ text: String, _ kind: TokenKind) -> Bool {
    tokens.contains { $0.0 == text && $0.1 == kind }
}

@Suite("Unit · tokenizers") struct TokenizerTests {
    @Test func yamlKeysScalarsAndComments() {
        let t = lex("# top\nname: \"Weekly: report\"  # trailing\ncount: 42\nratio: -0.5e3\nflag: true\nplain: some text # note\nzero: 007\n", .yaml)
        #expect(has(t, "# top", .comment))
        #expect(has(t, "name", .key))
        #expect(has(t, "\"Weekly: report\"", .string))
        #expect(has(t, "# trailing", .comment))
        #expect(has(t, "42", .number))
        #expect(has(t, "-0.5e3", .number))
        #expect(has(t, "true", .constant))
        #expect(has(t, "# note", .comment))
        #expect(!has(t, "007", .number))                       // leading zeros are strings
        #expect(!t.contains { $0.0.contains("some text") && $0.1 == .string })
    }

    @Test func yamlHashInsideAWordIsNotAComment() {
        let t = lex("url: http://example.com/#anchor\ncolor: a#b\n", .yaml)
        #expect(!t.contains { $0.1 == .comment })
    }

    @Test func yamlExpressionsInsidePlainAndQuotedScalars() {
        let t = lex("path: ${{ params.folder }}/out-${{ env.DATE }}.md\nq: \"${{ len(steps.fetch-data.output.items) > 0 }}\"\nlit: $${{ not }}\n", .yaml)
        #expect(t.filter { $0.0 == "${{" && $0.1 == .interpolation }.count == 3)
        #expect(t.filter { $0.0 == "}}" && $0.1 == .interpolation }.count == 3)
        #expect(has(t, "params", .variable))
        #expect(has(t, "env", .variable))
        #expect(has(t, "len", .function))
        #expect(has(t, "steps", .variable))
        #expect(has(t, "0", .number))
        #expect(has(t, ">", .op))
        #expect(!has(t, "not", .variable))
    }

    @Test func yamlAColonInsideAnExpressionDoesNotMakeAKey() {
        let t = lex("when: ${{ contains(vars.map, \"a: b\") }}\n", .yaml)
        #expect(t.filter { $0.1 == .key }.map(\.0) == ["when"])
        #expect(has(t, "\"a: b\"", .string))
    }

    @Test func yamlBlockScalarsSpanLinesAndEnd() {
        let source = "steps:\n  - id: run\n    with:\n      script: |\n        echo \"hi\"   # not a comment\n        key: value\n\n        last line\n      cwd: /tmp\n"
        let t = lex(source, .yaml)
        #expect(has(t, "|", .punctuation))
        #expect(has(t, "echo \"hi\"   # not a comment", .string))
        #expect(has(t, "key: value", .string))
        #expect(has(t, "last line", .string))
        #expect(has(t, "cwd", .key))
        #expect(!has(t, "key", .key))
        // A block scalar that is a list item.
        let item = lex("items:\n  - >-\n    folded text\n  - next\n", .yaml)
        #expect(has(item, "folded text", .string))
        #expect(!item.contains { $0.0.contains("next") && $0.1 == .string })
    }

    @Test func yamlFlowCollectionsAndToolIDs() {
        let t = lex("needs: [a, b]\nwith: {path: \"~/x\", n: 3}\ntool: filesystem.list\n- tool: shell.run\n", .yaml)
        #expect(t.filter { $0.0 == "[" || $0.0 == "]" || $0.0 == "{" || $0.0 == "}" }.allSatisfy { $0.1 == .punctuation })
        #expect(has(t, "path", .key))
        #expect(has(t, "3", .number))
        #expect(has(t, "filesystem.list", .function))
        #expect(has(t, "shell.run", .function))
    }

    @Test func jsonKeysStringsNumbersAndExpressions() {
        let t = lex("{\n  \"name\": \"a \\\"quoted\\\" b\",\n  \"n\": -12.5e2, \"ok\": true, \"none\": null,\n  \"path\": \"${{ params.x }}/y\"\n}\n", .json)
        #expect(has(t, "\"name\"", .key))
        #expect(has(t, "\"a \\\"quoted\\\" b\"", .string))
        #expect(has(t, "-12.5e2", .number))
        #expect(has(t, "true", .constant))
        #expect(has(t, "null", .constant))
        #expect(has(t, "params", .variable))
        #expect(has(t, "\"", .string))
        #expect(has(t, "/y\"", .string))
    }

    @Test func pythonStringsCommentsAndDefinitions() {
        let source = "import os  # comment with 'quote'\n@decorator\ndef greet(name: str) -> str:\n    \"\"\"Doc string\n    spans # lines\n    \"\"\"\n    x = r'raw\\n' + f\"{name!r}\" + b'bytes'\n    return 0x1F + 1_000 + 3.14e-2 if name is None else len(name)\nclass Box:\n    pass\ns = 'it''s # not a comment'\n"
        let t = lex(source, .python)
        #expect(has(t, "# comment with 'quote'", .comment))
        #expect(has(t, "@decorator", .attribute))
        #expect(has(t, "def", .keyword))
        #expect(has(t, "greet", .function))
        #expect(has(t, "\"\"\"Doc string", .string))
        #expect(has(t, "    spans # lines", .string))
        #expect(has(t, "    \"\"\"", .string))
        #expect(has(t, "r'raw\\n'", .string))
        #expect(has(t, "f\"{name!r}\"", .string))
        #expect(has(t, "b'bytes'", .string))
        #expect(has(t, "0x1F", .number))
        #expect(has(t, "1_000", .number))
        #expect(has(t, "3.14e-2", .number))
        #expect(has(t, "None", .constant))
        #expect(has(t, "len", .function))
        #expect(has(t, "Box", .type))
        #expect(!t.contains { $0.0.contains("not a comment") && $0.1 == .comment })
    }

    @Test func bashQuotesVariablesAndHeredocs() {
        let source = "#!/bin/bash\nname=\"World $USER ${HOME}\" # greet\necho 'single $notvar # no comment'\necho $# ${#arr[@]} a#b\ncat <<EOF > out.txt\nline with $var and # hash\nEOF\ncat <<-'END'\n\tindented body\n\tEND\nif [ -f x ]; then echo ok; fi\ngrep <<< \"here string\"\n"
        let t = lex(source, .bash)
        #expect(has(t, "#!/bin/bash", .comment))
        #expect(has(t, "$USER", .variable))
        #expect(has(t, "${HOME}", .variable))
        #expect(has(t, "# greet", .comment))
        #expect(has(t, "'single $notvar # no comment'", .string))
        #expect(has(t, "$#", .variable))
        #expect(has(t, "${#arr[@]}", .variable))
        #expect(t.filter { $0.1 == .comment }.count == 2)       // shebang and "# greet" only
        #expect(has(t, "line with $var and # hash", .string))
        #expect(has(t, "EOF", .constant))
        #expect(has(t, "\tindented body", .string))
        #expect(has(t, "END", .constant))
        #expect(has(t, "if", .keyword))
        #expect(has(t, "fi", .keyword))
        #expect(has(t, "\"here string\"", .string))
    }

    @Test func bashStringsSpanLines() {
        let t = lex("msg=\"first\nsecond $x\nthird\"\necho done\n", .bash)
        #expect(has(t, "\"first", .string))
        #expect(has(t, "$x", .variable))
        #expect(has(t, "third\"", .string))
        #expect(has(t, "echo", .function))
        #expect(has(t, "done", .keyword))
    }

    @Test func appleScriptCommentsAndKeywords() {
        let source = "-- line comment\n(* block (* nested *) still\n   comment *) tell application \"Finder\"\n    set n to \"a \\\"b\\\" -- c\"\n    Display Dialog n\nEND TELL\n# hash comment\n"
        let t = lex(source, .applescript)
        #expect(has(t, "-- line comment", .comment))
        #expect(has(t, "(* block (* nested *) still", .comment))
        #expect(has(t, "   comment *)", .comment))
        #expect(has(t, "tell", .keyword))
        #expect(has(t, "\"Finder\"", .string))
        #expect(has(t, "\"a \\\"b\\\" -- c\"", .string))
        #expect(has(t, "Display", .function))                    // case-insensitive
        #expect(has(t, "END", .keyword))
        #expect(has(t, "# hash comment", .comment))
    }

    @Test func swiftNestedCommentsInterpolationAndMultilineStrings() {
        let source = "/* outer /* inner */ still */ let a = 1\n// line\n@MainActor func run(_ x: Int) -> String {\n    let s = \"value \\(x + count(\"q\")) end\" // after\n    let m = \"\"\"\n    multi \"quoted\" // not comment\n    \"\"\"\n    #if DEBUG\n    return s + m\n    #endif\n}\nstruct Box<T> {}\n"
        let t = lex(source, .swift)
        #expect(has(t, "/* outer /* inner */ still */", .comment))
        #expect(has(t, "let", .keyword))
        #expect(has(t, "// line", .comment))
        #expect(has(t, "@MainActor", .attribute))
        #expect(has(t, "run", .function))
        #expect(has(t, "Int", .type))
        #expect(has(t, "\"value \\(x + count(\"q\")) end\"", .string))
        #expect(has(t, "// after", .comment))
        #expect(has(t, "    multi \"quoted\" // not comment", .string))
        #expect(has(t, "#if", .keyword))
        #expect(has(t, "Box", .type))
    }

    @Test func javaScriptTemplatesRegexAndComments() {
        let source = "const re = /ab+c[/]\\/x/gi; // trailing\nconst t = `line ${a}\nsecond // not comment`;\n/* block\n   comment */ let half = a / b / c;\nfunction go() { return 'it\\'s'; }\n"
        let t = lex(source, .javascript)
        #expect(has(t, "/ab+c[/]\\/x/gi", .string))
        #expect(has(t, "// trailing", .comment))
        #expect(has(t, "`line ${a}", .string))
        #expect(has(t, "second // not comment`", .string))
        #expect(has(t, "/* block", .comment))
        #expect(has(t, "   comment */", .comment))
        #expect(!t.contains { $0.0.hasPrefix("/ b") })            // division is not a regex
        #expect(has(t, "go", .function))
        #expect(has(t, "'it\\'s'", .string))
    }

    @Test func tokensNeverOverlapAndStayInBounds() {
        let samples: [(String, CodeLanguage)] = [
            (WorkflowSnippets.starter, .yaml), ("{\"a\": [1, \"${{ x }}\"]}", .json),
            (ScriptTemplates.templates(.python).map(\.body).joined(), .python), (ScriptTemplates.templates(.bash).map(\.body).joined(), .bash),
            (ScriptTemplates.templates(.applescript).map(\.body).joined(), .applescript), (ScriptTemplates.templates(.swift).map(\.body).joined(), .swift),
            (ScriptTemplates.templates(.javascript).map(\.body).joined() + ScriptTemplates.templates(.jxa).map(\.body).joined(), .javascript),
            ("\"unterminated\n'also\n${{ open\n/* never closed", .yaml), ("\"\"\"open\n<<EOF\n`tick", .bash),
        ]
        for (text, language) in samples {
            let tokens = SyntaxTokenizer.tokenize(text, language: language)
            var end = 0
            for t in tokens {
                #expect(t.range.location >= end, "overlap in \(language)")
                #expect(t.range.length > 0)
                end = NSMaxRange(t.range)
            }
            #expect(end <= (text as NSString).length)
        }
    }
}
