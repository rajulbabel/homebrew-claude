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
    /// True when the question accepts more than one selection. Defaults to
    /// false; mirrors the optional `multiSelect` field in the tool input.
    let multiSelect: Bool
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
    /// Multi-select answer: any subset of preset indices, plus an optional
    /// custom string. The empty `presets` set with `custom = nil` is *not*
    /// a valid stored answer (state methods normalise that back to `nil`).
    case multi(presets: Set<Int>, custom: String?)
}

/// Visual style for an option row's left-edge indicator.
///
/// - `radio`: filled circle (single-select). Existing behaviour.
/// - `checkbox`: rounded square with a check glyph (multi-select).
enum WizardIndicatorStyle {
    case radio
    case checkbox
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

    // Wizard — disabled button state
    static let wizardButtonDisabledBg      = NSColor(calibratedWhite: 1.0, alpha: 0.10)
    static let wizardButtonDisabledBorder  = NSColor(calibratedWhite: 1.0, alpha: 0.12)
    static let wizardButtonDisabledText    = NSColor(calibratedWhite: 0.45, alpha: 1.0)

    // Wizard — neutral button
    /// Neutral (non-accented) button fill/border — used for Back and Ok, which
    /// must be visually distinct from the blue primary button on the same row.
    static let wizardNeutralFillRest   = NSColor(calibratedWhite: 1.0, alpha: 0.06)
    static let wizardNeutralBorderRest = NSColor(calibratedWhite: 1.0, alpha: 0.18)
    /// Press-state fill for neutral (Back, Ok) wizard footer buttons. Alpha
    /// is picked to match the perceived brightness of the colored primary
    /// (Submit / Go to Terminal) buttons' press flash — the lower-alpha
    /// neutral fill doesn't brighten as visibly against the dark panel as
    /// the saturated blue / green fills do, so we compensate here.
    static let wizardNeutralFillPress  = NSColor(calibratedWhite: 1.0, alpha: 0.42)

    /// Hairline color used for dividers between the session-identity block
    /// and the tag-pill row in every dialog. Subtle on dark mode panels.
    static let wizardDivider           = NSColor(calibratedWhite: 1.0, alpha: 0.10)

    // Wizard — option row. Selected tints derive from `buttonAllow` so the
    // radio/card highlight stays in sync if the allow green is ever retuned.
    static let wizardRowBg                 = NSColor(calibratedWhite: 1.0, alpha: 0.03)
    static let wizardRowBorder             = NSColor(calibratedWhite: 1.0, alpha: 0.08)
    static let wizardRowSelectedBg         = buttonAllow.withAlphaComponent(0.14)
    static let wizardRowSelectedBorder     = buttonAllow.withAlphaComponent(0.55)
    /// Outline used on the keyboard-focused row of a multi-select page.
    /// Painted on top of the normal row border so the user can see which row
    /// `↑`/`↓` and `Space` are pointing at.
    static let wizardRowFocusBorder = NSColor(calibratedRed: 0.36, green: 0.52, blue: 0.90, alpha: 0.85)
    /// Color painted inside the filled radio to produce the ring hole.
    /// Aliases `background` so the hole stays flush with the panel.
    static let wizardRadioInnerGap         = background

    // Wizard — progress dots
    static let wizardProgressActive        = buttonAllow
    static let wizardProgressInactive      = NSColor(calibratedWhite: 1.0, alpha: 0.18)

    // Wizard — typography
    static let wizardQuestionFont          = NSFont.systemFont(ofSize: 13.5, weight: .medium)
    static let wizardLabelFont             = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let wizardDescFont              = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let wizardOtherTextFont         = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let wizardIndexFont             = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    // Shared wizard header/pill/footer typography.
    static let wizardHeaderTagFont         = NSFont.systemFont(ofSize: 11, weight: .bold)
    static let wizardHeaderCounterFont     = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let wizardPillFont              = NSFont.systemFont(ofSize: 10.5, weight: .bold)
    static let wizardReviewPillFont        = NSFont.systemFont(ofSize: 9.5, weight: .bold)
    static let wizardReviewTitleFont       = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let wizardReviewRowQuestionFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let wizardReviewRowAnswerFont   = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let wizardReviewEditFont        = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    static let wizardFooterButtonFont      = NSFont.systemFont(ofSize: 12, weight: .semibold)

    /// Accent color for the wizard's top-of-panel "ASKUSERQUESTION" tag.
    /// Lavender — distinct from the per-tool pill colors so the inquiry dialog
    /// has its own identity within the shared visual family.
    static let wizardHeaderAccent = NSColor(calibratedRed: 0.655, green: 0.545, blue: 0.980, alpha: 1.0)
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

    // Wizard — panel regions
    static let wizardHeaderHeight: CGFloat = 26
    static let wizardFooterHeight: CGFloat = 56
    static let wizardBodyPaddingH: CGFloat = 14
    static let wizardBodyPaddingV: CGFloat = 6
    static let wizardBodyBottomPadding: CGFloat = 12

    // Wizard — option row
    static let wizardRowHeightMin: CGFloat = 44
    static let wizardRowGap: CGFloat = 6
    static let wizardRowPaddingH: CGFloat = 12
    static let wizardRowPaddingV: CGFloat = 10
    static let wizardRowCornerRadius: CGFloat = 8
    static let wizardRowFocusBorderWidth: CGFloat = 2
    static let wizardRadioSize: CGFloat = 14
    static let wizardRadioInnerRing: CGFloat = 2.5
    static let wizardRadioBorderWidth: CGFloat = 2
    static let wizardRadioGap: CGFloat = 10
    // Wizard — checkbox indicator (multi-select). Same outer footprint as the
    // radio so the row never reflows when the style flips.
    static let wizardCheckboxCornerRadius: CGFloat = 3
    static let wizardCheckmarkInsetX: CGFloat = 2
    static let wizardCheckmarkLowY: CGFloat = 4
    static let wizardCheckmarkPeakX: CGFloat = 6
    static let wizardCheckmarkPeakY: CGFloat = 7
    static let wizardCheckmarkHighX: CGFloat = 11
    static let wizardCheckmarkHighY: CGFloat = 2
    static let wizardCheckmarkLineWidth: CGFloat = 2
    // Baselines for the label + description stack inside a row (bottom-origin Y).
    static let wizardRowLabelY: CGFloat = 21
    static let wizardRowLabelHeight: CGFloat = 16
    static let wizardRowDescY: CGFloat = 5
    static let wizardRowDescHeight: CGFloat = 14
    static let wizardRowIndexWidth: CGFloat = 16
    static let wizardRowIndexHeight: CGFloat = 14

    // Wizard — progress dots
    static let wizardProgressDotWidth: CGFloat = 22
    static let wizardProgressDotHeight: CGFloat = 3
    static let wizardProgressDotGap: CGFloat = 6
    static let wizardProgressTopPadding: CGFloat = 12

    // Wizard — panel shell
    /// Initial panel height before `resizePanelToFit` swaps in the measured content height.
    static let wizardInitialPanelHeight: CGFloat = 400
    /// Fraction of visible-frame height at which to place the panel's top (0.5 = center, 0.55 = slightly above).
    static let wizardVerticalBias: CGFloat = 0.55
    static let wizardPanelCornerRadius: CGFloat = 10

    // Wizard — header labels and step counter
    static let wizardHeaderLabelHeight: CGFloat = 16
    static let wizardHeaderLabelY: CGFloat = 5
    static let wizardHeaderTagWidth: CGFloat = 180
    static let wizardHeaderReviewTagWidth: CGFloat = 260
    static let wizardHeaderCounterWidth: CGFloat = 100
    static let wizardHeaderReviewCounterWidth: CGFloat = 180

    // Wizard — body block heights and gaps
    static let wizardPillHeight: CGFloat = 18
    static let wizardPillHPadding: CGFloat = 16
    static let wizardReviewPillHeight: CGFloat = 16
    static let wizardReviewPillHPadding: CGFloat = 14
    static let wizardBodyGapAfterPill: CGFloat = 6
    static let wizardBodyGapAfterQuestion: CGFloat = 10
    static let wizardReviewTitleHeight: CGFloat = 18
    static let wizardReviewRowHeight: CGFloat = 60
    static let wizardReviewRowSpacing: CGFloat = 8

    // Wizard — footer
    static let wizardFooterGap: CGFloat = 8
    static let wizardFooterButtonHeight: CGFloat = 36
    static let wizardFooterSideButtonWidth: CGFloat = 82
    /// Footer inner rows (2 stacked rows of 2 buttons each in the new layout).
    static let wizardFooterRowGap: CGFloat = 6
    /// Vertical padding at the top and bottom of the two-row footer.
    static let wizardFooterVerticalPadding: CGFloat = 10
    /// Total footer height = 2 rows × buttonHeight + rowGap + top/bottom padding.
    /// Replaces the single-row footer height used previously.
    static let wizardFooterTwoRowHeight: CGFloat =
        wizardFooterButtonHeight * 2 + wizardFooterRowGap
        + wizardFooterVerticalPadding * 2

    // Wizard — Other row text area
    static let wizardOtherMinHeight: CGFloat = 20
    static let wizardOtherMaxHeight: CGFloat = 140
    static let wizardOtherCaretWidth: CGFloat = 1.5
    static let wizardOtherCaretHeight: CGFloat = 12
    /// Other row height when the text field is active. Large enough for 3-4
    /// lines; additional text scrolls inside the scroll view.
    static let wizardOtherActiveRowHeight: CGFloat = 96
    static let wizardOtherActivePaddingV: CGFloat = 10

    /// Spacing breakdown for fixed chrome (everything except code block and buttons).
    static let fixedChrome: CGFloat = panelTopPadding + projectHeight + pathHeight
        + sectionGap + separatorHeight + sectionGap + tagButtonHeight + codeBlockGap
        + sectionGap + panelBottomPadding
}

// MARK: - Labels

/// Wizard footer button labels, matched verbatim to Claude Code CLI / Desktop
/// conventions. Single source of truth — never inline these strings elsewhere
/// so a future wording change touches this file only.
enum WizardLabels {
    static let back                    = "Back"
    static let next                    = "Next"
    static let submit                  = "Submit Answers"
    /// Suffix appended to the primary button on multi-select pages.
    /// `String(format: WizardLabels.submitMultiTail, count)` → ` · 3 Selected`.
    static let submitMultiTail         = " · %d Selected"
    static let terminal                = "Go to Terminal"
    static let terminalForClaudeDesktop = "Go to Claude Desktop"
    static let ok                      = "Ok"
}

/// Cached terminal button label. Parent-app detection requires a `ps` fork,
/// so we resolve once per process and reuse across every footer render.
private var cachedTerminalButtonLabel: String?

/// Returns the label for the "go to parent app" footer button, adapted to
/// the detected parent. Falls back to the terminal wording when the parent
/// can't be identified or is a genuine terminal emulator. Memoized per
/// process since the parent app does not change during a hook invocation.
func terminalButtonLabel() -> String {
    if let cached = cachedTerminalButtonLabel { return cached }
    let (_, parentApp) = resolveProcessAncestry()
    let app = parentApp ?? capturedTerminalApp
    let label: String
    if app?.bundleIdentifier == "com.anthropic.claudefordesktop" {
        label = WizardLabels.terminalForClaudeDesktop
    } else {
        label = WizardLabels.terminal
    }
    cachedTerminalButtonLabel = label
    return label
}

/// Permission-dialog labels that are tool-independent. Tool-dependent
/// labels (like "Yes, and don't ask again for `cd` *") stay generated
/// inside `buildPermOptions` where they can parameterize on tool/cmd/domain.
enum PermissionLabels {
    static let allowOnce                = "Yes"
    static let denyWithFeedbackFallback = "No, and tell Claude what to do differently"
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
    writeHookResponse(decision: decision, reason: reason, updatedInput: nil)
}

/// Emits the hook response with an optional `updatedInput` block. When
/// non-nil, Claude Code replaces the tool's input with the provided object
/// before running the tool. Used by the AskUserQuestion wizard to inject
/// the user's answers into the tool's `answers` field, so the tool sees
/// them as already-collected and skips its own native prompt.
func writeHookResponse(decision: String, reason: String, updatedInput: [String: Any]?) {
    var hookOut: [String: Any] = [
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason,
    ]
    if let updatedInput = updatedInput {
        hookOut["updatedInput"] = updatedInput
    }
    let response: [String: Any] = ["hookSpecificOutput": hookOut]
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

/// Keeps `panel` as the key window across every scenario that can cause it
/// to lose focus: Space switches, app re-foregrounding, screen wake, and the
/// initial-present settle. Returns a cleanup closure the caller invokes from
/// a `defer { }` when the dialog is torn down.
///
/// Each observer asyncs to the next main-loop tick before re-activating so
/// the window-server finishes its own transition first. If the panel is
/// already not-visible, the async block early-exits.
///
/// `didResignKeyNotification` is intentionally NOT observed — re-taking key
/// immediately when the user clicks elsewhere would fight legitimate user
/// intent. Focus returns on the next refocus event (app re-active, space
/// change, etc.).
func installFocusRecoveryObservers(on panel: NSPanel) -> () -> Void {
    let workspaceCenter = NSWorkspace.shared.notificationCenter
    let appCenter = NotificationCenter.default

    let reactivate: () -> Void = { [weak panel] in
        DispatchQueue.main.async {
            guard let p = panel, p.isVisible else { return }
            activatePanel(p)
        }
    }

    let spaceObs = workspaceCenter.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification,
        object: nil, queue: .main
    ) { _ in reactivate() }

    let appActiveObs = appCenter.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil, queue: .main
    ) { _ in reactivate() }

    let screenWakeObs = workspaceCenter.addObserver(
        forName: NSWorkspace.screensDidWakeNotification,
        object: nil, queue: .main
    ) { _ in reactivate() }

    let windowKeyObs = appCenter.addObserver(
        forName: NSWindow.didBecomeKeyNotification,
        object: panel, queue: .main
    ) { _ in /* no-op; used only to hold a strong ref until cleanup */ }

    // Initial-present settle: if the first orderFront didn't pick up key,
    // try once more after a short delay.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak panel] in
        guard let p = panel, p.isVisible, !p.isKeyWindow else { return }
        activatePanel(p)
    }

    return {
        workspaceCenter.removeObserver(spaceObs)
        workspaceCenter.removeObserver(screenWakeObs)
        appCenter.removeObserver(appActiveObs)
        appCenter.removeObserver(windowKeyObs)
    }
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

// MARK: - Button Animation

/// Plays a subtle press-in / release animation on any layer-backed button.
/// Used by every dialog's button press path (mouse click and keyboard
/// shortcut) so the two feel identical. Pure visual; does not alter target/
/// action or any behavior.
///
/// - Parameters:
///   - button: The NSButton (or any NSView) to animate. Must be layer-backed.
///   - restFillColor: Fill color to return to after the release phase; pass nil
///     to keep whatever fill the caller sets afterwards.
func animateButtonPress(_ button: NSView, restFillColor: NSColor? = nil) {
    guard let layer = button.layer else { return }

    // Press-in: scale to 0.96, brighten fill slightly.
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.06)
    CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
    let press = CABasicAnimation(keyPath: "transform.scale")
    press.fromValue = 1.0
    press.toValue   = 0.96
    press.duration  = 0.06
    press.fillMode  = .forwards
    press.isRemovedOnCompletion = false
    layer.add(press, forKey: "wizardPressIn")
    CATransaction.commit()

    // Release: scale back to 1.0 over 120 ms, ease-out.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        let release = CABasicAnimation(keyPath: "transform.scale")
        release.fromValue = 0.96
        release.toValue   = 1.0
        release.duration  = 0.12
        release.fillMode  = .forwards
        release.isRemovedOnCompletion = false
        layer.add(release, forKey: "wizardPressOut")
        if let rest = restFillColor {
            layer.backgroundColor = rest.cgColor
        }
        CATransaction.commit()
    }
}

// MARK: - Button Handler

/// Manages button press state, text input morphing, and dialog dismissal.
///
/// Tracks which option the user selected via `result`, prevents double-press via `pressing`,
/// and drives both click and keyboard-shortcut code paths through `animatePress(index:)`.
/// When the deny button (with `textInput`) is clicked, it morphs into an inline text field.
final class ButtonHandler: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
    let options: [PermOption]
    /// The `resultKey` of the selected `PermOption`. Defaults to `"deny"` (safe fallback).
    var result: String = "deny"
    /// User-typed feedback text from the deny text field (empty if none typed).
    var feedbackText: String = ""
    var buttons: [NSButton] = []
    private var pressing = false
    var textInputActive = false
    // Held onto so submitTextInput can read the typed string. Swapped from
    // NSTextField to NSTextView + NSScrollView to support Shift+Return newlines.
    private var activeTextView: NSTextView?

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
        animateButtonPress(button)
        button.display()
        DispatchQueue.main.asyncAfter(deadline: .now() + Layout.pressAnimationDelay) {
            NSApp.stopModal()
        }
    }

    /// Morphs the deny button into a text field + Send button.
    private func morphToTextField(index: Int) {
        guard !pressing, index >= 0, index < buttons.count else { return }
        let button = buttons[index]
        let option = options[index]
        guard let superview = button.superview else { return }

        let frame = button.frame
        let tint = option.color

        let container = NSView(frame: frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = Layout.buttonCornerRadius
        container.layer?.backgroundColor = Theme.morphInputBg.cgColor
        container.layer?.borderColor = tint.withAlphaComponent(0.45).cgColor
        container.layer?.borderWidth = 1
        container.alphaValue = 0
        superview.addSubview(container)

        // Send button pinned to the right edge.
        let sendW = Layout.morphSendWidth
        let sendH = Layout.morphSendHeight
        let sendMargin = Layout.morphSendMargin
        let sendBtn = NSButton(frame: NSRect(
            x: frame.width - sendW - sendMargin,
            y: (frame.height - sendH) / 2,
            width: sendW, height: sendH))
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

        // Multi-line text view inside a scroll view. Mirrors WizardOtherRow.
        let leftPad = Layout.morphTextPaddingLeft
        let rightPad = sendW + sendMargin * 2

        let textContainer = NSTextContainer(size: NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        manager.addTextContainer(textContainer)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = Theme.morphInputFont
        textView.textColor = Theme.morphText
        textView.insertionPointColor = tint
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.identifier = NSUserInterfaceItemIdentifier(String(index))

        let scrollHeight = frame.height - 8
        let scrollView = NSScrollView(frame: NSRect(
            x: leftPad, y: 4,
            width: frame.width - leftPad - rightPad, height: scrollHeight))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        // Placeholder label — hidden once typing starts.
        let placeholder = NSTextField(labelWithString: option.placeholder)
        placeholder.font = Theme.morphInputFont
        placeholder.textColor = Theme.morphPlaceholder
        placeholder.frame = NSRect(
            x: leftPad, y: (frame.height - 14) / 2,
            width: frame.width - leftPad - rightPad, height: 14)
        placeholder.identifier = NSUserInterfaceItemIdentifier("morph-placeholder")
        container.addSubview(placeholder)
        container.addSubview(scrollView)

        activeTextView = textView

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            button.animator().alphaValue = 0
            container.animator().alphaValue = 1
        }, completionHandler: {
            button.isHidden = true
            superview.window?.makeFirstResponder(textView)
        })
    }

    private func submitTextInput(index: Int) {
        guard index >= 0, index < options.count else { return }
        pressing = true
        result = options[index].resultKey
        feedbackText = activeTextView?.string ?? ""
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

    // NSTextViewDelegate — handles commands from the morphed multi-line input.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            if shift {
                textView.insertText("\n", replacementRange: textView.selectedRange())
            } else {
                let idx = Int(textView.identifier?.rawValue ?? "") ?? 0
                submitTextInput(index: idx)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.insertLineBreak(_:)) ||
           commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            pressing = true
            let idx = Int(textView.identifier?.rawValue ?? "") ?? 0
            result = options[idx].resultKey
            feedbackText = ""
            NSApp.stopModal()
            return true
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = activeTextView, let container = tv.enclosingScrollView?.superview else { return }
        if let placeholder = container.subviews.first(where: {
            $0.identifier == NSUserInterfaceItemIdentifier("morph-placeholder")
        }) {
            placeholder.isHidden = !tv.string.isEmpty
        }
        tv.scrollRangeToVisible(tv.selectedRange())
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
        animateButtonPress(button)
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
    // Borderless rounded chrome — same shell the wizard uses so the three
    // dialogs share a silhouette. WizardPanel subclass is required because
    // a hidden-titlebar panel otherwise refuses to become key, which blocks
    // keyboard shortcuts.
    let panel = WizardPanel(
        contentRect: NSRect(x: 0, y: 0, width: Layout.panelWidth, height: height),
        styleMask:   [.titled, .nonactivatingPanel, .fullSizeContentView],
        backing:     .buffered, defer: false
    )
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.backgroundColor = Theme.background
    panel.isOpaque = false
    panel.hasShadow = true
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.standardWindowButton(.closeButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.contentView?.wantsLayer = true
    panel.contentView?.layer?.cornerRadius = Layout.wizardPanelCornerRadius
    panel.contentView?.layer?.masksToBounds = true
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
    // Hairline separator (matches the wizard body divider).
    let separator = NSView(frame: NSRect(x: Layout.panelInset, y: yPos,
                                         width: Layout.panelWidth - Layout.panelInset * 2,
                                         height: Layout.separatorHeight))
    separator.wantsLayer = true
    separator.layer?.backgroundColor = Theme.wizardDivider.cgColor
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
    codeContainer.layer?.cornerRadius = Layout.wizardRowCornerRadius
    codeContainer.layer?.backgroundColor = Theme.wizardRowBg.cgColor
    codeContainer.layer?.borderColor = Theme.wizardRowBorder.cgColor
    codeContainer.layer?.borderWidth = 1
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
            applyUnifiedButtonSkin(button, tint: option.color, isDeny: option.resultKey == "deny")
            addKeyboardBadge(to: button, number: optionIndex + 1, tint: option.color)

            if optionIndex == 0 && !option.textInput {
                panel.defaultButtonCell = button.cell as? NSButtonCell
            }
        }
    }
    handler.buttons.sort { $0.tag < $1.tag }
}

/// Applies the unified wizard button skin to an NSButton whose frame has
/// already been set. Only the visual attributes (corner radius, fill,
/// border, font) change — frame, target, action, tag are untouched.
private func applyUnifiedButtonSkin(_ button: NSButton,
                                    tint: NSColor,
                                    isDeny: Bool = false)
{
    button.isBordered = false
    button.bezelStyle = .rounded
    button.wantsLayer = true
    button.layer?.cornerRadius = Layout.wizardRowCornerRadius
    button.layer?.borderWidth = 1
    let fillAlpha:   CGFloat = isDeny ? 0.12 : 0.22
    let borderAlpha: CGFloat = isDeny ? 0.40 : 0.55
    button.layer?.backgroundColor = tint.withAlphaComponent(fillAlpha).cgColor
    button.layer?.borderColor     = tint.withAlphaComponent(borderAlpha).cgColor
    button.attributedTitle = NSAttributedString(string: button.title, attributes: [
        .font: Theme.wizardFooterButtonFont,
        .foregroundColor: Theme.textPrimary,
        .paragraphStyle: {
            let ps = NSMutableParagraphStyle()
            ps.alignment = .center
            return ps
        }(),
    ])
    button.contentTintColor = Theme.textPrimary
}

/// Adds a 1-based keyboard-shortcut numeral to the left edge of a button,
/// vertically centered. The badge is a child NSTextField inside the button
/// so it moves with any window-resize. Uses the button's tint for color.
private func addKeyboardBadge(to button: NSButton, number: Int, tint: NSColor) {
    let badge = NSTextField(labelWithString: "\(number)")
    badge.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    badge.textColor = tint.withAlphaComponent(0.85)
    badge.backgroundColor = .clear
    badge.isBordered = false
    badge.isEditable = false
    badge.alignment = .center
    let size = badge.intrinsicContentSize
    let x: CGFloat = 10
    let y = (button.frame.height - size.height) / 2
    badge.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    button.addSubview(badge)
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
        let multi = dict["multiSelect"] as? Bool ?? false
        result.append(WizardQuestion(
            header: header, question: question,
            options: opts, multiSelect: multi))
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
        answers.allSatisfy { a in
            switch a {
            case .none: return false
            case .some(.preset), .some(.custom): return true
            case .some(.multi(let p, let c)):
                return p.count + (c == nil ? 0 : 1) >= 1
            }
        }
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

    /// Multi-select: flips `optionIndex` in the answer's preset set. Creates
    /// the answer if needed; normalises an emptied answer back to `nil`.
    func togglePreset(question: Int, optionIndex: Int) {
        guard question >= 0, question < answers.count else { return }
        var presets: Set<Int> = []
        var custom: String? = nil
        if case .multi(let p, let c) = answers[question] {
            presets = p
            custom = c
        }
        if presets.contains(optionIndex) {
            presets.remove(optionIndex)
        } else {
            presets.insert(optionIndex)
        }
        answers[question] = (presets.isEmpty && custom == nil)
            ? nil
            : .multi(presets: presets, custom: custom)
    }

    /// Multi-select: ticks or unticks the Other inclusion. Ticking with an
    /// empty pending string is a no-op (matches the auto-tick contract).
    func toggleCustom(question: Int, on: Bool) {
        guard question >= 0, question < answers.count else { return }
        var presets: Set<Int> = []
        if case .multi(let p, _) = answers[question] { presets = p }
        if on {
            let trimmed = pendingCustom[question]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            answers[question] = .multi(presets: presets, custom: pendingCustom[question])
        } else {
            answers[question] = presets.isEmpty
                ? nil
                : .multi(presets: presets, custom: nil)
        }
    }

    /// Multi-select: every keystroke in the Other text view routes here.
    /// Updates `pendingCustom`; if Other is currently ticked, updates the
    /// `.multi.custom` value in place. Empty (or all-whitespace) text on a
    /// previously-ticked Other unticks the box. Auto-ticks on first non-empty
    /// keystroke when no custom answer was set.
    func setMultiCustomText(question: Int, text: String) {
        guard question >= 0, question < answers.count else { return }
        pendingCustom[question] = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var presets: Set<Int> = []
        var custom: String? = nil
        if case .multi(let p, let c) = answers[question] {
            presets = p
            custom = c
        }
        if custom != nil {
            if trimmed.isEmpty {
                answers[question] = presets.isEmpty
                    ? nil
                    : .multi(presets: presets, custom: nil)
            } else {
                answers[question] = .multi(presets: presets, custom: text)
            }
        } else if !trimmed.isEmpty {
            answers[question] = .multi(presets: presets, custom: text)
        }
    }
}

/// Builds the `permissionDecisionReason` string that Claude reads as feedback
/// when the user submits answers via the wizard.
///
/// Layout (one block per question, separated by a blank line):
/// ```
///   1. [HEADER] Question text?
///      → answer line (option label — description, OR custom text)
/// ```
/// Multi-line custom answers preserve their newlines; continuation lines are
/// indented five spaces so they align under the content after `→`.
///
/// Unanswered questions render `→ (no answer)` — should not normally occur
/// because Submit is disabled until all answers are present, but the safety
/// branch keeps the output unambiguous if a submission ever happens anyway.
///
/// Out-of-range preset indices (upstream invariant violation) render as
/// `→ (invalid option)` rather than crashing the hook.
/// Builds the `answers` dictionary that AskUserQuestion's tool input accepts
/// when the permission component has pre-collected answers. Keyed by the
/// original question text (the schema's contract), value is the plain answer
/// string the user picked or typed. The tool reads this and skips its own
/// native prompt, so the model sees the answers as a normal tool result.
func buildWizardAnswersDict(state: WizardState) -> [String: String] {
    var dict: [String: String] = [:]
    for (i, q) in state.questions.enumerated() {
        switch state.answers[i] {
        case .preset(let idx):
            if idx >= 0, idx < q.options.count {
                dict[q.question] = q.options[idx].label
            }
        case .custom(let text):
            dict[q.question] = text
        case .multi(let presets, let custom):
            var parts: [String] = []
            for idx in presets.sorted() where idx < q.options.count {
                parts.append(q.options[idx].label)
            }
            if let c = custom, !c.isEmpty {
                parts.append(c)
            }
            if !parts.isEmpty {
                dict[q.question] = parts.joined(separator: ", ")
            }
        case .none:
            continue
        }
    }
    return dict
}

func formatWizardAnswers(state: WizardState) -> String {
    var lines: [String] = ["User answered inline via dialog:", ""]
    for (i, q) in state.questions.enumerated() {
        let headerPart = q.header.isEmpty ? "" : "[\(q.header)] "
        lines.append("\(i + 1). \(headerPart)\(q.question)")
        switch state.answers[i] {
        case .preset(let idx):
            if idx >= 0, idx < q.options.count {
                let opt = q.options[idx]
                let suffix = opt.description.isEmpty ? "" : " — \(opt.description)"
                lines.append("   → \(opt.label)\(suffix)")
            } else {
                lines.append("   → (invalid option)")
            }
        case .custom(let text):
            let parts = text.components(separatedBy: "\n")
            lines.append("   → \(parts[0])")
            for cont in parts.dropFirst() {
                lines.append("     \(cont)")
            }
        case .multi(let presets, let custom):
            if presets.isEmpty && (custom?.isEmpty ?? true) {
                lines.append("   → (no selection)")
                break
            }
            for idx in presets.sorted() where idx < q.options.count {
                let opt = q.options[idx]
                let suffix = opt.description.isEmpty ? "" : " — \(opt.description)"
                lines.append("   → \(opt.label)\(suffix)")
            }
            if let c = custom, !c.isEmpty {
                let parts = c.components(separatedBy: "\n")
                lines.append("   → (custom) \(parts[0])")
                for cont in parts.dropFirst() {
                    lines.append("     \(cont)")
                }
            }
        case .none:
            lines.append("   → (no answer)")
        }
        lines.append("")
    }
    // Drop trailing blank line
    if lines.last == "" { lines.removeLast() }
    return lines.joined(separator: "\n")
}

/// Renders the left-edge indicator (radio circle or checkbox square) into the
/// given square frame. Frame width/height must equal `Layout.wizardRadioSize`
/// so radio and checkbox occupy the same footprint.
///
/// - Parameters:
///   - frame: target frame inside the row, in row-local coordinates.
///   - selected: whether the indicator should render in the filled/checked state.
///   - style: `.radio` for single-select, `.checkbox` for multi-select.
/// - Returns: an `NSView` ready to be added to the row container.
func drawWizardIndicator(frame: NSRect, selected: Bool, style: WizardIndicatorStyle) -> NSView {
    let v = NSView(frame: frame)
    v.wantsLayer = true
    v.layer?.borderWidth = Layout.wizardRadioBorderWidth
    switch style {
    case .radio:
        v.layer?.cornerRadius = Layout.wizardRadioSize / 2
        if selected {
            v.layer?.borderColor = Theme.buttonAllow.cgColor
            v.layer?.backgroundColor = Theme.buttonAllow.cgColor
            let ring = NSView(frame: NSRect(
                x: Layout.wizardRadioInnerRing, y: Layout.wizardRadioInnerRing,
                width: Layout.wizardRadioSize - Layout.wizardRadioInnerRing * 2,
                height: Layout.wizardRadioSize - Layout.wizardRadioInnerRing * 2))
            ring.wantsLayer = true
            ring.layer?.backgroundColor = Theme.wizardRadioInnerGap.cgColor
            ring.layer?.cornerRadius = ring.frame.width / 2
            v.addSubview(ring)
        } else {
            v.layer?.borderColor = Theme.textSecondary.withAlphaComponent(0.55).cgColor
            v.layer?.backgroundColor = NSColor.clear.cgColor
        }
    case .checkbox:
        v.layer?.cornerRadius = Layout.wizardCheckboxCornerRadius
        if selected {
            v.layer?.borderColor = Theme.buttonAllow.cgColor
            v.layer?.backgroundColor = Theme.buttonAllow.cgColor
            let path = CGMutablePath()
            path.move(to: CGPoint(x: Layout.wizardCheckmarkInsetX,
                                  y: Layout.wizardCheckmarkPeakY))
            path.addLine(to: CGPoint(x: Layout.wizardCheckmarkPeakX,
                                     y: Layout.wizardCheckmarkLowY))
            path.addLine(to: CGPoint(x: Layout.wizardCheckmarkHighX,
                                     y: Layout.wizardCheckmarkHighY +
                                        Layout.wizardCheckmarkPeakY))
            let check = CAShapeLayer()
            check.path = path
            check.strokeColor = Theme.background.cgColor
            check.fillColor = NSColor.clear.cgColor
            check.lineWidth = Layout.wizardCheckmarkLineWidth
            check.lineCap = .square
            check.lineJoin = .miter
            v.layer?.addSublayer(check)
        } else {
            v.layer?.borderColor = Theme.textSecondary.withAlphaComponent(0.55).cgColor
            v.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
    return v
}

/// Builds a single radio-card row view used in the question panel.
///
/// The row is a horizontal layout: a left-edge indicator (radio circle for
/// single-select, checkbox for multi-select), then a vertical stack holding
/// the bolded label on top and a secondary-colored description below. The
/// description wraps onto multiple lines and the row grows to fit; when the
/// description is empty the row stays at `Layout.wizardRowHeightMin`.
///
/// - Parameters:
///   - label: Bold label text (e.g. `"SQLite"` or `"Other"`).
///   - description: Secondary description text under the label. Empty hides the line.
///   - selected: If true, indicator is filled and the row uses selected colors.
///   - index: 1-based display index shown on the right; pass 0 to hide.
///   - style: `.radio` for single-select; `.checkbox` for multi-select.
/// - Returns: A configured `NSView` sized to the panel width × measured height.
func buildWizardOptionRow(label: String, description: String, selected: Bool,
                          index: Int, style: WizardIndicatorStyle) -> NSView {
    let rowWidth = Layout.panelWidth - Layout.wizardBodyPaddingH * 2
    let textX = Layout.wizardRowPaddingH + Layout.wizardRadioSize + Layout.wizardRadioGap
    let textWidth = rowWidth - textX - Layout.wizardRowPaddingH - Layout.wizardRowIndexWidth

    // Measure description height for wrapping. Empty description keeps the row
    // at the minimum height (label + vertical padding).
    var descHeight: CGFloat = 0
    let descField = NSTextField(labelWithString: description)
    if !description.isEmpty {
        descField.font = Theme.wizardDescFont
        descField.textColor = Theme.textSecondary
        descField.usesSingleLineMode = false
        descField.maximumNumberOfLines = 0
        descField.lineBreakMode = .byWordWrapping
        descField.preferredMaxLayoutWidth = textWidth
        descHeight = ceil(descField.intrinsicContentSize.height)
    }

    // Row grows to fit label + gap + wrapped description + vertical padding.
    // Existing label/desc baselines describe the minimum-height layout; we use
    // the same gap above the description so short and tall rows visually align
    // around the indicator.
    let labelGapFromBottom = Layout.wizardRowDescY
    let labelHeight = Layout.wizardRowLabelHeight
    let interGap = (Layout.wizardRowLabelY - Layout.wizardRowDescY - Layout.wizardRowDescHeight)
    let computedHeight = labelGapFromBottom + descHeight + (descHeight > 0 ? interGap : 0)
        + labelHeight + (Layout.wizardRowHeightMin - Layout.wizardRowLabelY - labelHeight)
    let rowHeight = max(Layout.wizardRowHeightMin, computedHeight)

    let container = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: rowHeight))
    container.wantsLayer = true
    container.layer?.cornerRadius = Layout.wizardRowCornerRadius
    container.layer?.backgroundColor =
        (selected ? Theme.wizardRowSelectedBg : Theme.wizardRowBg).cgColor
    container.layer?.borderColor =
        (selected ? Theme.wizardRowSelectedBorder : Theme.wizardRowBorder).cgColor
    container.layer?.borderWidth = 1

    let indFrame = NSRect(
        x: Layout.wizardRowPaddingH,
        y: (rowHeight - Layout.wizardRadioSize) / 2,
        width: Layout.wizardRadioSize, height: Layout.wizardRadioSize)
    container.addSubview(drawWizardIndicator(frame: indFrame, selected: selected, style: style))

    let labelField = NSTextField(labelWithString: label)
    labelField.font = Theme.wizardLabelFont
    labelField.textColor = Theme.textPrimary
    labelField.lineBreakMode = .byTruncatingTail
    let labelY = rowHeight - (Layout.wizardRowHeightMin - Layout.wizardRowLabelY)
    labelField.frame = NSRect(x: textX, y: labelY, width: textWidth, height: labelHeight)
    container.addSubview(labelField)

    if !description.isEmpty {
        descField.frame = NSRect(x: textX, y: labelGapFromBottom,
                                 width: textWidth, height: descHeight)
        container.addSubview(descField)
    }

    if index > 0 {
        let idxField = NSTextField(labelWithString: "\(index)")
        idxField.font = Theme.wizardIndexFont
        idxField.textColor = selected
            ? Theme.buttonAllow
            : Theme.textSecondary.withAlphaComponent(0.55)
        idxField.alignment = .right
        idxField.frame = NSRect(
            x: rowWidth - Layout.wizardRowPaddingH - Layout.wizardRowIndexWidth,
            y: (rowHeight - Layout.wizardRowIndexHeight) / 2,
            width: Layout.wizardRowIndexWidth, height: Layout.wizardRowIndexHeight)
        container.addSubview(idxField)
    }

    return container
}

/// The "Other" row of a question panel. Rest state mirrors a preset row;
/// active state morphs the label cell into a multi-line editable text area.
///
/// The controller owns an instance per wizard run (one for each question's
/// panel) and calls:
///   - `activate()` to enter typing mode and focus the text view.
///   - `deactivate()` to return to rest state (text is preserved).
///   - `currentText` to read what the user has typed.
///   - `setText(_:)` to restore typed text when navigating back to a question.
///
/// The row calls back to the controller via four closures:
///   - `onActivate`: user clicked or pressed the row's number — controller
///      flips state and re-renders.
///   - `onSubmit`: user pressed Return while typing — controller advances.
///   - `onEscape`: user pressed Esc while typing — controller deactivates
///      and returns to option-selection mode.
///   - `onTextChange(String)`: every keystroke — controller saves to
///      `pendingCustom` and re-evaluates Submit-enabled.
final class WizardOtherRow: NSView, NSTextViewDelegate {

    // Dependencies injected by the controller.
    var onActivate: () -> Void = {}
    var onSubmit: () -> Void = {}
    var onEscape: () -> Void = {}
    var onTextChange: (String) -> Void = { _ in }
    /// Fires when the row's height changes. The `delta` is the signed change
    /// relative to the previous height. Controller shifts siblings + resizes
    /// the panel in response. Never torn-down mid-call — receiver adjusts
    /// frames in place so no view destruction happens during typing.
    var onRowHeightChange: (_ delta: CGFloat) -> Void = { _ in }

    /// Bound number shown on the right (1-based); 0 hides.
    /// Setter refreshes the rendered index field.
    var indexNumber: Int = 0 {
        didSet { refreshIndex() }
    }

    /// Is this row the currently selected option in its question?
    private(set) var selected: Bool = false

    /// Is the text view currently accepting input?
    private(set) var isActive: Bool = false

    private let scrollView: NSScrollView
    private let textView: NSTextView
    private var labelField: NSTextField!
    private var descField: NSTextField!
    private var radioView: NSView!
    private var idxField: NSTextField!
    private let style: WizardIndicatorStyle

    /// Current string contents of the text view.
    var currentText: String { textView.string }

    init(style: WizardIndicatorStyle = .radio) {
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)

        self.style = style
        self.textView = NSTextView(frame: .zero, textContainer: container)
        self.scrollView = NSScrollView(frame: .zero)
        super.init(frame: NSRect(x: 0, y: 0,
            width: Layout.panelWidth - Layout.wizardBodyPaddingH * 2,
            height: Layout.wizardRowHeightMin))

        wantsLayer = true
        layer?.cornerRadius = Layout.wizardRowCornerRadius
        layer?.backgroundColor = Theme.wizardRowBg.cgColor
        layer?.borderColor = Theme.wizardRowBorder.cgColor
        layer?.borderWidth = 1

        buildRest()
        buildTextView()
        updateVisibility()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    /// Marks the row as selected (radio filled, selected colors) but leaves
    /// it in rest state. Call `activate()` additionally to start typing.
    func setSelected(_ on: Bool) {
        selected = on
        refreshColors()
    }

    /// Enter typing mode — swap rest view for text view and move first responder
    /// into the text view.
    func activate() {
        isActive = true
        setSelected(true)
        updateVisibility()
        window?.makeFirstResponder(textView)
    }

    /// Return to rest state (text preserved, first responder surrendered).
    /// Selection state is unchanged.
    func deactivate() {
        isActive = false
        updateVisibility()
        window?.makeFirstResponder(nil)
    }

    /// Replace text view contents (used when navigating back to a question
    /// where the user previously typed something).
    func setText(_ text: String) {
        textView.string = text
        updateVisibility()
    }

    /// Moves the caret to the end of the current text. Used after the
    /// controller rebuilds the panel so typing resumes where the user left off.
    func moveCaretToEnd() {
        let len = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: len, length: 0))
        textView.scrollRangeToVisible(NSRange(location: len, length: 0))
    }

    // MARK: Subview construction

    private func buildRest() {
        // Indicator (radio or checkbox depending on style).
        radioView = drawWizardIndicator(
            frame: NSRect(
                x: Layout.wizardRowPaddingH,
                y: (Layout.wizardRowHeightMin - Layout.wizardRadioSize) / 2,
                width: Layout.wizardRadioSize, height: Layout.wizardRadioSize),
            selected: false, style: style)
        addSubview(radioView)

        let textX = Layout.wizardRowPaddingH + Layout.wizardRadioSize + Layout.wizardRadioGap
        let textWidth = frame.width - textX - Layout.wizardRowPaddingH - Layout.wizardRowIndexWidth

        labelField = NSTextField(labelWithString: "Other")
        labelField.font = Theme.wizardLabelFont
        labelField.textColor = Theme.textPrimary
        labelField.frame = NSRect(x: textX, y: Layout.wizardRowLabelY,
                                  width: textWidth, height: Layout.wizardRowLabelHeight)
        addSubview(labelField)

        descField = NSTextField(labelWithString: "Type your own answer")
        descField.font = Theme.wizardDescFont
        descField.textColor = Theme.textSecondary
        descField.frame = NSRect(x: textX, y: Layout.wizardRowDescY,
                                 width: textWidth, height: Layout.wizardRowDescHeight)
        addSubview(descField)

        idxField = NSTextField(labelWithString: "")
        idxField.font = Theme.wizardIndexFont
        idxField.textColor = Theme.textSecondary.withAlphaComponent(0.55)
        idxField.alignment = .right
        idxField.frame = NSRect(
            x: frame.width - Layout.wizardRowPaddingH - Layout.wizardRowIndexWidth,
            y: (Layout.wizardRowHeightMin - Layout.wizardRowIndexHeight) / 2,
            width: Layout.wizardRowIndexWidth, height: Layout.wizardRowIndexHeight)
        addSubview(idxField)

        refreshColors()

        // Whole-row click → activate
        let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked))
        addGestureRecognizer(click)
    }

    /// Updates the right-side index number display based on `indexNumber`.
    private func refreshIndex() {
        guard let field = idxField else { return }
        field.stringValue = indexNumber > 0 ? "\(indexNumber)" : ""
        field.textColor = selected ? Theme.buttonAllow : Theme.textSecondary.withAlphaComponent(0.55)
    }

    private func buildTextView() {
        let textX = Layout.wizardRowPaddingH + Layout.wizardRadioSize + Layout.wizardRadioGap
        let textWidth = frame.width - textX - Layout.wizardRowPaddingH - Layout.wizardRowIndexWidth

        // ScrollView sized for the expanded row; updateVisibility centers it
        // vertically within whatever row height is current (collapsed/expanded).
        let scrollHeight = Layout.wizardOtherActiveRowHeight - Layout.wizardOtherActivePaddingV * 2
        scrollView.frame = NSRect(x: textX, y: Layout.wizardOtherActivePaddingV,
                                  width: textWidth, height: scrollHeight)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        // NSTextView inside NSScrollView needs explicit min/max size and
        // correct resizing flags; without these the text view doesn't receive
        // mouse events for selection, and long content can't scroll.
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = Theme.wizardOtherTextFont
        textView.textColor = Theme.textPrimary
        textView.insertionPointColor = Theme.buttonAllow
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        addSubview(scrollView)
    }

    @objc private func rowClicked() {
        onActivate()
    }

    /// Returns the first non-empty line of the typed text, or empty string.
    private var textSummary: String {
        let trimmed = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        return textView.string.components(separatedBy: "\n").first ?? textView.string
    }

    private func updateVisibility() {
        labelField.isHidden = isActive
        descField.isHidden = isActive
        scrollView.isHidden = !isActive

        // Rest state: if the user has typed anything, surface it in the label
        // (first line, truncated by NSTextField's tail truncation) so they
        // can see what their custom answer is without re-activating the row.
        let summary = textSummary
        if !summary.isEmpty {
            labelField.stringValue = summary
            descField.stringValue = "\u{2713} custom"
        } else {
            labelField.stringValue = "Other"
            descField.stringValue = "Type your own answer"
        }
        refreshHeight()
    }

    private func refreshColors() {
        layer?.backgroundColor =
            (selected ? Theme.wizardRowSelectedBg : Theme.wizardRowBg).cgColor
        layer?.borderColor =
            (selected ? Theme.wizardRowSelectedBorder : Theme.wizardRowBorder).cgColor
        // Replace the indicator view rather than mutating sublayers so the
        // checkbox check-glyph layer is rebuilt cleanly on each toggle.
        let oldFrame = radioView.frame
        radioView.removeFromSuperview()
        radioView = drawWizardIndicator(frame: oldFrame, selected: selected, style: style)
        addSubview(radioView)
        refreshIndex()
    }

    /// Row height scales with content when active, down to wizardRowHeightMin
    /// for short answers and up to wizardOtherActiveRowHeight for long ones
    /// (content beyond that scrolls inside the text view). Inactive state is
    /// always wizardRowHeightMin. The delta is broadcast via `onRowHeightChange`
    /// so the controller can grow/shrink the panel in place without rebuilding.
    private func refreshHeight() {
        let oldHeight = frame.height
        let rowHeight: CGFloat
        if isActive {
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            let used = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
            let content = ceil(used.height) + 4
            let desired = content + Layout.wizardOtherActivePaddingV * 2
            rowHeight = min(Layout.wizardOtherActiveRowHeight,
                            max(Layout.wizardRowHeightMin, desired))
        } else {
            rowHeight = Layout.wizardRowHeightMin
        }
        setFrameSize(NSSize(width: frame.width, height: rowHeight))

        // Re-center radio and scroll view vertically within the current row.
        radioView.frame.origin.y = (rowHeight - Layout.wizardRadioSize) / 2

        let textX = Layout.wizardRowPaddingH + Layout.wizardRadioSize + Layout.wizardRadioGap
        let textWidth = frame.width - textX - Layout.wizardRowPaddingH - Layout.wizardRowIndexWidth

        if isActive {
            let scrollHeight = rowHeight - Layout.wizardOtherActivePaddingV * 2
            // Measure how much vertical space the laid-out text actually uses; if it
            // is shorter than the scroll view, shift the scroll view frame down so
            // the visible text sits in the vertical center of the row instead of
            // being stuck at the top with empty space underneath.
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            let used = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
            let textH = ceil(used.height) + 4  // matches textContainerInset contribution
            let emptyBelow = max(0, scrollHeight - textH)
            let scrollY = Layout.wizardOtherActivePaddingV + emptyBelow / 2
            scrollView.frame = NSRect(
                x: textX, y: scrollY,
                width: textWidth, height: scrollHeight - emptyBelow)
        }
        idxField.frame.origin.y = (rowHeight - Layout.wizardRowIndexHeight) / 2
        labelField.frame.origin.y = isActive ? 0 : Layout.wizardRowLabelY
        descField.frame.origin.y = isActive ? 0 : Layout.wizardRowDescY

        let delta = rowHeight - oldHeight
        if delta != 0 { onRowHeightChange(delta) }
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        onTextChange(textView.string)
        refreshHeight()
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Return → submit; Shift+Return / Option+Return → explicit newline.
        // macOS routes Shift+Return through `insertNewline:` in plain NSTextView,
        // so we disambiguate via the current event's modifier flags rather than
        // relying only on the selector.
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            if shift {
                textView.insertText("\n", replacementRange: textView.selectedRange())
            } else {
                onSubmit()
            }
            return true
        }
        if commandSelector == #selector(NSResponder.insertLineBreak(_:)) ||
           commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onEscape()
            return true
        }
        return false
    }
}

/// Handles into a freshly built question panel so the controller can hook
/// event targets and later update selected state and Submit-enabled.
struct WizardQuestionPanelHandles {
    let root: NSView
    let identityHeader: NSView          // project + cwd + separator; shifts when body grows
    let header: NSView                  // ASKUSERQUESTION band; shifts when body grows
    let body: NSView                    // content area; resizes with Other row
    let pill: NSButton                  // category tag
    let questionField: NSTextField
    let optionRowViews: [NSView]        // preset rows only (not the Other row)
    let otherRow: WizardOtherRow
    let backButton: NSButton
    let primaryButton: NSButton         // Next → or Submit ⏎
    let terminalButton: NSButton
    let cancelButton: NSButton
    let progressDots: [NSView]
}

/// Builds a full question panel (header + body + footer). Radio selection
/// state, progress dot colors, and Submit-enabled state are applied after
/// the fact by the controller based on `WizardState`.
///
/// - Parameters:
///   - question: The question to render in the body.
///   - stepIndex: Zero-based index of this question within the wizard.
///   - totalSteps: Total number of question steps (not counting review).
///   - isLastStep: True if Return / → should say `WizardLabels.submit` instead of `WizardLabels.next`.
/// - Returns: Handles to the root and every interactive view.
func buildWizardQuestionPanel(
    question: WizardQuestion,
    stepIndex: Int,
    totalSteps: Int,
    isLastStep: Bool,
    projectName: String,
    cwd: String
) -> WizardQuestionPanelHandles {
    let width = Layout.panelWidth
    let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
    root.wantsLayer = true

    // --- Header band ---
    let header = NSView(frame: NSRect(x: 0, y: 0, width: width, height: Layout.wizardHeaderHeight))
    header.wantsLayer = true
    header.layer?.backgroundColor = Theme.background.cgColor

    let tag = NSTextField(labelWithString: "ASKUSERQUESTION")
    tag.font = Theme.wizardHeaderTagFont
    tag.attributedStringValue = NSAttributedString(
        string: "ASKUSERQUESTION",
        attributes: [
            .font: Theme.wizardHeaderTagFont,
            .foregroundColor: Theme.wizardHeaderAccent,
            .kern: 1.2,
        ])
    tag.frame = NSRect(x: Layout.wizardBodyPaddingH, y: Layout.wizardHeaderLabelY,
                        width: Layout.wizardHeaderTagWidth, height: Layout.wizardHeaderLabelHeight)
    header.addSubview(tag)

    let stepCounter = NSTextField(labelWithString: "\(stepIndex + 1) of \(totalSteps)")
    stepCounter.font = Theme.wizardHeaderCounterFont
    stepCounter.textColor = Theme.textSecondary
    stepCounter.alignment = .right
    stepCounter.frame = NSRect(
        x: width - Layout.wizardBodyPaddingH - Layout.wizardHeaderCounterWidth,
        y: Layout.wizardHeaderLabelY,
        width: Layout.wizardHeaderCounterWidth, height: Layout.wizardHeaderLabelHeight)
    header.addSubview(stepCounter)
    root.addSubview(header)

    // --- Body ---
    let body = NSView(frame: .zero)

    // Header tag pill
    let pillFont = Theme.wizardPillFont
    let pill = NSButton(frame: .zero)
    pill.title = question.header.uppercased()
    pill.font = pillFont
    pill.isBordered = false
    pill.wantsLayer = true
    pill.layer?.cornerRadius = 4
    pill.layer?.backgroundColor = (Theme.toolTagColors["AskUserQuestion"] ?? Theme.mcpTag).cgColor
    pill.contentTintColor = Theme.background
    let pillSize = (question.header.uppercased() as NSString)
        .size(withAttributes: [.font: pillFont])
    pill.frame = NSRect(x: Layout.wizardBodyPaddingH, y: 0,
                        width: ceil(pillSize.width) + Layout.wizardPillHPadding,
                        height: Layout.wizardPillHeight)
    body.addSubview(pill)

    // Question text
    let qField = NSTextField(labelWithString: question.question)
    qField.font = Theme.wizardQuestionFont
    qField.textColor = Theme.textPrimary
    qField.lineBreakMode = .byWordWrapping
    qField.usesSingleLineMode = false
    qField.maximumNumberOfLines = 0
    qField.preferredMaxLayoutWidth = width - Layout.wizardBodyPaddingH * 2
    let qHeight = ceil(qField.intrinsicContentSize.height)
    qField.frame = NSRect(x: Layout.wizardBodyPaddingH, y: 0,
                          width: width - Layout.wizardBodyPaddingH * 2, height: qHeight)
    body.addSubview(qField)

    // Option rows
    var optionRowViews: [NSView] = []
    for (i, opt) in question.options.enumerated() {
        let row = buildWizardOptionRow(label: opt.label, description: opt.description,
                                       selected: false, index: i + 1,
                                       style: question.multiSelect ? .checkbox : .radio)
        optionRowViews.append(row)
        body.addSubview(row)
    }

    // Other row (last)
    let otherRow = WizardOtherRow(
        style: question.multiSelect ? .checkbox : .radio)
    otherRow.indexNumber = question.options.count + 1
    body.addSubview(otherRow)

    // Progress dots
    var progressDots: [NSView] = []
    for _ in 0..<totalSteps {
        let dot = NSView(frame: NSRect(x: 0, y: 0,
            width: Layout.wizardProgressDotWidth, height: Layout.wizardProgressDotHeight))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Layout.wizardProgressDotHeight / 2
        dot.layer?.backgroundColor = Theme.wizardProgressInactive.cgColor
        body.addSubview(dot)
        progressDots.append(dot)
    }

    // Layout body contents vertically
    // (we stack from top down; AppKit uses bottom-left origin, so we lay out at end)
    let pillTopY = Layout.wizardBodyPaddingV
    let qTopY = pillTopY + Layout.wizardPillHeight + Layout.wizardBodyGapAfterPill
    let rowTopY = qTopY + qHeight + Layout.wizardBodyGapAfterQuestion
    // Option rows take their measured height (from `buildWizardOptionRow`'s
    // wrap pass). The Other row stays at `wizardRowHeightMin` in rest state
    // and grows at runtime when the user activates it and types; the
    // controller shifts siblings + resizes the panel in response to
    // `onRowHeightChange`.
    var rowsTotal: CGFloat = 0
    for row in optionRowViews {
        rowsTotal += row.frame.height
    }
    rowsTotal += Layout.wizardRowHeightMin   // Other row, always min in rest state
    rowsTotal += CGFloat(question.options.count) * Layout.wizardRowGap
    let totalRowsHeight = rowsTotal
    let progressAreaHeight: CGFloat = Layout.wizardProgressTopPadding +
        Layout.wizardProgressDotHeight
    let bodyHeight = rowTopY + totalRowsHeight + progressAreaHeight + Layout.wizardBodyBottomPadding
    body.frame = NSRect(x: 0, y: Layout.wizardFooterTwoRowHeight, width: width, height: bodyHeight)

    // Flip y (AppKit origin bottom-left)
    pill.frame.origin.y = bodyHeight - pillTopY - Layout.wizardPillHeight
    qField.frame.origin.y = bodyHeight - qTopY - qHeight

    var yCursor = bodyHeight - rowTopY
    for row in optionRowViews {
        let rh = row.frame.height
        yCursor -= rh
        row.frame = NSRect(x: Layout.wizardBodyPaddingH, y: yCursor,
            width: width - Layout.wizardBodyPaddingH * 2, height: rh)
        yCursor -= Layout.wizardRowGap
    }
    yCursor -= Layout.wizardRowHeightMin
    otherRow.frame = NSRect(x: Layout.wizardBodyPaddingH, y: yCursor,
        width: width - Layout.wizardBodyPaddingH * 2, height: Layout.wizardRowHeightMin)

    // Progress dots centered below Other row.
    let dotsTotalWidth = CGFloat(totalSteps) * Layout.wizardProgressDotWidth +
        CGFloat(max(0, totalSteps - 1)) * Layout.wizardProgressDotGap
    var dx = (width - dotsTotalWidth) / 2
    let dotY = yCursor - Layout.wizardProgressTopPadding - Layout.wizardProgressDotHeight
    for dot in progressDots {
        dot.frame.origin = NSPoint(x: dx, y: dotY)
        dx += Layout.wizardProgressDotWidth + Layout.wizardProgressDotGap
    }

    root.addSubview(body)

    // --- Footer (two rows) ---
    let footer = NSView(frame: NSRect(x: 0, y: 0, width: width,
                                      height: Layout.wizardFooterTwoRowHeight))
    footer.wantsLayer = true
    footer.layer?.backgroundColor = Theme.codeBackground.cgColor

    // Row 1: Back + Primary (Next / Submit Answers)
    let back = makeWizardFooterButton(
        title: WizardLabels.back,
        fill:  Theme.wizardNeutralFillRest,
        border: Theme.wizardNeutralBorderRest,
        textColor: Theme.textPrimary)
    let primary = makeWizardFooterButton(
        title: isLastStep ? WizardLabels.submit : WizardLabels.next,
        fill:  Theme.buttonPersist.withAlphaComponent(0.22),
        border: Theme.buttonPersist.withAlphaComponent(0.50),
        textColor: Theme.textPrimary)

    // Row 2: Terminal (green) + Ok (neutral gray — intentionally distinct from
    // Row 1's blue so the user never sees two same-colored primary buttons)
    let terminal = makeWizardFooterButton(
        title: terminalButtonLabel(),
        fill:  Theme.buttonAllow.withAlphaComponent(0.22),
        border: Theme.buttonAllow.withAlphaComponent(0.55),
        textColor: Theme.textPrimary)
    let cancel = makeWizardFooterButton(
        title: WizardLabels.ok,
        fill:  Theme.wizardNeutralFillRest,
        border: Theme.wizardNeutralBorderRest,
        textColor: Theme.textPrimary)

    // Layout math: 2 rows of 2 equal-width buttons, 10pt top/bottom padding,
    // rowGap between the two rows.
    let buttonH = Layout.wizardFooterButtonHeight
    let rowGap  = Layout.wizardFooterRowGap
    let gutter  = Layout.wizardFooterGap
    let sidePad = Layout.wizardBodyPaddingH
    let colW    = (width - sidePad * 2 - gutter) / 2
    let topPad  = Layout.wizardFooterVerticalPadding

    // Row 2 sits at the bottom; row 1 above it.
    let row2Y = topPad
    let row1Y = topPad + buttonH + rowGap

    back.frame     = NSRect(x: sidePad,                   y: row1Y, width: colW, height: buttonH)
    primary.frame  = NSRect(x: sidePad + colW + gutter,   y: row1Y, width: colW, height: buttonH)
    terminal.frame = NSRect(x: sidePad,                   y: row2Y, width: colW, height: buttonH)
    cancel.frame   = NSRect(x: sidePad + colW + gutter,   y: row2Y, width: colW, height: buttonH)

    footer.addSubview(back)
    footer.addSubview(primary)
    footer.addSubview(terminal)
    footer.addSubview(cancel)

    root.addSubview(footer)

    // Identity header (project + cwd + separator) — matches Permission / Done.
    let (identityHeaderView, identityHeaderH) =
        makeWizardIdentityHeader(projectName: projectName, cwd: cwd, width: width)
    root.addSubview(identityHeaderView)

    // Size root
    let rootHeight = identityHeaderH + Layout.wizardHeaderHeight
        + bodyHeight + Layout.wizardFooterTwoRowHeight
    root.frame.size = NSSize(width: width, height: rootHeight)
    identityHeaderView.frame.origin.y = rootHeight - identityHeaderH
    header.frame.origin.y = rootHeight - identityHeaderH - Layout.wizardHeaderHeight
    body.frame.origin.y = Layout.wizardFooterTwoRowHeight

    return WizardQuestionPanelHandles(
        root: root,
        identityHeader: identityHeaderView,
        header: header,
        body: body,
        pill: pill,
        questionField: qField,
        optionRowViews: optionRowViews,
        otherRow: otherRow,
        backButton: back,
        primaryButton: primary,
        terminalButton: terminal,
        cancelButton: cancel,
        progressDots: progressDots)
}

/// Builds the wizard's identity band — project name, cwd, hairline separator —
/// matching the header style of the Permission and Done dialogs. Returns the
/// band's view plus its total height so the caller can stack it on top of the
/// existing wizard content and size the root accordingly.
func makeWizardIdentityHeader(projectName: String, cwd: String, width: CGFloat) -> (NSView, CGFloat) {
    // Matches the spacing stack used by Permission / Done dialog headers so
    // the wizard visually belongs to the same family. Vertical rhythm, from
    // top down: panelTopPadding → project → path → sectionGap → hairline
    // separator → sectionGap (breathing room before the ASKUSERQUESTION band).
    let topPad     = Layout.panelTopPadding
    let gapToSep   = Layout.sectionGap
    // Match `wizardBodyPaddingV` so the ASKUSERQUESTION band has equal
    // breathing room above and below, and so the outer padding of the top
    // region matches the bottom region (progress dots area).
    let bottomPad  = Layout.wizardBodyPaddingV
    let height     = topPad + Layout.projectHeight + Layout.pathHeight
        + gapToSep + Layout.separatorHeight + bottomPad

    let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    view.wantsLayer = true
    view.layer?.backgroundColor = Theme.background.cgColor

    var y = height - topPad

    y -= Layout.projectHeight
    let projectLabel = NSTextField(labelWithString: projectName)
    projectLabel.font = NSFont.systemFont(ofSize: Layout.projectFontSize, weight: .bold)
    projectLabel.textColor = Theme.textPrimary
    projectLabel.frame = NSRect(x: Layout.panelMargin, y: y,
                                width: width - Layout.panelMargin * 2,
                                height: Layout.projectHeight)
    projectLabel.lineBreakMode = .byTruncatingTail
    view.addSubview(projectLabel)

    y -= Layout.pathHeight
    let pathLabel = NSTextField(labelWithString: cwd)
    pathLabel.font = NSFont.systemFont(ofSize: Layout.pathFontSize, weight: .regular)
    pathLabel.textColor = Theme.textSecondary
    pathLabel.frame = NSRect(x: Layout.panelMargin, y: y,
                             width: width - Layout.panelMargin * 2,
                             height: Layout.pathLineHeight)
    pathLabel.lineBreakMode = .byTruncatingMiddle
    view.addSubview(pathLabel)

    y -= gapToSep
    let separator = NSView(frame: NSRect(x: Layout.panelInset, y: y - Layout.separatorHeight,
                                         width: width - Layout.panelInset * 2,
                                         height: Layout.separatorHeight))
    separator.wantsLayer = true
    separator.layer?.backgroundColor = Theme.wizardDivider.cgColor
    view.addSubview(separator)

    return (view, height)
}

/// Factory for a single footer button with fill/border/text colors.
/// Used by both the question panel and the review panel.
func makeWizardFooterButton(title: String, fill: NSColor, border: NSColor, textColor: NSColor) -> NSButton {
    let b = NSButton(title: title, target: nil, action: nil)
    b.isBordered = false
    b.wantsLayer = true
    b.alignment = .center
    b.layer?.cornerRadius = Layout.wizardRowCornerRadius
    b.layer?.backgroundColor = fill.cgColor
    b.layer?.borderColor = border.cgColor
    b.layer?.borderWidth = 1
    b.attributedTitle = NSAttributedString(string: title, attributes: [
        .font: Theme.wizardFooterButtonFont,
        .foregroundColor: textColor,
    ])
    return b
}

/// Handles into a review panel for controller wiring.
struct WizardReviewPanelHandles {
    let root: NSView
    let reviewRows: [NSView]       // one per question, clickable
    let editButtons: [NSButton]    // explicit "edit" links on each row
    let backButton: NSButton
    let submitButton: NSButton     // disabled when not all answered
    let terminalButton: NSButton
    let cancelButton: NSButton
    let progressDots: [NSView]
}

/// Builds the review panel. Each row summarises one question's answer.
/// Submit is styled enabled here; the controller greys it when `allAnswered`
/// is false via `applyWizardSubmitEnabled`.
func buildWizardReviewPanel(state: WizardState) -> WizardReviewPanelHandles {
    let width = Layout.panelWidth
    let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
    root.wantsLayer = true

    // Header band
    let header = NSView(frame: NSRect(x: 0, y: 0, width: width, height: Layout.wizardHeaderHeight))
    header.wantsLayer = true
    header.layer?.backgroundColor = Theme.background.cgColor
    let tag = NSTextField(labelWithString: "ASKUSERQUESTION · REVIEW")
    tag.font = Theme.wizardHeaderTagFont
    tag.attributedStringValue = NSAttributedString(
        string: "ASKUSERQUESTION · REVIEW",
        attributes: [
            .font: Theme.wizardHeaderTagFont,
            .foregroundColor: Theme.wizardHeaderAccent,
            .kern: 1.2,
        ])
    tag.frame = NSRect(x: Layout.wizardBodyPaddingH, y: Layout.wizardHeaderLabelY,
                       width: Layout.wizardHeaderReviewTagWidth,
                       height: Layout.wizardHeaderLabelHeight)
    header.addSubview(tag)
    let answered = state.answers.filter { $0 != nil }.count
    let counter = NSTextField(labelWithString: "\(answered) of \(state.questions.count) answered")
    counter.font = Theme.wizardHeaderCounterFont
    counter.textColor = Theme.textSecondary
    counter.alignment = .right
    counter.frame = NSRect(
        x: width - Layout.wizardBodyPaddingH - Layout.wizardHeaderReviewCounterWidth,
        y: Layout.wizardHeaderLabelY,
        width: Layout.wizardHeaderReviewCounterWidth,
        height: Layout.wizardHeaderLabelHeight)
    header.addSubview(counter)
    root.addSubview(header)

    // Body
    let body = NSView(frame: .zero)

    let title = NSTextField(labelWithString: "Review your answers")
    title.font = Theme.wizardReviewTitleFont
    title.textColor = Theme.textPrimary
    title.frame = NSRect(x: Layout.wizardBodyPaddingH, y: 0,
                         width: width - 2 * Layout.wizardBodyPaddingH,
                         height: Layout.wizardReviewTitleHeight)
    body.addSubview(title)

    var reviewRows: [NSView] = []
    var editButtons: [NSButton] = []
    let rowSpacing = Layout.wizardReviewRowSpacing
    let rowHeight = Layout.wizardReviewRowHeight

    for (i, q) in state.questions.enumerated() {
        let row = NSView(frame: .zero)
        row.wantsLayer = true
        row.layer?.cornerRadius = 6
        row.layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.02).cgColor
        row.layer?.borderWidth = 1
        row.layer?.borderColor = Theme.wizardRowBorder.cgColor

        let pillFont = Theme.wizardReviewPillFont
        let pill = NSButton(title: q.header.uppercased(), target: nil, action: nil)
        pill.isBordered = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 3
        pill.layer?.backgroundColor = (Theme.toolTagColors["AskUserQuestion"] ?? Theme.mcpTag).cgColor
        pill.attributedTitle = NSAttributedString(string: q.header.uppercased(), attributes: [
            .font: pillFont,
            .foregroundColor: Theme.background,
        ])
        let pillSize = (q.header.uppercased() as NSString).size(withAttributes: [.font: pillFont])
        pill.frame = NSRect(x: 12, y: 37,
            width: ceil(pillSize.width) + Layout.wizardReviewPillHPadding,
            height: Layout.wizardReviewPillHeight)
        row.addSubview(pill)

        let qLabel = NSTextField(labelWithString: q.question)
        qLabel.font = Theme.wizardReviewRowQuestionFont
        qLabel.textColor = Theme.textSecondary
        qLabel.lineBreakMode = .byTruncatingTail
        qLabel.frame = NSRect(x: pill.frame.maxX + 8, y: 37,
            width: width - pill.frame.maxX - 80, height: Layout.wizardHeaderLabelHeight)
        row.addSubview(qLabel)

        let edit = NSButton(title: "edit", target: nil, action: nil)
        edit.isBordered = false
        edit.attributedTitle = NSAttributedString(string: "edit", attributes: [
            .font: Theme.wizardReviewEditFont,
            .foregroundColor: Theme.buttonAllow,
        ])
        edit.frame = NSRect(x: width - Layout.wizardBodyPaddingH * 2 - 50, y: 37,
            width: 50, height: Layout.wizardHeaderLabelHeight)
        edit.tag = i
        row.addSubview(edit)
        editButtons.append(edit)

        let answerText: String
        switch state.answers[i] {
        case .preset(let idx):
            let opt = q.options[idx]
            answerText = opt.description.isEmpty
                ? "✓ \(opt.label)"
                : "✓ \(opt.label) · \(opt.description)"
        case .custom(let text):
            let firstLine = text.components(separatedBy: "\n").first ?? text
            answerText = "✓ \(firstLine) · custom"
        case .multi(let presets, let custom):
            var parts: [String] = []
            for idx in presets.sorted() where idx < q.options.count {
                parts.append(q.options[idx].label)
            }
            if let c = custom, !c.isEmpty {
                parts.append("✎ \(c.components(separatedBy: "\n").first ?? c)")
            }
            answerText = parts.isEmpty
                ? "(none)"
                : "✓ \(parts.joined(separator: ", "))"
        case .none:
            answerText = "⋯ (not answered yet)"
        }
        let ans = NSTextField(labelWithString: answerText)
        ans.font = Theme.wizardReviewRowAnswerFont
        ans.textColor = Theme.textPrimary
        ans.lineBreakMode = .byTruncatingTail
        ans.frame = NSRect(x: 12, y: 10,
            width: width - 2 * Layout.wizardBodyPaddingH - 24,
            height: Layout.wizardHeaderLabelHeight)
        row.addSubview(ans)

        row.frame = NSRect(x: Layout.wizardBodyPaddingH, y: 0,
            width: width - 2 * Layout.wizardBodyPaddingH, height: rowHeight)

        // Click on row body (not on edit button) triggers the same action as edit
        let click = NSClickGestureRecognizer(target: nil, action: nil)
        row.addGestureRecognizer(click)
        reviewRows.append(row)
        body.addSubview(row)
    }

    // Progress dots (all green on review)
    var progressDots: [NSView] = []
    for _ in 0..<state.questions.count {
        let dot = NSView(frame: NSRect(x: 0, y: 0,
            width: Layout.wizardProgressDotWidth, height: Layout.wizardProgressDotHeight))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Layout.wizardProgressDotHeight / 2
        dot.layer?.backgroundColor = Theme.wizardProgressActive.cgColor
        body.addSubview(dot)
        progressDots.append(dot)
    }

    // Body layout (top-down → flip to AppKit)
    let titleTop = Layout.wizardBodyPaddingV
    let rowsTopStart = titleTop + Layout.wizardReviewTitleHeight + Layout.wizardBodyGapAfterQuestion
    let rowsTotalHeight = CGFloat(state.questions.count) * rowHeight +
        CGFloat(max(0, state.questions.count - 1)) * rowSpacing
    let progressTop = rowsTopStart + rowsTotalHeight + Layout.wizardProgressTopPadding
    let bodyHeight = progressTop + Layout.wizardProgressDotHeight + Layout.wizardBodyBottomPadding

    body.frame = NSRect(x: 0, y: Layout.wizardFooterHeight, width: width, height: bodyHeight)
    title.frame.origin.y = bodyHeight - titleTop - Layout.wizardReviewTitleHeight

    var yCursor = bodyHeight - rowsTopStart - rowHeight
    for r in reviewRows {
        r.frame.origin.y = yCursor
        yCursor -= (rowHeight + rowSpacing)
    }
    let dotsTotalWidth = CGFloat(state.questions.count) * Layout.wizardProgressDotWidth +
        CGFloat(max(0, state.questions.count - 1)) * Layout.wizardProgressDotGap
    var dx = (width - dotsTotalWidth) / 2
    let dotY = bodyHeight - progressTop - Layout.wizardProgressDotHeight
    for dot in progressDots {
        dot.frame.origin = NSPoint(x: dx, y: dotY)
        dx += Layout.wizardProgressDotWidth + Layout.wizardProgressDotGap
    }

    root.addSubview(body)

    // Footer
    let footer = NSView(frame: NSRect(x: 0, y: 0, width: width, height: Layout.wizardFooterHeight))
    footer.wantsLayer = true
    footer.layer?.backgroundColor = Theme.codeBackground.cgColor

    let back = makeWizardFooterButton(title: WizardLabels.back,
        fill: Theme.buttonPersist.withAlphaComponent(0.06),
        border: Theme.buttonPersist.withAlphaComponent(0.12),
        textColor: Theme.textPrimary)
    back.frame = NSRect(x: Layout.wizardBodyPaddingH,
        y: (Layout.wizardFooterHeight - Layout.wizardFooterButtonHeight) / 2,
        width: Layout.wizardFooterSideButtonWidth, height: Layout.wizardFooterButtonHeight)
    footer.addSubview(back)

    let submit = makeWizardFooterButton(title: WizardLabels.submit,
        fill: Theme.buttonPersist.withAlphaComponent(0.22),
        border: Theme.buttonPersist.withAlphaComponent(0.50),
        textColor: Theme.textPrimary)
    footer.addSubview(submit)

    let terminal = makeWizardFooterButton(title: terminalButtonLabel(),
        fill: Theme.buttonAllow.withAlphaComponent(0.22),
        border: Theme.buttonAllow.withAlphaComponent(0.55),
        textColor: Theme.textPrimary)
    terminal.frame = NSRect(x: 0, y: (Layout.wizardFooterHeight - Layout.wizardFooterButtonHeight) / 2,
        width: Layout.wizardFooterSideButtonWidth, height: Layout.wizardFooterButtonHeight)
    footer.addSubview(terminal)

    let cancel = makeWizardFooterButton(title: WizardLabels.ok,
        fill: Theme.buttonDeny.withAlphaComponent(0.10),
        border: Theme.buttonDeny.withAlphaComponent(0.35),
        textColor: Theme.textPrimary)
    cancel.frame = NSRect(x: 0, y: (Layout.wizardFooterHeight - Layout.wizardFooterButtonHeight) / 2,
        width: Layout.wizardFooterSideButtonWidth, height: Layout.wizardFooterButtonHeight)
    footer.addSubview(cancel)

    let backRightEdge = back.frame.maxX + Layout.wizardFooterGap
    let rightReserved = Layout.wizardFooterSideButtonWidth * 2 + Layout.wizardFooterGap * 2
    submit.frame = NSRect(
        x: backRightEdge,
        y: (Layout.wizardFooterHeight - Layout.wizardFooterButtonHeight) / 2,
        width: width - backRightEdge - rightReserved - Layout.wizardBodyPaddingH,
        height: Layout.wizardFooterButtonHeight)
    terminal.frame.origin.x = submit.frame.maxX + Layout.wizardFooterGap
    cancel.frame.origin.x = terminal.frame.maxX + Layout.wizardFooterGap

    root.addSubview(footer)

    let rootHeight = Layout.wizardHeaderHeight + bodyHeight + Layout.wizardFooterHeight
    root.frame.size = NSSize(width: width, height: rootHeight)
    header.frame.origin.y = rootHeight - Layout.wizardHeaderHeight
    body.frame.origin.y = Layout.wizardFooterHeight

    return WizardReviewPanelHandles(
        root: root,
        reviewRows: reviewRows,
        editButtons: editButtons,
        backButton: back,
        submitButton: submit,
        terminalButton: terminal,
        cancelButton: cancel,
        progressDots: progressDots)
}

/// Applies the disabled style to a Submit/Next button when the wizard is
/// missing answers; restores enabled style otherwise.
func applyWizardSubmitEnabled(_ button: NSButton, enabled: Bool, isSubmit: Bool) {
    button.isEnabled = enabled
    if enabled {
        // Always blue — keeps the primary button visually distinct from the
        // green "Go to Terminal" button on the last step. Previously switched
        // to green when isSubmit, which made both buttons the same hue.
        button.layer?.backgroundColor = Theme.buttonPersist.withAlphaComponent(0.22).cgColor
        button.layer?.borderColor = Theme.buttonPersist.withAlphaComponent(0.50).cgColor
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [
            .font: Theme.wizardFooterButtonFont,
            .foregroundColor: Theme.textPrimary,
        ])
    } else {
        button.layer?.backgroundColor = Theme.wizardButtonDisabledBg.cgColor
        button.layer?.borderColor = Theme.wizardButtonDisabledBorder.cgColor
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [
            .font: Theme.wizardFooterButtonFont,
            .foregroundColor: Theme.wizardButtonDisabledText,
        ])
    }
}

/// Outcome of a wizard run, returned by `WizardController.run()`.
enum WizardOutcome {
    /// User submitted answers. `answers` is the per-question dictionary ready
    /// to inject into AskUserQuestion's `updatedInput` so the tool skips its
    /// native prompt. `reasonText` is the same data formatted for humans —
    /// retained as a fallback for anything that needs a string (logging,
    /// legacy deny paths).
    case submit(answers: [String: String], reasonText: String)
    case cancel                         // User dismissed; deny with generic reason
    case terminal                       // User chose Go to Terminal; allow + open terminal
}

/// Drives a wizard session end-to-end: builds panels, routes events, keeps
/// `WizardState` in sync with the UI, and resolves the modal with a
/// `WizardOutcome` when the user submits / cancels / chooses terminal.
final class WizardController: NSObject {
    let state: WizardState
    private let panel: NSPanel
    private let container: NSView
    /// Project identity — shown in the wizard's top band. Mirrors the
    /// Permission / Done dialogs so the user always sees which terminal
    /// tab the dialog belongs to.
    private let projectName: String
    private let cwd: String
    private var currentQuestionHandles: WizardQuestionPanelHandles?
    private var outcome: WizardOutcome = .cancel
    private var localKeyMonitor: Any?
    /// True while the user is editing the current question's Other text field.
    /// Drives panel layout (expanded row height) and keyboard-routing.
    private var otherActive: Bool = false
    /// Focused-row index for multi-select keyboard nav. `0..options.count-1`
    /// targets a preset row; `options.count` targets the Other row. Single-
    /// select pages ignore this field. Reset on every step change.
    private var focusedRow: Int = 0

    init(state: WizardState, panel: NSPanel, contentContainer: NSView,
         projectName: String, cwd: String) {
        self.state = state
        self.panel = panel
        self.container = contentContainer
        self.projectName = projectName
        self.cwd = cwd
    }

    /// Runs the wizard modally and returns its outcome.
    func run() -> WizardOutcome {
        renderCurrentStep()
        installKeyMonitor()
        NSApp.runModal(for: panel)
        removeKeyMonitor()
        return outcome
    }

    // MARK: Render

    private func renderCurrentStep() {
        // Clear container
        container.subviews.forEach { $0.removeFromSuperview() }
        currentQuestionHandles = nil

        let qIndex = state.step
        let q = state.questions[qIndex]
        // Every question except the last advances with "Next". The last
        // question's primary button is the final Submit — no separate
        // review step, matching Claude Code CLI's flow.
        let isLast = (qIndex == state.questions.count - 1)
        let h = buildWizardQuestionPanel(
            question: q, stepIndex: qIndex,
            totalSteps: state.questions.count,
            isLastStep: isLast,
            projectName: projectName,
            cwd: cwd)
        container.addSubview(h.root)
        resizePanelToFit(rootHeight: h.root.frame.height)
        currentQuestionHandles = h
        focusedRow = 0
        wireQuestionHandles(h, questionIndex: qIndex)
        applySelectionFromState(h, questionIndex: qIndex)
        applyProgress(dots: h.progressDots)
        // Back disabled on step 0
        h.backButton.isEnabled = (qIndex > 0)
        // Primary disabled until current question has an answer
        recomputePrimaryEnabled()

        if otherActive {
            h.otherRow.activate()
            h.otherRow.moveCaretToEnd()
        }
    }

    private func resizePanelToFit(rootHeight: CGFloat) {
        var frame = panel.frame
        let delta = rootHeight - container.frame.height
        frame.size.height += delta
        frame.origin.y -= delta
        panel.setFrame(frame, display: true)
        container.frame = NSRect(x: 0, y: 0, width: container.frame.width, height: rootHeight)
    }

    private func applyProgress(dots: [NSView]) {
        // Dots reflect the user's position in the wizard, not per-question
        // answer state. With pre-selected first options every answer is
        // immediately non-nil, so "answered" would paint all dots active
        // from the first paint. Position-based filling — dots 0..step are
        // green, the rest gray — correctly communicates progress.
        for (i, dot) in dots.enumerated() {
            let active = i <= state.step
            dot.layer?.backgroundColor = (active ? Theme.wizardProgressActive : Theme.wizardProgressInactive).cgColor
        }
    }

    private func applySelectionFromState(_ h: WizardQuestionPanelHandles, questionIndex: Int) {
        guard questionIndex >= 0, questionIndex < state.questions.count else { return }
        let answer = state.answers[questionIndex]
        for row in h.optionRowViews {
            row.layer?.backgroundColor = Theme.wizardRowBg.cgColor
            row.layer?.borderColor = Theme.wizardRowBorder.cgColor
            row.layer?.borderWidth = 1
        }

        if state.questions[questionIndex].multiSelect {
            // Multi: paint every ticked preset; Other row ticked iff custom != nil.
            if case .multi(let presets, let custom) = answer {
                for idx in presets where idx < h.optionRowViews.count {
                    let row = h.optionRowViews[idx]
                    row.layer?.backgroundColor = Theme.wizardRowSelectedBg.cgColor
                    row.layer?.borderColor = Theme.wizardRowSelectedBorder.cgColor
                }
                h.otherRow.setSelected(custom != nil || otherActive)
            } else {
                h.otherRow.setSelected(otherActive)
            }
            h.otherRow.setText(state.pendingCustom[questionIndex])
            // Overlay keyboard focus outline on the focused row.
            if focusedRow >= 0, focusedRow < h.optionRowViews.count {
                let row = h.optionRowViews[focusedRow]
                row.layer?.borderColor = Theme.wizardRowFocusBorder.cgColor
                row.layer?.borderWidth = Layout.wizardRowFocusBorderWidth
            } else if focusedRow == h.optionRowViews.count {
                h.otherRow.layer?.borderColor = Theme.wizardRowFocusBorder.cgColor
                h.otherRow.layer?.borderWidth = Layout.wizardRowFocusBorderWidth
            }
            return
        }

        // Single: existing behaviour, unchanged.
        h.otherRow.layer?.borderWidth = 1
        let isCustom: Bool = { if case .custom = answer { return true } else { return false } }()
        h.otherRow.setSelected(otherActive || isCustom)
        if !otherActive, case .preset(let idx) = answer, idx < h.optionRowViews.count {
            let row = h.optionRowViews[idx]
            row.layer?.backgroundColor = Theme.wizardRowSelectedBg.cgColor
            row.layer?.borderColor = Theme.wizardRowSelectedBorder.cgColor
        }
        h.otherRow.setText(state.pendingCustom[questionIndex])
    }

    // MARK: Wiring

    private func wireQuestionHandles(_ h: WizardQuestionPanelHandles, questionIndex: Int) {
        // Preset row clicks
        for (i, row) in h.optionRowViews.enumerated() {
            row.gestureRecognizers.forEach { row.removeGestureRecognizer($0) }
            let click = WizardClickGesture(
                target: self, action: #selector(onPresetClicked(_:)))
            click.payload = i
            row.addGestureRecognizer(click)
        }
        // Other row
        h.otherRow.onActivate = { [weak self] in
            guard let self = self else { return }
            self.activateOther(questionIndex: questionIndex)
        }
        h.otherRow.onTextChange = { [weak self] text in
            guard let self = self else { return }
            if self.state.questions[questionIndex].multiSelect {
                self.state.setMultiCustomText(question: questionIndex, text: text)
            } else {
                self.state.setPending(question: questionIndex, text: text)
                // If Other is the selected answer, update answers in real-time too
                if case .custom = self.state.answers[questionIndex] {
                    self.state.commitCustom(question: questionIndex, text: text)
                }
            }
            self.recomputePrimaryEnabled()
        }
        h.otherRow.onSubmit = { [weak self] in self?.advance() }
        h.otherRow.onEscape = { [weak self] in self?.exitOtherEditing() }
        h.otherRow.onRowHeightChange = { [weak self] delta in
            self?.applyOtherRowDelta(delta)
        }

        h.backButton.target = self
        h.backButton.action = #selector(onBack)
        h.primaryButton.target = self
        h.primaryButton.action = #selector(onPrimary)
        h.terminalButton.target = self
        h.terminalButton.action = #selector(onTerminal)
        h.cancelButton.target = self
        h.cancelButton.action = #selector(onCancel)
    }

    private func wireReviewHandles(_ h: WizardReviewPanelHandles) {
        for (i, row) in h.reviewRows.enumerated() {
            row.gestureRecognizers.forEach { row.removeGestureRecognizer($0) }
            let click = WizardClickGesture(
                target: self, action: #selector(onReviewRowClicked(_:)))
            click.payload = i
            row.addGestureRecognizer(click)
        }
        for (i, edit) in h.editButtons.enumerated() {
            edit.target = self
            edit.action = #selector(onEditClicked(_:))
            edit.tag = i
        }
        h.backButton.target = self
        h.backButton.action = #selector(onBack)
        h.submitButton.target = self
        h.submitButton.action = #selector(onPrimary)
        h.terminalButton.target = self
        h.terminalButton.action = #selector(onTerminal)
        h.cancelButton.target = self
        h.cancelButton.action = #selector(onCancel)
    }

    // MARK: Actions

    @objc private func onPresetClicked(_ g: WizardClickGesture) {
        guard let h = currentQuestionHandles else { return }
        let qi = state.step
        if g.payload >= 0, g.payload < h.optionRowViews.count {
            animateButtonPress(h.optionRowViews[g.payload])
        }
        if state.questions[qi].multiSelect {
            state.togglePreset(question: qi, optionIndex: g.payload)
            applySelectionFromState(h, questionIndex: qi)
            applyProgress(dots: h.progressDots)
            recomputePrimaryEnabled()
            return
        }
        let wasOtherActive = otherActive
        state.selectPreset(question: qi, optionIndex: g.payload)
        if wasOtherActive {
            otherActive = false
            renderCurrentStep()
        } else {
            applySelectionFromState(h, questionIndex: qi)
            applyProgress(dots: h.progressDots)
            recomputePrimaryEnabled()
        }
    }

    @objc private func onReviewRowClicked(_ g: WizardClickGesture) {
        jumpTo(step: g.payload)
    }

    @objc private func onEditClicked(_ sender: NSButton) {
        jumpTo(step: sender.tag)
    }

    @objc private func onBack() {
        // Press animation on the triggered button (mouse or keyboard path).
        // Background brightens + scales, matching Permission / Done dialogs.
        if let h = currentQuestionHandles {
            h.backButton.layer?.backgroundColor = Theme.wizardNeutralFillPress.cgColor
            animateButtonPress(h.backButton)
        }
        // Delay the re-render so the press animation has time to play out —
        // otherwise renderCurrentStep() replaces the button mid-animation and
        // the flash is invisible. Same delay Terminal / Ok / Submit already use.
        DispatchQueue.main.asyncAfter(deadline: .now() + Layout.pressAnimationDelay) { [weak self] in
            guard let self = self, self.state.step > 0 else { return }
            self.state.step -= 1
            self.otherActive = false
            self.renderCurrentStep()
        }
    }

    @objc private func onPrimary() {
        if let h = currentQuestionHandles {
            h.primaryButton.layer?.backgroundColor =
                Theme.buttonPersist.withAlphaComponent(Theme.buttonPressAlpha).cgColor
            animateButtonPress(h.primaryButton)
        }
        advance()
    }

    @objc private func onTerminal() {
        if let h = currentQuestionHandles {
            h.terminalButton.layer?.backgroundColor =
                Theme.buttonAllow.withAlphaComponent(Theme.buttonPressAlpha).cgColor
            animateButtonPress(h.terminalButton)
        }
        outcome = .terminal
        DispatchQueue.main.asyncAfter(deadline: .now() + Layout.pressAnimationDelay) {
            self.stopModal()
        }
    }

    @objc private func onCancel() {
        if let h = currentQuestionHandles {
            h.cancelButton.layer?.backgroundColor = Theme.wizardNeutralFillPress.cgColor
            animateButtonPress(h.cancelButton)
        }
        outcome = .cancel
        DispatchQueue.main.asyncAfter(deadline: .now() + Layout.pressAnimationDelay) {
            self.stopModal()
        }
    }

    private func advance() {
        let qi = state.step
        // Promote any typed-but-not-yet-committed Other text so Return submits it.
        if let h = currentQuestionHandles, otherActive {
            let text = h.otherRow.currentText
            if !text.isEmpty {
                state.commitCustom(question: qi, text: text)
            }
        }
        guard state.answers[qi] != nil else { return }
        if qi == state.questions.count - 1 {
            // Last question → final submit. Matches Claude Code CLI flow
            // (no separate review step).
            outcome = .submit(
                answers: buildWizardAnswersDict(state: state),
                reasonText: formatWizardAnswers(state: state))
            DispatchQueue.main.asyncAfter(deadline: .now() + Layout.pressAnimationDelay) {
                self.stopModal()
            }
        } else {
            // Delay the re-render so the Next button's press animation plays
            // out before the panel rebuilds. Without this the flash is cut
            // off mid-animation on non-last steps.
            DispatchQueue.main.asyncAfter(deadline: .now() + Layout.pressAnimationDelay) { [weak self] in
                guard let self = self else { return }
                self.state.step = qi + 1
                self.otherActive = false
                self.renderCurrentStep()
            }
        }
    }

    private func jumpTo(step: Int) {
        guard step >= 0 && step < state.questions.count else { return }
        state.step = step
        otherActive = false
        renderCurrentStep()
    }

    /// Expands the Other row for typing — the row itself adjusts its height
    /// via `refreshHeight` and broadcasts a delta the controller applies to
    /// siblings + panel in `applyOtherRowDelta`. No full re-render.
    ///
    /// On multi-select pages a tap flips the Other row's inclusion in the
    /// answer set: if it was already ticked (custom != nil) we untick it and
    /// deactivate typing; otherwise we enter typing mode and, if there's
    /// already pending text, auto-tick to match the keystroke-path contract.
    private func activateOther(questionIndex qi: Int) {
        guard let h = currentQuestionHandles else { return }
        if state.questions[qi].multiSelect {
            let alreadyTicked: Bool = {
                if case .multi(_, let c) = state.answers[qi], c != nil { return true }
                return false
            }()
            if alreadyTicked {
                state.toggleCustom(question: qi, on: false)
                otherActive = false
                h.otherRow.deactivate()
                applySelectionFromState(h, questionIndex: qi)
                recomputePrimaryEnabled()
                return
            }
            otherActive = true
            h.otherRow.activate()
            h.otherRow.moveCaretToEnd()
            if !state.pendingCustom[qi]
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state.toggleCustom(question: qi, on: true)
            }
            applySelectionFromState(h, questionIndex: qi)
            recomputePrimaryEnabled()
            return
        }
        if otherActive { return }
        otherActive = true
        // Press animation on the Other row as it activates.
        animateButtonPress(h.otherRow)
        // Pre-commit existing pending text so Submit-enabled reflects reality.
        let text = state.pendingCustom[qi]
        if !text.isEmpty {
            state.commitCustom(question: qi, text: text)
        }
        applySelectionFromState(h, questionIndex: qi)
        applyProgress(dots: h.progressDots)
        recomputePrimaryEnabled()
        h.otherRow.activate()
        h.otherRow.moveCaretToEnd()
    }

    /// Collapses the Other row back to rest height. Pending text stays in
    /// state and is displayed as the row's summary label.
    private func exitOtherEditing() {
        guard let h = currentQuestionHandles else { return }
        if !otherActive { return }
        otherActive = false
        h.otherRow.deactivate()
        applySelectionFromState(h, questionIndex: state.step)
        recomputePrimaryEnabled()
    }

    /// Applies a row-height delta in place: shifts siblings upward in body-
    /// local coordinates (so their world positions stay fixed), extends
    /// body/root, and grows the panel. No view hierarchy is torn down, so
    /// this is safe to call from inside the text view's own delegate.
    private func applyOtherRowDelta(_ delta: CGFloat) {
        guard let h = currentQuestionHandles, delta != 0 else { return }
        h.pill.frame.origin.y += delta
        h.questionField.frame.origin.y += delta
        for row in h.optionRowViews { row.frame.origin.y += delta }
        h.body.frame.size.height += delta
        h.root.frame.size.height += delta
        h.header.frame.origin.y += delta
        // Identity band sits above the header in root coordinates. Like
        // `header`, it must shift up by `delta` so it stays pinned to the
        // top of the (now-taller) root. Without this it drifts and the
        // ASKUSERQUESTION band overlaps it on each Other-row keystroke.
        h.identityHeader.frame.origin.y += delta
        resizePanelToFit(rootHeight: h.root.frame.height)
    }

    private func recomputePrimaryEnabled() {
        guard let h = currentQuestionHandles else { return }
        let qi = state.step
        guard qi >= 0, qi < state.questions.count else { return }
        let q = state.questions[qi]
        let isLast = (qi == state.questions.count - 1)
        let answered: Bool = {
            switch state.answers[qi] {
            case .none: return false
            case .some(.preset), .some(.custom): return true
            case .some(.multi(let p, let c)):
                return p.count + (c == nil ? 0 : 1) >= 1
            }
        }()
        if q.multiSelect {
            let count: Int = {
                if case .multi(let p, let c) = state.answers[qi] {
                    return p.count + (c == nil ? 0 : 1)
                }
                return 0
            }()
            let base = isLast ? WizardLabels.submit : WizardLabels.next
            h.primaryButton.title = base + String(format: WizardLabels.submitMultiTail, count)
        } else {
            h.primaryButton.title = isLast ? WizardLabels.submit : WizardLabels.next
        }
        applyWizardSubmitEnabled(h.primaryButton, enabled: answered, isSubmit: isLast)
    }

    private func stopModal() {
        NSApp.stopModal()
    }

    // MARK: Key handling

    private func installKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if self.handleKey(event) { return nil }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = localKeyMonitor {
            NSEvent.removeMonitor(m)
            localKeyMonitor = nil
        }
    }

    /// Returns true if the event was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        // If currently editing Other's text view, all keystrokes belong to the text view
        // EXCEPT Esc (handled by the text view delegate) and Return (handled there too).
        if otherActive {
            return false
        }

        let qi = state.step
        if qi >= 0, qi < state.questions.count,
           state.questions[qi].multiSelect {
            let q = state.questions[qi]
            let nPresets = q.options.count
            if let ch = event.charactersIgnoringModifiers,
               ch.count == 1, let scalar = ch.unicodeScalars.first,
               let digit = Int(String(scalar)) {
                if digit >= 1, digit <= nPresets {
                    focusedRow = digit - 1
                    state.togglePreset(question: qi, optionIndex: digit - 1)
                    if let h = self.currentQuestionHandles {
                        self.applySelectionFromState(h, questionIndex: qi)
                        self.recomputePrimaryEnabled()
                    }
                    return true
                }
                if digit == nPresets + 1 {
                    focusedRow = nPresets
                    activateOther(questionIndex: qi)
                    return true
                }
            }
            switch event.keyCode {
            case 49:  // Space
                if focusedRow < nPresets {
                    state.togglePreset(question: qi, optionIndex: focusedRow)
                } else {
                    activateOther(questionIndex: qi)
                }
                if let h = self.currentQuestionHandles {
                    self.applySelectionFromState(h, questionIndex: qi)
                    self.recomputePrimaryEnabled()
                }
                return true
            case 126:  // up arrow
                focusedRow = (focusedRow - 1 + nPresets + 1) % (nPresets + 1)
                if let h = self.currentQuestionHandles {
                    self.applySelectionFromState(h, questionIndex: qi)
                }
                return true
            case 125:  // down arrow
                focusedRow = (focusedRow + 1) % (nPresets + 1)
                if let h = self.currentQuestionHandles {
                    self.applySelectionFromState(h, questionIndex: qi)
                }
                return true
            default:
                break  // Fall through to shared Return / Esc / arrows handling
            }
        }

        switch event.keyCode {
        case 126: // up arrow
            moveSelection(by: -1); return true
        case 125: // down arrow
            moveSelection(by: +1); return true
        case 123: // left arrow
            onBack(); return true
        case 124: // right arrow
            onPrimary(); return true
        case 36, 76: // return / enter
            onPrimary(); return true
        case 53: // esc
            onCancel(); return true
        default:
            break
        }

        // Digit 1..9 jumps to option
        if let chars = event.charactersIgnoringModifiers,
           let c = chars.unicodeScalars.first,
           c.value >= 0x31 && c.value <= 0x39 {
            let digit = Int(c.value - 0x30) // 1..9
            selectOption(byNumber: digit)
            return true
        }
        return false
    }

    private func moveSelection(by delta: Int) {
        guard let h = currentQuestionHandles else { return }
        let qi = state.step
        let total = state.questions[qi].options.count + 1 // + Other
        let current: Int
        switch state.answers[qi] {
        case .preset(let i): current = i
        case .custom:         current = total - 1
        case .multi:
            // Multi-select pages have their own keyboard branch in handleKey;
            // this arm is unreachable in practice. Treated like .none for safety.
            current = otherActive ? (total - 1) : -1
        case .none:           current = otherActive ? (total - 1) : -1
        }
        let next = (current + delta + total) % total
        if next == total - 1 {
            activateOther(questionIndex: qi)
        } else {
            let wasOtherActive = otherActive
            state.selectPreset(question: qi, optionIndex: next)
            if wasOtherActive {
                otherActive = false
                renderCurrentStep()
                if let newH = currentQuestionHandles, next < newH.optionRowViews.count {
                    animateButtonPress(newH.optionRowViews[next])
                }
            } else {
                applySelectionFromState(h, questionIndex: qi)
                applyProgress(dots: h.progressDots)
                recomputePrimaryEnabled()
                if next < h.optionRowViews.count {
                    animateButtonPress(h.optionRowViews[next])
                }
            }
        }
    }

    private func selectOption(byNumber n: Int) {
        guard let h = currentQuestionHandles else { return }
        let qi = state.step
        let total = state.questions[qi].options.count
        if n <= total {
            let idx = n - 1
            let wasOtherActive = otherActive
            state.selectPreset(question: qi, optionIndex: idx)
            if wasOtherActive {
                otherActive = false
                renderCurrentStep()
                if let newH = currentQuestionHandles, idx < newH.optionRowViews.count {
                    animateButtonPress(newH.optionRowViews[idx])
                }
            } else {
                applySelectionFromState(h, questionIndex: qi)
                applyProgress(dots: h.progressDots)
                recomputePrimaryEnabled()
                if idx < h.optionRowViews.count {
                    animateButtonPress(h.optionRowViews[idx])
                }
            }
        } else if n == total + 1 {
            activateOther(questionIndex: qi)
        }
    }

}

/// A click-gesture subclass that carries a single `Int` payload so one
/// `@objc` action can service many rows without per-row subclassing.
/// Scoped narrowly to the wizard rather than adding methods to every NSObject.
private final class WizardClickGesture: NSClickGestureRecognizer {
    var payload: Int = 0
}

/// A borderless `NSPanel` that can become key. Borderless panels default to
/// `canBecomeKey == false`, which blocks keyboard events (typing, arrow-key
/// navigation) from reaching the wizard. We need them to reach us.
private final class WizardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Creates the NSPanel, installs a content container, and runs the wizard.
///
/// Mirrors the non-activating, all-Spaces behavior of the legacy permission
/// dialog so it behaves identically relative to the terminal. The initial
/// height is a placeholder — `WizardController` calls `resizePanelToFit` on
/// every render, so the panel snaps to its actual content height before the
/// modal begins.
///
/// There is no automatic timeout: an `AskUserQuestion` is always an explicit
/// request for user input, so walking away is the user's signal, not a
/// failure mode.
///
/// - Parameter questions: Parsed wizard questions to drive the UI.
/// - Returns: The user's outcome (submit with reasons, go-to-terminal, or cancel).
func runAskUserQuestionWizard(
    questions: [WizardQuestion],
    projectName: String,
    cwd: String
) -> WizardOutcome {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // Panel shell. Style `.titled + .fullSizeContentView` with a hidden
    // titlebar gives a borderless look while still behaving like a standard
    // panel for keyboard-focus purposes — pure `.borderless` + nonactivating
    // panels don't reliably accept keyDown events on all macOS versions.
    let initialHeight = Layout.wizardInitialPanelHeight
    let panel = WizardPanel(
        contentRect: NSRect(x: 0, y: 0, width: Layout.panelWidth, height: initialHeight),
        styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
        backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hasShadow = true
    panel.backgroundColor = Theme.background
    panel.isOpaque = false
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.standardWindowButton(.closeButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true
    panel.contentView?.wantsLayer = true
    panel.contentView?.layer?.cornerRadius = Layout.wizardPanelCornerRadius
    panel.contentView?.layer?.masksToBounds = true

    let container = NSView(frame: NSRect(x: 0, y: 0, width: Layout.panelWidth, height: initialHeight))
    panel.contentView?.addSubview(container)

    // Center on screen (slight bias above vertical center per wizardVerticalBias)
    if let screen = NSScreen.main {
        let scr = screen.visibleFrame
        let x = scr.origin.x + (scr.width - panel.frame.width) / 2
        let y = scr.origin.y + (scr.height - panel.frame.height) * Layout.wizardVerticalBias
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // Bring the wizard to front with keyboard focus. `activatePanel` runs
    // `NSApp.activate()` + `makeKeyAndOrderFront(nil)` — matches the legacy
    // permission dialog's focus-acquisition path.
    activatePanel(panel)

    // Sibling dialogs use SIGUSR1 to re-activate the next hook process.
    // Default action for SIGUSR1 is terminate — ignore it so a parallel dialog
    // dismiss cannot kill our modal while the user is answering.
    signal(SIGUSR1, SIG_IGN)

    let focusCleanup = installFocusRecoveryObservers(on: panel)
    defer { focusCleanup() }

    let state = WizardState(questions: questions)
    // UI-level convenience: pre-select the first option for every question
    // so Next / Submit is immediately actionable on first paint. Users can
    // still navigate with ↑/↓ or digits and pick a different option. Kept
    // out of WizardState's defaults because the state type is also used by
    // pure-logic tests that assume unanswered initial state.
    for (i, q) in questions.enumerated() where !q.options.isEmpty {
        state.selectPreset(question: i, optionIndex: 0)
    }
    let controller = WizardController(
        state: state, panel: panel, contentContainer: container,
        projectName: projectName, cwd: cwd)
    let outcome = controller.run()
    panel.orderOut(nil)
    return outcome
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

    // Re-activate on Space switch / app activation / screen wake
    let focusCleanup = installFocusRecoveryObservers(on: panel)

    // SIGUSR1: sibling dialog dismissed, re-activate
    signal(SIGUSR1, SIG_IGN)
    let signalSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    signalSource.setEventHandler {
        if panel.isVisible { activatePanel(panel); panel.display() }
    }
    signalSource.resume()

    defer {
        panel.orderOut(nil)
        focusCleanup()
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

    // AskUserQuestion: route well-formed prompts through the wizard instead of
    // the legacy read-only dialog. A malformed payload with no questions falls
    // through to the old dialog so the user still gets a "Go to Terminal" path.
    if input.toolName == "AskUserQuestion" {
        let questions = parseWizardQuestions(from: input.toolInput)
        if !questions.isEmpty {
            let outcome = runAskUserQuestionWizard(
                questions: questions,
                projectName: input.projectName,
                cwd: input.cwd)
            switch outcome {
            case .submit(let answers, _):
                // Inject the wizard's answers into the tool's `answers` field
                // via `updatedInput`, then allow the tool to run. AskUserQuestion
                // sees the answers are pre-collected and skips its native prompt.
                // Claude receives the answers as a normal tool result — no
                // "hook blocking error" banner.
                var updated = input.toolInput
                updated["answers"] = answers
                writeHookResponse(
                    decision: "allow",
                    reason: "Answers collected via wizard",
                    updatedInput: updated)
                notifyNextSiblingDialog()
                exit(0)
            case .terminal:
                openTerminalApp(cwd: input.cwd, sessionId: input.sessionId)
                writeHookResponse(decision: "allow", reason: "Allowed — terminal activated for user input")
                notifyNextSiblingDialog()
                exit(0)
            case .cancel:
                writeHookResponse(decision: "deny", reason: "User cancelled the question dialog")
                notifyNextSiblingDialog()
                exit(0)
            }
        }
        // Fallthrough: malformed AskUserQuestion with no questions → show the
        // old read-only dialog so the user still has Go to Terminal.
    }

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
