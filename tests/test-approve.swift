///
///  test-approve.swift
///  Unit tests for pure-logic functions in claude-approve.swift.
///
///  Compiled with:  swiftc -D TESTING -framework AppKit \
///                    hooks/claude-approve.swift tests/harness.swift tests/test-approve.swift \
///                    -o tests/test-approve-bin
///

import AppKit
import Foundation

// MARK: - Test Helpers

/// Shorthand for building a HookInput with defaults.
func makeInput(
    tool: String = "Bash",
    input: [String: Any] = [:],
    cwd: String = "/tmp/test-project",
    session: String = ""
) -> HookInput {
    HookInput(toolName: tool, toolInput: input, cwd: cwd, sessionId: session)
}

/// Returns a unique session ID scoped to this PID (for test isolation).
func testSessionId() -> String {
    "test-\(ProcessInfo.processInfo.processIdentifier)-\(Int.random(in: 100000..<999999))"
}

/// Removes the session file created during a test.
func cleanupSession(_ sessionId: String) {
    let path = "\(HookInput.sessionDirectory)/\(sessionId)"
    try? FileManager.default.removeItem(atPath: path)
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - buildGist Tests (18)
// ═══════════════════════════════════════════════════════════════════

func testBuildGist() {
    test("buildGist: Bash with description") {
        let i = makeInput(tool: "Bash", input: [
            "command": "echo hello", "description": "Print greeting",
        ])
        assertEq(buildGist(input: i), "Print greeting")
    }
    test("buildGist: Bash simple command") {
        let i = makeInput(tool: "Bash", input: ["command": "echo hello world"])
        assertEq(buildGist(input: i), "echo")
    }
    test("buildGist: Bash with && operator") {
        let i = makeInput(tool: "Bash", input: ["command": "cd /tmp && ls -la"])
        assertEq(buildGist(input: i), "cd && ls")
    }
    test("buildGist: Bash empty command") {
        let i = makeInput(tool: "Bash", input: ["command": ""])
        assertEq(buildGist(input: i), "")
    }
    test("buildGist: Edit") {
        let i = makeInput(tool: "Edit", input: ["file_path": "/Users/test/src/main.swift"])
        assertEq(buildGist(input: i), "Edit main.swift")
    }
    test("buildGist: Write") {
        let i = makeInput(tool: "Write", input: ["file_path": "/Users/test/README.md"])
        assertEq(buildGist(input: i), "Write README.md")
    }
    test("buildGist: Read") {
        let i = makeInput(tool: "Read", input: ["file_path": "/Users/test/config.json"])
        assertEq(buildGist(input: i), "Read config.json")
    }
    test("buildGist: NotebookEdit") {
        let i = makeInput(tool: "NotebookEdit", input: [
            "edit_mode": "replace", "notebook_path": "/test/nb.ipynb",
        ])
        assertEq(buildGist(input: i), "Replace cell in nb.ipynb")
    }
    test("buildGist: Task with description") {
        let i = makeInput(tool: "Task", input: ["description": "Research API"])
        assertEq(buildGist(input: i), "Research API")
    }
    test("buildGist: Task without description") {
        let i = makeInput(tool: "Task", input: [:])
        assertEq(buildGist(input: i), "Launch agent")
    }
    test("buildGist: WebFetch short URL") {
        let i = makeInput(tool: "WebFetch", input: ["url": "https://example.com"])
        assertEq(buildGist(input: i), "Fetch https://example.com")
    }
    test("buildGist: WebFetch long URL truncated") {
        let longUrl = "https://example.com/" + String(repeating: "a", count: 60)
        let i = makeInput(tool: "WebFetch", input: ["url": longUrl])
        let gist = buildGist(input: i)
        assertTrue(gist.hasSuffix("..."), "long URL should be truncated")
        assertTrue(gist.hasPrefix("Fetch "))
    }
    test("buildGist: WebSearch") {
        let i = makeInput(tool: "WebSearch", input: ["query": "swift testing"])
        assertEq(buildGist(input: i), "Search: swift testing")
    }
    test("buildGist: Glob") {
        let i = makeInput(tool: "Glob", input: ["pattern": "**/*.swift"])
        assertEq(buildGist(input: i), "Find files: **/*.swift")
    }
    test("buildGist: Grep") {
        let i = makeInput(tool: "Grep", input: ["pattern": "TODO"])
        assertEq(buildGist(input: i), "Search code: TODO")
    }
    test("buildGist: AskUserQuestion single question") {
        let i = makeInput(tool: "AskUserQuestion", input: [
            "questions": [["question": "Which approach?", "header": "Approach"]],
        ])
        assertEq(buildGist(input: i), "Which approach?")
    }
    test("buildGist: AskUserQuestion multiple questions") {
        let i = makeInput(tool: "AskUserQuestion", input: [
            "questions": [
                ["question": "Q1?", "header": "Auth"],
                ["question": "Q2?", "header": "DB"],
            ],
        ])
        assertEq(buildGist(input: i), "Auth \u{00b7} DB")
    }
    test("buildGist: unknown tool") {
        let i = makeInput(tool: "CustomTool", input: [:])
        assertEq(buildGist(input: i), "CustomTool")
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - lastComponent Tests (5)
// ═══════════════════════════════════════════════════════════════════

func testLastComponent() {
    test("lastComponent: nil") {
        assertEq(lastComponent(nil), "")
    }
    test("lastComponent: empty string") {
        assertEq(lastComponent(""), "")
    }
    test("lastComponent: filename only") {
        assertEq(lastComponent("main.swift"), "main.swift")
    }
    test("lastComponent: full path") {
        assertEq(lastComponent("/Users/test/src/main.swift"), "main.swift")
    }
    test("lastComponent: non-string type") {
        assertEq(lastComponent(42), "")
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - summarizeBashCommand Tests (8)
// ═══════════════════════════════════════════════════════════════════

func testSummarizeBashCommand() {
    test("summarize: simple command") {
        assertEq(summarizeBashCommand("echo hello world"), "echo")
    }
    test("summarize: && operator") {
        assertEq(summarizeBashCommand("cd /tmp && ls -la"), "cd && ls")
    }
    test("summarize: || operator") {
        assertEq(summarizeBashCommand("test -f foo || echo missing"), "test || echo")
    }
    test("summarize: pipe") {
        assertEq(summarizeBashCommand("cat file | grep pattern"), "cat | grep")
    }
    test("summarize: semicolon") {
        assertEq(summarizeBashCommand("echo a ; echo b"), "echo ; echo")
    }
    test("summarize: multi-line takes first") {
        assertEq(summarizeBashCommand("echo hello\necho world"), "echo")
    }
    test("summarize: empty string") {
        assertEq(summarizeBashCommand(""), "")
    }
    test("summarize: chained operators") {
        assertEq(summarizeBashCommand("mkdir -p dir && cd dir && ls"), "mkdir && cd && ls")
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - ansiColor / parseAnsiCodes Tests (13)
// ═══════════════════════════════════════════════════════════════════

func testAnsiColor() {
    let def = NSColor.white

    test("ansiColor: code 0 resets to default") {
        assertEq(ansiColor(code: 0, defaultColor: def), def)
    }
    test("ansiColor: code 39 resets to default") {
        assertEq(ansiColor(code: 39, defaultColor: def), def)
    }
    test("ansiColor: code 31 is non-nil") {
        assertTrue(ansiColor(code: 31, defaultColor: def) != nil)
    }
    test("ansiColor: standard range 30-37 all non-nil") {
        for code in 30...37 {
            assertTrue(ansiColor(code: code, defaultColor: def) != nil, "code \(code)")
        }
    }
    test("ansiColor: bright range 90-97 all non-nil") {
        for code in 90...97 {
            assertTrue(ansiColor(code: code, defaultColor: def) != nil, "code \(code)")
        }
    }
    test("ansiColor: unknown code returns nil") {
        assertTrue(ansiColor(code: 999, defaultColor: def) == nil)
    }
    test("ansiColor: code 31 differs from default") {
        assertTrue(ansiColor(code: 31, defaultColor: def) != def)
    }
}

func testParseAnsiCodes() {
    test("parseAnsi: plain text no codes") {
        assertEq(plainText(parseAnsiCodes("hello world")), "hello world")
    }
    test("parseAnsi: single color code") {
        assertEq(plainText(parseAnsiCodes("\u{1b}[31mred text")), "red text")
    }
    test("parseAnsi: reset code") {
        assertEq(plainText(parseAnsiCodes("\u{1b}[31mred\u{1b}[0mnormal")), "rednormal")
    }
    test("parseAnsi: multiple colors") {
        assertEq(plainText(parseAnsiCodes("\u{1b}[31mred\u{1b}[32mgreen")), "redgreen")
    }
    test("parseAnsi: empty string") {
        assertEq(plainText(parseAnsiCodes("")), "")
    }
    test("parseAnsi: semicolon-separated codes") {
        assertEq(plainText(parseAnsiCodes("\u{1b}[0;31mtext")), "text")
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - highlightBash Tests (10)
// ═══════════════════════════════════════════════════════════════════

func testHighlightBash() {
    test("highlight: preserves text") {
        assertEq(plainText(highlightBash("if true; then echo hi; fi")),
                 "if true; then echo hi; fi")
    }
    test("highlight: double-quoted string") {
        assertEq(plainText(highlightBash("echo \"hello world\"")),
                 "echo \"hello world\"")
    }
    test("highlight: single-quoted string") {
        assertEq(plainText(highlightBash("echo 'hello'")),
                 "echo 'hello'")
    }
    test("highlight: flags preserved") {
        assertEq(plainText(highlightBash("ls -la --color")),
                 "ls -la --color")
    }
    test("highlight: pipe operator") {
        assertEq(plainText(highlightBash("cat file | grep pat")),
                 "cat file | grep pat")
    }
    test("highlight: comment line") {
        assertEq(plainText(highlightBash("# this is a comment")),
                 "# this is a comment")
    }
    test("highlight: && operator") {
        assertEq(plainText(highlightBash("cd dir && ls")),
                 "cd dir && ls")
    }
    test("highlight: multi-line") {
        assertEq(plainText(highlightBash("echo a\necho b")),
                 "echo a\necho b")
    }
    test("highlight: empty string") {
        assertEq(plainText(highlightBash("")), "")
    }
    test("highlight: first word gets command color") {
        let result = highlightBash("git status")
        assertTrue(colorAt(result, index: 0) != nil, "first word should have a color")
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - computeLineDiff Tests (8)
// ═══════════════════════════════════════════════════════════════════

func testComputeLineDiff() {
    test("diff: identical strings") {
        let ops = computeLineDiff(old: "hello", new: "hello")
        assertEq(ops, [.context("hello")])
    }
    test("diff: completely different") {
        let ops = computeLineDiff(old: "old", new: "new")
        assertEq(ops, [.removal("old"), .addition("new")])
    }
    test("diff: one line changed in middle") {
        let ops = computeLineDiff(old: "a\nb\nc", new: "a\nB\nc")
        assertTrue(ops.contains(.context("a")))
        assertTrue(ops.contains(.removal("b")))
        assertTrue(ops.contains(.addition("B")))
        assertTrue(ops.contains(.context("c")))
    }
    test("diff: empty old (pure addition)") {
        let ops = computeLineDiff(old: "", new: "added")
        assertTrue(ops.contains(.addition("added")))
    }
    test("diff: empty new (pure removal)") {
        let ops = computeLineDiff(old: "removed", new: "")
        assertTrue(ops.contains(.removal("removed")))
    }
    test("diff: large >500 lines falls back to simple") {
        let old = (0..<501).map { "line\($0)" }.joined(separator: "\n")
        let new = (0..<501).map { "new\($0)" }.joined(separator: "\n")
        let ops = computeLineDiff(old: old, new: new)
        let removals = ops.filter { if case .removal = $0 { return true }; return false }
        let additions = ops.filter { if case .addition = $0 { return true }; return false }
        assertEq(removals.count, 501)
        assertEq(additions.count, 501)
    }
    test("diff: single line each different") {
        let ops = computeLineDiff(old: "aaa", new: "bbb")
        assertEq(ops, [.removal("aaa"), .addition("bbb")])
    }
    test("diff: common prefix and suffix") {
        let ops = computeLineDiff(old: "a\nb\nc", new: "a\nb\nd")
        assertTrue(ops.contains(.context("a")))
        assertTrue(ops.contains(.context("b")))
        assertTrue(ops.contains(.removal("c")))
        assertTrue(ops.contains(.addition("d")))
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - collapseContext Tests (6)
// ═══════════════════════════════════════════════════════════════════

func testCollapseContext() {
    test("collapse: short run kept") {
        let ops: [DiffOp] = [.context("a"), .context("b"), .context("c")]
        assertEq(collapseContext(ops).count, 3)
    }
    test("collapse: long run collapsed") {
        // threshold=5, prefix=3, suffix=2 → 3+1+2=6
        let ops: [DiffOp] = (0..<10).map { .context("line\($0)") }
        let result = collapseContext(ops)
        assertEq(result.count, 6)
        assertTrue(result.contains(.context("\u{2026}")))
    }
    test("collapse: exactly at threshold kept") {
        let ops: [DiffOp] = (0..<5).map { .context("line\($0)") }
        assertEq(collapseContext(ops).count, 5)
    }
    test("collapse: one above threshold collapsed") {
        let ops: [DiffOp] = (0..<6).map { .context("line\($0)") }
        let result = collapseContext(ops)
        // 6 > 5 → collapsed: 3 prefix + 1 ellipsis + 2 suffix = 6
        assertEq(result.count, 6)
        assertTrue(result.contains(.context("\u{2026}")))
    }
    test("collapse: mixed changes preserve surrounding context") {
        let ops: [DiffOp] = [
            .context("a"), .context("b"), .context("c"),
            .context("d"), .context("e"), .context("f"),
            .removal("old"),
            .addition("new"),
            .context("g"),
        ]
        let result = collapseContext(ops)
        assertTrue(result.contains(.removal("old")))
        assertTrue(result.contains(.addition("new")))
        assertTrue(result.contains(.context("g")))
    }
    test("collapse: empty input") {
        assertEq(collapseContext([]).count, 0)
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - findStartLine Tests (5)
// ═══════════════════════════════════════════════════════════════════

func testFindStartLine() {
    test("findStartLine: text at line 1") {
        withTempDir { dir in
            let path = "\(dir)/test.txt"
            try! "hello\nworld\nfoo".write(toFile: path, atomically: true, encoding: .utf8)
            assertEq(findStartLine(filePath: path, oldString: "hello\nworld"), 1)
        }
    }
    test("findStartLine: text at line 3") {
        withTempDir { dir in
            let path = "\(dir)/test.txt"
            try! "a\nb\nc\nd".write(toFile: path, atomically: true, encoding: .utf8)
            assertEq(findStartLine(filePath: path, oldString: "c\nd"), 3)
        }
    }
    test("findStartLine: text not found") {
        withTempDir { dir in
            let path = "\(dir)/test.txt"
            try! "hello\nworld".write(toFile: path, atomically: true, encoding: .utf8)
            assertEq(findStartLine(filePath: path, oldString: "missing"), 1)
        }
    }
    test("findStartLine: file does not exist") {
        assertEq(findStartLine(filePath: "/nonexistent/file.txt", oldString: "x"), 1)
    }
    test("findStartLine: empty search string") {
        withTempDir { dir in
            let path = "\(dir)/test.txt"
            try! "hello".write(toFile: path, atomically: true, encoding: .utf8)
            assertEq(findStartLine(filePath: path, oldString: ""), 1)
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - buildContent Tests (12)
// ═══════════════════════════════════════════════════════════════════

func testBuildContent() {
    test("buildContent: Bash shows command") {
        let i = makeInput(tool: "Bash", input: ["command": "echo hello"])
        assertContains(plainText(buildContent(input: i)), "echo hello")
    }
    test("buildContent: Edit shows file path") {
        let i = makeInput(tool: "Edit", input: [
            "file_path": "/test/main.swift",
            "old_string": "old line",
            "new_string": "new line",
        ])
        assertContains(plainText(buildContent(input: i)), "/test/main.swift")
    }
    test("buildContent: Write shows path and preview") {
        let i = makeInput(tool: "Write", input: [
            "file_path": "/test/out.txt",
            "content": "line1\nline2\nline3",
        ])
        let text = plainText(buildContent(input: i))
        assertContains(text, "/test/out.txt")
        assertContains(text, "line1")
    }
    test("buildContent: Write truncates long content") {
        let lines = (0..<100).map { "line\($0)" }.joined(separator: "\n")
        let i = makeInput(tool: "Write", input: [
            "file_path": "/test/big.txt", "content": lines,
        ])
        assertContains(plainText(buildContent(input: i)), "more lines")
    }
    test("buildContent: Read shows path") {
        let i = makeInput(tool: "Read", input: ["file_path": "/test/config.json"])
        assertContains(plainText(buildContent(input: i)), "/test/config.json")
    }
    test("buildContent: Read shows offset and limit") {
        let i = makeInput(tool: "Read", input: [
            "file_path": "/test/file.txt", "offset": 10, "limit": 50,
        ])
        let text = plainText(buildContent(input: i))
        assertContains(text, "offset: 10")
        assertContains(text, "limit: 50")
    }
    test("buildContent: NotebookEdit") {
        let i = makeInput(tool: "NotebookEdit", input: [
            "notebook_path": "/test/nb.ipynb",
            "edit_mode": "replace",
            "new_source": "print('hello')",
        ])
        let text = plainText(buildContent(input: i))
        assertContains(text, "/test/nb.ipynb")
        assertContains(text, "print('hello')")
    }
    test("buildContent: Task") {
        let i = makeInput(tool: "Task", input: [
            "description": "Research API",
            "subagent_type": "explore",
            "prompt": "Find all endpoints",
        ])
        let text = plainText(buildContent(input: i))
        assertContains(text, "Research API")
        assertContains(text, "agent: explore")
        assertContains(text, "Find all endpoints")
    }
    test("buildContent: WebFetch") {
        let i = makeInput(tool: "WebFetch", input: [
            "url": "https://example.com", "prompt": "Extract title",
        ])
        let text = plainText(buildContent(input: i))
        assertContains(text, "https://example.com")
        assertContains(text, "Extract title")
    }
    test("buildContent: Glob") {
        let i = makeInput(tool: "Glob", input: [
            "pattern": "**/*.swift", "path": "/src",
        ])
        let text = plainText(buildContent(input: i))
        assertContains(text, "**/*.swift")
        assertContains(text, "in: /src")
    }
    test("buildContent: Grep with glob filter") {
        let i = makeInput(tool: "Grep", input: [
            "pattern": "TODO", "path": "/src", "glob": "*.swift",
        ])
        let text = plainText(buildContent(input: i))
        assertContains(text, "TODO")
        assertContains(text, "in: /src")
        assertContains(text, "glob: *.swift")
    }
    test("buildContent: AskUserQuestion") {
        let i = makeInput(tool: "AskUserQuestion", input: [
            "questions": [[
                "header": "Approach",
                "question": "Which method?",
                "options": [
                    ["label": "Option A", "description": "First approach"],
                    ["label": "Option B", "description": "Second approach"],
                ],
            ]],
        ])
        let text = plainText(buildContent(input: i))
        assertContains(text, "Approach")
        assertContains(text, "Which method?")
        assertContains(text, "Option A")
        assertContains(text, "Option B")
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - buildPermOptions Tests (7)
// ═══════════════════════════════════════════════════════════════════

func testBuildPermOptions() {
    test("permOptions: Bash has command prefix") {
        let i = makeInput(tool: "Bash", input: ["command": "git status"])
        let opts = buildPermOptions(input: i)
        assertEq(opts.count, 3)
        assertEq(opts[0].resultKey, "allow_once")
        assertEq(opts[1].resultKey, "dont_ask_bash")
        assertContains(opts[1].label, "git")
        assertEq(opts[2].resultKey, "deny")
    }
    test("permOptions: Edit") {
        let opts = buildPermOptions(input: makeInput(tool: "Edit"))
        assertEq(opts.count, 3)
        assertEq(opts[1].resultKey, "allow_edits_session")
    }
    test("permOptions: Write same as Edit") {
        let opts = buildPermOptions(input: makeInput(tool: "Write"))
        assertEq(opts[1].resultKey, "allow_edits_session")
    }
    test("permOptions: WebFetch includes domain") {
        let opts = buildPermOptions(input: makeInput(
            tool: "WebFetch", input: ["url": "https://example.com/page"]
        ))
        assertEq(opts[1].resultKey, "dont_ask_domain")
        assertContains(opts[1].label, "example.com")
    }
    test("permOptions: WebSearch") {
        let opts = buildPermOptions(input: makeInput(tool: "WebSearch"))
        assertEq(opts[1].resultKey, "dont_ask_tool")
    }
    test("permOptions: AskUserQuestion single button") {
        let opts = buildPermOptions(input: makeInput(tool: "AskUserQuestion"))
        assertEq(opts.count, 1)
        assertEq(opts[0].resultKey, "allow_goto_terminal")
    }
    test("permOptions: default tool has session option") {
        let opts = buildPermOptions(input: makeInput(tool: "Read"))
        assertEq(opts.count, 3)
        assertEq(opts[1].resultKey, "allow_session")
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - computeButtonRows Tests (6)
// ═══════════════════════════════════════════════════════════════════

func testComputeButtonRows() {
    test("buttonRows: single option") {
        let opts = [PermOption(label: "Yes", resultKey: "a", color: .green)]
        let (rows, height) = computeButtonRows(options: opts)
        assertEq(rows.count, 1)
        assertEq(rows[0], [0])
        assertTrue(height > 0)
    }
    test("buttonRows: two short options fit one row") {
        let opts = [
            PermOption(label: "Yes", resultKey: "a", color: .green),
            PermOption(label: "No", resultKey: "b", color: .red),
        ]
        let (rows, _) = computeButtonRows(options: opts)
        assertEq(rows.count, 1)
        assertEq(rows[0], [0, 1])
    }
    test("buttonRows: three options need two rows") {
        let opts = [
            PermOption(label: "Yes", resultKey: "a", color: .green),
            PermOption(label: "Allow all", resultKey: "b", color: .blue),
            PermOption(label: "No", resultKey: "c", color: .red),
        ]
        let (rows, _) = computeButtonRows(options: opts)
        assertEq(rows.count, 2)
        assertTrue(rows[0].count <= 2)
    }
    test("buttonRows: very long label forces new row") {
        let longLabel = String(repeating: "x", count: 200)
        let opts = [
            PermOption(label: "Yes", resultKey: "a", color: .green),
            PermOption(label: longLabel, resultKey: "b", color: .blue),
        ]
        let (rows, _) = computeButtonRows(options: opts)
        assertEq(rows.count, 2)
    }
    test("buttonRows: height increases with rows") {
        let opts1 = [PermOption(label: "A", resultKey: "a", color: .green)]
        let opts3 = [
            PermOption(label: "A", resultKey: "a", color: .green),
            PermOption(label: "B", resultKey: "b", color: .blue),
            PermOption(label: "C", resultKey: "c", color: .red),
        ]
        let (_, h1) = computeButtonRows(options: opts1)
        let (_, h3) = computeButtonRows(options: opts3)
        assertTrue(h3 > h1, "more rows should yield more height")
    }
    test("buttonRows: AskUserQuestion single option") {
        let opts = [PermOption(label: "Go to Terminal", resultKey: "x", color: .green)]
        let (rows, _) = computeButtonRows(options: opts)
        assertEq(rows, [[0]])
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - processResult Tests (8)
// ═══════════════════════════════════════════════════════════════════

func testProcessResult() {
    test("processResult: allow_once") {
        let (d, r) = processResult(resultKey: "allow_once", input: makeInput())
        assertEq(d, "allow")
        assertContains(r, "Allowed once")
    }
    test("processResult: allow_session writes session file") {
        let sid = testSessionId()
        defer { cleanupSession(sid) }
        let i = makeInput(tool: "Read", session: sid)
        let (d, _) = processResult(resultKey: "allow_session", input: i)
        assertEq(d, "allow")
        let content = try? String(contentsOfFile: i.sessionFilePath!, encoding: .utf8)
        assertContains(content ?? "", "Read")
    }
    test("processResult: allow_edits_session writes Edit and Write") {
        let sid = testSessionId()
        defer { cleanupSession(sid) }
        let i = makeInput(tool: "Edit", session: sid)
        let (d, _) = processResult(resultKey: "allow_edits_session", input: i)
        assertEq(d, "allow")
        let content = try? String(contentsOfFile: i.sessionFilePath!, encoding: .utf8)
        assertContains(content ?? "", "Edit")
        assertContains(content ?? "", "Write")
    }
    test("processResult: dont_ask_bash writes project settings") {
        withTempDir { dir in
            let i = makeInput(tool: "Bash", input: ["command": "git status"], cwd: dir)
            let (d, _) = processResult(resultKey: "dont_ask_bash", input: i)
            assertEq(d, "allow")
            let path = "\(dir)/.claude/settings.local.json"
            if let data = FileManager.default.contents(atPath: path),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let perms = json["permissions"] as? [String: Any],
               let allow = perms["allow"] as? [String] {
                assertTrue(allow.contains("Bash(git *)"))
            } else {
                assertTrue(false, "settings file should be created and parseable")
            }
        }
    }
    test("processResult: dont_ask_domain writes domain rule") {
        withTempDir { dir in
            let i = makeInput(
                tool: "WebFetch", input: ["url": "https://example.com/page"], cwd: dir
            )
            let (d, _) = processResult(resultKey: "dont_ask_domain", input: i)
            assertEq(d, "allow")
            let path = "\(dir)/.claude/settings.local.json"
            if let data = FileManager.default.contents(atPath: path),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let perms = json["permissions"] as? [String: Any],
               let allow = perms["allow"] as? [String] {
                assertTrue(allow.contains("WebFetch(domain:example.com)"))
            }
        }
    }
    test("processResult: dont_ask_tool writes tool rule") {
        withTempDir { dir in
            let i = makeInput(tool: "WebSearch", cwd: dir)
            let (d, _) = processResult(resultKey: "dont_ask_tool", input: i)
            assertEq(d, "allow")
            let path = "\(dir)/.claude/settings.local.json"
            if let data = FileManager.default.contents(atPath: path),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let perms = json["permissions"] as? [String: Any],
               let allow = perms["allow"] as? [String] {
                assertTrue(allow.contains("WebSearch"))
            }
        }
    }
    test("processResult: allow_goto_terminal") {
        let i = makeInput(tool: "AskUserQuestion", cwd: "/tmp")
        let (d, r) = processResult(resultKey: "allow_goto_terminal", input: i)
        assertEq(d, "allow")
        assertContains(r, "terminal")
    }
    test("processResult: deny") {
        let (d, r) = processResult(resultKey: "deny", input: makeInput())
        assertEq(d, "deny")
        assertContains(r, "Rejected")
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - writeHookResponse Tests (3)
// ═══════════════════════════════════════════════════════════════════

func testWriteHookResponse() {
    test("writeHookResponse: allow decision") {
        let output = captureStdout {
            writeHookResponse(decision: "allow", reason: "Test allow")
        }
        assertContains(output, "\"permissionDecision\":\"allow\"")
        assertContains(output, "Test allow")
    }
    test("writeHookResponse: deny decision") {
        let output = captureStdout {
            writeHookResponse(decision: "deny", reason: "Test deny")
        }
        assertContains(output, "\"permissionDecision\":\"deny\"")
    }
    test("writeHookResponse: includes hookEventName") {
        let output = captureStdout {
            writeHookResponse(decision: "allow", reason: "reason")
        }
        assertContains(output, "PreToolUse")
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - checkSessionAutoApprove Tests (4)
// ═══════════════════════════════════════════════════════════════════

func testCheckSessionAutoApprove() {
    test("sessionApprove: tool present in session file") {
        let sid = testSessionId()
        defer { cleanupSession(sid) }
        let i = makeInput(tool: "Bash", session: sid)
        try? FileManager.default.createDirectory(
            atPath: HookInput.sessionDirectory, withIntermediateDirectories: true
        )
        try? "Bash\n".write(toFile: i.sessionFilePath!, atomically: true, encoding: .utf8)
        let output = captureStdout {
            let result = checkSessionAutoApprove(input: i)
            assertTrue(result, "should return true")
        }
        assertContains(output, "\"permissionDecision\":\"allow\"")
    }
    test("sessionApprove: tool NOT in session file") {
        let sid = testSessionId()
        defer { cleanupSession(sid) }
        let i = makeInput(tool: "Bash", session: sid)
        try? FileManager.default.createDirectory(
            atPath: HookInput.sessionDirectory, withIntermediateDirectories: true
        )
        try? "Edit\n".write(toFile: i.sessionFilePath!, atomically: true, encoding: .utf8)
        assertFalse(checkSessionAutoApprove(input: i))
    }
    test("sessionApprove: no session file") {
        let sid = testSessionId()
        assertFalse(checkSessionAutoApprove(input: makeInput(tool: "Bash", session: sid)))
    }
    test("sessionApprove: empty session ID") {
        assertFalse(checkSessionAutoApprove(input: makeInput(tool: "Bash", session: "")))
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - saveToSessionFile Tests (4)
// ═══════════════════════════════════════════════════════════════════

func testSaveToSessionFile() {
    test("saveSession: creates dir and writes entry") {
        let sid = testSessionId()
        defer { cleanupSession(sid) }
        let i = makeInput(session: sid)
        saveToSessionFile(input: i, entry: "TestTool")
        let content = try? String(contentsOfFile: i.sessionFilePath!, encoding: .utf8)
        assertContains(content ?? "", "TestTool")
    }
    test("saveSession: appends multiple entries") {
        let sid = testSessionId()
        defer { cleanupSession(sid) }
        let i = makeInput(session: sid)
        saveToSessionFile(input: i, entry: "Tool1")
        saveToSessionFile(input: i, entry: "Tool2")
        let content = try? String(contentsOfFile: i.sessionFilePath!, encoding: .utf8)
        assertContains(content ?? "", "Tool1")
        assertContains(content ?? "", "Tool2")
    }
    test("saveSession: nil path is no-op") {
        let i = makeInput(session: "")
        assertTrue(i.sessionFilePath == nil)
        saveToSessionFile(input: i, entry: "Something")
        // No crash = pass
        assertTrue(true)
    }
    test("saveSession: creates session directory") {
        let sid = testSessionId()
        defer { cleanupSession(sid) }
        saveToSessionFile(input: makeInput(session: sid), entry: "X")
        assertTrue(FileManager.default.fileExists(atPath: HookInput.sessionDirectory))
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - saveToLocalSettings Tests (5)
// ═══════════════════════════════════════════════════════════════════

func testSaveToLocalSettings() {
    test("localSettings: creates new file") {
        withTempDir { dir in
            saveToLocalSettings(input: makeInput(cwd: dir), rule: "Bash(echo *)")
            let path = "\(dir)/.claude/settings.local.json"
            assertTrue(FileManager.default.fileExists(atPath: path))
            if let data = FileManager.default.contents(atPath: path),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let perms = json["permissions"] as? [String: Any],
               let allow = perms["allow"] as? [String] {
                assertTrue(allow.contains("Bash(echo *)"))
            }
        }
    }
    test("localSettings: appends to existing") {
        withTempDir { dir in
            let i = makeInput(cwd: dir)
            saveToLocalSettings(input: i, rule: "Rule1")
            saveToLocalSettings(input: i, rule: "Rule2")
            let path = "\(dir)/.claude/settings.local.json"
            if let data = FileManager.default.contents(atPath: path),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let perms = json["permissions"] as? [String: Any],
               let allow = perms["allow"] as? [String] {
                assertTrue(allow.contains("Rule1"))
                assertTrue(allow.contains("Rule2"))
            }
        }
    }
    test("localSettings: deduplicates same rule") {
        withTempDir { dir in
            let i = makeInput(cwd: dir)
            saveToLocalSettings(input: i, rule: "SameRule")
            saveToLocalSettings(input: i, rule: "SameRule")
            let path = "\(dir)/.claude/settings.local.json"
            if let data = FileManager.default.contents(atPath: path),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let perms = json["permissions"] as? [String: Any],
               let allow = perms["allow"] as? [String] {
                assertEq(allow.filter { $0 == "SameRule" }.count, 1)
            }
        }
    }
    test("localSettings: preserves existing keys") {
        withTempDir { dir in
            let settingsDir = "\(dir)/.claude"
            let settingsPath = "\(settingsDir)/settings.local.json"
            try? FileManager.default.createDirectory(
                atPath: settingsDir, withIntermediateDirectories: true
            )
            let existing: [String: Any] = [
                "customKey": "customValue",
                "permissions": ["allow": ["ExistingRule"]],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: existing) {
                try? data.write(to: URL(fileURLWithPath: settingsPath))
            }
            saveToLocalSettings(input: makeInput(cwd: dir), rule: "NewRule")
            if let data = FileManager.default.contents(atPath: settingsPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                assertEq(json["customKey"] as? String, "customValue")
                if let perms = json["permissions"] as? [String: Any],
                   let allow = perms["allow"] as? [String] {
                    assertTrue(allow.contains("ExistingRule"))
                    assertTrue(allow.contains("NewRule"))
                }
            }
        }
    }
    test("localSettings: creates .claude directory") {
        withTempDir { dir in
            saveToLocalSettings(input: makeInput(cwd: dir), rule: "Test")
            assertTrue(FileManager.default.fileExists(atPath: "\(dir)/.claude"))
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - sessionFilePath Sanitization Tests (5)
// ═══════════════════════════════════════════════════════════════════

func testSessionFilePathSanitization() {
    test("sessionFilePath: normal ID unchanged") {
        let i = makeInput(session: "abc-123_test.session")
        assertContains(i.sessionFilePath ?? "", "abc-123_test.session")
    }
    test("sessionFilePath: path traversal sanitized") {
        let i = makeInput(session: "../../etc/passwd")
        let path = i.sessionFilePath ?? ""
        // Slashes must be stripped — the file should be directly in sessionDirectory
        let dir = (path as NSString).deletingLastPathComponent
        assertEq(dir, HookInput.sessionDirectory)
        // Must not contain the original traversal target
        assertNotContains(path, "/etc/passwd")
    }
    test("sessionFilePath: slashes replaced") {
        let i = makeInput(session: "foo/bar/baz")
        let path = i.sessionFilePath ?? ""
        // The sanitized path should end with the sanitized ID, not create subdirs
        let filename = (path as NSString).lastPathComponent
        assertNotContains(filename, "/")
    }
    test("sessionFilePath: spaces replaced") {
        let i = makeInput(session: "session with spaces")
        let path = i.sessionFilePath ?? ""
        assertNotContains(path.components(separatedBy: "/").last ?? "", " ")
    }
    test("sessionFilePath: empty still returns nil") {
        let i = makeInput(session: "")
        assertTrue(i.sessionFilePath == nil)
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - Session Directory Permissions Tests (1)
// ═══════════════════════════════════════════════════════════════════

func testSessionDirectoryPermissions() {
    test("saveSession: directory has restricted permissions") {
        let sid = testSessionId()
        defer { cleanupSession(sid) }
        let i = makeInput(session: sid)
        saveToSessionFile(input: i, entry: "TestTool")
        let attrs = try? FileManager.default.attributesOfItem(
            atPath: HookInput.sessionDirectory
        )
        let perms = (attrs?[.posixPermissions] as? Int) ?? 0
        // Group and other should have no permissions (0o077 mask = 0)
        assertEq(perms & 0o077, 0)
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - Main Entry Point
// ═══════════════════════════════════════════════════════════════════

@main
enum ApproveTests {
    static func main() {
        testBuildGist()
        testLastComponent()
        testSummarizeBashCommand()
        testAnsiColor()
        testParseAnsiCodes()
        testHighlightBash()
        testComputeLineDiff()
        testCollapseContext()
        testFindStartLine()
        testBuildContent()
        testBuildPermOptions()
        testComputeButtonRows()
        testProcessResult()
        testWriteHookResponse()
        testCheckSessionAutoApprove()
        testSaveToSessionFile()
        testSaveToLocalSettings()
        testSessionFilePathSanitization()
        testSessionDirectoryPermissions()

        exit(printSummary())
    }
}
