#!/usr/bin/env swift
//
//  claude-stop.swift
//  Claude Code Hook — Stop Notification Dialog
//
//  A lightweight macOS notification panel that appears whenever Claude finishes
//  a turn. Uses the same dark visual style as claude-approve: bold project header,
//  separator, green "Done" pill, gist line, and a scrollable content block showing
//  the last assistant message. Auto-dismisses after 15 seconds.
//
//  ## Hook Protocol
//  - **Input:**  JSON on stdin — `stop_hook_active`, `cwd`, `session_id`,
//                `last_assistant_message`
//  - **Output:** Nothing (exit 0; Claude continues normally)
//
//  ## Build
//  ```
//  swiftc -framework AppKit -o claude-stop claude-stop.swift
//  ```
//

import AppKit
import Foundation

// MARK: - Models

/// Parsed representation of the Stop hook JSON input.
struct StopInput {
    let stopHookActive: Bool
    let cwd: String
    let lastMessage: String

    /// Directory name shown as the project heading.
    var projectName: String { (cwd as NSString).lastPathComponent }
}

// MARK: - Theme

/// Visual theme constants — mirrors the dark palette used in claude-approve.
private enum Theme {
    // Backgrounds
    static let background     = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1)
    static let codeBackground = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)
    static let border         = NSColor(calibratedRed: 0.22, green: 0.22, blue: 0.26, alpha: 1)

    // Text
    static let textPrimary    = NSColor(calibratedWhite: 0.93, alpha: 1)
    static let textSecondary  = NSColor(calibratedWhite: 0.55, alpha: 1)
    static let codeText       = NSColor(calibratedRed: 0.78, green: 0.85, blue: 0.78, alpha: 1)

    // Tag / buttons
    static let doneTag        = NSColor(calibratedRed: 0.18, green: 0.80, blue: 0.44, alpha: 1)
    static let buttonGreen    = NSColor(calibratedRed: 0.18, green: 0.80, blue: 0.44, alpha: 1)
    static let buttonBlue     = NSColor(calibratedRed: 0.30, green: 0.56, blue: 1.0,  alpha: 1)
    static let buttonRestAlpha:  CGFloat = 0.18
    static let buttonPressAlpha: CGFloat = 0.55

    // Fonts
    static let mono       = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let buttonFont = NSFont.systemFont(ofSize: 12.5, weight: .bold)
}

// MARK: - Layout

/// Dimension and timing constants for the Stop dialog panel.
private enum Layout {
    // Panel
    static let panelWidth:        CGFloat = 580
    static let panelMargin:       CGFloat = 16
    static let panelInset:        CGFloat = 12
    static let panelTopPadding:   CGFloat = 14
    static let panelBottomPadding: CGFloat = 6

    // Header
    static let projectHeight:     CGFloat = 28
    static let projectFontSize:   CGFloat = 20
    static let pathHeight:        CGFloat = 18
    static let pathLineHeight:    CGFloat = 16
    static let pathFontSize:      CGFloat = 12

    // Separator / spacing
    static let separatorHeight:   CGFloat = 1
    static let sectionGap:        CGFloat = 10

    // Tag pill
    static let tagHeight:         CGFloat = 26
    static let tagFontSize:       CGFloat = 13
    static let tagTextPadding:    CGFloat = 20
    static let tagGistGap:        CGFloat = 10
    static let tagCornerRadius:   CGFloat = 5

    // Gist
    static let gistFontSize:      CGFloat = 15
    static let gistTrailingPad:   CGFloat = 42

    // Code block
    static let codeBlockGap:      CGFloat = 8
    static let codeCornerRadius:  CGFloat = 6
    static let codeBorderWidth:   CGFloat = 1
    static let codeTextInset:     CGFloat = 8
    static let codeScrollerWidth: CGFloat = 22
    static let minCodeBlockHeight: CGFloat = 36
    static let maxCodeBlockHeight: CGFloat = 400
    static let maxScreenFraction: CGFloat = 0.5
    static let minVerticalPadding: CGFloat = 8
    static let contentMeasurePad: CGFloat = 24

    // Buttons
    static let buttonHeight:      CGFloat = 34
    static let buttonGap:         CGFloat = 8
    static let buttonMargin:      CGFloat = 12
    static let buttonCornerRadius: CGFloat = 7
    static let buttonTopGap:      CGFloat = 10
    static let buttonBottomPad:   CGFloat = 12

    // Timing
    static let autoDismiss:           TimeInterval = 15
    static let pressAnimationDelay:   TimeInterval = 0.12
}

// MARK: - Input Parsing

/// Reads and parses the Stop hook input JSON from stdin.
///
/// - Returns: A populated `StopInput`. Missing fields default to `false` or empty strings.
private func parseStopInput() -> StopInput {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    return StopInput(
        stopHookActive: json["stop_hook_active"] as? Bool   ?? false,
        cwd:            json["cwd"]              as? String ?? "",
        lastMessage:    json["last_assistant_message"] as? String ?? ""
    )
}

// MARK: - Gist Generation

/// Strips block-level Markdown from a single line, leaving inline syntax intact.
///
/// Removes: headings, bullet/numbered list prefixes, blockquotes, and link URLs.
/// Inline formatting (`**bold**`, `*italic*`, `` `code` ``) is left in place so
/// `renderMarkdownInline` can render it as styled text.
///
/// - Parameter text: A single line potentially containing Markdown.
/// - Returns: The line with block-level syntax removed.
private func stripBlockMarkdown(_ text: String) -> String {
    var s = text
    s = s.replacingOccurrences(of: #"^#{1,6}\s+"#,  with: "", options: [.regularExpression, .anchored])
    s = s.replacingOccurrences(of: #"^[-*+]\s+"#,   with: "", options: [.regularExpression, .anchored])
    s = s.replacingOccurrences(of: #"^\d+\.\s+"#,   with: "", options: [.regularExpression, .anchored])
    s = s.replacingOccurrences(of: #"^>\s*"#,       with: "", options: [.regularExpression, .anchored])
    s = s.replacingOccurrences(of: #"\[(.+?)\]\(.+?\)"#, with: "$1", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespaces)
}

/// Returns an italic variant of `font` using font descriptor symbolic traits.
private func italicVariant(of font: NSFont) -> NSFont {
    let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
    return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
}

/// Renders inline Markdown spans within `text` as a styled `NSAttributedString`.
///
/// Handles (in priority order): `***bold italic***`, `**bold**`, `*italic*`,
/// `___bold italic___`, `__bold__`, `_italic_`, and `` `code` ``.
/// Unmatched text is rendered with `font` and `color`.
///
/// - Parameters:
///   - text:  The string possibly containing inline Markdown.
///   - font:  Base font (used for plain text and as size reference).
///   - color: Foreground color applied to all spans.
/// - Returns: An `NSAttributedString` with appropriate bold/italic/mono attributes.
private func renderMarkdownInline(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
    let size   = font.pointSize
    let bold   = NSFont.systemFont(ofSize: size, weight: .bold)
    let italic = italicVariant(of: NSFont.systemFont(ofSize: size))
    let boldIt = italicVariant(of: bold)
    let mono   = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)

    // Groups: 1=***bold-italic***, 2=**bold**, 3=*italic*,
    //         4=___bold-italic___, 5=__bold__,  6=_italic_,  7=`code`
    let pattern = #"\*{3}(.+?)\*{3}|\*{2}(.+?)\*{2}|\*(.+?)\*|_{3}(.+?)_{3}|_{2}(.+?)_{2}|_(.+?)_|`(.+?)`"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    let ns      = text as NSString
    let full    = NSRange(location: 0, length: ns.length)
    let matches = regex.matches(in: text, range: full)
    let result  = NSMutableAttributedString()
    var cursor  = 0

    let plain: (String) -> NSAttributedString = {
        NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: color])
    }
    let styled: (String, NSFont) -> NSAttributedString = {
        NSAttributedString(string: $0, attributes: [.font: $1, .foregroundColor: color])
    }

    for match in matches {
        if match.range.location > cursor {
            result.append(plain(ns.substring(with: NSRange(location: cursor,
                                                            length: match.range.location - cursor))))
        }
        let groupFonts: [(Int, NSFont)] = [(1, boldIt), (2, bold), (3, italic),
                                            (4, boldIt), (5, bold), (6, italic), (7, mono)]
        for (group, f) in groupFonts {
            let r = match.range(at: group)
            if r.location != NSNotFound {
                result.append(styled(ns.substring(with: r), f))
                break
            }
        }
        cursor = match.range.location + match.range.length
    }
    if cursor < ns.length {
        result.append(plain(ns.substring(from: cursor)))
    }
    return result
}

/// Returns the first non-blank line of the message with block-level Markdown stripped,
/// truncated to ~80 characters. Inline formatting is preserved for `renderMarkdownInline`.
///
/// Strips a leading "Done." prefix since the "Done" pill already conveys completion.
/// Falls back to "Claude has finished" when blank.
///
/// - Parameter message: The full `last_assistant_message` string.
/// - Returns: A short string (may still contain inline Markdown) for the Done pill gist.
private func buildStopGist(_ message: String) -> String {
    let firstLine = message
        .components(separatedBy: "\n")
        .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
    if firstLine.isEmpty { return "Claude has finished" }
    var line = firstLine.trimmingCharacters(in: .whitespaces)
    for prefix in ["Done. ", "Done! ", "Done.\n", "Done!"] {
        if line.lowercased().hasPrefix(prefix.lowercased()) {
            line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
    }
    line = stripBlockMarkdown(line)
    if line.isEmpty { return "Claude has finished" }
    return line.count > 80 ? String(line.prefix(77)) + "..." : line
}

// MARK: - Content Rendering

/// Builds the rendered attributed string for the scrollable content block.
///
/// Renders inline Markdown (bold, italic, code) per line. Code fences (```)
/// toggle monospaced mode for their contents. Headings (`#`) are rendered
/// bold at a slightly larger size. Bullet/numbered list prefixes are replaced
/// with `• `. All other prose uses the system font so formatting displays
/// correctly instead of appearing as raw `**asterisks**`.
///
/// - Parameter message: The raw `last_assistant_message` text.
/// - Returns: An `NSAttributedString` with formatting applied, trailing newlines stripped.
private func buildStopContent(_ message: String) -> NSAttributedString {
    let baseSize:    CGFloat = 14
    let baseFont             = NSFont.systemFont(ofSize: baseSize)
    let monoFont             = NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular)
    let headingFont          = NSFont.systemFont(ofSize: baseSize + 2, weight: .semibold)
    let color                = Theme.codeText
    let result               = NSMutableAttributedString()
    var inCodeFence          = false

    for rawLine in message.components(separatedBy: "\n") {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

        // Toggle code fence mode; render fence line in mono
        if trimmed.hasPrefix("```") {
            inCodeFence = !inCodeFence
            result.append(NSAttributedString(
                string: rawLine + "\n",
                attributes: [.font: monoFont, .foregroundColor: color]))
            continue
        }

        // Inside a code fence: keep raw monospaced
        if inCodeFence {
            result.append(NSAttributedString(
                string: rawLine + "\n",
                attributes: [.font: monoFont, .foregroundColor: color]))
            continue
        }

        // Heading: # Title → bold + slightly larger, strip the # prefix
        if trimmed.hasPrefix("#") {
            let headingText = trimmed.replacingOccurrences(
                of: #"^#{1,6}\s*"#, with: "", options: [.regularExpression, .anchored])
            let rendered = renderMarkdownInline(headingText, font: headingFont, color: color)
            let line = NSMutableAttributedString(attributedString: rendered)
            line.append(NSAttributedString(string: "\n"))
            result.append(line)
            continue
        }

        // Bullet list: - / * / + → • with indent
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            let itemText = "• " + String(trimmed.dropFirst(2))
            let rendered = renderMarkdownInline(itemText, font: baseFont, color: color)
            let line = NSMutableAttributedString(attributedString: rendered)
            line.append(NSAttributedString(string: "\n"))
            result.append(line)
            continue
        }

        // Numbered list: 1. text → keep number, render inline
        let numberedLine = rawLine.replacingOccurrences(
            of: #"^(\s*\d+\.)\s+"#, with: "$1 ", options: [.regularExpression, .anchored])

        // Regular prose: render inline markdown
        let rendered = renderMarkdownInline(numberedLine, font: baseFont, color: color)
        let line = NSMutableAttributedString(attributedString: rendered)
        line.append(NSAttributedString(string: "\n"))
        result.append(line)
    }

    // Strip trailing newlines
    while result.length > 0 {
        let range = NSRange(location: result.length - 1, length: 1)
        if result.attributedSubstring(from: range).string == "\n" {
            result.deleteCharacters(in: range)
        } else { break }
    }
    return result
}

/// Measures the rendered height of an attributed string at the given width.
///
/// - Parameters:
///   - content: The attributed string to measure.
///   - width: Available horizontal space in points.
/// - Returns: Required height in points, including vertical padding.
private func measureStopContentHeight(_ content: NSAttributedString, width: CGFloat) -> CGFloat {
    let storage   = NSTextStorage(attributedString: content)
    let layout    = NSLayoutManager()
    storage.addLayoutManager(layout)
    let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
    layout.addTextContainer(container)
    layout.ensureLayout(for: container)
    return layout.usedRect(for: container).height + Layout.contentMeasurePad
}

// MARK: - Focus Management

/// The frontmost application at hook launch time, captured before any UI activation.
/// Set once in the main entry point. Used by `openTerminalApp()`.
private var capturedTerminalApp: NSRunningApplication?

/// Activates the given panel and brings it to front with keyboard focus.
///
/// - Parameter panel: The `NSPanel` to make key and bring to front.
private func activateStopPanel(_ panel: NSPanel) {
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

    return (foundTTY, foundApp)
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

/// Recursively searches the Accessibility tree for a clickable element whose
/// title or value contains `substring` (case-insensitive) and presses it.
///
/// Used by JetBrains IDEs to activate the Terminal tool window. Only matches
/// elements whose role is in `roles` — typically buttons, radio buttons, tabs.
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
    return searchAXTree(element: axApp, needle: substring.lowercased(), roles: roles, depth: 0, maxDepth: maxDepth)
}

/// Recursive helper for `focusAXDescendant`.
private func searchAXTree(element: AXUIElement, needle: String, roles: Set<String>, depth: Int, maxDepth: Int) -> Bool {
    if depth > maxDepth { return false }

    var roleRef: CFTypeRef?
    let role: String? = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success
        ? (roleRef as? String) : nil

    var titleRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
       let title = titleRef as? String, !title.isEmpty,
       title.lowercased().contains(needle),
       let r = role, roles.contains(r) {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
        return true
    }

    var valueRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
       let value = valueRef as? String, !value.isEmpty,
       value.lowercased().contains(needle),
       let r = role, roles.contains(r) {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
        return true
    }

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
/// - **Other** (VS Code, Kitty, etc.): AX window-title match, standard activation.
///
/// - Parameter cwd: The current working directory, used to extract the project
///   name for window-title matching.
private func openTerminalApp(cwd: String) {
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

// MARK: - Button Handler

/// Manages button press animation and result tracking for the Stop notification dialog.
///
/// Tracks whether the user chose "Go to Terminal" via `goToTerminal`, prevents double-press
/// via `pressing`, and drives both click and keyboard-shortcut code paths through
/// `animatePress(index:)`.
private final class StopHandler: NSObject {
    /// `true` if the user pressed "Go to Terminal" (index 0); `false` for "Ok".
    var goToTerminal = false
    private(set) var buttons: [NSButton] = []
    private(set) var colors:  [NSColor]  = []
    private var pressing = false

    /// Registers a button and its associated highlight color with this handler.
    ///
    /// - Parameters:
    ///   - button: The `NSButton` to register.
    ///   - color: The color used for the pressed-state highlight.
    func register(button: NSButton, color: NSColor) {
        buttons.append(button)
        colors.append(color)
    }

    /// Visually depresses `button` at `index`, records the user's intent, then stops the modal.
    ///
    /// Uses `CATransaction` to force an immediate layer flush so the pressed state renders
    /// reliably even on panels that were backgrounded at launch. Safe to call from both
    /// keyboard and mouse handlers — the `pressing` guard prevents double-firing.
    ///
    /// - Parameter index: Zero-based index into `buttons` and `colors`.
    func animatePress(index: Int) {
        guard !pressing, index >= 0, index < buttons.count else { return }
        pressing = true
        goToTerminal = (index == 0)
        let btn = buttons[index]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        btn.layer?.backgroundColor = colors[index].withAlphaComponent(Theme.buttonPressAlpha).cgColor
        CATransaction.commit()
        CATransaction.flush()
        btn.display()
        DispatchQueue.main.asyncAfter(deadline: .now() + Layout.pressAnimationDelay) {
            NSApp.stopModal()
        }
    }

    /// Button click target — delegates to `animatePress(index:)` via the button's tag.
    @objc func tapped(_ sender: NSButton) { animatePress(index: sender.tag) }
}

// MARK: - Dialog Construction

/// Creates and positions the floating `NSPanel` for the Stop dialog.
///
/// - Parameter height: Total panel height in points.
/// - Returns: A configured floating `NSPanel` centered on the main screen.
private func makeStopPanel(height: CGFloat) -> NSPanel {
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
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - Layout.panelWidth / 2, y: f.midY - height / 2))
    } else {
        panel.center()
    }
    return panel
}

/// Adds the session identity header — project name, full path, and separator — to `contentView`.
///
/// - Parameters:
///   - contentView: The panel's root view.
///   - input: Stop hook input supplying `projectName` and `cwd`.
///   - panelHeight: Total panel height, used as the Y origin for top-down layout.
/// - Returns: The Y position immediately below the separator, ready for the next row.
private func addStopHeader(to contentView: NSView, input: StopInput, panelHeight: CGFloat) -> CGFloat {
    var y = panelHeight - Layout.panelTopPadding

    y -= Layout.projectHeight
    let projectLabel = NSTextField(labelWithString: input.projectName)
    projectLabel.font = NSFont.systemFont(ofSize: Layout.projectFontSize, weight: .bold)
    projectLabel.textColor = Theme.textPrimary
    projectLabel.frame = NSRect(x: Layout.panelMargin, y: y,
                                width: Layout.panelWidth - Layout.panelMargin * 2,
                                height: Layout.projectHeight)
    projectLabel.lineBreakMode = .byTruncatingTail
    contentView.addSubview(projectLabel)

    y -= Layout.pathHeight
    let pathLabel = NSTextField(labelWithString: input.cwd)
    pathLabel.font = NSFont.systemFont(ofSize: Layout.pathFontSize, weight: .regular)
    pathLabel.textColor = Theme.textSecondary
    pathLabel.frame = NSRect(x: Layout.panelMargin, y: y,
                             width: Layout.panelWidth - Layout.panelMargin * 2,
                             height: Layout.pathLineHeight)
    pathLabel.lineBreakMode = .byTruncatingMiddle
    contentView.addSubview(pathLabel)

    y -= Layout.sectionGap
    let separator = NSBox(frame: NSRect(x: Layout.panelInset, y: y,
                                        width: Layout.panelWidth - Layout.panelInset * 2,
                                        height: Layout.separatorHeight))
    separator.boxType = .separator
    contentView.addSubview(separator)

    return y
}

/// Adds the "Done" tag pill and gist label to `contentView`.
///
/// - Parameters:
///   - contentView: The panel's root view.
///   - gist: The short summary string displayed beside the pill.
///   - yPos: The Y coordinate immediately below the separator.
/// - Returns: The Y position at the bottom of the tag row.
private func addStopTagAndGist(to contentView: NSView, gist: String, yPos: CGFloat) -> CGFloat {
    let y = yPos - Layout.sectionGap - Layout.tagHeight

    let tagFont  = NSFont.systemFont(ofSize: Layout.tagFontSize, weight: .bold)
    let tagTextW = ("Done" as NSString).size(withAttributes: [.font: tagFont]).width
    let tagWidth = tagTextW + Layout.tagTextPadding

    let tagPill = NSButton(frame: NSRect(x: Layout.panelMargin, y: y,
                                         width: tagWidth, height: Layout.tagHeight))
    tagPill.title = "Done"
    tagPill.bezelStyle = .rounded
    tagPill.isBordered = false
    tagPill.wantsLayer = true
    tagPill.layer?.cornerRadius = Layout.tagCornerRadius
    tagPill.layer?.backgroundColor = Theme.doneTag.withAlphaComponent(Theme.buttonRestAlpha).cgColor
    tagPill.font = tagFont
    tagPill.contentTintColor = Theme.doneTag
    tagPill.focusRingType = .none
    tagPill.refusesFirstResponder = true
    contentView.addSubview(tagPill)

    // Build the gist text view using the same explicit text-system chain as the
    // code block — NSTextStorage → NSLayoutManager → NSTextContainer → NSTextView.
    // NSTextView(frame:textContainer:) reliably renders attributed fonts/styles;
    // NSTextField label mode and NSTextView(frame:) both discard mixed font attrs.
    let gistFont   = NSFont.systemFont(ofSize: Layout.gistFontSize, weight: .bold)
    let attributed = renderMarkdownInline(gist, font: gistFont, color: Theme.textPrimary)
    let gistWidth  = Layout.panelWidth - Layout.gistTrailingPad - tagWidth

    let gistStorage = NSTextStorage(attributedString: attributed)
    let gistLayout  = NSLayoutManager()
    gistStorage.addLayoutManager(gistLayout)
    let gistContainer = NSTextContainer(size: NSSize(width: gistWidth, height: 200))
    gistContainer.maximumNumberOfLines = 1
    gistContainer.lineBreakMode        = .byTruncatingTail
    gistContainer.lineFragmentPadding  = 0
    gistLayout.addTextContainer(gistContainer)
    gistLayout.ensureLayout(for: gistContainer)

    let gistH = max(ceil(gistLayout.usedRect(for: gistContainer).height),
                    gistFont.capHeight + 4)

    let gistView = NSTextView(
        frame: NSRect(
            x: Layout.panelMargin + tagWidth + Layout.tagGistGap,
            y: y + (Layout.tagHeight - gistH) / 2,
            width: gistWidth,
            height: gistH
        ),
        textContainer: gistContainer
    )
    gistView.isEditable      = false
    gistView.isSelectable    = false
    gistView.drawsBackground = false
    gistView.textContainerInset = .zero
    contentView.addSubview(gistView)

    return y
}

/// Adds the scrollable code block displaying `content` to `contentView`.
///
/// - Parameters:
///   - contentView: The panel's root view.
///   - content: The attributed string to display.
///   - blockHeight: Pre-calculated height for the block.
///   - yPos: The Y coordinate at the bottom of the tag row.
/// - Returns: The Y position at the bottom edge of the code block.
private func addStopCodeBlock(to contentView: NSView, content: NSAttributedString,
                               blockHeight: CGFloat, yPos: CGFloat) -> CGFloat {
    let bottom = yPos - Layout.codeBlockGap - blockHeight

    let codeContainer = NSView(frame: NSRect(x: Layout.panelInset, y: bottom,
                                              width: Layout.panelWidth - Layout.panelInset * 2,
                                              height: blockHeight))
    codeContainer.wantsLayer = true
    codeContainer.layer?.backgroundColor = Theme.codeBackground.cgColor
    codeContainer.layer?.cornerRadius = Layout.codeCornerRadius
    codeContainer.layer?.borderWidth = Layout.codeBorderWidth
    codeContainer.layer?.borderColor = Theme.border.cgColor
    contentView.addSubview(codeContainer)

    let scrollView = NSScrollView(frame: NSRect(
        x: Layout.codeBorderWidth, y: Layout.codeBorderWidth,
        width:  codeContainer.frame.width  - Layout.codeBorderWidth * 2,
        height: codeContainer.frame.height - Layout.codeBorderWidth * 2
    ))
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder

    let textStorage = NSTextStorage(attributedString: content)
    let layoutManager = NSLayoutManager()
    textStorage.addLayoutManager(layoutManager)
    let textContainer = NSTextContainer(size: NSSize(
        width: scrollView.frame.width - Layout.codeScrollerWidth,
        height: .greatestFiniteMagnitude
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
    layoutManager.ensureLayout(for: textContainer)

    let textHeight = layoutManager.usedRect(for: textContainer).height
    let vertPad = max(Layout.minVerticalPadding, (scrollView.frame.height - textHeight) / 2)
    textView.textContainerInset = NSSize(width: Layout.codeTextInset, height: vertPad)
    textView.autoresizingMask = [.width]
    textView.frame.size.height = max(textHeight + vertPad * 2, scrollView.frame.height)

    scrollView.documentView = textView
    codeContainer.addSubview(scrollView)
    return bottom
}

/// Adds the "Go to Terminal" and "Ok" buttons to `contentView`, wired to `handler`.
///
/// Sets "Ok" as the panel's `defaultButtonCell` so Enter triggers it by default
/// (keyboard shortcuts override this via the local event monitor).
///
/// - Parameters:
///   - contentView: The panel's root view.
///   - handler: The `StopHandler` that receives button taps.
///   - panel: The panel, used to set `defaultButtonCell`.
///   - bottomY: The Y coordinate at the bottom edge of the code block.
private func addStopButtons(to contentView: NSView, handler: StopHandler,
                             panel: NSPanel, bottomY: CGFloat) {
    let availW   = Layout.panelWidth - Layout.buttonMargin * 2
    let buttonW  = (availW - Layout.buttonGap) / 2
    let buttonY  = bottomY - Layout.buttonTopGap - Layout.buttonHeight

    let specs: [(title: String, color: NSColor)] = [
        ("Go to Terminal", Theme.buttonGreen),
        ("Ok",             Theme.buttonBlue),
    ]
    for (i, spec) in specs.enumerated() {
        let x = Layout.buttonMargin + CGFloat(i) * (buttonW + Layout.buttonGap)
        let btn = NSButton(frame: NSRect(x: x, y: buttonY, width: buttonW, height: Layout.buttonHeight))
        btn.title = spec.title
        btn.alignment = .center
        btn.bezelStyle = .rounded
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = Layout.buttonCornerRadius
        btn.layer?.backgroundColor = spec.color.withAlphaComponent(Theme.buttonRestAlpha).cgColor
        btn.contentTintColor = spec.color
        btn.font = Theme.buttonFont
        btn.focusRingType = .none
        btn.tag = i
        btn.target = handler
        btn.action = #selector(StopHandler.tapped(_:))
        contentView.addSubview(btn)
        handler.register(button: btn, color: spec.color)
        if i == 1 { panel.defaultButtonCell = btn.cell as? NSButtonCell }
    }
}

/// Builds and runs the Done notification panel, blocking until the user dismisses it
/// or the auto-dismiss timer fires.
///
/// After the modal exits, activates the user's terminal if "Go to Terminal" was chosen.
///
/// - Parameter input: Parsed Stop hook input providing project context and last message.
private func showStopDialog(input: StopInput) {
    let content = buildStopContent(input.lastMessage)
    let gist    = buildStopGist(input.lastMessage)

    // Calculate code block height
    let screenH   = NSScreen.main?.visibleFrame.height ?? 800
    let maxBlockH = min(Layout.maxCodeBlockHeight, screenH * Layout.maxScreenFraction)
    let measureW  = Layout.panelWidth - Layout.panelInset * 2 - Layout.codeScrollerWidth
    let blockH    = content.length > 0
        ? max(Layout.minCodeBlockHeight, min(measureStopContentHeight(content, width: measureW), maxBlockH))
        : CGFloat(0)

    // Calculate total panel height
    let buttonAreaH = Layout.buttonTopGap + Layout.buttonHeight + Layout.buttonBottomPad
    let panelH = Layout.panelTopPadding + Layout.projectHeight + Layout.pathHeight
        + Layout.sectionGap + Layout.separatorHeight
        + Layout.sectionGap + Layout.tagHeight
        + (blockH > 0 ? Layout.codeBlockGap + blockH : 0)
        + buttonAreaH + Layout.panelBottomPadding

    // Build panel and content view
    let panel = makeStopPanel(height: panelH)
    let cv    = NSView(frame: NSRect(x: 0, y: 0, width: Layout.panelWidth, height: panelH))
    cv.wantsLayer = true
    cv.layer?.backgroundColor = Theme.background.cgColor
    panel.contentView = cv

    // Lay out UI sections top-down
    let afterHeader = addStopHeader(to: cv, input: input, panelHeight: panelH)
    let afterTag    = addStopTagAndGist(to: cv, gist: gist, yPos: afterHeader)
    let codeBottom  = blockH > 0
        ? addStopCodeBlock(to: cv, content: content, blockHeight: blockH, yPos: afterTag)
        : afterTag

    // Buttons
    let handler = StopHandler()
    addStopButtons(to: cv, handler: handler, panel: panel, bottomY: codeBottom)

    // Keyboard: 1/Enter → Go to Terminal, 2/Esc → Ok
    let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        switch event.charactersIgnoringModifiers ?? "" {
        case "1", "\r":     handler.animatePress(index: 0); return nil
        case "2", "\u{1b}": handler.animatePress(index: 1); return nil
        default:            return event
        }
    }

    // Auto-dismiss
    DispatchQueue.main.asyncAfter(deadline: .now() + Layout.autoDismiss) { NSApp.stopModal() }

    // Re-activate on Space switch
    let spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification,
        object: nil, queue: .main
    ) { _ in if panel.isVisible { activateStopPanel(panel) } }

    defer {
        NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
    }
    activateStopPanel(panel)
    NSApp.runModal(for: panel)

    // Hide the floating panel BEFORE activating the terminal, otherwise
    // the panel covers the terminal window at the floating level.
    panel.orderOut(nil)

    if handler.goToTerminal { openTerminalApp(cwd: input.cwd) }
}

// MARK: - Main Entry Point

/// Main execution flow:
/// 1. Parse Stop hook input from stdin
/// 2. Guard against infinite loops (`stop_hook_active == true` → exit immediately)
/// 3. Initialize headless NSApplication and show the Done dialog
/// 4. Exit 0 — Claude continues normally (no stdout output)

let stopInput = parseStopInput()

// Safety guard: if a Stop hook fired this process, don't loop infinitely
if stopInput.stopHookActive { exit(0) }

// Capture terminal/IDE before activating our own UI
capturedTerminalApp = NSWorkspace.shared.frontmostApplication

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
NSSound(named: "Blow")?.play()

showStopDialog(input: stopInput)
exit(0)
