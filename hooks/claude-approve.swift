#!/usr/bin/env swift
//
//  claude-approve.swift
//  Claude Code Hook — PreToolUse Permission Dialog
//
//  A macOS native dialog that intercepts Claude Code tool requests and presents
//  the user with permission options matching Claude Code's built-in prompts.
//  Displays tool details with syntax highlighting, unified diffs, and session
//  identity for multi-session workflows.
//
//  ## Hook Protocol
//  - **Input:**  JSON on stdin — `tool_name`, `tool_input`, `cwd`, `session_id`
//  - **Output:** JSON on stdout — `permissionDecision` ("allow" / "deny") with reason
//
//  ## Features
//  - Tool-specific permission buttons matching Claude Code's native prompts
//  - Bash syntax highlighting with keyword/flag/string/pipe coloring
//  - Unified diff view (LCS-based) with line numbers for Edit operations
//  - Session auto-approve: remembers per-session tool approvals in /tmp
//  - Project-level persistence via .claude/settings.local.json
//  - Keyboard shortcuts: 1–3 for options, Enter = accept, Esc = reject
//  - Floating panel visible across all macOS Spaces
//
//  ## Build
//  ```
//  swiftc -framework AppKit -o claude-approve claude-approve.swift
//  ```
//

import AppKit
import Foundation

// MARK: - Models

/// Represents the parsed JSON input received from Claude Code's hook system.
struct HookInput {
    let toolName: String
    let toolInput: [String: Any]
    let cwd: String
    let sessionId: String

    /// Project directory name (last path component of `cwd`).
    var projectName: String { (cwd as NSString).lastPathComponent }

    /// Path to the session auto-approve file.
    var sessionFilePath: String { "/tmp/claude-hook-sessions/\(sessionId)" }
}

/// A permission option displayed as a button in the dialog.
struct PermOption {
    let label: String
    let resultKey: String
    let color: NSColor
}

/// Represents a single operation in a unified diff.
enum DiffOp {
    case context(String)
    case removal(String)
    case addition(String)
}

// MARK: - Theme

/// Visual theme constants for the dialog — dark mode color palette and typography.
enum Theme {
    // Background
    static let background      = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)
    static let codeBackground  = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 1.0)
    static let border          = NSColor(calibratedRed: 0.22, green: 0.22, blue: 0.26, alpha: 1.0)

    // Text
    static let textPrimary     = NSColor(calibratedWhite: 0.93, alpha: 1.0)
    static let textSecondary   = NSColor(calibratedWhite: 0.55, alpha: 1.0)
    static let codeText        = NSColor(calibratedRed: 0.78, green: 0.85, blue: 0.78, alpha: 1.0)
    static let filePathText    = NSColor(calibratedRed: 0.55, green: 0.75, blue: 1.0, alpha: 1.0)
    static let labelText       = NSColor(calibratedRed: 0.55, green: 0.60, blue: 0.70, alpha: 1.0)

    // Diff
    static let diffRemoved     = NSColor(calibratedRed: 1.0,  green: 0.35, blue: 0.35, alpha: 1.0)
    static let diffAdded       = NSColor(calibratedRed: 0.30, green: 0.90, blue: 0.45, alpha: 1.0)
    static let diffContext     = NSColor(calibratedWhite: 0.88, alpha: 1.0)
    static let diffGutter      = NSColor(calibratedWhite: 0.38, alpha: 1.0)
    static let diffEllipsis    = NSColor(calibratedRed: 0.40, green: 0.55, blue: 0.90, alpha: 1.0)

    // Buttons
    static let buttonAllow     = NSColor(calibratedRed: 0.18, green: 0.80, blue: 0.44, alpha: 1.0)
    static let buttonPersist   = NSColor(calibratedRed: 0.30, green: 0.56, blue: 1.0,  alpha: 1.0)
    static let buttonDeny      = NSColor(calibratedRed: 1.0,  green: 0.32, blue: 0.32, alpha: 1.0)

    // Tool tag pill colors (per tool type)
    static let toolTagColors: [String: NSColor] = [
        "Bash":      NSColor(calibratedRed: 0.18, green: 0.80, blue: 0.44, alpha: 1),
        "Edit":      NSColor(calibratedRed: 0.95, green: 0.68, blue: 0.25, alpha: 1),
        "Write":     NSColor(calibratedRed: 0.95, green: 0.68, blue: 0.25, alpha: 1),
        "Read":      NSColor(calibratedRed: 0.45, green: 0.72, blue: 1.0,  alpha: 1),
        "Task":      NSColor(calibratedRed: 0.72, green: 0.52, blue: 0.95, alpha: 1),
        "WebFetch":  NSColor(calibratedRed: 0.40, green: 0.85, blue: 0.85, alpha: 1),
        "WebSearch": NSColor(calibratedRed: 0.40, green: 0.85, blue: 0.85, alpha: 1),
        "Glob":      NSColor(calibratedRed: 0.65, green: 0.75, blue: 0.85, alpha: 1),
        "Grep":      NSColor(calibratedRed: 0.65, green: 0.75, blue: 0.85, alpha: 1),
    ]

    // Bash syntax highlighting
    static let shKeyword = NSColor(calibratedRed: 0.70, green: 0.50, blue: 0.90, alpha: 1)
    static let shString  = NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.55, alpha: 1)
    static let shFlag    = NSColor(calibratedRed: 0.55, green: 0.75, blue: 1.0,  alpha: 1)
    static let shPipe    = NSColor(calibratedRed: 0.90, green: 0.75, blue: 0.40, alpha: 1)
    static let shComment = NSColor(calibratedWhite: 0.45, alpha: 1)
    static let shCommand = NSColor(calibratedRed: 0.40, green: 0.85, blue: 0.95, alpha: 1)

    // Fonts
    static let mono       = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let monoBold   = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    static let labelFont  = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
    static let gutterFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let buttonFont = NSFont.systemFont(ofSize: 12.5, weight: .bold)

    /// Returns the tag color for a given tool name, with a neutral fallback.
    static func tagColor(for tool: String) -> NSColor {
        toolTagColors[tool] ?? NSColor(calibratedWhite: 0.65, alpha: 1)
    }
}

// MARK: - Layout

/// Layout constants for the dialog panel.
enum Layout {
    static let panelWidth: CGFloat = 580
    static let buttonHeight: CGFloat = 34
    static let buttonGap: CGFloat = 8
    static let buttonPadding: CGFloat = 20
    static let buttonMargin: CGFloat = 12
    static let maxButtonsPerRow = 2
    static let buttonCornerRadius: CGFloat = 7
    static let codeCornerRadius: CGFloat = 6
    static let tagCornerRadius: CGFloat = 5
    static let tagButtonHeight: CGFloat = 26
    static let minCodeBlockHeight: CGFloat = 36
    static let maxCodeBlockHeight: CGFloat = 400
    static let dialogTimeout: TimeInterval = 600

    /// Spacing breakdown for fixed chrome (everything except code block and buttons).
    /// top(14) + project(28) + path(18) + gap(10) + sep(1) + gap(10) + toolGist(26) + gap(8) + gap(10) + bottom(6)
    static let fixedChrome: CGFloat = 14 + 28 + 18 + 10 + 1 + 10 + 26 + 8 + 10 + 6
}

// MARK: - Input Parsing

/// Reads and parses the hook input JSON from stdin.
func parseHookInput() -> HookInput {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    return HookInput(
        toolName:  json["tool_name"]  as? String ?? "Tool",
        toolInput: json["tool_input"] as? [String: Any] ?? [:],
        cwd:       json["cwd"]        as? String ?? "",
        sessionId: json["session_id"] as? String ?? ""
    )
}

// MARK: - Session Management

/// Checks if the tool has been auto-approved for this session.
///
/// Session approvals are stored as newline-separated tool names in a temporary file.
/// Returns `true` if the tool is already approved, and writes the allow response to stdout.
func checkSessionAutoApprove(input: HookInput) -> Bool {
    guard let contents = try? String(contentsOfFile: input.sessionFilePath, encoding: .utf8),
          contents.components(separatedBy: "\n").contains(input.toolName) else {
        return false
    }
    writeHookResponse(
        decision: "allow",
        reason: "Auto-approved (\(input.toolName) allowed for session)"
    )
    return true
}

/// Appends a tool name to the session auto-approve file.
///
/// Future invocations for this tool will be automatically allowed without showing the dialog.
func saveToSessionFile(input: HookInput, entry: String) {
    let dir = "/tmp/claude-hook-sessions"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if let handle = FileHandle(forWritingAtPath: input.sessionFilePath) {
        handle.seekToEndOfFile()
        handle.write("\(entry)\n".data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(
            atPath: input.sessionFilePath,
            contents: "\(entry)\n".data(using: .utf8)
        )
    }
}

/// Adds a permission rule to the project's `.claude/settings.local.json`.
///
/// This persists the allow rule across sessions for the current project directory.
/// Rules follow Claude Code's format (e.g., `"Bash(echo *)"`, `"WebFetch(domain:example.com)"`).
func saveToLocalSettings(input: HookInput, rule: String) {
    let settingsDir = input.cwd + "/.claude"
    let settingsPath = settingsDir + "/settings.local.json"
    try? FileManager.default.createDirectory(atPath: settingsDir, withIntermediateDirectories: true)

    var json: [String: Any] = [:]
    if let data = FileManager.default.contents(atPath: settingsPath),
       let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        json = existing
    }

    var perms = json["permissions"] as? [String: Any] ?? [:]
    var allow = perms["allow"] as? [String] ?? []
    if !allow.contains(rule) { allow.append(rule) }
    perms["allow"] = allow
    json["permissions"] = perms

    if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: settingsPath))
    }
}

// MARK: - Hook Response Output

/// Writes the hook response JSON to stdout and exits.
func writeHookResponse(decision: String, reason: String) {
    let response: [String: Any] = ["hookSpecificOutput": [
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason,
    ]]
    FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: response))
}

// MARK: - Gist Generation

/// Builds a short one-line summary of the tool operation for the dialog header.
///
/// For Bash commands, extracts just the command names joined by shell operators
/// (e.g., `cd && swiftc` instead of the full command with arguments).
func buildGist(input: HookInput) -> String {
    switch input.toolName {
    case "Bash":
        let cmd = input.toolInput["command"] as? String ?? ""
        if let desc = input.toolInput["description"] as? String, !desc.isEmpty {
            return desc
        }
        return summarizeBashCommand(cmd)
    case "Edit":
        return "Edit \(lastComponent(input.toolInput["file_path"]))"
    case "Write":
        return "Write \(lastComponent(input.toolInput["file_path"]))"
    case "Read":
        return "Read \(lastComponent(input.toolInput["file_path"]))"
    case "NotebookEdit":
        let mode = input.toolInput["edit_mode"] as? String ?? "edit"
        return "\(mode.capitalized) cell in \(lastComponent(input.toolInput["notebook_path"]))"
    case "Task":
        return input.toolInput["description"] as? String ?? "Launch agent"
    case "WebFetch":
        let url = input.toolInput["url"] as? String ?? ""
        return "Fetch \(url.count > 60 ? String(url.prefix(57)) + "..." : url)"
    case "WebSearch":
        return "Search: \(input.toolInput["query"] as? String ?? "")"
    case "Glob":
        return "Find files: \(input.toolInput["pattern"] as? String ?? "")"
    case "Grep":
        return "Search code: \(input.toolInput["pattern"] as? String ?? "")"
    default:
        return input.toolName
    }
}

/// Extracts the last path component from an optional tool input value.
private func lastComponent(_ value: Any?) -> String {
    ((value as? String ?? "") as NSString).lastPathComponent
}

/// Summarizes a Bash command to just its command names joined by operators.
///
/// Example: `cd ~/.claude/hooks && swiftc -framework AppKit -o out file.swift` → `cd && swiftc`
private func summarizeBashCommand(_ cmd: String) -> String {
    let line = cmd.components(separatedBy: "\n").first ?? cmd
    let operators = ["&&", "||", "|", ";"]
    var summary = [String]()
    var remaining = line.trimmingCharacters(in: .whitespaces)

    while !remaining.isEmpty {
        var matched = false
        for op in operators {
            if let range = remaining.range(of: " \(op) ") {
                let segment = String(remaining[remaining.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let name = segment.components(separatedBy: .whitespaces).first ?? segment
                if !name.isEmpty { summary.append(name) }
                summary.append(op)
                remaining = String(remaining[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                matched = true
                break
            }
        }
        if !matched {
            let name = remaining.components(separatedBy: .whitespaces).first ?? remaining
            if !name.isEmpty { summary.append(name) }
            break
        }
    }
    return summary.joined(separator: " ")
}

// MARK: - Syntax Highlighting

/// Parses ANSI escape codes in a string and returns a colored attributed string.
///
/// Supports standard (30–37) and bright (90–97) foreground color codes, plus reset (0, 39).
func parseAnsiCodes(_ raw: String, defaultColor: NSColor = Theme.codeText) -> NSAttributedString {
    let result = NSMutableAttributedString()
    var currentColor = defaultColor
    let segments = raw.components(separatedBy: "\u{1b}[")

    for (index, segment) in segments.enumerated() {
        if index == 0 {
            result.append(styledCode(segment, color: currentColor))
            continue
        }
        guard let mIdx = segment.firstIndex(of: "m") else {
            result.append(styledCode(segment, color: currentColor))
            continue
        }
        let codeStr = String(segment[segment.startIndex..<mIdx])
        let text = String(segment[segment.index(after: mIdx)...])
        let codes = codeStr.components(separatedBy: ";").compactMap { Int($0) }

        for code in codes {
            currentColor = ansiColor(code: code, defaultColor: defaultColor) ?? currentColor
        }
        if !text.isEmpty {
            result.append(styledCode(text, color: currentColor))
        }
    }
    return result
}

/// Maps an ANSI color code to an NSColor, or `nil` if not recognized.
private func ansiColor(code: Int, defaultColor: NSColor) -> NSColor? {
    switch code {
    case 0:  return defaultColor
    case 30: return NSColor(calibratedWhite: 0.35, alpha: 1)
    case 31: return NSColor(calibratedRed: 1.0,  green: 0.40, blue: 0.40, alpha: 1)
    case 32: return NSColor(calibratedRed: 0.40, green: 0.90, blue: 0.50, alpha: 1)
    case 33: return NSColor(calibratedRed: 0.90, green: 0.80, blue: 0.35, alpha: 1)
    case 34: return NSColor(calibratedRed: 0.40, green: 0.60, blue: 1.0,  alpha: 1)
    case 35: return NSColor(calibratedRed: 0.75, green: 0.50, blue: 0.95, alpha: 1)
    case 36: return NSColor(calibratedRed: 0.40, green: 0.85, blue: 0.90, alpha: 1)
    case 37: return NSColor(calibratedWhite: 0.90, alpha: 1)
    case 39: return defaultColor
    case 90: return NSColor(calibratedWhite: 0.55, alpha: 1)
    case 91: return NSColor(calibratedRed: 1.0,  green: 0.55, blue: 0.55, alpha: 1)
    case 92: return NSColor(calibratedRed: 0.55, green: 1.0,  blue: 0.60, alpha: 1)
    case 93: return NSColor(calibratedRed: 1.0,  green: 0.95, blue: 0.55, alpha: 1)
    case 94: return NSColor(calibratedRed: 0.55, green: 0.75, blue: 1.0,  alpha: 1)
    case 95: return NSColor(calibratedRed: 0.90, green: 0.60, blue: 1.0,  alpha: 1)
    case 96: return NSColor(calibratedRed: 0.55, green: 0.95, blue: 1.0,  alpha: 1)
    case 97: return NSColor(calibratedWhite: 1.0, alpha: 1)
    default: return nil
    }
}

/// Creates a monospaced attributed string fragment with the given color.
private func styledCode(_ text: String, color: NSColor) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [.font: Theme.mono, .foregroundColor: color])
}

/// Shell keywords recognized by the Bash syntax highlighter.
private let bashKeywords: Set<String> = [
    "if", "then", "else", "elif", "fi", "for", "while", "do", "done",
    "case", "esac", "in", "function", "return", "exit", "export",
    "local", "set", "unset", "source", "eval",
]

/// Applies syntax highlighting to a Bash command string.
///
/// Colors: commands (cyan), keywords (purple), flags (blue), strings (green),
/// pipes/operators (amber), comments (gray).
func highlightBash(_ cmd: String) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let lines = cmd.components(separatedBy: "\n")

    for (lineIndex, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            result.append(styledCode(line, color: Theme.shComment))
        } else {
            highlightBashLine(line, into: result)
        }
        if lineIndex < lines.count - 1 {
            result.append(NSAttributedString(string: "\n", attributes: [.font: Theme.mono]))
        }
    }
    return result
}

/// Highlights a single line of Bash, appending tokens to the result.
private func highlightBashLine(_ line: String, into result: NSMutableAttributedString) {
    var idx = line.startIndex
    var isFirstWord = true

    while idx < line.endIndex {
        let ch = line[idx]

        if ch == "\"" || ch == "'" {
            // String literal
            var end = line.index(after: idx)
            while end < line.endIndex && line[end] != ch { end = line.index(after: end) }
            if end < line.endIndex { end = line.index(after: end) }
            result.append(styledCode(String(line[idx..<end]), color: Theme.shString))
            idx = end
            isFirstWord = false

        } else if ch == "|" || ch == ";" || ch == ">" || ch == "<" {
            // Pipe / redirect / separator
            result.append(styledCode(String(ch), color: Theme.shPipe))
            idx = line.index(after: idx)
            isFirstWord = true

        } else if ch == "&" && line.index(after: idx) < line.endIndex
                    && line[line.index(after: idx)] == "&" {
            // Logical AND
            result.append(styledCode("&&", color: Theme.shPipe))
            idx = line.index(idx, offsetBy: 2)
            isFirstWord = true

        } else if ch.isWhitespace {
            result.append(styledCode(String(ch), color: Theme.codeText))
            idx = line.index(after: idx)

        } else {
            // Word token
            var end = line.index(after: idx)
            let delimiters: Set<Character> = ["|", ";", "\"", "'", ">", "<"]
            while end < line.endIndex && !line[end].isWhitespace && !delimiters.contains(line[end]) {
                end = line.index(after: end)
            }
            let word = String(line[idx..<end])
            let color: NSColor
            if word.hasPrefix("-")          { color = Theme.shFlag }
            else if bashKeywords.contains(word) { color = Theme.shKeyword }
            else if isFirstWord             { color = Theme.shCommand }
            else                            { color = Theme.codeText }
            result.append(styledCode(word, color: color))
            idx = end
            isFirstWord = false
        }
    }
}

// MARK: - Diff Engine

/// Computes a line-level diff between two strings using the LCS (Longest Common Subsequence) algorithm.
///
/// Long runs of unchanged context (>5 lines) are collapsed with an ellipsis marker.
/// The output matches the style of a unified diff: context, removals (-), and additions (+).
func computeLineDiff(old oldStr: String, new newStr: String) -> [DiffOp] {
    let oldLines = oldStr.components(separatedBy: "\n")
    let newLines = newStr.components(separatedBy: "\n")
    let m = oldLines.count
    let n = newLines.count

    // Build LCS dynamic programming table
    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
    for i in 1...m {
        for j in 1...n {
            dp[i][j] = oldLines[i - 1] == newLines[j - 1]
                ? dp[i - 1][j - 1] + 1
                : max(dp[i - 1][j], dp[i][j - 1])
        }
    }

    // Backtrack to produce diff operations
    var ops = [DiffOp]()
    var i = m, j = n
    while i > 0 || j > 0 {
        if i > 0 && j > 0 && oldLines[i - 1] == newLines[j - 1] {
            ops.append(.context(oldLines[i - 1]))
            i -= 1; j -= 1
        } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
            ops.append(.addition(newLines[j - 1]))
            j -= 1
        } else {
            ops.append(.removal(oldLines[i - 1]))
            i -= 1
        }
    }
    ops.reverse()

    return collapseContext(ops)
}

/// Collapses long runs of unchanged context lines (>5) into an ellipsis marker.
private func collapseContext(_ ops: [DiffOp]) -> [DiffOp] {
    var result = [DiffOp]()
    var contextRun = [String]()

    func flushContext() {
        if contextRun.count <= 5 {
            for line in contextRun { result.append(.context(line)) }
        } else {
            for line in contextRun.prefix(3) { result.append(.context(line)) }
            result.append(.context("\u{2026}"))  // Ellipsis marker
            for line in contextRun.suffix(2) { result.append(.context(line)) }
        }
        contextRun.removeAll()
    }

    for op in ops {
        if case .context(let line) = op {
            contextRun.append(line)
        } else {
            flushContext()
            result.append(op)
        }
    }
    flushContext()
    return result
}

/// Finds the 1-based starting line number of `oldString` within a file.
///
/// Performs an exact multi-line match against the file contents. Returns 1 if not found.
func findStartLine(filePath: String, oldString: String) -> Int {
    guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return 1 }
    let fileLines = content.components(separatedBy: "\n")
    let searchLines = oldString.components(separatedBy: "\n")
    guard let firstSearchLine = searchLines.first else { return 1 }

    for (index, line) in fileLines.enumerated() {
        if line == firstSearchLine {
            let remaining = fileLines[index...]
            if remaining.count >= searchLines.count {
                let slice = Array(remaining.prefix(searchLines.count))
                if slice == searchLines { return index + 1 }
            }
        }
    }
    return 1
}

// MARK: - Content Rendering

/// Builds the detailed content attributed string for the code block area.
///
/// Each tool type has custom rendering: Bash gets syntax highlighting, Edit gets a unified
/// diff with line numbers, Write shows a preview, and others show relevant metadata.
func buildContent(input: HookInput) -> NSAttributedString {
    let result = NSMutableAttributedString()

    /// Appends a label line (dim monospaced text).
    func appendLabel(_ text: String) {
        result.append(NSAttributedString(
            string: text + "\n",
            attributes: [.font: Theme.labelFont, .foregroundColor: Theme.labelText]
        ))
    }

    /// Appends a file path line (bright blue monospaced text).
    func appendFilePath(_ text: String) {
        result.append(NSAttributedString(
            string: text + "\n",
            attributes: [.font: Theme.monoBold, .foregroundColor: Theme.filePathText]
        ))
    }

    /// Appends a code line with optional background color.
    func appendCode(_ text: String, color: NSColor = Theme.codeText, background: NSColor? = nil) {
        var attrs: [NSAttributedString.Key: Any] = [.font: Theme.mono, .foregroundColor: color]
        if let bg = background { attrs[.backgroundColor] = bg }
        result.append(NSAttributedString(string: text + "\n", attributes: attrs))
    }

    /// Appends a multi-line code block.
    func appendBlock(_ text: String, color: NSColor = Theme.codeText) {
        for line in text.components(separatedBy: "\n") { appendCode(line, color: color) }
    }

    /// Appends a blank line.
    func appendNewline() {
        result.append(NSAttributedString(string: "\n"))
    }

    switch input.toolName {
    case "Bash":
        if let command = input.toolInput["command"] as? String {
            result.append(highlightBash(command))
        }

    case "Edit":
        let filePath = input.toolInput["file_path"] as? String ?? ""
        if !filePath.isEmpty { appendFilePath(filePath); appendNewline() }

        let oldStr = input.toolInput["old_string"] as? String ?? ""
        let newStr = input.toolInput["new_string"] as? String ?? ""
        let diffOps = computeLineDiff(old: oldStr, new: newStr)
        let startLine = findStartLine(filePath: filePath, oldString: oldStr)
        renderUnifiedDiff(diffOps, startLine: startLine, oldStr: oldStr, newStr: newStr, into: result)

    case "Write":
        if let path = input.toolInput["file_path"] as? String { appendFilePath(path); appendNewline() }
        if let content = input.toolInput["content"] as? String {
            let lines = content.components(separatedBy: "\n")
            for line in lines.prefix(50) { appendCode(line) }
            if lines.count > 50 { appendLabel("... (\(lines.count - 50) more lines)") }
        }

    case "Read":
        if let path = input.toolInput["file_path"] as? String { appendFilePath(path) }
        if let offset = input.toolInput["offset"] as? Int { appendLabel("offset: \(offset)") }
        if let limit = input.toolInput["limit"] as? Int { appendLabel("limit: \(limit)") }

    case "NotebookEdit":
        if let path = input.toolInput["notebook_path"] as? String { appendFilePath(path) }
        if let mode = input.toolInput["edit_mode"] as? String { appendLabel("mode: \(mode)") }
        appendNewline()
        if let source = input.toolInput["new_source"] as? String { appendBlock(source) }

    case "Task":
        if let desc = input.toolInput["description"] as? String { appendLabel(desc) }
        if let agent = input.toolInput["subagent_type"] as? String { appendLabel("agent: \(agent)") }
        appendNewline()
        if let prompt = input.toolInput["prompt"] as? String { appendBlock(prompt) }

    case "WebFetch":
        if let url = input.toolInput["url"] as? String { appendFilePath(url); appendNewline() }
        if let prompt = input.toolInput["prompt"] as? String { appendBlock(prompt) }

    case "WebSearch":
        if let query = input.toolInput["query"] as? String { appendBlock(query) }

    case "Glob":
        if let pattern = input.toolInput["pattern"] as? String { appendCode(pattern) }
        if let path = input.toolInput["path"] as? String { appendLabel("in: \(path)") }

    case "Grep":
        if let pattern = input.toolInput["pattern"] as? String { appendCode(pattern) }
        if let path = input.toolInput["path"] as? String { appendLabel("in: \(path)") }
        if let glob = input.toolInput["glob"] as? String { appendLabel("glob: \(glob)") }

    default:
        if let data = try? JSONSerialization.data(withJSONObject: input.toolInput, options: .prettyPrinted),
           let jsonStr = String(data: data, encoding: .utf8) {
            appendBlock(jsonStr)
        }
    }

    // Trim trailing newlines to prevent extra blank line at bottom of code block
    while result.length > 0 {
        let last = result.attributedSubstring(from: NSRange(location: result.length - 1, length: 1)).string
        if last == "\n" {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        } else {
            break
        }
    }

    return result
}

/// Renders a unified diff into an attributed string with line numbers and color coding.
private func renderUnifiedDiff(
    _ ops: [DiffOp],
    startLine: Int,
    oldStr: String,
    newStr: String,
    into result: NSMutableAttributedString
) {
    let oldCount = oldStr.components(separatedBy: "\n").count
    let newCount = newStr.components(separatedBy: "\n").count
    let maxLineNo = startLine + max(oldCount, newCount) + 5
    let gutterWidth = max(3, String(maxLineNo).count)
    var lineNo = startLine

    for op in ops {
        let line = NSMutableAttributedString()
        switch op {
        case .removal(let text):
            appendDiffLine(into: line, lineNo: lineNo, gutterWidth: gutterWidth,
                           prefix: "- ", text: text, color: Theme.diffRemoved)
            lineNo += 1
        case .addition(let text):
            appendDiffLine(into: line, lineNo: lineNo, gutterWidth: gutterWidth,
                           prefix: "+ ", text: text, color: Theme.diffAdded)
            lineNo += 1
        case .context(let text):
            if text == "\u{2026}" {
                let padding = String(repeating: " ", count: gutterWidth)
                line.append(NSAttributedString(
                    string: "\(padding)   ...\n",
                    attributes: [.font: Theme.mono, .foregroundColor: Theme.diffEllipsis]
                ))
            } else {
                appendDiffLine(into: line, lineNo: lineNo, gutterWidth: gutterWidth,
                               prefix: "  ", text: text, color: Theme.diffContext)
                lineNo += 1
            }
        }
        result.append(line)
    }
}

/// Appends a single diff line with gutter number, prefix (+/-/space), and colored text.
private func appendDiffLine(
    into line: NSMutableAttributedString,
    lineNo: Int,
    gutterWidth: Int,
    prefix: String,
    text: String,
    color: NSColor
) {
    let num = String(format: "%\(gutterWidth)d", lineNo)
    line.append(NSAttributedString(
        string: "\(num) ",
        attributes: [.font: Theme.gutterFont, .foregroundColor: Theme.diffGutter]
    ))
    line.append(NSAttributedString(
        string: prefix,
        attributes: [.font: Theme.mono, .foregroundColor: color]
    ))
    line.append(NSAttributedString(
        string: text + "\n",
        attributes: [.font: Theme.mono, .foregroundColor: color]
    ))
}

// MARK: - Permission Options

/// Generates tool-specific permission options that match Claude Code's native prompts.
///
/// Each tool type has three options: allow once, allow persistently (varies by tool), and deny.
/// The persistent option text and behavior differs per tool:
/// - **Bash:** Adds a command-prefix rule to project settings
/// - **Edit/Write:** Allows all edits for the current session
/// - **WebFetch:** Adds a domain allow rule to project settings
/// - **WebSearch:** Adds a tool allow rule to project settings
/// - **Default:** Allows the tool for the current session
func buildPermOptions(input: HookInput) -> [PermOption] {
    switch input.toolName {
    case "Bash":
        let cmd = input.toolInput["command"] as? String ?? ""
        let firstWord = cmd.components(separatedBy: .whitespaces).first ?? cmd
        let prefix = firstWord.isEmpty ? "similar" : firstWord
        return [
            PermOption(label: "Yes", resultKey: "allow_once", color: Theme.buttonAllow),
            PermOption(
                label: "Yes, and don't ask again for \(prefix) commands in \(input.projectName)",
                resultKey: "dont_ask_bash",
                color: Theme.buttonPersist
            ),
            PermOption(label: "No, and tell Claude what to do differently", resultKey: "deny", color: Theme.buttonDeny),
        ]

    case "Edit", "Write":
        return [
            PermOption(label: "Yes", resultKey: "allow_once", color: Theme.buttonAllow),
            PermOption(label: "Yes, allow all edits during this session", resultKey: "allow_edits_session", color: Theme.buttonPersist),
            PermOption(label: "No, and tell Claude what to do differently", resultKey: "deny", color: Theme.buttonDeny),
        ]

    case "WebFetch":
        let urlStr = input.toolInput["url"] as? String ?? ""
        let domain = URL(string: urlStr)?.host ?? urlStr
        return [
            PermOption(label: "Yes", resultKey: "allow_once", color: Theme.buttonAllow),
            PermOption(label: "Yes, and don't ask again for \(domain)", resultKey: "dont_ask_domain", color: Theme.buttonPersist),
            PermOption(label: "No, and tell Claude what to do differently", resultKey: "deny", color: Theme.buttonDeny),
        ]

    case "WebSearch":
        return [
            PermOption(label: "Yes", resultKey: "allow_once", color: Theme.buttonAllow),
            PermOption(label: "Yes, and don't ask again for WebSearch", resultKey: "dont_ask_tool", color: Theme.buttonPersist),
            PermOption(label: "No, and tell Claude what to do differently", resultKey: "deny", color: Theme.buttonDeny),
        ]

    default:
        return [
            PermOption(label: "Yes", resultKey: "allow_once", color: Theme.buttonAllow),
            PermOption(label: "Yes, during this session", resultKey: "allow_session", color: Theme.buttonPersist),
            PermOption(label: "No, and tell Claude what to do differently", resultKey: "deny", color: Theme.buttonDeny),
        ]
    }
}

// MARK: - Button Layout

/// Packs buttons into rows with a maximum of `Layout.maxButtonsPerRow` per row.
///
/// Uses a greedy algorithm: adds buttons left-to-right until the row is full (by count or width),
/// then starts a new row. Buttons within a row are stretched to fill the available width equally.
func computeButtonRows(options: [PermOption]) -> (rows: [[Int]], totalHeight: CGFloat) {
    let availableWidth = Layout.panelWidth - Layout.buttonMargin * 2
    let naturalWidths = options.map { opt in
        (opt.label as NSString).size(withAttributes: [.font: Theme.buttonFont]).width + Layout.buttonPadding * 2
    }

    var rows: [[Int]] = [[]]
    var currentRowWidth: CGFloat = 0

    for i in 0..<options.count {
        let needed = naturalWidths[i] + (rows[rows.count - 1].isEmpty ? 0 : Layout.buttonGap)
        let rowFull = rows[rows.count - 1].count >= Layout.maxButtonsPerRow
        let widthExceeded = !rows[rows.count - 1].isEmpty && currentRowWidth + needed > availableWidth

        if rowFull || widthExceeded {
            rows.append([i])
            currentRowWidth = naturalWidths[i]
        } else {
            rows[rows.count - 1].append(i)
            currentRowWidth += needed
        }
    }

    let numRows = rows.count
    let totalHeight = CGFloat(numRows) * Layout.buttonHeight
        + CGFloat(max(0, numRows - 1)) * Layout.buttonGap + 12

    return (rows, totalHeight)
}

// MARK: - Content Measurement

/// Measures the natural height of an attributed string when rendered at the given width.
func measureContentHeight(_ content: NSAttributedString, width: CGFloat) -> CGFloat {
    let textStorage = NSTextStorage(attributedString: content)
    let layoutManager = NSLayoutManager()
    textStorage.addLayoutManager(layoutManager)
    let textContainer = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
    textContainer.widthTracksTextView = true
    layoutManager.addTextContainer(textContainer)
    layoutManager.ensureLayout(for: textContainer)
    return layoutManager.usedRect(for: textContainer).height + 24
}

// MARK: - Dialog Construction

/// Builds and runs the permission dialog, returning the user's selected result key.
///
/// The dialog is a floating `NSPanel` visible across all macOS Spaces with:
/// - Session identity header (project name + full path)
/// - Tool type tag pill + one-line gist summary
/// - Scrollable code block with tool-specific content
/// - Permission buttons in rows (max 2 per row)
/// - Keyboard shortcuts (1–3, Enter, Esc)
func showPermissionDialog(
    input: HookInput,
    options: [PermOption],
    content: NSAttributedString,
    gist: String,
    buttonRows: [[Int]],
    optionsHeight: CGFloat
) -> String {
    var dialogResult = "deny"
    let hasContent = content.length > 0

    // Calculate code block height
    let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
    let maxContentHeight = min(Layout.maxCodeBlockHeight, screenHeight * 0.5)
    let naturalHeight = hasContent ? measureContentHeight(content, width: Layout.panelWidth - 56) : 0
    let codeBlockHeight = hasContent ? max(Layout.minCodeBlockHeight, min(naturalHeight, maxContentHeight)) : CGFloat(0)

    // Total panel height
    let panelHeight = Layout.fixedChrome + codeBlockHeight + optionsHeight

    // --- Create panel ---
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: Layout.panelWidth, height: panelHeight),
        styleMask: [.titled, .closable, .nonactivatingPanel],
        backing: .buffered, defer: false
    )
    panel.title = "Claude Code"
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isMovableByWindowBackground = true
    panel.backgroundColor = Theme.background
    panel.titleVisibility = .visible
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true

    // Center on screen
    if let screen = NSScreen.main {
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - Layout.panelWidth / 2,
                                     y: frame.midY - panelHeight / 2))
    } else {
        panel.center()
    }

    // --- Content view ---
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: Layout.panelWidth, height: panelHeight))
    contentView.wantsLayer = true
    contentView.layer?.backgroundColor = Theme.background.cgColor
    panel.contentView = contentView

    var yPos = panelHeight - 14

    // --- Header: project name ---
    yPos -= 28
    let projectLabel = NSTextField(labelWithString: input.projectName)
    projectLabel.font = NSFont.systemFont(ofSize: 20, weight: .bold)
    projectLabel.textColor = Theme.textPrimary
    projectLabel.frame = NSRect(x: 16, y: yPos, width: Layout.panelWidth - 32, height: 28)
    projectLabel.lineBreakMode = .byTruncatingTail
    contentView.addSubview(projectLabel)

    // --- Header: full path ---
    yPos -= 18
    let pathLabel = NSTextField(labelWithString: input.cwd)
    pathLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
    pathLabel.textColor = Theme.textSecondary
    pathLabel.frame = NSRect(x: 16, y: yPos, width: Layout.panelWidth - 32, height: 16)
    pathLabel.lineBreakMode = .byTruncatingMiddle
    contentView.addSubview(pathLabel)

    // --- Separator ---
    yPos -= 10
    let separator = NSBox(frame: NSRect(x: 12, y: yPos, width: Layout.panelWidth - 24, height: 1))
    separator.boxType = .separator
    contentView.addSubview(separator)

    // --- Tool tag pill + gist ---
    yPos -= 10
    yPos -= 26
    let tagColor = Theme.tagColor(for: input.toolName)
    let tagFont = NSFont.systemFont(ofSize: 13, weight: .bold)
    let tagTextWidth = (input.toolName as NSString).size(withAttributes: [.font: tagFont]).width
    let tagWidth = tagTextWidth + 20

    let tagPill = NSButton(frame: NSRect(x: 16, y: yPos, width: tagWidth, height: Layout.tagButtonHeight))
    tagPill.title = input.toolName
    tagPill.bezelStyle = .rounded
    tagPill.isBordered = false
    tagPill.wantsLayer = true
    tagPill.layer?.cornerRadius = Layout.tagCornerRadius
    tagPill.layer?.backgroundColor = tagColor.withAlphaComponent(0.18).cgColor
    tagPill.font = tagFont
    tagPill.contentTintColor = tagColor
    tagPill.focusRingType = .none
    tagPill.refusesFirstResponder = true
    contentView.addSubview(tagPill)

    let gistLabel = NSTextField(labelWithString: gist)
    gistLabel.font = NSFont.systemFont(ofSize: 15, weight: .bold)
    gistLabel.textColor = Theme.textPrimary
    gistLabel.sizeToFit()
    let gistNaturalHeight = gistLabel.frame.height
    gistLabel.frame = NSRect(
        x: 16 + tagWidth + 10,
        y: yPos + (26 - gistNaturalHeight) / 2,
        width: Layout.panelWidth - 42 - tagWidth,
        height: gistNaturalHeight
    )
    gistLabel.lineBreakMode = .byTruncatingTail
    contentView.addSubview(gistLabel)

    // --- Code block ---
    yPos -= hasContent ? 8 : 0
    let codeBlockBottom = yPos - codeBlockHeight

    if hasContent {
        let codeContainer = NSView(frame: NSRect(
            x: 12, y: codeBlockBottom,
            width: Layout.panelWidth - 24, height: codeBlockHeight
        ))
        codeContainer.wantsLayer = true
        codeContainer.layer?.backgroundColor = Theme.codeBackground.cgColor
        codeContainer.layer?.cornerRadius = Layout.codeCornerRadius
        codeContainer.layer?.borderWidth = 1
        codeContainer.layer?.borderColor = Theme.border.cgColor
        contentView.addSubview(codeContainer)

        let scrollView = NSScrollView(frame: NSRect(
            x: 1, y: 1,
            width: codeContainer.frame.width - 2, height: codeContainer.frame.height - 2
        ))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textStorage = NSTextStorage(attributedString: content)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(
            width: scrollView.frame.width - 22, height: .greatestFiniteMagnitude
        ))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: scrollView.frame.width, height: scrollView.frame.height),
            textContainer: textContainer
        )
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textStorage?.setAttributedString(content)
        layoutManager.ensureLayout(for: textContainer)

        let textHeight = layoutManager.usedRect(for: textContainer).height
        let verticalPadding = max(8, (scrollView.frame.height - textHeight) / 2)
        textView.textContainerInset = NSSize(width: 8, height: verticalPadding)
        textView.autoresizingMask = [.width]
        textView.frame.size.height = max(textHeight + verticalPadding * 2, scrollView.frame.height)

        scrollView.documentView = textView
        codeContainer.addSubview(scrollView)
    }

    // --- Permission buttons ---
    class ButtonHandler: NSObject {
        var options: [PermOption]
        var result: UnsafeMutablePointer<String>
        init(options: [PermOption], result: UnsafeMutablePointer<String>) {
            self.options = options
            self.result = result
        }
        @objc func clicked(_ sender: NSButton) {
            result.pointee = options[sender.tag].resultKey
            NSApp.stopModal()
        }
    }

    let handler = ButtonHandler(
        options: options,
        result: UnsafeMutablePointer<String>.allocate(capacity: 1)
    )
    handler.result.initialize(to: "deny")

    let availableWidth = Layout.panelWidth - Layout.buttonMargin * 2
    for (rowIndex, row) in buttonRows.enumerated() {
        let rowY = codeBlockBottom - 10 - Layout.buttonHeight - CGFloat(rowIndex) * (Layout.buttonHeight + Layout.buttonGap)
        let totalGaps = Layout.buttonGap * CGFloat(max(0, row.count - 1))
        let buttonWidth = (availableWidth - totalGaps) / CGFloat(row.count)

        for (col, optionIndex) in row.enumerated() {
            let buttonX = Layout.buttonMargin + CGFloat(col) * (buttonWidth + Layout.buttonGap)
            let option = options[optionIndex]

            let button = NSButton(frame: NSRect(x: buttonX, y: rowY, width: buttonWidth, height: Layout.buttonHeight))
            button.title = option.label
            button.alignment = .center
            button.bezelStyle = .rounded
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = Layout.buttonCornerRadius
            button.layer?.backgroundColor = option.color.withAlphaComponent(0.18).cgColor
            button.contentTintColor = option.color
            button.font = Theme.buttonFont
            button.tag = optionIndex
            button.target = handler
            button.action = #selector(ButtonHandler.clicked(_:))
            contentView.addSubview(button)

            if optionIndex == 0 {
                panel.defaultButtonCell = button.cell as? NSButtonCell
            }
        }
    }

    // --- Keyboard shortcuts ---
    let keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        let key = event.charactersIgnoringModifiers ?? ""
        if let num = Int(key), num >= 1, num <= options.count {
            handler.result.pointee = options[num - 1].resultKey
            NSApp.stopModal()
            return nil
        }
        if key == "\r" {
            handler.result.pointee = options[0].resultKey
            NSApp.stopModal()
            return nil
        }
        if key == "\u{1b}" {
            handler.result.pointee = "deny"
            NSApp.stopModal()
            return nil
        }
        return event
    }

    // --- Timeout ---
    DispatchQueue.main.asyncAfter(deadline: .now() + Layout.dialogTimeout) {
        handler.result.pointee = "deny"
        NSApp.stopModal()
    }

    // --- Show dialog ---
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    NSApp.runModal(for: panel)
    panel.orderOut(nil)

    if let monitor = keyboardMonitor {
        NSEvent.removeMonitor(monitor)
    }

    dialogResult = handler.result.pointee
    handler.result.deallocate()
    return dialogResult
}

// MARK: - Result Processing

/// Processes the dialog result and persists the user's approval choice.
///
/// Returns the hook decision ("allow"/"deny") and a human-readable reason string.
func processResult(resultKey: String, input: HookInput) -> (decision: String, reason: String) {
    switch resultKey {
    case "allow_once":
        return ("allow", "Allowed once via dialog")

    case "allow_session":
        saveToSessionFile(input: input, entry: input.toolName)
        return ("allow", "Allowed \(input.toolName) for this session")

    case "allow_edits_session":
        saveToSessionFile(input: input, entry: "Edit")
        saveToSessionFile(input: input, entry: "Write")
        return ("allow", "Allowed all edits for this session")

    case "dont_ask_bash":
        let cmd = input.toolInput["command"] as? String ?? ""
        let prefix = cmd.components(separatedBy: .whitespaces).first ?? ""
        let rule = prefix.isEmpty ? "Bash(*)" : "Bash(\(prefix) *)"
        saveToLocalSettings(input: input, rule: rule)
        return ("allow", "Allowed \(rule) for project")

    case "dont_ask_domain":
        let urlStr = input.toolInput["url"] as? String ?? ""
        let domain = URL(string: urlStr)?.host ?? ""
        let rule = domain.isEmpty ? "WebFetch" : "WebFetch(domain:\(domain))"
        saveToLocalSettings(input: input, rule: rule)
        return ("allow", "Allowed \(rule)")

    case "dont_ask_tool":
        saveToLocalSettings(input: input, rule: input.toolName)
        return ("allow", "Allowed \(input.toolName) for project")

    default:
        return ("deny", "Rejected via dialog")
    }
}

// MARK: - Main Entry Point

/// Main execution flow:
/// 1. Parse hook input from stdin
/// 2. Check session auto-approve (exit early if already approved)
/// 3. Initialize app, play notification sound
/// 4. Build dialog content and show the permission dialog
/// 5. Process the result and write the hook response to stdout

let input = parseHookInput()

// Fast path: skip dialog if tool is already approved for this session
if checkSessionAutoApprove(input: input) {
    exit(0)
}

// Initialize headless NSApplication (no Dock icon)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
NSSound(named: "Funk")?.play()

// Build dialog data
let permOptions = buildPermOptions(input: input)
let contentAttr = buildContent(input: input)
let gist = buildGist(input: input)
let (buttonRows, optionsHeight) = computeButtonRows(options: permOptions)

// Show dialog and get user's choice
let resultKey = showPermissionDialog(
    input: input,
    options: permOptions,
    content: contentAttr,
    gist: gist,
    buttonRows: buttonRows,
    optionsHeight: optionsHeight
)

// Process result: persist approvals and write response
let (decision, reason) = processResult(resultKey: resultKey, input: input)
writeHookResponse(decision: decision, reason: reason)
exit(0)
