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

/// Returns the first non-blank line of the message, truncated to ~80 characters.
///
/// Strips a leading "Done." prefix (case-insensitive) since the "Done" pill
/// already conveys completion. Falls back to "Claude has finished" when blank.
///
/// - Parameter message: The full `last_assistant_message` string.
/// - Returns: A short gist string for display next to the Done pill.
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
    if line.isEmpty { return "Claude has finished" }
    return line.count > 80 ? String(line.prefix(77)) + "..." : line
}

// MARK: - Content Rendering

/// Builds the monospaced attributed string for the scrollable content block.
///
/// - Parameter message: The raw `last_assistant_message` text.
/// - Returns: An `NSAttributedString` rendered in `Theme.mono` with trailing newlines stripped.
private func buildStopContent(_ message: String) -> NSAttributedString {
    let result = NSMutableAttributedString()
    for line in message.components(separatedBy: "\n") {
        result.append(NSAttributedString(
            string: line + "\n",
            attributes: [.font: Theme.mono, .foregroundColor: Theme.codeText]
        ))
    }
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

/// Activates the given panel and brings it to front with keyboard focus.
///
/// - Parameter panel: The `NSPanel` to make key and bring to front.
private func activateStopPanel(_ panel: NSPanel) {
    NSApp.activate()
    panel.makeKeyAndOrderFront(nil)
}

/// Returns the parent process ID of `pid` by invoking `/bin/ps`.
private func parentProcessID(of pid: pid_t) -> pid_t? {
    let pipe = Pipe()
    let ps   = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments     = ["-p", String(pid), "-o", "ppid="]
    ps.standardOutput = pipe
    try? ps.run()
    ps.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return pid_t(out.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Finds and activates the terminal application that spawned this Claude session.
///
/// Walks up the process parent chain (up to 15 levels) looking for a running
/// application whose bundle identifier matches a known terminal emulator. Activating
/// by exact PID ensures the correct terminal window comes forward even when multiple
/// terminal types or multiple windows of the same type are open simultaneously.
/// Falls back to `TERM_PROGRAM` environment variable detection if the walk fails.
private func openTerminalApp() {
    let knownTerminals: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.microsoft.VSCode",
        "com.jetbrains.webstorm",
        "com.jetbrains.rider",
        "com.jetbrains.idea",
    ]
    var pid = ProcessInfo.processInfo.processIdentifier
    for _ in 0..<15 {
        guard let ppid = parentProcessID(of: pid), ppid > 1 else { break }
        pid = ppid
        if let app = NSRunningApplication(processIdentifier: pid),
           let bundleId = app.bundleIdentifier,
           knownTerminals.contains(bundleId) {
            app.activate()
            return
        }
    }
    // Fallback: TERM_PROGRAM env var
    let bundleId: String
    switch ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "" {
    case "iTerm.app":    bundleId = "com.googlecode.iterm2"
    case "WarpTerminal": bundleId = "dev.warp.Warp-Stable"
    case "vscode":       bundleId = "com.microsoft.VSCode"
    default:             bundleId = "com.apple.Terminal"
    }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
        NSWorkspace.shared.open(url)
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

    let gistLabel = NSTextField(labelWithString: gist)
    gistLabel.font = NSFont.systemFont(ofSize: Layout.gistFontSize, weight: .bold)
    gistLabel.textColor = Theme.textPrimary
    gistLabel.sizeToFit()
    let gistH = gistLabel.frame.height
    gistLabel.frame = NSRect(
        x: Layout.panelMargin + tagWidth + Layout.tagGistGap,
        y: y + (Layout.tagHeight - gistH) / 2,
        width: Layout.panelWidth - Layout.gistTrailingPad - tagWidth,
        height: gistH
    )
    gistLabel.lineBreakMode = .byTruncatingTail
    contentView.addSubview(gistLabel)

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
        panel.orderOut(nil)
        NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
    }
    activateStopPanel(panel)
    NSApp.runModal(for: panel)

    if handler.goToTerminal { openTerminalApp() }
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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
NSSound(named: "Blow")?.play()

showStopDialog(input: stopInput)
exit(0)
