// ORIX OS Automation
// File: Packages/ORIXWorkflowEngine/Tests/ORIXWorkflowEngineTests/ExpressionTests.swift
// Description: Unit tests of the expression language: operators, every function, scoping, templates, single-pass interpolation, rejected syntax and bounds.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import Testing
import ORIXCore
@testable import ORIXWorkflowEngine

private let hostile = "${{ secret(\"x\") }} then ${{ env.HOME }} and ${{ 1 + 1 }}"

private func context() -> ExpressionContext {
    ExpressionContext(
        params: ["name": "Ada", "n": 3, "list": [1, 2, 3], "folder": "~/x"],
        vars: ["count": 2, "obj": ["a": 1, "b": [10, 20]], "text": "Hello World", "empty": []],
        steps: [
            "fetch": ["status": "succeeded", "error": nil,
                      "output": ["items": [["name": "a", "size": 1], ["name": "b", "size": 5]], "text": .string(hostile)]],
            "step-one": ["status": "failed", "output": ["n": 7], "error": "boom"],
        ],
        locals: ["item": ["name": "it"], "index": 4],
        environment: ["HOME": "/Users/t", "USER": "t", "TMPDIR": "/tmp/", "DATE": "2027-01-15", "TIME": "08:00:00",
                      "DATETIME": "2027-01-15T08:00:00Z", "TIMESTAMP": "1800000000", "PATH": "/usr/bin", "SECRET_TOKEN": "nope"],
        now: Date(timeIntervalSince1970: 1_800_000_000), timeZone: TimeZone(identifier: "UTC")!)
}

private func ev(_ source: String) throws -> JSONValue { try WorkflowExpression.evaluate(source, context: context()) }

private func failure(_ source: String, template: Bool = false) -> WorkflowExpressionError? {
    do {
        _ = template ? try WorkflowExpression.interpolate(source, context: context()) : try WorkflowExpression.evaluate(source, context: context())
        return nil
    } catch let e as WorkflowExpressionError { return e } catch { return WorkflowExpressionError(message: "\(error)") }
}

private func expectFailure(_ source: String, _ fragment: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let e = failure(source)
    #expect(e != nil, "\(source) should fail", sourceLocation: sourceLocation)
    #expect(e?.message.contains(fragment) == true, "\(source): got \"\(e?.message ?? "no error")\", expected to contain \"\(fragment)\"", sourceLocation: sourceLocation)
}

@Suite("Expression language: literals and operators (unit)") struct ExpressionOperatorTests {
    @Test func literals() throws {
        #expect(try ev("42") == .int(42) && ev("1.5") == .number(1.5) && ev("2e3") == .number(2000) && ev("1.5e-1") == .number(0.15))
        #expect(try ev("true") == true && ev("false") == false && ev("null") == .null)
        #expect(try ev(#"'it\'s'"#) == "it's" && ev(#""a\nb\t\"q\" \\ é""#) == "a\nb\t\"q\" \\ é")
        #expect(try ev("[1, 'a', [true], null]") == [1, "a", [true], nil] && ev("[]") == [])
        #expect(try ev("  1  ") == 1)
        expectFailure("", "empty expression")
        expectFailure("'open", "unterminated string")
        expectFailure(#"'bad \q'"#, "unknown escape")
    }

    @Test func arithmeticKeepsIntegersWhenExact() throws {
        #expect(try ev("1 + 2") == .int(3) && ev("5 - 7") == .int(-2) && ev("4 * 3") == .int(12))
        #expect(try ev("6 / 2") == .int(3) && ev("7 / 2") == .number(3.5) && ev("7 % 3") == .int(1) && ev("-7 % 3") == .int(-1))
        #expect(try ev("1.5 + 1") == .number(2.5) && ev("3 * 0.5") == .number(1.5) && ev("5.5 % 2") == .number(1.5) && ev("1 / 4.0") == .number(0.25))
        #expect(try ev("-3") == .int(-3) && ev("-(1 + 2)") == .int(-3) && ev("-1.5") == .number(-1.5) && ev("1 - -1") == .int(2) && ev("--2") == .int(2))
    }

    @Test func integerOverflowFallsBackToFloatingPoint() throws {
        #expect(try ev("9223372036854775807 + 1") == .number(9.223372036854775807e18))
        #expect(try ev("9223372036854775807 * 2") == .number(1.8446744073709552e19))
        #expect(try ev("-9223372036854775807 - 2") == .number(-9.223372036854775807e18))
        #expect(try ev("99999999999999999999") == .number(1e20))
        #expect(try ev("(-9223372036854775807 - 1) % -1") == .int(0))
        #expect(try ev("-(-9223372036854775807 - 1)") == .number(9.223372036854775808e18))
    }

    @Test func divisionByZeroIsAnError() {
        expectFailure("1 / 0", "division by zero")
        expectFailure("1 % 0", "division by zero")
        expectFailure("1.5 / 0", "division by zero")
        expectFailure("1 % 0.0", "division by zero")
    }

    @Test func precedenceAndAssociativity() throws {
        #expect(try ev("1 + 2 * 3") == 7 && ev("(1 + 2) * 3") == 9 && ev("10 - 2 - 3") == 5 && ev("2 * 3 % 4") == 2 && ev("-2 * 3") == -6)
        #expect(try ev("1 + 1 == 2") == true && ev("1 < 2 == true") == true && ev("!false == true") == true)
        #expect(try ev("true || false && false") == true && ev("(true || false) && false") == false)
        #expect(try ev("1 + 2 > 2 && 2 * 2 <= 4") == true)
    }

    @Test func comparisons() throws {
        #expect(try ev("1 < 2") == true && ev("2 <= 2") == true && ev("3 > 4") == false && ev("4 >= 5") == false && ev("1 < 1.5") == true)
        #expect(try ev("'a' < 'b'") == true && ev("'b' >= 'b'") == true && ev("'abc' > 'abd'") == false)
        #expect(try ev("1 == 1.0") == true && ev("1 != 2") == true && ev("'1' == 1") == false && ev("null == null") == true)
        #expect(try ev("[1, 2] == [1, 2]") == true && ev("vars.obj == vars.obj") == true && ev("true != false") == true && ev("null != 0") == true)
        expectFailure("1 < 'a'", "cannot compare")
        expectFailure("null > 1", "cannot compare")
        expectFailure("[1] < [2]", "cannot compare")
    }

    @Test func logicalOperatorsShortCircuitAndYieldBooleans() throws {
        #expect(try ev("false && (1 / 0)") == false && ev("true || (1 / 0)") == true)
        #expect(try ev("0 && nope()") == false && ev("'x' || nope()") == true)
        #expect(try ev("1 && 'x'") == true && ev("0 || ''") == false && ev("null || [0]") == true)
        #expect(try ev("!0") == true && ev("!!'x'") == true && ev("![]") == true && ev("!vars.obj") == false)
        expectFailure("true && (1 / 0)", "division by zero")
        expectFailure("-'x'", "cannot negate")
    }

    @Test func plusConcatenatesStringsAndLists() throws {
        #expect(try ev("'a' + 'b'") == "ab" && ev("'n=' + 1") == "n=1" && ev("1 + 'a'") == "1a" && ev("'v' + 1.5 + true + null") == "v1.5truenull")
        #expect(try ev("'l=' + [1, 2]") == "l=[1,2]" && ev("[1] + [2, 3]") == [1, 2, 3] && ev("[] + []") == [])
        expectFailure("true + 1", "needs numbers")
        expectFailure("[1] + 1", "needs numbers")
        expectFailure("'a' * 2", "needs numbers")
        expectFailure("null - 1", "needs numbers")
    }
}

@Suite("Expression language: access and scoping (unit)") struct ExpressionAccessTests {
    @Test func indexing() throws {
        #expect(try ev("params.list[0]") == 1 && ev("params.list[-1]") == 3 && ev("params.list[5]") == .null && ev("params.list[-9]") == .null)
        #expect(try ev("'abc'[1]") == "b" && ev("'abc'[-1]") == "c" && ev("'abc'[3]") == .null)
        #expect(try ev("vars.obj['a']") == 1 && ev("vars.obj[\"b\"][1]") == 20 && ev("vars.obj.b.1") == 20 && ev("vars.obj.b.length") == 2)
        #expect(try ev("params.list[1 + 1]") == 3 && ev("[10, 20][1]") == 20 && ev("vars.obj['zz']") == .null)
        #expect(try ev("vars.missing") == .null && ev("vars.missing.deep.er") == .null && ev("vars.missing[0]") == .null && ev("params.list.name") == .null)
        #expect(try ev("params.name.anything") == .null)
        expectFailure("1[0]", "cannot index")
        expectFailure("params.list[1.5]", "must be an integer")
        expectFailure("params.list['x']", "must be an integer")
        expectFailure("'abc'['x']", "must be an integer")
    }

    @Test func stepsParamsAndVars() throws {
        #expect(try ev("steps.fetch.status") == "succeeded" && ev("steps.fetch.output.items[1].name") == "b" && ev("steps.fetch.output.items.0.size") == 1)
        #expect(try ev("steps.fetch.error") == .null && ev("steps.fetch.output.nothing.here") == .null)
        #expect(try ev("steps.step-one.status") == "failed" && ev("steps.step-one.output.n - 1") == 6 && ev("steps['step-one'].error") == "boom")
        #expect(try ev("len(steps.fetch.output.items) > 1 && steps.fetch.status == 'succeeded'") == true)
        #expect(try ev("params.name") == "Ada" && ev("params['n'] * 2") == 6 && ev("vars.count + params.n") == 5 && ev("keys(params)") == ["folder", "list", "n", "name"])
        expectFailure("steps.ghost.output", "unknown step 'ghost'")
        expectFailure("steps['ghost']", "unknown step 'ghost'")
        expectFailure("params.ghost", "unknown parameter 'ghost'")
        expectFailure("stranger", "unknown name 'stranger'")
        expectFailure("stranger.field", "unknown name 'stranger'")
    }

    @Test func localsAndLambdaScoping() throws {
        #expect(try ev("item.name") == "it" && ev("index + 1") == 5)
        #expect(try ev("map(params.list, x => x * params.n)") == [3, 6, 9])
        #expect(try ev("map(params.list, item => item)") == [1, 2, 3], "a lambda parameter shadows a loop variable")
        #expect(try ev("map([1], item => item) + [item.name]") == [1, "it"], "and the loop variable is back afterwards")
        #expect(try ev("map([10, 20], (x, i) => x + i)") == [10, 21])
        #expect(try ev("map([1, 2], x => map([10, 20], y => x + y))") == [[11, 21], [12, 22]])
        #expect(try ev("map([[1, 2], [3]], x => map(x, x => x * 2))") == [[2, 4], [6]])
        #expect(try ev("map([1], params => params)") == [1] && ev("map([1], steps => steps + 1)") == [2])
        expectFailure("map([1], x => x) + x", "unknown name 'x'")
        expectFailure("map([1], x => y)", "unknown name 'y'")
    }

    @Test func environmentIsAnAllowlist() throws {
        #expect(try ev("env.HOME") == "/Users/t" && ev("env.USER") == "t" && ev("env.TMPDIR") == "/tmp/" && ev("env['DATE']") == "2027-01-15")
        #expect(try ev("env.TIME + ' ' + env.DATETIME + ' ' + env.TIMESTAMP") == "08:00:00 2027-01-15T08:00:00Z 1800000000")
        #expect(try ev("keys(env)") == ["DATE", "DATETIME", "HOME", "TIME", "TIMESTAMP", "TMPDIR", "USER"])
        expectFailure("env.PATH", "'env.PATH' is not available")
        expectFailure("env['PATH']", "'env.PATH' is not available")
        expectFailure("env.SECRET_TOKEN", "not available")
        #expect(try ev("toJSON(env)").stringValue?.contains("nope") == false)
        let real = WorkflowExpression.defaultEnvironment()
        #expect(Set(real.keys) == WorkflowExpression.environmentAllowlist && real["HOME"] == NSHomeDirectory())
    }
}

@Suite("Expression language: functions (unit)") struct ExpressionFunctionTests {
    /// name, expression, expected value, an expression that must fail.
    static let table: [(String, String, JSONValue, String)] = [
        ("len", "[len('héllo'), len(params.list), len(vars.obj), len(null)]", [5, 3, 2, 0], "len(5)"),
        ("contains", "[contains('hello', 'ell'), contains(params.list, 2.0), contains(vars.obj, 'a'), contains(null, 1), contains([1], 9)]", [true, true, true, false, false], "contains(5, 1)"),
        ("startsWith", "[startsWith('hello', 'he'), startsWith('hello', 'lo')]", [true, false], "startsWith(1, 'a')"),
        ("endsWith", "[endsWith('a.pdf', '.pdf'), endsWith('a.pdf', '.txt')]", [true, false], "endsWith('a')"),
        ("lower", "lower('HeLLo')", "hello", "lower(1)"),
        ("upper", "upper('héllo')", "HÉLLO", "upper([])"),
        ("trim", "trim('  a b \\n')", "a b", "trim(null)"),
        ("split", "split('a,b,,c', ',')", ["a", "b", "", "c"], "split('a', '')"),
        ("join", "[join(['a', 1, true], '-'), join([1, 2]), join(null, '-')]", ["a-1-true", "1,2", ""], "join('abc', '-')"),
        ("replace", "replace('a-b-c', '-', '+')", "a+b+c", "replace('a', '', 'b')"),
        ("basename", "basename('/a/b/c.txt')", "c.txt", "basename(1)"),
        ("dirname", "dirname('/a/b/c.txt')", "/a/b", "dirname()"),
        ("extname", "[extname('/a/b.TXT'), extname('/a/b'), extname('archive.tar.gz')]", [".TXT", "", ".gz"], "extname(null)"),
        ("joinPath", "[joinPath('~/a/', '/b', 'c.txt'), joinPath('/root'), joinPath('', 'x')]", ["~/a/b/c.txt", "/root", "x"], "joinPath()"),
        ("toJSON", "toJSON(vars.obj)", "{\"a\":1,\"b\":[10,20]}", "toJSON()"),
        ("fromJSON", "fromJSON('{\"a\": [1, 2.5, null]}').a", [1, 2.5, nil], "fromJSON('nope')"),
        ("number", "[number('42'), number(' 1.5 '), number(true), number(7), number('-3')]", [42, 1.5, 1, 7, -3], "number('x')"),
        ("string", "[string(12), string([1, 'a']), string(null), string('s'), string(1.5)]", ["12", "[1,\"a\"]", "null", "s", "1.5"], "string()"),
        ("default", "[default(null, vars.ghost, 3), default(null), default(0, 5), default('', 'x')]", [3, nil, 0, ""], "default()"),
        ("keys", "keys(vars.obj)", ["a", "b"], "keys([1])"),
        ("values", "values(vars.obj)", [1, [10, 20]], "values('x')"),
        ("map", "[map(params.list, x => x * 2), map(steps.fetch.output.items, 'name'), map(null, x => x)]", [[2, 4, 6], ["a", "b"], []], "map(1, x => x)"),
        ("filter", "[filter(params.list, x => x > 1), filter(steps.fetch.output.items, i => i.size > 2), filter([0, 1, '', 'a'], x => x)]",
         [[2, 3], [["name": "b", "size": 5]], [1, "a"]], "filter('abc', x => x)"),
        ("reduce", "[reduce(params.list, (acc, x) => acc + x, 0), reduce(['a', 'b'], (acc, x) => acc + x, ''), reduce([], (a, b) => a, 9)]", [6, "ab", 9],
         "reduce(params.list, x => x, 0)"),
        ("count", "[count(params.list), count(params.list, x => x > 1), count(null)]", [3, 2, 0], "count(5)"),
        ("sum", "[sum(params.list), sum(steps.fetch.output.items, i => i.size), sum([1, 0.5]), sum([])]", [6, 6, 1.5, 0], "sum(['a'])"),
        ("first", "[first(params.list), first([]), first(null)]", [1, nil, nil], "first('abc')"),
        ("last", "[last(params.list), last([])]", [3, nil], "last(1)"),
        ("slice", "[slice('hello', 1, 3), slice('hello', -3), slice(params.list, 1), slice(params.list, -2, -1), slice(params.list, 2, 1), slice(params.list, 0, 99)]",
         ["el", "llo", [2, 3], [2], [], [1, 2, 3]], "slice(params.list, 'a')"),
        ("now", "now()", "2027-01-15T08:00:00Z", "now(1)"),
        ("formatDate", "[formatDate('2026-11-21T10:30:00Z', 'yyyy/MM/dd HH:mm'), formatDate(1800000000, 'yyyy-MM-dd'), formatDate('2026-11-21T10:30:00Z', 'HH:mm', 'America/Toronto'), formatDate('2026-07-04', 'EEE d MMM')]",
         ["2026/11/21 10:30", "2027-01-15", "05:30", "Sat 4 Jul"], "formatDate('not a date', 'yyyy')"),
        ("secret", "secret('smtp-password')", ["$secret": "smtp-password"], "secret(vars.text)"),
    ]

    @Test func theTableCoversEveryFunction() {
        #expect(Self.table.map(\.0).sorted() == WorkflowExpression.functionNames.sorted())
        #expect(Set(WorkflowExpression.functionNames).count == WorkflowExpression.functionNames.count)
    }

    @Test(arguments: table.indices)
    func everyFunctionWorksAndReportsMisuse(index: Int) throws {
        let (name, expression, expected, bad) = Self.table[index]
        #expect(try ev(expression) == expected, "\(name): \(expression)")
        let e = failure(bad)
        #expect(e != nil, "\(name): \(bad) should fail")
        #expect(e?.message.isEmpty == false)
    }

    @Test func misuseMessagesAreSpecific() {
        expectFailure("nope(1)", "unknown function 'nope'")
        expectFailure("len()", "len() takes 1 argument, got 0")
        expectFailure("slice([1])", "slice() takes 2 to 3 arguments")
        expectFailure("fromJSON('{')", "could not parse")
        expectFailure("formatDate(1800000000, 'yyyy', 'Mars/Olympus')", "unknown time zone")
        expectFailure("formatDate(true, 'yyyy')", "ISO 8601 string or a Unix timestamp")
        expectFailure("number([])", "cannot convert")
        expectFailure("map(params.list, 5)", "lambda")
        expectFailure("map(params.list, (a, b, c) => a)", "takes 3 arguments")
        expectFailure("vars.text(1)", "only named functions can be called")
        expectFailure("x => x", "unexpected")
        expectFailure("(x => x)(1)", "expected")
        expectFailure("1 + (x => x)", "expected")
    }

    @Test func secretYieldsAnOpaquePlaceholderOnly() throws {
        #expect(try ev("secret(\"api-token\")") == ["$secret": "api-token"])
        #expect(WorkflowExpression.secretPlaceholderKey == "$secret")
        expectFailure("secret(vars.text)", "literal reference name")
        expectFailure("secret('a' + 'b')", "literal reference name")
        expectFailure("secret('')", "literal reference name")
        expectFailure("secret('a', 'b')", "takes 1 argument")
        let header = try WorkflowExpression.interpolate("Bearer ${{ secret('api-token') }}", context: context())
        #expect(header == "Bearer {\"$secret\":\"api-token\"}", "inside text the placeholder is still only a reference")
    }
}

@Suite("Expression language: templates and injection (unit)") struct ExpressionTemplateTests {
    private func tpl(_ s: String) throws -> JSONValue { try WorkflowExpression.interpolate(s, context: context()) }

    @Test func aSingleInterpolationYieldsTheTypedValue() throws {
        #expect(try tpl("${{ params.list }}") == [1, 2, 3] && tpl("${{ 1 + 1 }}") == .int(2) && tpl("${{ vars.obj }}") == ["a": 1, "b": [10, 20]])
        #expect(try tpl("${{ null }}") == .null && tpl("${{true}}") == true && tpl("${{ vars.count > 1 }}") == true)
        #expect(try tpl(" ${{ 1 }}") == " 1" && tpl("${{ 1 }} ") == "1 " && tpl("${{ 1 }}${{ 2 }}") == "12")
        #expect(try tpl("no interpolation") == "no interpolation" && tpl("") == "" && tpl("$ {{ 1 }} ${ {1} }") == "$ {{ 1 }} ${ {1} }")
    }

    @Test func mixedTextUsesDisplayStrings() throws {
        #expect(try tpl("n=${{ 1 + 1 }} l=${{ [1, 2] }} o=${{ vars.obj }} z=${{ null }} b=${{ true }} s=${{ params.name }} f=${{ 0.5 }}")
                == "n=2 l=[1,2] o={\"a\":1,\"b\":[10,20]} z=null b=true s=Ada f=0.5")
        #expect(try tpl("${{ params.folder }}/out-${{ env.DATE }}.pdf") == "~/x/out-2027-01-15.pdf")
        #expect(try tpl("line1\n${{ join(map(params.list, x => '- ' + x), '\\n') }}\nend") == "line1\n- 1\n- 2\n- 3\nend")
    }

    @Test func escapesAndDelimiters() throws {
        #expect(try tpl("$${{ not evaluated }}") == "${{ not evaluated }}")
        #expect(try tpl("cost: $${{ x }} and ${{ 1 }}") == "cost: ${{ x }} and 1")
        #expect(try tpl("${{ \"a}}b\" }}") == "a}}b" && tpl("${{ 'x}}' + '{{y' }}!") == "x}}{{y!")
        #expect(try tpl("${{ 'it\\'s }}' }}") == "it's }}")
        #expect(try tpl("a }} b") == "a }} b")
    }

    @Test func templateErrorsCarryOffsets() {
        let unterminated = failure("abc ${{ 1 + ", template: true)
        #expect(unterminated?.message.contains("unterminated") == true && unterminated?.offset == 4)
        let inner = failure("ab ${{ 1 + }} cd", template: true)
        #expect(inner != nil && inner?.offset == 11, "offset \(inner?.offset ?? -1) points inside the template")
        let second = failure("${{ 1 }} and ${{ nope }}", template: true)
        #expect(second?.message.contains("unknown name 'nope'") == true && second?.offset == 17)
        #expect(failure("${{ }}", template: true)?.message.contains("empty expression") == true)
        let bare = failure("1 + ")
        #expect(bare?.offset == 4)
        #expect(WorkflowExpression.syntaxErrors(in: "1 +", isExpressionField: true).count == 1)
        #expect(WorkflowExpression.syntaxErrors(in: "plain text (not an expression", isExpressionField: false).isEmpty)
        #expect(WorkflowExpression.syntaxErrors(in: "x ${{ ( }}", isExpressionField: false).count == 1)
        #expect(WorkflowExpression.syntaxErrors(in: "len(vars.x) > 0", isExpressionField: true).isEmpty)
    }

    @Test func interpolationIsSinglePassAndResultsAreData() throws {
        // A step output that looks like a template is returned verbatim: never parsed, never evaluated.
        #expect(try tpl("${{ steps.fetch.output.text }}") == .string(hostile))
        #expect(try tpl("pre ${{ steps.fetch.output.text }} post") == .string("pre \(hostile) post"))
        #expect(try tpl("${{ steps.fetch.output.text + steps.fetch.output.text }}") == .string(hostile + hostile))
        #expect(try WorkflowExpression.evaluateField("steps.fetch.output.text", context: context()) == .string(hostile))
        let resolved = try WorkflowExpression.resolve(["body": "${{ steps.fetch.output.text }}", "list": ["x ${{ steps.fetch.output.text }}"]], context: context())
        #expect(resolved == ["body": .string(hostile), "list": [.string("x \(hostile)")]])
        // Resolving the already-resolved value again is what must never happen implicitly; it is shown here to be a distinct, explicit call.
        #expect(try WorkflowExpression.resolve(resolved, context: context()) != resolved)
        // Data cannot become code through functions either.
        #expect(try ev("fromJSON('\"${{ env.HOME }}\"')") == "${{ env.HOME }}")
        #expect(try ev("replace(steps.fetch.output.text, 'x', 'y')").stringValue?.contains("${{ secret(\"y\") }}") == true)
        #expect(try ev("'${{ 1 + 1 }}'") == "${{ 1 + 1 }}", "a string literal inside an expression is just a string")
        #expect(try tpl("${{ '$' + '{{ env.HOME }}' }}") == "${{ env.HOME }}")
    }

    @Test func evaluateFieldAndResolve() throws {
        let c = context()
        #expect(try WorkflowExpression.evaluateField("1 + 1", context: c) == 2)
        #expect(try WorkflowExpression.evaluateField("${{ 1 + 1 }}", context: c) == 2)
        #expect(try WorkflowExpression.evaluateField("x ${{ 1 }}", context: c) == "x 1")
        let value: JSONValue = ["path": "${{ params.folder }}/a", "n": "${{ params.n }}", "keep": 5, "flag": true, "nested": ["list": ["${{ vars.count }}", "lit", nil]],
                                "${{ key }}": "untouched key"]
        #expect(try WorkflowExpression.resolve(value, context: c)
                == ["path": "~/x/a", "n": 3, "keep": 5, "flag": true, "nested": ["list": [2, "lit", nil]], "${{ key }}": "untouched key"])
        #expect(throws: WorkflowExpressionError.self) { try WorkflowExpression.resolve(["a": ["${{ nope }}"]], context: c) }
    }
}

@Suite("Expression language: rejected syntax, bounds and analysis (unit)") struct ExpressionSafetyTests {
    @Test func noAssignmentNoStatementsNoArbitraryCode() {
        expectFailure("vars.count = 1", "assignment is not part of the expression language")
        expectFailure("a = 1", "assignment")
        expectFailure("1; 2", "unexpected character ';'")
        expectFailure("`ls`", "unexpected character '`'")
        expectFailure("$(whoami)", "unexpected character '$'")
        expectFailure("{a: 1}", "unexpected character '{'")
        expectFailure("1 ? 2 : 3", "unexpected character '?'")
        expectFailure("1 | 2", "unexpected character '|'")
        expectFailure("1 & 2", "unexpected character '&'")
        expectFailure("vars.text.toUpperCase()", "only named functions can be called")
        expectFailure("len('a')('b')", "only named functions can be called")
        expectFailure("eval('1 + 1')", "unknown function 'eval'")
        expectFailure("import('os')", "unknown function 'import'")
        expectFailure("system('rm -rf /')", "unknown function 'system'")
        expectFailure("__proto__", "unknown name")
        expectFailure("1 2", "unexpected number")
        expectFailure("(1", "expected ')'")
        expectFailure("[1, 2", "expected ']'")
        expectFailure("vars.", "expected a property name")
        expectFailure("a b", "unexpected 'b'")
        expectFailure("café", "unexpected character")
    }

    @Test func nestingDepthIsBounded() throws {
        let ok = String(repeating: "(", count: 20) + "1" + String(repeating: ")", count: 20)
        #expect(try ev(ok) == 1)
        let deep = String(repeating: "(", count: 70) + "1" + String(repeating: ")", count: 70)
        expectFailure(deep, "nested too deeply")
        expectFailure(String(repeating: "!", count: 70) + "true", "nested too deeply")
        expectFailure(String(repeating: "[", count: 70) + String(repeating: "]", count: 70), "nested too deeply")
        expectFailure(String(repeating: "len(", count: 70) + "1" + String(repeating: ")", count: 70), "nested too deeply")
    }

    @Test func sourceLengthAndOperatorChainsAreBounded() throws {
        let long = (0..<6000).map { _ in "1" }.joined(separator: " + ")
        #expect(long.count > ExpressionLimits.maxSourceCharacters)
        expectFailure(long, "longer than")
        // Chains nest without brackets: they are bounded so that a long one is an error, never a stack overflow.
        let limit = ExpressionLimits.maxChainedOperators
        #expect(try ev((0...limit).map { _ in "1" }.joined(separator: " + ")) == .int(limit + 1))
        expectFailure((0...(limit + 1)).map { _ in "1" }.joined(separator: " + "), "too many chained operators")
        expectFailure("vars" + String(repeating: ".a", count: limit + 1), "too many chained operators")
        expectFailure("vars.x" + String(repeating: "[0]", count: limit + 1), "too many chained operators")
        #expect(try ev("vars" + String(repeating: ".a", count: limit)) == .null)
        #expect(try ev("true" + String(repeating: " && true", count: limit - 1) + " && false") == false)
        // Static analysis and renaming walk the same trees.
        let longest = (0..<limit).map { "steps.s\($0).output" }.joined(separator: " + ")
        #expect(longest.count < ExpressionLimits.maxSourceCharacters)
        #expect(WorkflowExpression.syntaxErrors(in: longest, isExpressionField: true).count == 1, "member accesses count as chained operators too")
        let chain = (0..<(limit / 4)).map { "steps.s\($0).output" }.joined(separator: " + ")
        #expect(try WorkflowExpression.references(in: chain, isExpressionField: true).steps.count == limit / 4)
        #expect(try WorkflowExpression.references(in: (0...limit).map { _ in "x" }.joined(separator: " + "), isExpressionField: true).freeNames == ["x"])
        #expect(WorkflowExpression.renamingStep(in: chain, from: "s1", to: "renamed", isExpressionField: true).contains("steps.renamed.output + steps.s2.output"))
        #expect(WorkflowExpression.syntaxErrors(in: "${{ " + (0...(limit + 1)).map { _ in "1" }.joined(separator: "-") + " }}", isExpressionField: false).count == 1)
    }

    @Test func evaluationWorkIsBounded() {
        var c = context()
        c.vars["big"] = .array((0..<1000).map { .int($0) })
        let nested = "map(vars.big, x => map(vars.big, y => x + y))"
        #expect(throws: WorkflowExpressionError.self) { try WorkflowExpression.evaluate(nested, context: c) }
        do { _ = try WorkflowExpression.evaluate(nested, context: c) }
        catch { #expect("\(error)".contains("evaluation budget")) }
        #expect((try? WorkflowExpression.evaluate("sum(map(vars.big, x => x * 2))", context: c)) == .int(999_000))
    }

    @Test func outputSizeIsBounded() throws {
        var c = context()
        c.vars["s"] = .string(String(repeating: "a", count: 600_000))
        c.vars["many"] = .array(Array(repeating: .int(1), count: 60_000))
        func message(_ source: String, template: Bool = false) -> String {
            do {
                _ = template ? try WorkflowExpression.interpolate(source, context: c) : try WorkflowExpression.evaluate(source, context: c)
                return "no error"
            } catch { return "\(error)" }
        }
        #expect(message("vars.s + vars.s").contains("larger than"))
        #expect(message("join([vars.s, vars.s], '')").contains("larger than"))
        #expect(message("replace(vars.s, 'a', 'bb')").contains("larger than"))
        #expect(message("${{ vars.s }}${{ vars.s }}", template: true).contains("larger than"))
        #expect(message("vars.many + vars.many").contains("more than"))
        #expect(message("split(vars.s, 'a')").contains("more than"))
        #expect(try WorkflowExpression.evaluate("len(vars.s + 'b')", context: c) == .int(600_001))
    }

    @Test func referencesAreFoundStatically() throws {
        let refs = try WorkflowExpression.references(
            in: "x ${{ steps.a.output + params.p + vars.v + env.HOME + secret('s') }} y ${{ len(item) + map(xs, y => y + z + steps[\"b-2\"].status) + steps.c-3.output }}",
            isExpressionField: false)
        #expect(refs.steps == ["a", "b-2", "c-3"] && refs.parameters == ["p"] && refs.variables == ["v"] && refs.environment == ["HOME"])
        #expect(refs.secrets == ["s"] && refs.functions == ["secret", "len", "map"] && refs.freeNames == ["item", "xs", "z"])
        let bare = try WorkflowExpression.references(in: "params['q'] + vars[\"w\"] + env['USER']", isExpressionField: true)
        #expect(bare.parameters == ["q"] && bare.variables == ["w"] && bare.environment == ["USER"])
        #expect(try WorkflowExpression.references(in: "steps.a.output", isExpressionField: false) == ExpressionReferences(), "plain template text holds no reference")
        #expect(try WorkflowExpression.references(in: "map([1], steps => steps.a)", isExpressionField: true).steps.isEmpty, "a lambda parameter named steps is not the steps root")
        #expect(throws: WorkflowExpressionError.self) { try WorkflowExpression.references(in: "${{ 1 + }}", isExpressionField: false) }
    }

    @Test func renamingAStepRewritesOnlyRealReferences() {
        let template = "${{ steps.old.output }} and ${{ steps.older.x + steps.old.y + steps['old'].z + steps[\"old\"].w }} steps.old 'old'"
        #expect(WorkflowExpression.renamingStep(in: template, from: "old", to: "fresh-1", isExpressionField: false)
                == "${{ steps.fresh-1.output }} and ${{ steps.older.x + steps.fresh-1.y + steps['fresh-1'].z + steps[\"fresh-1\"].w }} steps.old 'old'")
        #expect(WorkflowExpression.renamingStep(in: "steps.old.status == 'old' && vars.old > 0 && params.steps.old", from: "old", to: "n", isExpressionField: true)
                == "steps.n.status == 'old' && vars.old > 0 && params.steps.old")
        #expect(WorkflowExpression.renamingStep(in: "steps.a-b.output", from: "a-b", to: "c", isExpressionField: true) == "steps.c.output")
        #expect(WorkflowExpression.renamingStep(in: "steps.old.output", from: "old", to: "n", isExpressionField: false) == "steps.old.output", "literal text is not an expression")
        #expect(WorkflowExpression.renamingStep(in: "${{ steps.old. }}", from: "old", to: "n", isExpressionField: false) == "${{ steps.old. }}", "text that does not parse is left alone")
        let renamed = WorkflowExpression.renamingStep(in: "${{ steps.old.output }}", from: "old", to: "new", isExpressionField: false)
        #expect((try? WorkflowExpression.references(in: renamed, isExpressionField: false))?.steps == ["new"])
    }
}
