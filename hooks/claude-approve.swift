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
//  swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift
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
    let permissionMode: String

    /// Directory for session auto-approve files.
    static let sessionDirectory = "/tmp/claude-hook-sessions"

    /// Path to the persistent auto-approve config listing tool names to always allow.
    static let autoApprovePath = NSString("~/.claude/hooks/auto-approve.json").expandingTildeInPath

    /// Project directory name (last path component of `cwd`), or "Claude Code" if cwd is empty.
    var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? "Claude Code" : name
    }

    /// Whether this tool is an MCP tool (name starts with `mcp__`).
    var isMCP: Bool { toolName.hasPrefix("mcp__") }

    /// The MCP server name extracted from the tool name (e.g., "clickup" from "mcp__clickup__get_task").
    /// Returns an empty string for non-MCP tools.
    var mcpServer: String {
        guard isMCP else { return "" }
        let parts = toolName.split(separator: "_", maxSplits: 4, omittingEmptySubsequences: false)
        // Format: mcp__<server>__<tool> → parts: ["mcp", "", "<server>", "", ...]
        return parts.count >= 3 ? String(parts[2]) : ""
    }

    /// The MCP tool action name (e.g., "get_task" from "mcp__clickup__get_task").
    /// Returns the full tool name for non-MCP tools.
    var mcpAction: String {
        guard isMCP else { return toolName }
        // Drop "mcp__<server>__" prefix
        let prefix = "mcp__\(mcpServer)__"
        return toolName.hasPrefix(prefix) ? String(toolName.dropFirst(prefix.count)) : toolName
    }

    /// A short display name for the tag pill. For MCP tools returns the server name
    /// (e.g., "clickup"), otherwise the original tool name.
    var displayName: String {
        isMCP ? mcpServer : toolName
    }

    /// Whether this tool targets a Claude settings file (`.claude/settings*.json`).
    /// Only true for Edit/Write tools whose `file_path` contains `/.claude/settings`.
    var isClaudeSettings: Bool {
        guard toolName == "Edit" || toolName == "Write" else { return false }
        let filePath = toolInput["file_path"] as? String ?? ""
        return filePath.contains("/.claude/settings")
    }

    /// Path to the session auto-approve file, or `nil` if `sessionId` is empty.
    ///
    /// Sanitizes the session ID to prevent path traversal — only ASCII
    /// alphanumerics, dots, underscores, and hyphens are kept; all other
    /// characters are replaced with underscores.
    var sessionFilePath: String? {
        guard !sessionId.isEmpty else { return nil }
        let sanitized = String(sessionId.map { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-")
                ? c : Character("_")
        })
        return "\(HookInput.sessionDirectory)/\(sanitized)"
    }
}

/// A permission option displayed as a button in the dialog.
struct PermOption {
    let label: String
    let resultKey: String
    let color: NSColor
    var textInput: Bool = false
    var placeholder: String = ""
}

/// A single question inside an `AskUserQuestion` tool invocation.
///
/// Mirrors the JSON shape Claude Code sends: `header` is the short category tag
/// (uppercased for the pill), `question` is the prompt text, `options` is the
/// list of preset answers the user can pick from. The wizard automatically
/// appends an "Other" row after these options for free-text answers.
struct WizardQuestion {
    let header: String
    let question: String
    let options: [WizardOption]
}

/// A preset option inside a `WizardQuestion`.
struct WizardOption {
    let label: String
    let description: String
}

/// The user's answer to a single `WizardQuestion`.
///
/// - `preset(index:)`: user picked the option at that index in `question.options`.
/// - `custom(text:)`: user typed a free-text answer in the "Other" row.
enum WizardAnswer: Equatable {
    case preset(index: Int)
    case custom(text: String)
}

/// Represents a single operation in a unified diff.
enum DiffOp: Equatable {
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

    // Text-input morph (No button → text field)
    static let morphInputBg     = NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.18, alpha: 1.0)
    static let morphPlaceholder = NSColor(calibratedWhite: 0.42, alpha: 1.0)
    static let morphText        = NSColor(calibratedWhite: 0.88, alpha: 1.0)
    static let morphInputFont   = NSFont.systemFont(ofSize: 12.5, weight: .semibold)

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
        "Grep":            NSColor(calibratedRed: 0.65, green: 0.75, blue: 0.85, alpha: 1),
        "AskUserQuestion": NSColor(calibratedRed: 1.0,  green: 0.80, blue: 0.15, alpha: 1),
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

    /// Color for MCP tool tags — a distinctive teal/cyan.
    static let mcpTag = NSColor(calibratedRed: 0.30, green: 0.75, blue: 0.70, alpha: 1)

    /// Returns the tag color for a given tool name, with a neutral fallback.
    /// MCP tools (identified by their display name not being in the built-in map) get a distinct teal color.
    static func tagColor(for tool: String) -> NSColor {
        toolTagColors[tool] ?? mcpTag
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

    // Text-input morph
    static let morphTextPaddingLeft: CGFloat = 12
    static let morphSendWidth: CGFloat = 62
    static let morphSendHeight: CGFloat = 24
    static let morphSendCornerRadius: CGFloat = 6
    static let morphSendMargin: CGFloat = 5

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
        toolName:       json["tool_name"]       as? String ?? "",
        toolInput:      json["tool_input"]      as? [String: Any] ?? [:],
        cwd:            json["cwd"]             as? String ?? "",
        sessionId:      json["session_id"]      as? String ?? "",
        permissionMode: json["permission_mode"] as? String ?? ""
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
func checkSessionAutoApprove(input: HookInput) -> Bool {
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

/// Checks if the tool is in the persistent always-approve list.
///
/// Reads the JSON array from `HookInput.autoApprovePath` and checks if the
/// current tool name is included. If yes, writes the allow response to stdout.
///
/// - Parameter input: The parsed hook input containing the tool name.
/// - Returns: `true` if the tool was auto-approved (response already written), `false` otherwise.
func checkAlwaysApprove(input: HookInput) -> Bool {
    guard let data = FileManager.default.contents(atPath: HookInput.autoApprovePath),
          let tools = try? JSONSerialization.jsonObject(with: data) as? [String] else {
        return false
    }
    for rule in tools {
        if rule == input.toolName {
            writeHookResponse(decision: "allow", reason: "Auto-approved (\(rule) in auto-approve.json)")
            return true
        }
        // Bare suffix-glob match (e.g., "mcp__Claude__*")
        if rule.hasSuffix("*") && globMatch(pattern: rule, value: input.toolName) {
            writeHookResponse(decision: "allow", reason: "Auto-approved (\(rule) in auto-approve.json)")
            return true
        }
    }
    return false
}

/// Checks if the tool matches a project-level allow rule in `.claude/settings.local.json`.
///
/// Rules use glob matching: `Bash(echo *)` matches any command starting with `echo`.
///
/// - Parameter input: The parsed hook input.
/// - Returns: `true` if a matching rule was found (response already written), `false` otherwise.
func checkProjectSettings(input: HookInput) -> Bool {
    let allow = loadProjectAllowRules(cwd: input.cwd)
    if allow.isEmpty { return false }

    let toolName = input.toolName
    let cmd = input.toolInput["command"] as? String ?? ""
    let url = input.toolInput["url"] as? String ?? ""

    for rule in allow {
        // Exact tool match (e.g., "WebSearch", "Read")
        if rule == toolName {
            writeHookResponse(decision: "allow", reason: "Allowed by project rule: \(rule)")
            return true
        }
        // Bare suffix-glob match (e.g., "mcp__Claude__*" matches "mcp__Claude__preview_resize")
        if rule.hasSuffix("*") && !rule.contains("(") {
            if globMatch(pattern: rule, value: toolName) {
                writeHookResponse(decision: "allow", reason: "Allowed by project rule: \(rule)")
                return true
            }
        }
        // Pattern match: ToolName(pattern) where pattern uses glob-style *
        if rule.hasPrefix("\(toolName)(") && rule.hasSuffix(")") {
            let start = rule.index(rule.startIndex, offsetBy: toolName.count + 1)
            let end = rule.index(before: rule.endIndex)
            let pattern = String(rule[start..<end])

            let valueToMatch: String
            if toolName == "Bash" {
                valueToMatch = cmd
            } else if toolName == "WebFetch" && pattern.hasPrefix("domain:") {
                valueToMatch = "domain:" + (URL(string: url)?.host ?? url)
            } else {
                valueToMatch = cmd
            }

            if globMatch(pattern: pattern, value: valueToMatch) {
                writeHookResponse(decision: "allow", reason: "Allowed by project rule: \(rule)")
                return true
            }
        }
    }
    return false
}

/// Loads the merged `permissions.allow` arrays from both `.claude/settings.json`
/// and `.claude/settings.local.json` in the project directory.
///
/// - Parameter cwd: The project working directory.
/// - Returns: A combined array of allow rule strings (duplicates preserved — matching stops at first hit).
private func loadProjectAllowRules(cwd: String) -> [String] {
    var allRules: [String] = []
    for filename in ["settings.json", "settings.local.json"] {
        let path = cwd + "/.claude/" + filename
        if let data = FileManager.default.contents(atPath: path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let perms = json["permissions"] as? [String: Any],
           let allow = perms["allow"] as? [String] {
            allRules.append(contentsOf: allow)
        }
    }
    return allRules
}

/// Simple glob matcher — supports `*` as a wildcard for any sequence of characters.
private func globMatch(pattern: String, value: String) -> Bool {
    if pattern == "*" { return true }
    if pattern.hasSuffix(" *") {
        let prefix = String(pattern.dropLast(2))
        return value == prefix || value.hasPrefix(prefix + " ") || value.hasPrefix(prefix + "\t")
    }
    if pattern.hasSuffix("*") {
        let prefix = String(pattern.dropLast())
        return value.hasPrefix(prefix)
    }
    return pattern == value
}

/// Appends a tool name to the session auto-approve file.
///
/// Future invocations for this tool will be automatically allowed without showing the dialog.
/// Uses `O_APPEND` for atomic writes safe against concurrent processes.
///
/// - Parameters:
///   - input: The parsed hook input containing the session file path.
///   - entry: The tool name to add to the session's approved list.
func saveToSessionFile(input: HookInput, entry: String) {
    guard let path = input.sessionFilePath else { return }
    try? FileManager.default.createDirectory(
        atPath: HookInput.sessionDirectory, withIntermediateDirectories: true
    )
    try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: HookInput.sessionDirectory
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

/// Writes the hook response JSON to stdout.
///
/// Falls back to a hardcoded deny JSON string if serialization fails.
///
/// - Parameters:
///   - decision: The permission decision — `"allow"` or `"deny"`.
///   - reason: A human-readable reason string explaining the decision.
func writeHookResponse(decision: String, reason: String) {
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
        return "Fetch \(url.count > Layout.maxGistUrlLength ? String(url.prefix(Layout.gistUrlTruncLength)) + "..." : url)"
    case "WebSearch":
        return "Search: \(input.toolInput["query"] as? String ?? "")"
    case "Glob":
        return "Find files: \(input.toolInput["pattern"] as? String ?? "")"
    case "Grep":
        return "Search code: \(input.toolInput["pattern"] as? String ?? "")"
    case "AskUserQuestion":
        if let questions = input.toolInput["questions"] as? [[String: Any]] {
            if questions.count == 1, let q = questions.first?["question"] as? String { return q }
            let headers = questions.compactMap { $0["header"] as? String }
            if !headers.isEmpty { return headers.joined(separator: " · ") }
            return "\(questions.count) questions"
        }
        return "Question"
    default:
        if input.isMCP {
            // Show readable action name: "clickup_get_task" → "Get Task"
            let words = input.mcpAction
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            return words.joined(separator: " ")
        }
        return input.toolName
    }
}

/// Extracts the last path component from an optional tool input value.
func lastComponent(_ value: Any?) -> String {
    ((value as? String ?? "") as NSString).lastPathComponent
}

/// Summarizes a Bash command to just its command names joined by operators.
///
/// Example: `cd ~/.claude/hooks && swiftc -framework AppKit -o out file.swift` → `cd && swiftc`
func summarizeBashCommand(_ cmd: String) -> String {
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
func ansiColor(code: Int, defaultColor: NSColor) -> NSColor? {
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
func styledCode(_ text: String, color: NSColor) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [.font: Theme.mono, .foregroundColor: color])
}

/// Shell keywords recognized by the Bash syntax highlighter.
let bashKeywords: Set<String> = [
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
/// Long runs of unchanged context lines are collapsed with an ellipsis marker.
/// The output matches the style of a unified diff: context, removals (-), and additions (+).
/// If either input exceeds `Layout.maxDiffLines`, returns a simple removal/addition pair instead
/// of computing the full LCS to avoid excessive memory usage.
///
/// - Parameters:
///   - oldStr: The original text (before the edit).
///   - newStr: The replacement text (after the edit).
/// - Returns: An array of `DiffOp` values representing context, removals, and additions.
func computeLineDiff(old oldStr: String, new newStr: String) -> [DiffOp] {
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
func collapseContext(_ ops: [DiffOp]) -> [DiffOp] {
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
///
/// - Parameter input: The parsed hook input containing tool name and parameters.
/// - Returns: An `NSAttributedString` with the formatted content for display in the code block.
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

    case "AskUserQuestion":
        if let questions = input.toolInput["questions"] as? [[String: Any]] {
            for (qi, q) in questions.enumerated() {
                if qi > 0 { appendNewline() }
                if let header = q["header"] as? String { appendLabel(header) }
                if let question = q["question"] as? String { appendCode(question, color: Theme.textPrimary) }
                appendNewline()
                if let opts = q["options"] as? [[String: Any]] {
                    for (oi, opt) in opts.enumerated() {
                        if let label = opt["label"] as? String { appendCode("  \(oi + 1).  \(label)") }
                        if let desc = opt["description"] as? String, !desc.isEmpty {
                            appendLabel("       \(desc)")
                        }
                    }
                }
            }
        }

    default:
        if input.isMCP {
            // Display MCP parameters as labeled fields
            let sortedKeys = input.toolInput.keys.sorted()
            for key in sortedKeys {
                let value = input.toolInput[key]
                let displayValue: String
                if let str = value as? String {
                    displayValue = str
                } else if let obj = value, JSONSerialization.isValidJSONObject(obj),
                    let data = try? JSONSerialization.data(
                        withJSONObject: obj, options: .prettyPrinted),
                    let str = String(data: data, encoding: .utf8) {
                    displayValue = str
                } else {
                    displayValue = "\(value ?? "")"
                }
                appendLabel("\(key): \(displayValue)")
            }
        } else if let data = try? JSONSerialization.data(withJSONObject: input.toolInput, options: .prettyPrinted),
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
            PermOption(label: "No, and tell Claude what to do differently", resultKey: "deny", color: Theme.buttonDeny, textInput: true, placeholder: "Tell Claude what to do differently"),
        ]

    case "Edit", "Write":
        return [
            PermOption(label: "Yes", resultKey: "allow_once", color: Theme.buttonAllow),
            PermOption(label: "Yes, allow all edits during this session", resultKey: "allow_edits_session", color: Theme.buttonPersist),
            PermOption(label: "No, and tell Claude what to do differently", resultKey: "deny", color: Theme.buttonDeny, textInput: true, placeholder: "Tell Claude what to do differently"),
        ]

    case "WebFetch":
        let urlStr = input.toolInput["url"] as? String ?? ""
        let domain = URL(string: urlStr)?.host ?? urlStr
        return [
            PermOption(label: "Yes", resultKey: "allow_once", color: Theme.buttonAllow),
            PermOption(label: "Yes, and don't ask again for \(domain)", resultKey: "dont_ask_domain", color: Theme.buttonPersist),
            PermOption(label: "No, and tell Claude what to do differently", resultKey: "deny", color: Theme.buttonDeny, textInput: true, placeholder: "Tell Claude what to do differently"),
        ]

    case "WebSearch":
        return [
            PermOption(label: "Yes", resultKey: "allow_once", color: Theme.buttonAllow),
            PermOption(label: "Yes, and don't ask again for WebSearch", resultKey: "dont_ask_tool", color: Theme.buttonPersist),
            PermOption(label: "No, and tell Claude what to do differently", resultKey: "deny", color: Theme.buttonDeny, textInput: true, placeholder: "Tell Claude what to do differently"),
        ]

    case "AskUserQuestion":
        return [
            PermOption(label: "Go to Terminal", resultKey: "allow_goto_terminal", color: Theme.buttonAllow),
        ]

    default:
        if input.isMCP {
            let server = input.mcpServer
            return [
                PermOption(label: "Yes", resultKey: "allow_once", color: Theme.buttonAllow),
                PermOption(
                    label: "Yes, and don't ask again for \(server) commands in \(input.projectName)",
                    resultKey: "dont_ask_mcp_server",
                    color: Theme.buttonPersist
                ),
                PermOption(label: "No, and tell Claude what to do differently", resultKey: "deny", color: Theme.buttonDeny, textInput: true, placeholder: "Tell Claude what to do differently"),
            ]
        }
        return [
            PermOption(label: "Yes", resultKey: "allow_once", color: Theme.buttonAllow),
            PermOption(label: "Yes, during this session", resultKey: "allow_session", color: Theme.buttonPersist),
            PermOption(label: "No", resultKey: "deny", color: Theme.buttonDeny),
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
func measureContentHeight(_ content: NSAttributedString, width: CGFloat) -> CGFloat {
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

/// The frontmost application at hook launch time, captured before any UI activation.
/// Set once in the main entry point. Used by `openTerminalApp()`.
private var capturedTerminalApp: NSRunningApplication?

/// Activates the application and brings the panel to front with keyboard focus.
///
/// - Parameter panel: The `NSPanel` to make key and bring to front.
private func activatePanel(_ panel: NSPanel) {
    NSApp.activate()
    panel.makeKeyAndOrderFront(nil)
}

/// Resolves the terminal TTY and parent GUI application in a single pass.
///
/// Snapshots the full process table with one `ps` call, then walks from the hook
/// process upward through ancestors. This replaces separate tree-walks for TTY
/// lookup and parent-app discovery, reducing subprocess spawns from O(N) to O(1).
///
/// - Returns: The owning TTY (e.g. `"s015"`) and the first GUI ancestor, either
///   of which may be `nil`.
private func resolveProcessAncestry() -> (tty: String?, app: NSRunningApplication?) {
    let pipe = Pipe()
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-eo", "pid=,ppid=,tty="]
    ps.standardOutput = pipe
    try? ps.run()
    ps.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    var ppidMap: [pid_t: pid_t] = [:]
    var ttyMap: [pid_t: String] = [:]
    for line in output.components(separatedBy: "\n") {
        let fields = line.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count >= 2,
              let pid = pid_t(fields[0]),
              let ppid = pid_t(fields[1]) else { continue }
        ppidMap[pid] = ppid
        if fields.count > 2 {
            let tty = String(fields[2]).trimmingCharacters(in: .whitespaces)
            if !tty.isEmpty && tty != "??" { ttyMap[pid] = tty }
        }
    }

    var foundTTY: String? = nil
    var foundApp: NSRunningApplication? = nil
    var pid = ProcessInfo.processInfo.processIdentifier
    if let t = ttyMap[pid] { foundTTY = t }

    for _ in 0..<15 {
        guard let ppid = ppidMap[pid], ppid > 1 else { break }
        pid = ppid
        if foundTTY == nil, let t = ttyMap[pid] { foundTTY = t }
        if foundApp == nil,
           let app = NSRunningApplication(processIdentifier: pid),
           app.activationPolicy == .regular {
            foundApp = app
        }
        if foundTTY != nil && foundApp != nil { break }
    }

    // If inside tmux, the TTY from the walk is a tmux-internal pts and the
    // walk may have dead-ended at launchd without finding a GUI app.  Ask tmux
    // for the *client* PID/TTY so we can resolve the real hosting terminal.
    if ProcessInfo.processInfo.environment["TMUX"] != nil,
       let parsed = queryTmuxClient() {
        // Always prefer the client TTY (terminal's actual TTY) over tmux pts.
        if let t = parsed.tty { foundTTY = t }
        // If no GUI app found via normal walk, walk from the client PID.
        if foundApp == nil {
            var pid = parsed.pid
            for _ in 0..<15 {
                if let app = NSRunningApplication(processIdentifier: pid),
                   app.activationPolicy == .regular {
                    foundApp = app
                    break
                }
                guard let ppid = ppidMap[pid], ppid > 1 else { break }
                pid = ppid
            }
        }
    }

    return (foundTTY, foundApp)
}

/// Parses the output of `tmux display-message -p '#{client_pid} #{client_tty}'`.
///
/// Extracts the client PID and normalizes the TTY from `/dev/ttysXXX` (or
/// `ttysXXX`) to the short `sXXX` format used by `ps -o tty=`.
///
/// - Parameter output: Raw stdout from the tmux command.
/// - Returns: A tuple of (client PID, normalized TTY) or `nil` if parsing fails.
func parseTmuxClientOutput(_ output: String) -> (pid: pid_t, tty: String?)? {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    guard let pid = pid_t(parts[0]) else { return nil }

    var tty: String? = nil
    if parts.count > 1 {
        var raw = String(parts[1]).trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("/dev/tty") {
            raw = String(raw.dropFirst("/dev/tty".count))
        } else if raw.hasPrefix("tty") {
            raw = String(raw.dropFirst("tty".count))
        }
        tty = raw.isEmpty ? nil : raw
    }

    return (pid, tty)
}

/// Queries tmux for the current client's PID and TTY.
///
/// Uses `tmux display-message` to retrieve the attached client's process ID
/// and controlling TTY.  Returns `nil` if tmux is not available or the
/// command fails (e.g. when not running inside tmux).
private func queryTmuxClient() -> (pid: pid_t, tty: String?)? {
    let pipe = Pipe()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["tmux", "display-message", "-p", "#{client_pid} #{client_tty}"]
    p.standardOutput = pipe
    p.standardError = Pipe()
    try? p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return parseTmuxClientOutput(output)
}

/// Executes an AppleScript source string, ignoring errors.
private func runAppleScript(_ source: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", source]
    try? p.run()
    p.waitUntilExit()
}

/// Focuses the Terminal.app tab whose TTY matches `tty`.
///
/// Terminal.app reports tab TTYs as `ttysXXX`; `ps -o tty=` returns just `sXXX`,
/// so we match by suffix to handle both formats.
private func focusTerminalTab(tty: String) {
    runAppleScript("""
    tell application "Terminal"
        repeat with w in windows
            repeat with t in tabs of w
                if (tty of t) ends with "\(tty)" then
                    set selected tab of w to t
                    set frontmost of w to true
                    return
                end if
            end repeat
        end repeat
    end tell
    """)
}

/// Focuses the iTerm2 session whose TTY matches `tty` and activates the app.
///
/// iTerm2 reports session TTYs as `/dev/ttysXXX`; we match by suffix.
/// Activation is done inside the same AppleScript to avoid the `reopen`
/// command in `openApp()` resetting the selected tab.
private func focusiTermSession(tty: String) {
    runAppleScript("""
    tell application "iTerm2"
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    if (tty of s) ends with "\(tty)" then
                        select t
                        select s
                        set index of w to 1
                        activate
                        return
                    end if
                end repeat
            end repeat
        end repeat
        activate
    end tell
    """)
}

/// Finds and raises the window whose title contains `substring` (case-insensitive)
/// using the Accessibility API.
///
/// This is the generic strategy for terminals and IDEs that lack AppleScript tab
/// control (Warp, VS Code, JetBrains, etc.). Most of these apps include the
/// project directory or file name in the window title.
///
/// - Parameters:
///   - app: The running application to search.
///   - substring: The case-insensitive substring to match against window titles.
/// - Returns: `true` if a matching window was found and raised; `false` otherwise.
@discardableResult
private func focusAXWindowByTitle(app: NSRunningApplication, substring: String) -> Bool {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement] else {
        return false
    }
    let needle = substring.lowercased()
    for window in windows {
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String, title.lowercased().contains(needle) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, true as CFTypeRef)
            return true
        }
    }
    return false
}

/// Checks whether the current Warp tab's text area contains `needle`.
private func warpTabContains(_ needle: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", """
    tell application "System Events"
        tell process "Warp"
            if value of text area 1 of window 1 contains "\(needle)" then
                return "yes"
            end if
        end tell
    end tell
    return "no"
    """]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    try? p.run()
    p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return out == "yes"
}

/// Focuses the Warp tab that owns our TTY and activates Warp.
///
/// Writes a unique plain-text marker to the TTY device, checks if the
/// current tab already has it (no activation needed for the check), and
/// if not, activates Warp and cycles tabs in a single AppleScript loop.
/// The marker is erased via backspace sequences after identification.
///
/// - Parameters:
///   - bundleId: Warp's bundle identifier.
///   - tty: The TTY string (e.g. `"s015"`).
/// - Returns: `true` if the target tab was found and activated.
private func focusWarpTab(bundleId: String, tty: String?) -> Bool {
    guard let tty = tty else { return false }

    let marker = "claude-hook-\(ProcessInfo.processInfo.processIdentifier)"

    // Write marker to our TTY so we can identify the correct tab.
    let ttyPath = tty.hasPrefix("/dev/") ? tty
        : tty.hasPrefix("tty") ? "/dev/\(tty)"
        : "/dev/tty\(tty)"
    guard let data = marker.data(using: .utf8),
          let handle = FileHandle(forWritingAtPath: ttyPath) else {
        return false
    }
    handle.write(data)
    handle.closeFile()
    Thread.sleep(forTimeInterval: 0.2)

    // Erase the marker from the terminal after tab identification.
    defer {
        let cleanup = "\r\u{1b}[2K"
        if let cleanupData = cleanup.data(using: .utf8),
           let cleanHandle = FileHandle(forWritingAtPath: ttyPath) {
            cleanHandle.write(cleanupData)
            cleanHandle.closeFile()
        }
    }

    // Fast path: if the current tab already has our marker, just activate.
    if warpTabContains(marker) {
        runAppleScript("""
        tell application id "\(bundleId)"
            activate
        end tell
        """)
        return true
    }

    // Cycle tabs in a single AppleScript to find ours.
    let cycleProc = Process()
    cycleProc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    cycleProc.arguments = ["-e", """
    try
        tell application id "\(bundleId)" to activate
        delay 0.2
        tell application "System Events"
            tell process "Warp"
                set startTitle to ""
                try
                    set startTitle to name of window 1
                end try
                repeat 20 times
                    keystroke "]" using {command down, shift down}
                    delay 0.1
                    try
                        if value of text area 1 of window 1 contains "\(marker)" then
                            return "found"
                        end if
                    end try
                    try
                        if startTitle is not "" then
                            set currentTitle to name of window 1
                            if currentTitle = startTitle then
                                return "wrapped"
                            end if
                        end if
                    end try
                end repeat
            end tell
        end tell
        return "exhausted"
    on error errMsg
        return "error:" & errMsg
    end try
    """]
    let cyclePipe = Pipe()
    cycleProc.standardOutput = cyclePipe
    cycleProc.standardError = Pipe()
    try? cycleProc.run()
    cycleProc.waitUntilExit()
    let result = String(data: cyclePipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return result == "found"
}

/// Recursively searches the Accessibility tree for a clickable element whose
/// title or value contains `substring` (case-insensitive) and presses it.
///
/// Used by JetBrains IDEs to activate the Terminal tool window. Only matches
/// elements whose role is in
/// `roles` — typically buttons, radio buttons, tabs, or cells.
///
/// - Parameters:
///   - app: The running application whose AX tree to search.
///   - substring: Case-insensitive text to match against element titles/values.
///   - roles: Set of AX role strings that are eligible for pressing.
///   - maxDepth: Maximum recursion depth (default 8) to avoid runaway traversal.
/// - Returns: `true` if a matching element was found and pressed.
@discardableResult
private func focusAXDescendant(app: NSRunningApplication, matching substring: String, roles: Set<String>, maxDepth: Int = 8) -> Bool {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    let needle = substring.lowercased()
    return searchAXTree(element: axApp, needle: needle, roles: roles, depth: 0, maxDepth: maxDepth)
}

/// Recursive helper for `focusAXDescendant`. Walks the AX element tree
/// depth-first, checking title and value attributes at each node.
private func searchAXTree(element: AXUIElement, needle: String, roles: Set<String>, depth: Int, maxDepth: Int) -> Bool {
    if depth > maxDepth { return false }

    var roleRef: CFTypeRef?
    let role: String? = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success
        ? (roleRef as? String) : nil

    // Check title attribute.
    var titleRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
       let title = titleRef as? String, !title.isEmpty,
       title.lowercased().contains(needle),
       let r = role, roles.contains(r) {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
        return true
    }

    // Check value attribute (some apps store tab titles in AXValue).
    var valueRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
       let value = valueRef as? String, !value.isEmpty,
       value.lowercased().contains(needle),
       let r = role, roles.contains(r) {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
        return true
    }

    // Recurse into children.
    var childrenRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
       let children = childrenRef as? [AXUIElement] {
        for child in children {
            if searchAXTree(element: child, needle: needle, roles: roles, depth: depth + 1, maxDepth: maxDepth) {
                return true
            }
        }
    }
    return false
}

/// Runs a cmux CLI command, discarding output.
private func runCmuxCmd(_ cli: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cli)
    p.arguments = args
    p.standardOutput = Pipe(); p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
}

/// Transfers activation from this hook to the target running application.
///
/// Uses two complementary strategies:
/// 1. **AX raise** — window-level focus via Accessibility.
/// 2. **AppleScript `reopen` + `activate`** — reliably brings apps to front
///    even across Spaces by simulating a Dock-icon click.
private func openApp(_ app: NSRunningApplication) {
    guard let bundleId = app.bundleIdentifier else { return }

    // AX raise — best-effort window-level focus.
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var windowsRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
       let windows = windowsRef as? [AXUIElement], !windows.isEmpty {
        for window in windows {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, true as CFTypeRef)
    }

    // AppleScript reopen + activate — triggers the Dock-click handler.
    runAppleScript("""
    tell application id "\(bundleId)"
        reopen
        activate
    end tell
    """)
}

/// Activates the terminal or IDE that spawned this Claude session.
///
/// Uses `resolveProcessAncestry()` to find the parent terminal/IDE in a single
/// `ps` call, falling back to the frontmost app captured at launch. Each
/// terminal family gets a dedicated strategy:
///
/// - **Terminal.app**: AppleScript tab selection by TTY.
/// - **iTerm2**: AppleScript session selection by TTY with inline activation.
/// - **Warp**: TTY marker + tab cycling via Cmd+Shift+].
/// - **JetBrains IDEs**: AX window-title match + AX deep search for Terminal tool.
/// - **Claude desktop**: `claude://resume` deep link to navigate to the Code session.
/// - **Other** (VS Code, Kitty, etc.): AX window-title match, standard activation.
///
/// - Parameters:
///   - cwd: The current working directory, used to extract the project
///     name for window-title matching.
///   - sessionId: The Claude CLI session ID, used for Claude desktop deep links.
private func openTerminalApp(cwd: String, sessionId: String = "") {
    let (tty, parentApp) = resolveProcessAncestry()
    guard let app = parentApp ?? capturedTerminalApp else { return }

    let projectName = (cwd as NSString).lastPathComponent
    let bundleId = app.bundleIdentifier ?? ""

    switch bundleId {
    case "com.apple.Terminal":
        if let t = tty { focusTerminalTab(tty: t) }
        openApp(app)

    case "com.googlecode.iterm2":
        // iTerm2: AppleScript handles both tab selection and activation in one
        // call to avoid `reopen` in openApp() resetting the selected tab.
        if let t = tty {
            focusiTermSession(tty: t)
        } else {
            openApp(app)
        }

    case _ where bundleId.hasPrefix("dev.warp."):
        // Warp exposes 0 AX windows and has no AppleScript tab API.
        // `reopen` and NSWorkspace.open both create new tabs.
        if !focusWarpTab(bundleId: bundleId, tty: tty) {
            runAppleScript("""
            tell application id "\(bundleId)"
                activate
            end tell
            """)
        }

    case _ where bundleId.hasPrefix("com.jetbrains."):
        // JetBrains IDEs: focus the window matching the project name, then
        // activate the Terminal tool window via AX deep search.
        focusAXWindowByTitle(app: app, substring: projectName)
        openApp(app)
        Thread.sleep(forTimeInterval: 0.15)
        let toolRoles: Set<String> = ["AXButton", "AXRadioButton", "AXTab", "AXCheckBox", "AXStaticText"]
        focusAXDescendant(app: app, matching: "Terminal", roles: toolRoles)

    case "com.cmuxterm.app":
        // cmux: pre-focus via CLI to prevent duplicate windows, activate to
        // bring to front, then select the Claude workspace.
        let cmuxCLI = "/Applications/cmux.app/Contents/Resources/bin/cmux"
        let cmuxEnv = ProcessInfo.processInfo.environment

        // 1. Pre-select workspace + focus window via CLI (prevents duplicate).
        if let wsId = cmuxEnv["CMUX_WORKSPACE_ID"] {
            runCmuxCmd(cmuxCLI, ["select-workspace", "--workspace", wsId])
        }

        // 2. Activate to bring cmux to front and switch Spaces.
        runAppleScript("""
        tell application id "\(bundleId)"
            activate
        end tell
        """)

        // 3. Re-select workspace after activation (brief delay for cmux to
        //    finish processing the activate event).
        Thread.sleep(forTimeInterval: 0.15)
        if let wsId = cmuxEnv["CMUX_WORKSPACE_ID"] {
            runCmuxCmd(cmuxCLI, ["select-workspace", "--workspace", wsId])
        }
        if let surfId = cmuxEnv["CMUX_SURFACE_ID"] {
            runCmuxCmd(cmuxCLI, ["focus-panel", "--panel", surfId])
        }

    case "com.anthropic.claudefordesktop":
        // Claude desktop is Electron with a separate Code BrowserWindow.
        // `reopen` and NSWorkspace.open(cwd) switch to Chat/Cowork, so skip
        // those. Use the `claude://resume` deep link to navigate to the
        // correct Code session, then `activate` to bring the app to front.
        openClaudeDesktop(bundleId: bundleId, sessionId: sessionId, cwd: cwd)

    default:
        // VS Code, Kitty, and other terminals.
        if !focusAXWindowByTitle(app: app, substring: projectName) {
            openApp(app)
        }
        let cwdURL = URL(fileURLWithPath: cwd)
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            let sem = DispatchSemaphore(value: 0)
            NSWorkspace.shared.open([cwdURL], withApplicationAt: appURL, configuration: config) { _, _ in
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 3)
        }
    }
}

/// Builds the `claude://resume` deep link URL for a given session.
///
/// - Parameters:
///   - sessionId: The CLI session UUID.
///   - cwd: The session's working directory.
/// - Returns: The deep link URL string, or `nil` if `sessionId` is empty.
func buildClaudeDesktopResumeURL(sessionId: String, cwd: String) -> String? {
    guard !sessionId.isEmpty else { return nil }
    var comps = URLComponents()
    comps.scheme = "claude"
    comps.host = "resume"
    comps.queryItems = [
        URLQueryItem(name: "session", value: sessionId),
        URLQueryItem(name: "cwd", value: cwd),
    ]
    return comps.url?.absoluteString
}

/// Activates Claude desktop by navigating to the correct Code session.
///
/// Sends a `claude://resume` deep link to switch to the CLI session identified
/// by `sessionId`, then activates the app via AppleScript. The deep link is
/// opened via `/usr/bin/open` because `NSWorkspace.shared.open` does not
/// reliably trigger the Electron URL handler from an accessory-mode process.
///
/// - Parameters:
///   - bundleId: The Claude desktop bundle identifier.
///   - sessionId: The CLI session UUID to resume.
///   - cwd: The session's working directory.
private func openClaudeDesktop(bundleId: String, sessionId: String, cwd: String) {
    if let urlString = buildClaudeDesktopResumeURL(sessionId: sessionId, cwd: cwd) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [urlString]
        try? p.run()
        p.waitUntilExit()
    }
    runAppleScript("""
    tell application id "\(bundleId)"
        activate
    end tell
    """)
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

// MARK: - Button Handler

/// Manages button press state, text input morphing, and dialog dismissal.
///
/// Tracks which option the user selected via `result`, prevents double-press via `pressing`,
/// and drives both click and keyboard-shortcut code paths through `animatePress(index:)`.
/// When the deny button (with `textInput`) is clicked, it morphs into an inline text field.
final class ButtonHandler: NSObject, NSTextFieldDelegate {
    let options: [PermOption]
    /// The `resultKey` of the selected `PermOption`. Defaults to `"deny"` (safe fallback).
    var result: String = "deny"
    /// User-typed feedback text from the deny text field (empty if none typed).
    var feedbackText: String = ""
    var buttons: [NSButton] = []
    private var pressing = false
    var textInputActive = false
    private var activeTextField: NSTextField?

    init(options: [PermOption]) {
        self.options = options
    }

    /// Visually depresses the button at `index`, records `result`, then stops the modal.
    /// If the option has `textInput`, morphs the button into a text field instead.
    func animatePress(index: Int) {
        guard !pressing, index >= 0, index < buttons.count else { return }
        let option = options[index]

        if option.textInput && !textInputActive {
            textInputActive = true
            morphToTextField(index: index)
            return
        }

        pressing = true
        let button = buttons[index]
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

    /// Morphs the deny button into a text field + Send button.
    private func morphToTextField(index: Int) {
        let button = buttons[index]
        let option = options[index]
        guard let superview = button.superview else { return }

        let frame = button.frame
        let tint = option.color

        // Container — same frame/corners, soothing dark background + color-matched border
        let container = NSView(frame: frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = Layout.buttonCornerRadius
        container.layer?.backgroundColor = Theme.morphInputBg.cgColor
        container.layer?.borderColor = tint.withAlphaComponent(0.45).cgColor
        container.layer?.borderWidth = 1
        container.alphaValue = 0
        superview.addSubview(container)

        // Send button
        let sendW = Layout.morphSendWidth
        let sendH = Layout.morphSendHeight
        let sendMargin = Layout.morphSendMargin
        let sendBtn = NSButton(frame: NSRect(
            x: frame.width - sendW - sendMargin,
            y: (frame.height - sendH) / 2,
            width: sendW, height: sendH
        ))
        sendBtn.title = "Send ⏎"
        sendBtn.alignment = .center
        sendBtn.bezelStyle = .rounded
        sendBtn.isBordered = false
        sendBtn.wantsLayer = true
        sendBtn.layer?.cornerRadius = Layout.morphSendCornerRadius
        sendBtn.layer?.backgroundColor = tint.withAlphaComponent(0.55).cgColor
        sendBtn.contentTintColor = NSColor(calibratedWhite: 0.95, alpha: 1.0)
        sendBtn.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        sendBtn.tag = index
        sendBtn.target = self
        sendBtn.action = #selector(ButtonHandler.sendClicked(_:))
        container.addSubview(sendBtn)

        // Text field — vertically centered using font metrics
        let leftPad = Layout.morphTextPaddingLeft
        let rightPad = sendW + sendMargin * 2
        let lineHeight = ceil(Theme.morphInputFont.ascender - Theme.morphInputFont.descender + Theme.morphInputFont.leading)
        let tfHeight = lineHeight + 4
        let tf = NSTextField(frame: NSRect(
            x: leftPad, y: (frame.height - tfHeight) / 2 - 1,
            width: frame.width - leftPad - rightPad, height: tfHeight
        ))
        tf.placeholderAttributedString = NSAttributedString(
            string: option.placeholder,
            attributes: [
                .foregroundColor: Theme.morphPlaceholder,
                .font: Theme.morphInputFont,
            ]
        )
        tf.stringValue = ""
        tf.alignment = .left
        tf.font = Theme.morphInputFont
        tf.textColor = Theme.morphText
        tf.backgroundColor = .clear
        tf.drawsBackground = false
        tf.isBordered = false
        tf.isEditable = true
        tf.focusRingType = .none
        tf.delegate = self
        tf.tag = index
        container.addSubview(tf)
        activeTextField = tf

        // Animate: button fades out, container fades in
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            button.animator().alphaValue = 0
            container.animator().alphaValue = 1
        }, completionHandler: {
            button.isHidden = true
            superview.window?.makeFirstResponder(tf)
        })
    }

    private func submitTextInput(index: Int) {
        guard index >= 0, index < options.count else { return }
        pressing = true
        result = options[index].resultKey
        feedbackText = activeTextField?.stringValue ?? ""
        NSApp.stopModal()
    }

    @objc func sendClicked(_ sender: NSButton) { submitTextInput(index: sender.tag) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submitTextInput(index: control.tag)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            pressing = true
            result = options[control.tag].resultKey
            feedbackText = ""
            NSApp.stopModal()
            return true
        }
        return false
    }

    /// Direct press — skips textInput morph. Used by Enter/Esc keyboard shortcuts.
    func directPress(index: Int) {
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

    /// Button click target — delegates to `animatePress(index:)` via the button's tag.
    @objc func clicked(_ sender: NSButton) { animatePress(index: sender.tag) }
}

// MARK: - Dialog Helpers

/// Installs a minimal Edit menu so clipboard shortcuts (Cmd+C/V/X/A) work in text fields.
///
/// Headless `.accessory` apps have no menu bar, so macOS cannot route key equivalents
/// for Copy, Paste, Cut, and Select All to the focused `NSTextField`. Adding a hidden
/// Edit menu lets AppKit handle them automatically.
private func installEditMenu() {
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

    let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    editItem.submenu = editMenu

    let mainMenu = NSMenu(title: "Main")
    mainMenu.addItem(editItem)
    NSApp.mainMenu = mainMenu
}

/// Creates and positions the floating `NSPanel` for the permission dialog.
///
/// - Parameter height: Total panel height in points.
/// - Returns: A configured floating `NSPanel` centered on the main screen.
private func makePermissionPanel(height: CGFloat) -> NSPanel {
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: Layout.panelWidth, height: height),
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
    if let screen = NSScreen.main {
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - Layout.panelWidth / 2,
                                     y: frame.midY - height / 2))
    } else {
        panel.center()
    }
    return panel
}

/// Adds the session identity header — project name, full path, and separator — to `contentView`.
///
/// - Parameters:
///   - contentView: The panel's root view.
///   - input: Hook input supplying `projectName` and `cwd`.
///   - panelHeight: Total panel height, used as the Y origin for top-down layout.
/// - Returns: The Y position immediately below the separator, ready for the next row.
private func addHeader(to contentView: NSView, input: HookInput, panelHeight: CGFloat) -> CGFloat {
    var yPos = panelHeight - Layout.panelTopPadding

    yPos -= Layout.projectHeight
    let projectLabel = NSTextField(labelWithString: input.projectName)
    projectLabel.font = NSFont.systemFont(ofSize: Layout.projectFontSize, weight: .bold)
    projectLabel.textColor = Theme.textPrimary
    projectLabel.frame = NSRect(x: Layout.panelMargin, y: yPos,
                                width: Layout.panelWidth - Layout.panelMargin * 2,
                                height: Layout.projectHeight)
    projectLabel.lineBreakMode = .byTruncatingTail
    contentView.addSubview(projectLabel)

    yPos -= Layout.pathHeight
    let pathLabel = NSTextField(labelWithString: input.cwd)
    pathLabel.font = NSFont.systemFont(ofSize: Layout.pathFontSize, weight: .regular)
    pathLabel.textColor = Theme.textSecondary
    pathLabel.frame = NSRect(x: Layout.panelMargin, y: yPos,
                             width: Layout.panelWidth - Layout.panelMargin * 2,
                             height: Layout.pathLineHeight)
    pathLabel.lineBreakMode = .byTruncatingMiddle
    contentView.addSubview(pathLabel)

    yPos -= Layout.sectionGap
    let separator = NSBox(frame: NSRect(x: Layout.panelInset, y: yPos,
                                        width: Layout.panelWidth - Layout.panelInset * 2,
                                        height: Layout.separatorHeight))
    separator.boxType = .separator
    contentView.addSubview(separator)

    return yPos
}

/// Adds the tool tag pill and one-line gist summary label to `contentView`.
///
/// - Parameters:
///   - contentView: The panel's root view.
///   - toolName: The tool name shown in the colored pill.
///   - gist: The short summary displayed beside the pill.
///   - yPos: The Y coordinate immediately below the separator.
/// - Returns: The Y position at the bottom of the tag row.
private func addTagAndGist(to contentView: NSView, toolName: String,
                            gist: String, yPos: CGFloat) -> CGFloat {
    let y = yPos - Layout.sectionGap - Layout.tagButtonHeight

    let tagColor = Theme.tagColor(for: toolName)
    let tagFont  = NSFont.systemFont(ofSize: Layout.tagFontSize, weight: .bold)
    let tagTextW = (toolName as NSString).size(withAttributes: [.font: tagFont]).width
    let tagWidth = tagTextW + Layout.tagTextPadding

    let tagPill = NSButton(frame: NSRect(x: Layout.panelMargin, y: y,
                                         width: tagWidth, height: Layout.tagButtonHeight))
    tagPill.title = toolName
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
    let gistH = gistLabel.frame.height
    gistLabel.frame = NSRect(
        x: Layout.panelMargin + tagWidth + Layout.tagGistGap,
        y: y + (Layout.tagButtonHeight - gistH) / 2,
        width: Layout.panelWidth - Layout.gistTrailingPadding - tagWidth,
        height: gistH
    )
    gistLabel.lineBreakMode = .byTruncatingTail
    contentView.addSubview(gistLabel)

    return y
}

/// Adds the scrollable code block to `contentView` when `content` is non-empty.
///
/// No-ops (returning `yPos` unchanged) when `blockHeight` is zero.
///
/// - Parameters:
///   - contentView: The panel's root view.
///   - content: The attributed string to display.
///   - yPos: The Y coordinate at the bottom of the tag row.
///   - blockHeight: Pre-computed height for the block (0 when there is no content).
/// - Returns: The Y position at the bottom edge of the code block.
private func addCodeBlock(to contentView: NSView, content: NSAttributedString,
                           yPos: CGFloat, blockHeight: CGFloat) -> CGFloat {
    guard blockHeight > 0 else { return yPos }

    let codeBlockBottom = yPos - Layout.codeBlockGap - blockHeight

    let codeContainer = NSView(frame: NSRect(
        x: Layout.panelInset, y: codeBlockBottom,
        width: Layout.panelWidth - Layout.panelInset * 2, height: blockHeight
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

    return codeBlockBottom
}

/// Adds permission buttons in pre-computed rows to `contentView`, wired to `handler`.
///
/// Buttons within each row are stretched to fill the available width equally.
/// The first option's button is registered as the panel's `defaultButtonCell`.
/// Buttons are sorted by tag after insertion so `handler.buttons` index matches option index.
///
/// - Parameters:
///   - contentView: The panel's root view.
///   - panel: The panel, used to set `defaultButtonCell`.
///   - options: Permission options to render as buttons.
///   - buttonRows: Pre-computed row layout (each inner array is a list of indices into `options`).
///   - handler: The `ButtonHandler` that receives button targets.
///   - codeBlockBottom: Y coordinate of the code block's bottom edge; buttons are placed below.
private func addButtonRows(to contentView: NSView, panel: NSPanel, options: [PermOption],
                            buttonRows: [[Int]], handler: ButtonHandler, codeBlockBottom: CGFloat) {
    let availableWidth = Layout.panelWidth - Layout.buttonMargin * 2
    for (rowIndex, row) in buttonRows.enumerated() {
        let rowY = codeBlockBottom - Layout.buttonTopGap - Layout.buttonHeight
            - CGFloat(rowIndex) * (Layout.buttonHeight + Layout.buttonGap)
        let totalGaps = Layout.buttonGap * CGFloat(max(0, row.count - 1))
        let buttonWidth = (availableWidth - totalGaps) / CGFloat(row.count)

        for (col, optionIndex) in row.enumerated() {
            let buttonX = Layout.buttonMargin + CGFloat(col) * (buttonWidth + Layout.buttonGap)
            let option  = options[optionIndex]

            let button = NSButton(frame: NSRect(x: buttonX, y: rowY,
                                                width: buttonWidth, height: Layout.buttonHeight))
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

            if optionIndex == 0 && !option.textInput {
                panel.defaultButtonCell = button.cell as? NSButtonCell
            }
        }
    }
    handler.buttons.sort { $0.tag < $1.tag }
}

// MARK: - AskUserQuestion Wizard

/// Parses the `tool_input` of an `AskUserQuestion` call into typed `WizardQuestion`s.
///
/// Malformed entries (non-dict question entries, non-dict option entries, entries
/// with no `label`) are silently skipped rather than aborting the whole parse —
/// this mirrors the tolerant parsing used elsewhere in the file.
///
/// - Parameter toolInput: The raw `tool_input` dictionary from the hook JSON.
/// - Returns: The parsed questions in their original order. Empty array if the
///   `questions` key is missing or does not contain a list.
func parseWizardQuestions(from toolInput: [String: Any]) -> [WizardQuestion] {
    guard let raw = toolInput["questions"] as? [Any] else { return [] }
    var result: [WizardQuestion] = []
    for item in raw {
        guard let dict = item as? [String: Any] else { continue }
        let header = dict["header"] as? String ?? ""
        let question = dict["question"] as? String ?? ""
        var opts: [WizardOption] = []
        if let rawOpts = dict["options"] as? [Any] {
            for o in rawOpts {
                guard let od = o as? [String: Any],
                      let label = od["label"] as? String, !label.isEmpty
                else { continue }
                let desc = od["description"] as? String ?? ""
                opts.append(WizardOption(label: label, description: desc))
            }
        }
        result.append(WizardQuestion(header: header, question: question, options: opts))
    }
    return result
}

/// Mutable state of a running wizard: the questions, the user's answers,
/// typed-but-not-yet-committed "Other" text per question, and the current step.
///
/// Step numbering:
///  - `0..<questions.count` — a question panel.
///  - `questions.count` — the review panel (only used when `questions.count > 1`).
///
/// The controller owns the only instance and mutates it directly. No internal
/// notifications — the controller re-renders after each mutation.
final class WizardState {
    /// The parsed questions driving the wizard — immutable for the run.
    let questions: [WizardQuestion]
    /// Per-question answer, indexed parallel to `questions`. `nil` = unanswered.
    /// Always `questions.count` entries; established at init and never resized.
    var answers: [WizardAnswer?]
    /// Per-question typed-but-not-committed "Other" text, indexed parallel to
    /// `questions`. Always `questions.count` entries; survives step navigation.
    var pendingCustom: [String]
    /// Current wizard step (see class doc comment for numbering).
    var step: Int = 0

    init(questions: [WizardQuestion]) {
        self.questions = questions
        self.answers = Array(repeating: nil, count: questions.count)
        self.pendingCustom = Array(repeating: "", count: questions.count)
    }

    /// The final step index. For a single-question wizard this is `0`
    /// (no review). For multi-question it is `questions.count` (review panel).
    var lastStep: Int {
        questions.count <= 1 ? 0 : questions.count
    }

    /// True if the current step renders the review panel.
    var isReviewStep: Bool {
        questions.count > 1 && step == questions.count
    }

    /// True if every question has a non-nil answer.
    var allAnswered: Bool {
        answers.allSatisfy { $0 != nil }
    }

    /// Commits a preset-option pick as the answer to the given question.
    /// Does not touch `pendingCustom` — typed Other text is preserved in case
    /// the user changes their mind later.
    func selectPreset(question: Int, optionIndex: Int) {
        guard question >= 0, question < answers.count else { return }
        answers[question] = .preset(index: optionIndex)
    }

    /// Commits a custom free-text answer. An empty string clears the answer
    /// back to nil (so the user cannot submit an all-whitespace Other response).
    func commitCustom(question: Int, text: String) {
        guard question >= 0, question < answers.count else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            answers[question] = nil
        } else {
            answers[question] = .custom(text: text)
        }
    }

    /// Stores typed-but-not-yet-committed text for the Other row of a question.
    /// Survives step navigation so the user does not lose work when going Back.
    func setPending(question: Int, text: String) {
        guard question >= 0, question < pendingCustom.count else { return }
        pendingCustom[question] = text
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
/// - Returns: The `ButtonHandler` containing the selected result and any typed feedback.
private func showPermissionDialog(
    input: HookInput,
    options: [PermOption],
    content: NSAttributedString,
    gist: String,
    buttonRows: [[Int]],
    optionsHeight: CGFloat
) -> ButtonHandler {
    // Calculate code block height
    let screenHeight     = NSScreen.main?.visibleFrame.height ?? Layout.fallbackScreenHeight
    let maxContentHeight = min(Layout.maxCodeBlockHeight, screenHeight * Layout.maxScreenFraction)
    let naturalHeight    = content.length > 0
        ? measureContentHeight(content, width: Layout.panelWidth - Layout.codeContentInset)
        : 0
    let codeBlockHeight  = content.length > 0
        ? max(Layout.minCodeBlockHeight, min(naturalHeight, maxContentHeight))
        : CGFloat(0)
    let panelHeight = Layout.fixedChrome + codeBlockHeight + optionsHeight

    // Build panel and content view
    let panel = makePermissionPanel(height: panelHeight)
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: Layout.panelWidth, height: panelHeight))
    contentView.wantsLayer = true
    contentView.layer?.backgroundColor = Theme.background.cgColor
    panel.contentView = contentView

    // Lay out UI sections top-down
    let afterHeader      = addHeader(to: contentView, input: input, panelHeight: panelHeight)
    let afterTag         = addTagAndGist(to: contentView, toolName: input.displayName,
                                         gist: gist, yPos: afterHeader)
    let codeBlockBottom  = addCodeBlock(to: contentView, content: content,
                                        yPos: afterTag, blockHeight: codeBlockHeight)

    // Buttons
    let handler = ButtonHandler(options: options)
    addButtonRows(to: contentView, panel: panel, options: options,
                  buttonRows: buttonRows, handler: handler, codeBlockBottom: codeBlockBottom)

    // Keyboard shortcuts: 1–N select options, Enter accepts, Esc rejects
    // When text input is active, let the text field handle all keys.
    let keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        if handler.textInputActive { return event }
        let key = event.charactersIgnoringModifiers ?? ""
        if let num = Int(key), num >= 1, num <= options.count {
            handler.animatePress(index: num - 1); return nil
        }
        if key == "\r"     { handler.directPress(index: 0);                return nil }
        if key == "\u{1b}" { handler.directPress(index: options.count - 1); return nil }
        return event
    }

    // Timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + Layout.dialogTimeout) {
        handler.result = "deny"
        NSApp.stopModal()
    }

    // Re-activate on Space switch
    let spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification,
        object: nil, queue: .main
    ) { _ in if panel.isVisible { activatePanel(panel) } }

    // SIGUSR1: sibling dialog dismissed, re-activate
    signal(SIGUSR1, SIG_IGN)
    let signalSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    signalSource.setEventHandler {
        if panel.isVisible { activatePanel(panel); panel.display() }
    }
    signalSource.resume()

    defer {
        panel.orderOut(nil)
        NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        signalSource.cancel()
        if let monitor = keyboardMonitor { NSEvent.removeMonitor(monitor) }
    }
    activatePanel(panel)
    NSApp.runModal(for: panel)

    return handler
}

// MARK: - Result Processing

/// Processes the dialog result and persists the user's approval choice.
///
/// Handles session-level and project-level persistence based on the selected option.
///
/// - Parameters:
///   - handler: The `ButtonHandler` containing the selected result and feedback text.
///   - input: The parsed hook input for persistence (session file, project settings).
/// - Returns: A tuple of the hook decision (`"allow"` or `"deny"`) and a reason string.
func processResult(handler: ButtonHandler, input: HookInput) -> (decision: String, reason: String) {
    let resultKey = handler.result
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

    case "dont_ask_mcp_server":
        let rule = "mcp__\(input.mcpServer)__*"
        saveToLocalSettings(input: input, rule: rule)
        return ("allow", "Allowed all \(input.mcpServer) MCP tools for project")

    case "allow_goto_terminal":
        openTerminalApp(cwd: input.cwd, sessionId: input.sessionId)
        return ("allow", "Allowed — terminal activated for user input")

    case "deny":
        let reason = handler.feedbackText.isEmpty ? "Rejected via dialog" : handler.feedbackText
        return ("deny", reason)

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

private func approveMain() {
    let input = parseHookInput()

    // Fast path: deny immediately if stdin was empty or missing tool_name
    if input.toolName.isEmpty {
        writeHookResponse(decision: "deny", reason: "Invalid or missing hook input")
        exit(0)
    }

    // Fast path: honor --dangerously-skip-permissions (but not for user-input tools)
    if input.permissionMode == "bypassPermissions" && input.toolName != "AskUserQuestion" {
        writeHookResponse(decision: "allow", reason: "Permissions bypassed (--dangerously-skip-permissions)")
        exit(0)
    }

    // Fast path: Claude settings files are auto-approved — Claude Code's own
    // terminal prompt handles the confirmation for these edits.
    if input.isClaudeSettings {
        writeHookResponse(decision: "allow", reason: "Auto-approved (Claude settings — terminal confirms)")
        exit(0)
    }

    // Fast path: acceptEdits mode auto-approves file operations
    // Edit/Write are the explicit grant; read-only tools (Read, Glob, Grep, NotebookEdit)
    // are also auto-approved since accepting edits implies accepting reads.
    if input.permissionMode == "acceptEdits" {
        let acceptEditsTools: Set<String> = ["Edit", "Write", "Read", "Glob", "Grep", "NotebookEdit"]
        if acceptEditsTools.contains(input.toolName) {
            writeHookResponse(decision: "allow", reason: "Auto-approved (acceptEdits mode)")
            exit(0)
        }
    }

    // Fast path: plan mode denies all write/execute tools
    if input.permissionMode == "plan" {
        let readOnlyTools: Set<String> = ["Read", "Glob", "Grep", "WebFetch", "WebSearch", "AskUserQuestion"]
        if !readOnlyTools.contains(input.toolName) && !input.isMCP {
            writeHookResponse(decision: "deny", reason: "Denied (plan mode — read-only)")
            exit(0)
        }
    }

    // Fast path: dontAsk mode denies tools unless pre-approved via settings or session
    // (falls through to the checkAlwaysApprove/checkSessionAutoApprove checks below,
    //  and denies if neither applies)

    // Fast path: skip dialog if tool is in the persistent always-approve list
    if checkAlwaysApprove(input: input) {
        exit(0)
    }

    // Fast path: skip dialog if tool matches a project-level allow rule
    if checkProjectSettings(input: input) {
        exit(0)
    }

    // Fast path: skip dialog if tool is already approved for this session
    if checkSessionAutoApprove(input: input) {
        exit(0)
    }

    // dontAsk mode: deny anything that wasn't caught by the pre-approve checks above
    if input.permissionMode == "dontAsk" && input.toolName != "AskUserQuestion" {
        writeHookResponse(decision: "deny", reason: "Denied (dontAsk mode — not pre-approved)")
        exit(0)
    }

    // Capture terminal/IDE before activating our own UI
    capturedTerminalApp = NSWorkspace.shared.frontmostApplication

    // Initialize headless NSApplication (no Dock icon)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    installEditMenu()
    NSSound(named: "Funk")?.play()

    // Build dialog data
    let permOptions = buildPermOptions(input: input)
    let contentAttr = buildContent(input: input)
    let gist = buildGist(input: input)
    let (buttonRows, optionsHeight) = computeButtonRows(options: permOptions)

    // Show dialog and get user's choice
    let handler = showPermissionDialog(
        input: input,
        options: permOptions,
        content: contentAttr,
        gist: gist,
        buttonRows: buttonRows,
        optionsHeight: optionsHeight
    )

    // Process result: persist approvals and write response immediately
    let (decision, reason) = processResult(handler: handler, input: input)
    writeHookResponse(decision: decision, reason: reason)

    // Signal next sibling AFTER response is delivered to Claude Code
    notifyNextSiblingDialog()

    exit(0)
}

#if !TESTING
@main
enum ApproveEntry {
    static func main() {
        approveMain()
    }
}
#endif
