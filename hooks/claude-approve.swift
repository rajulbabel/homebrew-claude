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

    /// Directory for session auto-approve files.
    static let sessionDirectory = "/tmp/claude-hook-sessions"

    /// Project directory name (last path component of `cwd`).
    var projectName: String { (cwd as NSString).lastPathComponent }

    /// Path to the session auto-approve file, or `nil` if `sessionId` is empty.
    var sessionFilePath: String? {
        sessionId.isEmpty ? nil : "\(HookInput.sessionDirectory)/\(sessionId)"
    }
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
    static let buttonRestAlpha: CGFloat = 0.18
    static let buttonPressAlpha: CGFloat = 0.55

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
    // Panel
    static let panelWidth: CGFloat = 580
    static let panelMargin: CGFloat = 16
    static let panelInset: CGFloat = 12
    static let panelTopPadding: CGFloat = 14
    static let panelBottomPadding: CGFloat = 6
    static let fallbackScreenHeight: CGFloat = 800
    static let maxScreenFraction: CGFloat = 0.5

    // Header
    static let projectFontSize: CGFloat = 20
    static let projectHeight: CGFloat = 28
    static let pathFontSize: CGFloat = 12
    static let pathHeight: CGFloat = 18
    static let pathLineHeight: CGFloat = 16

    // Separator / spacing
    static let separatorHeight: CGFloat = 1
    static let sectionGap: CGFloat = 10
    static let codeBlockGap: CGFloat = 8
    static let tagGistGap: CGFloat = 10

    // Tool tag
    static let tagCornerRadius: CGFloat = 5
    static let tagButtonHeight: CGFloat = 26
    static let tagFontSize: CGFloat = 13
    static let tagTextPadding: CGFloat = 20

    // Gist
    static let gistFontSize: CGFloat = 15
    static let gistTrailingPadding: CGFloat = 42

    // Code block
    static let codeCornerRadius: CGFloat = 6
    static let codeBorderWidth: CGFloat = 1
    static let codeTextInset: CGFloat = 8
    static let codeScrollerWidth: CGFloat = 22
    static let codeContentInset: CGFloat = 56
    static let contentMeasurePadding: CGFloat = 24
    static let minCodeBlockHeight: CGFloat = 36
    static let maxCodeBlockHeight: CGFloat = 400
    static let minVerticalPadding: CGFloat = 8

    // Buttons
    static let buttonHeight: CGFloat = 34
    static let buttonGap: CGFloat = 8
    static let buttonPadding: CGFloat = 20
    static let buttonMargin: CGFloat = 12
    static let maxButtonsPerRow = 2
    static let buttonCornerRadius: CGFloat = 7
    static let buttonRowsBottomPadding: CGFloat = 12
    static let buttonTopGap: CGFloat = 10

    // Timing
    static let dialogTimeout: TimeInterval = 600
    static let pressAnimationDelay: TimeInterval = 0.12

    // Diff
    static let maxDiffLines = 500
    static let contextCollapseThreshold = 5
    static let contextPrefixLines = 3
    static let contextSuffixLines = 2
    static let minGutterWidth = 3
    static let gutterPadding = 5

    // Content limits
    static let maxGistUrlLength = 60
    static let gistUrlTruncLength = 57
    static let writePreviewLines = 50

    /// Spacing breakdown for fixed chrome (everything except code block and buttons).
    static let fixedChrome: CGFloat = panelTopPadding + projectHeight + pathHeight
        + sectionGap + separatorHeight + sectionGap + tagButtonHeight + codeBlockGap
        + sectionGap + panelBottomPadding
}

// MARK: - Input Parsing

/// Reads and parses the hook input JSON from stdin.
///
/// - Returns: A populated `HookInput` with tool name, input parameters, working directory,
///   and session ID. Missing fields default to empty strings or an empty dictionary.
private func parseHookInput() -> HookInput {
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
/// If the tool is already approved, writes the allow response to stdout.
///
/// - Parameter input: The parsed hook input containing session and tool info.
/// - Returns: `true` if the tool was auto-approved (response already written), `false` otherwise.
private func checkSessionAutoApprove(input: HookInput) -> Bool {
    guard let path = input.sessionFilePath,
          let contents = try? String(contentsOfFile: path, encoding: .utf8),
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
/// Uses `O_APPEND` for atomic writes safe against concurrent processes.
///
/// - Parameters:
///   - input: The parsed hook input containing the session file path.
///   - entry: The tool name to add to the session's approved list.
private func saveToSessionFile(input: HookInput, entry: String) {
    guard let path = input.sessionFilePath else { return }
    try? FileManager.default.createDirectory(
        atPath: HookInput.sessionDirectory, withIntermediateDirectories: true
    )
    guard let data = "\(entry)\n".data(using: .utf8) else { return }
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    if fd >= 0 {
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress!, data.count) }
        close(fd)
    }
}

/// Adds a permission rule to the project's `.claude/settings.local.json`.
///
/// This persists the allow rule across sessions for the current project directory.
/// Rules follow Claude Code's format (e.g., `"Bash(echo *)"`, `"WebFetch(domain:example.com)"`).
///
/// - Parameters:
///   - input: The parsed hook input containing the project working directory.
///   - rule: The permission rule string to add (e.g., `"Bash(git *)"`, `"WebFetch"`).
private func saveToLocalSettings(input: HookInput, rule: String) {
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

/// Writes the hook response JSON to stdout.
///
/// Falls back to a hardcoded deny JSON string if serialization fails.
///
/// - Parameters:
///   - decision: The permission decision — `"allow"` or `"deny"`.
///   - reason: A human-readable reason string explaining the decision.
private func writeHookResponse(decision: String, reason: String) {
    let response: [String: Any] = ["hookSpecificOutput": [
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason,
    ]]
    if let data = try? JSONSerialization.data(withJSONObject: response) {
        FileHandle.standardOutput.write(data)
    } else {
        let fallback = """
        {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Internal error: failed to serialize response"}}
        """
        FileHandle.standardOutput.write(fallback.data(using: .utf8)!)
    }
}

// MARK: - Gist Generation

/// Builds a short one-line summary of the tool operation for the dialog header.
///
/// For Bash commands, extracts just the command names joined by shell operators
/// (e.g., `cd && swiftc` instead of the full command with arguments).
///
/// - Parameter input: The parsed hook input containing the tool name and parameters.
/// - Returns: A concise human-readable summary of the operation.
private func buildGist(input: HookInput) -> String {
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
        return "Fetch \(url.count > Layout.maxGistUrlLength ? String(url.prefix(Layout.gistUrlTruncLength)) + "..." : url)"
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
///
/// - Parameters:
///   - raw: The raw string potentially containing ANSI escape sequences.
///   - defaultColor: The base text color used when no ANSI code is active.
/// - Returns: An `NSAttributedString` with monospaced font and ANSI-derived colors.
private func parseAnsiCodes(_ raw: String, defaultColor: NSColor = Theme.codeText) -> NSAttributedString {
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
///
/// - Parameter cmd: The raw Bash command string to highlight.
/// - Returns: An `NSAttributedString` with per-token syntax coloring.
private func highlightBash(_ cmd: String) -> NSAttributedString {
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
/// Long runs of unchanged context lines are collapsed with an ellipsis marker.
/// The output matches the style of a unified diff: context, removals (-), and additions (+).
/// If either input exceeds `Layout.maxDiffLines`, returns a simple removal/addition pair instead
/// of computing the full LCS to avoid excessive memory usage.
///
/// - Parameters:
///   - oldStr: The original text (before the edit).
///   - newStr: The replacement text (after the edit).
/// - Returns: An array of `DiffOp` values representing context, removals, and additions.
private func computeLineDiff(old oldStr: String, new newStr: String) -> [DiffOp] {
    let oldLines = oldStr.components(separatedBy: "\n")
    let newLines = newStr.components(separatedBy: "\n")
    let m = oldLines.count
    let n = newLines.count

    // Guard against excessive memory usage for very large diffs
    if m > Layout.maxDiffLines || n > Layout.maxDiffLines {
        var ops = [DiffOp]()
        for line in oldLines { ops.append(.removal(line)) }
        for line in newLines { ops.append(.addition(line)) }
        return ops
    }

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

/// Collapses long runs of unchanged context lines into an ellipsis marker.
private func collapseContext(_ ops: [DiffOp]) -> [DiffOp] {
    var result = [DiffOp]()
    var contextRun = [String]()

    func flushContext() {
        if contextRun.count <= Layout.contextCollapseThreshold {
            for line in contextRun { result.append(.context(line)) }
        } else {
            for line in contextRun.prefix(Layout.contextPrefixLines) { result.append(.context(line)) }
            result.append(.context("\u{2026}"))  // Ellipsis marker
            for line in contextRun.suffix(Layout.contextSuffixLines) { result.append(.context(line)) }
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
/// Performs an exact multi-line match against the file contents.
///
/// - Parameters:
///   - filePath: Absolute path to the file to search.
///   - oldString: The multi-line text to locate in the file.
/// - Returns: The 1-based line number where the match starts, or `1` if not found.
private func findStartLine(filePath: String, oldString: String) -> Int {
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
///
/// - Parameter input: The parsed hook input containing tool name and parameters.
/// - Returns: An `NSAttributedString` with the formatted content for display in the code block.
private func buildContent(input: HookInput) -> NSAttributedString {
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
            for line in lines.prefix(Layout.writePreviewLines) { appendCode(line) }
            if lines.count > Layout.writePreviewLines {
                appendLabel("... (\(lines.count - Layout.writePreviewLines) more lines)")
            }
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

/// Renders a unified diff into an attributed string with dual line numbers and color coding.
///
/// Uses separate counters for old-file and new-file line numbers so that additions
/// and removals display their correct positions in each file.
private func renderUnifiedDiff(
    _ ops: [DiffOp],
    startLine: Int,
    oldStr: String,
    newStr: String,
    into result: NSMutableAttributedString
) {
    let oldCount = oldStr.components(separatedBy: "\n").count
    let newCount = newStr.components(separatedBy: "\n").count
    let maxLineNo = startLine + max(oldCount, newCount) + Layout.gutterPadding
    let gutterWidth = max(Layout.minGutterWidth, String(maxLineNo).count)
    var oldLineNo = startLine
    var newLineNo = startLine

    for op in ops {
        let line = NSMutableAttributedString()
        switch op {
        case .removal(let text):
            appendDiffLine(into: line, lineNo: oldLineNo, gutterWidth: gutterWidth,
                           prefix: "- ", text: text, color: Theme.diffRemoved)
            oldLineNo += 1
        case .addition(let text):
            appendDiffLine(into: line, lineNo: newLineNo, gutterWidth: gutterWidth,
                           prefix: "+ ", text: text, color: Theme.diffAdded)
            newLineNo += 1
        case .context(let text):
            if text == "\u{2026}" {
                let padding = String(repeating: " ", count: gutterWidth)
                line.append(NSAttributedString(
                    string: "\(padding)   ...\n",
                    attributes: [.font: Theme.mono, .foregroundColor: Theme.diffEllipsis]
                ))
            } else {
                appendDiffLine(into: line, lineNo: oldLineNo, gutterWidth: gutterWidth,
                               prefix: "  ", text: text, color: Theme.diffContext)
                oldLineNo += 1
                newLineNo += 1
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
///
/// - Parameter input: The parsed hook input containing tool name and parameters.
/// - Returns: An array of `PermOption` values for display as dialog buttons.
private func buildPermOptions(input: HookInput) -> [PermOption] {
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
///
/// - Parameter options: The permission options whose labels determine button widths.
/// - Returns: A tuple of row layouts (indices into `options`) and the total height in points.
private func computeButtonRows(options: [PermOption]) -> (rows: [[Int]], totalHeight: CGFloat) {
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
        + CGFloat(max(0, numRows - 1)) * Layout.buttonGap + Layout.buttonRowsBottomPadding

    return (rows, totalHeight)
}

// MARK: - Content Measurement

/// Measures the natural height of an attributed string when rendered at the given width.
///
/// - Parameters:
///   - content: The attributed string to measure.
///   - width: The available horizontal space in points.
/// - Returns: The required height in points, including vertical padding.
private func measureContentHeight(_ content: NSAttributedString, width: CGFloat) -> CGFloat {
    let textStorage = NSTextStorage(attributedString: content)
    let layoutManager = NSLayoutManager()
    textStorage.addLayoutManager(layoutManager)
    let textContainer = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
    textContainer.widthTracksTextView = true
    layoutManager.addTextContainer(textContainer)
    layoutManager.ensureLayout(for: textContainer)
    return layoutManager.usedRect(for: textContainer).height + Layout.contentMeasurePadding
}

// MARK: - Focus Management

/// Activates the application and brings the panel to front with keyboard focus.
///
/// - Parameter panel: The `NSPanel` to make key and bring to front.
private func activatePanel(_ panel: NSPanel) {
    NSApp.activate()
    panel.makeKeyAndOrderFront(nil)
}

/// Signals the next waiting sibling dialog to re-activate.
///
/// Uses `pgrep` to find other `claude-approve` processes and sends `SIGUSR1`
/// to the one with the lowest PID, creating an orderly activation queue so
/// dialogs take focus one at a time without fighting.
private func notifyNextSiblingDialog() {
    let myPid = ProcessInfo.processInfo.processIdentifier
    let pipe = Pipe()
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-x", "claude-approve"]
    pgrep.standardOutput = pipe
    try? pgrep.run()
    pgrep.waitUntilExit()
    if let pidStr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
        let pids = pidStr.components(separatedBy: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != myPid }
            .sorted()
        if let nextPid = pids.first {
            kill(nextPid, SIGUSR1)
        }
    }
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
///
/// - Parameters:
///   - input: The parsed hook input for header display (project name, path).
///   - options: Permission options to display as buttons.
///   - content: The attributed string to show in the scrollable code block.
///   - gist: A short summary string shown next to the tool tag pill.
///   - buttonRows: Pre-computed row layout (indices into `options`).
///   - optionsHeight: Pre-computed total height for the button area.
/// - Returns: The `resultKey` of the selected `PermOption`, or `"deny"` on timeout/escape.
private func showPermissionDialog(
    input: HookInput,
    options: [PermOption],
    content: NSAttributedString,
    gist: String,
    buttonRows: [[Int]],
    optionsHeight: CGFloat
) -> String {
    let hasContent = content.length > 0

    // Calculate code block height
    let screenHeight = NSScreen.main?.visibleFrame.height ?? Layout.fallbackScreenHeight
    let maxContentHeight = min(Layout.maxCodeBlockHeight, screenHeight * Layout.maxScreenFraction)
    let naturalHeight = hasContent ? measureContentHeight(content, width: Layout.panelWidth - Layout.codeContentInset) : 0
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

    var yPos = panelHeight - Layout.panelTopPadding

    // --- Header: project name ---
    yPos -= Layout.projectHeight
    let projectLabel = NSTextField(labelWithString: input.projectName)
    projectLabel.font = NSFont.systemFont(ofSize: Layout.projectFontSize, weight: .bold)
    projectLabel.textColor = Theme.textPrimary
    projectLabel.frame = NSRect(x: Layout.panelMargin, y: yPos,
                                width: Layout.panelWidth - Layout.panelMargin * 2,
                                height: Layout.projectHeight)
    projectLabel.lineBreakMode = .byTruncatingTail
    contentView.addSubview(projectLabel)

    // --- Header: full path ---
    yPos -= Layout.pathHeight
    let pathLabel = NSTextField(labelWithString: input.cwd)
    pathLabel.font = NSFont.systemFont(ofSize: Layout.pathFontSize, weight: .regular)
    pathLabel.textColor = Theme.textSecondary
    pathLabel.frame = NSRect(x: Layout.panelMargin, y: yPos,
                             width: Layout.panelWidth - Layout.panelMargin * 2,
                             height: Layout.pathLineHeight)
    pathLabel.lineBreakMode = .byTruncatingMiddle
    contentView.addSubview(pathLabel)

    // --- Separator ---
    yPos -= Layout.sectionGap
    let separator = NSBox(frame: NSRect(x: Layout.panelInset, y: yPos,
                                        width: Layout.panelWidth - Layout.panelInset * 2,
                                        height: Layout.separatorHeight))
    separator.boxType = .separator
    contentView.addSubview(separator)

    // --- Tool tag pill + gist ---
    yPos -= Layout.sectionGap
    yPos -= Layout.tagButtonHeight
    let tagColor = Theme.tagColor(for: input.toolName)
    let tagFont = NSFont.systemFont(ofSize: Layout.tagFontSize, weight: .bold)
    let tagTextWidth = (input.toolName as NSString).size(withAttributes: [.font: tagFont]).width
    let tagWidth = tagTextWidth + Layout.tagTextPadding

    let tagPill = NSButton(frame: NSRect(x: Layout.panelMargin, y: yPos,
                                         width: tagWidth, height: Layout.tagButtonHeight))
    tagPill.title = input.toolName
    tagPill.bezelStyle = .rounded
    tagPill.isBordered = false
    tagPill.wantsLayer = true
    tagPill.layer?.cornerRadius = Layout.tagCornerRadius
    tagPill.layer?.backgroundColor = tagColor.withAlphaComponent(Theme.buttonRestAlpha).cgColor
    tagPill.font = tagFont
    tagPill.contentTintColor = tagColor
    tagPill.focusRingType = .none
    tagPill.refusesFirstResponder = true
    contentView.addSubview(tagPill)

    let gistLabel = NSTextField(labelWithString: gist)
    gistLabel.font = NSFont.systemFont(ofSize: Layout.gistFontSize, weight: .bold)
    gistLabel.textColor = Theme.textPrimary
    gistLabel.sizeToFit()
    let gistNaturalHeight = gistLabel.frame.height
    gistLabel.frame = NSRect(
        x: Layout.panelMargin + tagWidth + Layout.tagGistGap,
        y: yPos + (Layout.tagButtonHeight - gistNaturalHeight) / 2,
        width: Layout.panelWidth - Layout.gistTrailingPadding - tagWidth,
        height: gistNaturalHeight
    )
    gistLabel.lineBreakMode = .byTruncatingTail
    contentView.addSubview(gistLabel)

    // --- Code block ---
    yPos -= hasContent ? Layout.codeBlockGap : 0
    let codeBlockBottom = yPos - codeBlockHeight

    if hasContent {
        let codeContainer = NSView(frame: NSRect(
            x: Layout.panelInset, y: codeBlockBottom,
            width: Layout.panelWidth - Layout.panelInset * 2, height: codeBlockHeight
        ))
        codeContainer.wantsLayer = true
        codeContainer.layer?.backgroundColor = Theme.codeBackground.cgColor
        codeContainer.layer?.cornerRadius = Layout.codeCornerRadius
        codeContainer.layer?.borderWidth = Layout.codeBorderWidth
        codeContainer.layer?.borderColor = Theme.border.cgColor
        contentView.addSubview(codeContainer)

        let borderInset = Layout.codeBorderWidth
        let scrollView = NSScrollView(frame: NSRect(
            x: borderInset, y: borderInset,
            width: codeContainer.frame.width - borderInset * 2,
            height: codeContainer.frame.height - borderInset * 2
        ))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textStorage = NSTextStorage(attributedString: content)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(
            width: scrollView.frame.width - Layout.codeScrollerWidth, height: .greatestFiniteMagnitude
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
        let verticalPadding = max(Layout.minVerticalPadding, (scrollView.frame.height - textHeight) / 2)
        textView.textContainerInset = NSSize(width: Layout.codeTextInset, height: verticalPadding)
        textView.autoresizingMask = [.width]
        textView.frame.size.height = max(textHeight + verticalPadding * 2, scrollView.frame.height)

        scrollView.documentView = textView
        codeContainer.addSubview(scrollView)
    }

    // --- Permission buttons ---
    class ButtonHandler: NSObject {
        var options: [PermOption]
        var result: String = "deny"
        var buttons: [NSButton] = []
        private var pressing = false
        init(options: [PermOption]) {
            self.options = options
        }
        /// Visually depresses a button, then dismisses the dialog after a brief pause.
        ///
        /// Uses `CATransaction` to force an immediate layer flush so the pressed state
        /// renders reliably even on panels that were backgrounded at launch.
        func animatePress(index: Int) {
            guard !pressing, index >= 0, index < buttons.count else { return }
            pressing = true
            let button = buttons[index]
            let option = options[index]
            result = option.resultKey
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            button.layer?.backgroundColor = option.color.withAlphaComponent(Theme.buttonPressAlpha).cgColor
            CATransaction.commit()
            CATransaction.flush()
            button.display()
            DispatchQueue.main.asyncAfter(deadline: .now() + Layout.pressAnimationDelay) {
                NSApp.stopModal()
            }
        }
        @objc func clicked(_ sender: NSButton) {
            animatePress(index: sender.tag)
        }
    }

    let handler = ButtonHandler(options: options)

    let availableWidth = Layout.panelWidth - Layout.buttonMargin * 2
    for (rowIndex, row) in buttonRows.enumerated() {
        let rowY = codeBlockBottom - Layout.buttonTopGap - Layout.buttonHeight - CGFloat(rowIndex) * (Layout.buttonHeight + Layout.buttonGap)
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
            button.layer?.backgroundColor = option.color.withAlphaComponent(Theme.buttonRestAlpha).cgColor
            button.contentTintColor = option.color
            button.font = Theme.buttonFont
            button.tag = optionIndex
            button.target = handler
            button.action = #selector(ButtonHandler.clicked(_:))
            contentView.addSubview(button)
            handler.buttons.append(button)

            if optionIndex == 0 {
                panel.defaultButtonCell = button.cell as? NSButtonCell
            }
        }
    }
    // Sort buttons array by tag so index matches option index
    handler.buttons.sort { $0.tag < $1.tag }

    // --- Keyboard shortcuts ---
    let keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        let key = event.charactersIgnoringModifiers ?? ""
        if let num = Int(key), num >= 1, num <= options.count {
            handler.animatePress(index: num - 1)
            return nil
        }
        if key == "\r" {
            handler.animatePress(index: 0)
            return nil
        }
        if key == "\u{1b}" {
            handler.animatePress(index: options.count - 1)
            return nil
        }
        return event
    }

    // --- Timeout ---
    DispatchQueue.main.asyncAfter(deadline: .now() + Layout.dialogTimeout) {
        handler.result = "deny"
        NSApp.stopModal()
    }

    // --- Re-activate on desktop/Space switch ---
    let spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification,
        object: nil,
        queue: .main
    ) { _ in
        if panel.isVisible { activatePanel(panel) }
    }

    // --- SIGUSR1 handler: sibling dialog dismissed, re-activate ---
    signal(SIGUSR1, SIG_IGN)
    let signalSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    signalSource.setEventHandler {
        if panel.isVisible {
            activatePanel(panel)
            panel.display()
        }
    }
    signalSource.resume()

    // --- Show dialog ---
    defer {
        panel.orderOut(nil)
        NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        signalSource.cancel()
        if let monitor = keyboardMonitor { NSEvent.removeMonitor(monitor) }
    }
    activatePanel(panel)
    NSApp.runModal(for: panel)

    return handler.result
}

// MARK: - Result Processing

/// Processes the dialog result and persists the user's approval choice.
///
/// Handles session-level and project-level persistence based on the selected option.
///
/// - Parameters:
///   - resultKey: The `resultKey` from the selected `PermOption`.
///   - input: The parsed hook input for persistence (session file, project settings).
/// - Returns: A tuple of the hook decision (`"allow"` or `"deny"`) and a reason string.
private func processResult(resultKey: String, input: HookInput) -> (decision: String, reason: String) {
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

// Process result: persist approvals and write response immediately
let (decision, reason) = processResult(resultKey: resultKey, input: input)
writeHookResponse(decision: decision, reason: reason)

// Signal next sibling AFTER response is delivered to Claude Code
notifyNextSiblingDialog()
exit(0)
