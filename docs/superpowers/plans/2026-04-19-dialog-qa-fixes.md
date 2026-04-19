# Dialog QA Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land four targeted QA fixes on top of the dialog-unification feature: (1) wizard keyboard navigation triggers the same press animation as mouse clicks, (2) every dialog regains focus after Space switching, app switching, screen wake, and first-present settle, (3) the Permission dialog's "No…" morph accepts multi-line input via Shift+Enter, and (4) the `Go to Terminal` label becomes `Go to Claude Desktop` when the parent app is Claude Desktop.

**Architecture:** Every change lives in the two existing single-file scripts (`hooks/claude-approve.swift`, `hooks/claude-stop.swift`). A shared pattern — `installFocusRecoveryObservers(on:)` — is added in both files as parallel local copies (per project's single-file rule). The deny-morph rewrite mirrors the structure of `WizardOtherRow.buildTextView`. The terminal-label helper consults `resolveProcessAncestry` + `capturedTerminalApp` to pick between constants in the existing `WizardLabels` / `StopLabels` enums.

**Tech Stack:** Swift 5, AppKit. Compiled with `swiftc -O -parse-as-library -framework AppKit`. Tests run with `bash tests/run.sh`.

---

## Non-negotiable guardrail

Every implementation step must preserve:

- Every button's click target, `resultKey`, outcome, action-dispatch path.
- Every keyboard shortcut (1…N digits, Enter, Esc, wizard's ↑↓←→, Shift+Enter in Other row).
- Modal lifecycle (`NSApp.runModal(for:)`, `NSApp.stopModal`).
- The 600-s dialog timeout; the 15-s Done auto-dismiss.
- SIGUSR1 sibling-dialog coordination.
- The existing `openTerminalApp` bundle-ID switch (only the button label changes, not the action behind it).
- Session identity display (project name + cwd).
- Wizard state machine.
- `WizardOtherRow` behavior (it is the model the deny-morph will follow, not be altered by).

Any step that appears to require touching any of the above: report BLOCKED.

---

## Reference

- Spec: `docs/superpowers/specs/2026-04-19-dialog-qa-fixes-design.md`
- Prior plan (visual unification): `docs/superpowers/plans/2026-04-19-dialog-visual-unification.md`
- Key existing functions / classes referenced:
  - `activatePanel(_:)` — `hooks/claude-approve.swift`
  - `resolveProcessAncestry()` — `hooks/claude-approve.swift`
  - `capturedTerminalApp` — `hooks/claude-approve.swift`
  - `animateButtonPress(_:restFillColor:)` — `hooks/claude-approve.swift`
  - `WizardController.moveSelection(by:)` and `.selectOption(byNumber:)` — `hooks/claude-approve.swift`
  - `ButtonHandler.morphToTextField(index:)` — `hooks/claude-approve.swift`
  - `WizardOtherRow.buildTextView()` and `.textView(_:doCommandBy:)` — `hooks/claude-approve.swift`
  - `showPermissionDialog(...)` space-observer block — `hooks/claude-approve.swift`
  - `showStopDialog(input:)` / `addStopButtons(...)` / `makeStopPanel(...)` — `hooks/claude-stop.swift`
  - `WizardLabels` / `StopLabels` / `PermissionLabels` enums — both files

## Working convention

- Every task ends with a commit. Imperative subject under 72 chars. No `Co-Authored-By`.
- Run `bash tests/run.sh` after every task — must pass.
- Build both binaries after source edits (`swiftc -O -parse-as-library -framework AppKit -o …`).

---

## Task 1 — Wizard: press animation on keyboard selection paths

**Files:**
- Modify: `hooks/claude-approve.swift` — `WizardController.moveSelection(by:)` and `.selectOption(byNumber:)`.

- [ ] **Step 1.1 — Find both methods**

Run: `grep -n 'private func moveSelection\|private func selectOption' hooks/claude-approve.swift`

You will find two methods inside `final class WizardController`. Their current shape:

```swift
private func moveSelection(by delta: Int) {
    guard let h = currentQuestionHandles else { return }
    let qi = state.step
    let total = state.questions[qi].options.count + 1   // + Other
    let current: Int
    switch state.answers[qi] {
    case .preset(let i): current = i
    case .custom:         current = total - 1
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
        } else {
            applySelectionFromState(h, questionIndex: qi)
            applyProgress(dots: h.progressDots)
            recomputePrimaryEnabled()
        }
    }
}

private func selectOption(byNumber n: Int) {
    guard let h = currentQuestionHandles else { return }
    let qi = state.step
    let total = state.questions[qi].options.count
    if n <= total {
        let wasOtherActive = otherActive
        state.selectPreset(question: qi, optionIndex: n - 1)
        if wasOtherActive {
            otherActive = false
            renderCurrentStep()
        } else {
            applySelectionFromState(h, questionIndex: qi)
            applyProgress(dots: h.progressDots)
            recomputePrimaryEnabled()
        }
    } else if n == total + 1 {
        activateOther(questionIndex: qi)
    }
}
```

- [ ] **Step 1.2 — Add `animateButtonPress` calls**

Replace both methods with:

```swift
private func moveSelection(by delta: Int) {
    guard let h = currentQuestionHandles else { return }
    let qi = state.step
    let total = state.questions[qi].options.count + 1   // + Other
    let current: Int
    switch state.answers[qi] {
    case .preset(let i): current = i
    case .custom:         current = total - 1
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
```

The new calls run AFTER the selection state + visual highlight are in place, so the animation plays on the correctly-highlighted row. When `wasOtherActive` was true and we re-render, we look up the fresh `currentQuestionHandles` (because `renderCurrentStep` replaces them) before animating.

`activateOther` already calls `animateButtonPress(h.otherRow)` internally — no change needed for the Other-row branches.

- [ ] **Step 1.3 — Build + test**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift && cd ..`
Run: `bash tests/run.sh`
Expected: pass.

- [ ] **Step 1.4 — Commit**

```bash
git add hooks/claude-approve.swift
git commit -m "Animate wizard rows on keyboard selection paths"
```

---

## Task 2 — Shared focus-recovery helper

**Files:**
- Modify: `hooks/claude-approve.swift` — add `installFocusRecoveryObservers(on:)` near `activatePanel`.
- Modify: `hooks/claude-stop.swift` — add the parallel copy.

The helper installs four observers and returns a `cleanup` closure. Same body in both files per the single-file rule.

- [ ] **Step 2.1 — Add helper to `claude-approve.swift`**

Grep for `private func activatePanel` to find the Focus Management section. Immediately below `activatePanel(_:)`, add:

```swift
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
```

- [ ] **Step 2.2 — Add helper to `claude-stop.swift`**

Grep for `private func activatePanel` (or the section that holds the stop dialog's focus helpers) in `hooks/claude-stop.swift`. If `activatePanel` is not in that file, find its Focus Management section (or wherever button press / animation helpers live — search `private func animateButtonPress`) and add the helper body there.

Copy the **exact** function from Step 2.1 into `claude-stop.swift` with one difference: if `claude-stop.swift` does not already define an `activatePanel` function, rename the call inside `reactivate` and inside the `asyncAfter` closure to the stop file's equivalent (search for `NSApp.activate` + `panel.makeKeyAndOrderFront` in that file to find the local activation helper). If no equivalent exists, inline:

```swift
NSApp.activate(ignoringOtherApps: true)
panel.makeKeyAndOrderFront(nil)
```

in place of `activatePanel(p)` in both call sites.

- [ ] **Step 2.3 — Build both + test**

Run:
```bash
cd hooks && \
  swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift && \
  swiftc -O -parse-as-library -framework AppKit -o claude-stop    claude-stop.swift    && \
  cd ..
bash tests/run.sh
```
Expected: both compile; tests pass.

- [ ] **Step 2.4 — Commit**

```bash
git add hooks/claude-approve.swift hooks/claude-stop.swift
git commit -m "Add installFocusRecoveryObservers helper in both files"
```

---

## Task 3 — Wire focus helper into all three dialogs

**Files:**
- Modify: `hooks/claude-approve.swift` — `showPermissionDialog` + `runAskUserQuestionWizard`.
- Modify: `hooks/claude-stop.swift` — `showStopDialog`.

Replace the existing ad-hoc Space-switch observers with the new helper; add it to the wizard (no existing observers).

- [ ] **Step 3.1 — Replace in `showPermissionDialog`**

Grep: `grep -n 'activeSpaceDidChangeNotification' hooks/claude-approve.swift`. Find the block inside `showPermissionDialog`:

```swift
// Re-activate on Space switch
let spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification,
    object: nil, queue: .main
) { _ in if panel.isVisible { activatePanel(panel) } }
```

And the corresponding `NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)` in the `defer` block. Replace the whole install-then-remove pair with:

```swift
let focusCleanup = installFocusRecoveryObservers(on: panel)
```

Add `focusCleanup()` inside the existing `defer { … }` block (in place of the old `removeObserver(spaceObserver)` line). Keep every other line inside `defer` untouched (the key monitor removal, signal source cancellation, panel.orderOut, etc.).

- [ ] **Step 3.2 — Add to `runAskUserQuestionWizard`**

Grep: `grep -n 'func runAskUserQuestionWizard' hooks/claude-approve.swift`. Find the section right after the panel is ordered front and the SIGUSR1 handler is installed, and just before `controller.run()`:

```swift
// Sibling dialogs use SIGUSR1 to re-activate the next hook process.
// Default action for SIGUSR1 is terminate — ignore it so a parallel dialog
// dismiss cannot kill our modal while the user is answering.
signal(SIGUSR1, SIG_IGN)

let state = WizardState(questions: questions)
let controller = WizardController(state: state, panel: panel, contentContainer: container)
let outcome = controller.run()
panel.orderOut(nil)
return outcome
```

Wrap the controller call with the focus-recovery lifecycle:

```swift
// Sibling dialogs use SIGUSR1 to re-activate the next hook process.
// Default action for SIGUSR1 is terminate — ignore it so a parallel dialog
// dismiss cannot kill our modal while the user is answering.
signal(SIGUSR1, SIG_IGN)

let focusCleanup = installFocusRecoveryObservers(on: panel)
defer { focusCleanup() }

let state = WizardState(questions: questions)
let controller = WizardController(state: state, panel: panel, contentContainer: container)
let outcome = controller.run()
panel.orderOut(nil)
return outcome
```

- [ ] **Step 3.3 — Replace / add in `showStopDialog`**

Grep: `grep -n 'activeSpaceDidChangeNotification\|showStopDialog' hooks/claude-stop.swift`. If there is an existing Space observer block in `showStopDialog`, replace it with `installFocusRecoveryObservers(on: panel)` and its cleanup call in the existing `defer` — same pattern as Step 3.1. If no observer exists yet, add the install just before `NSApp.runModal(for: panel)` and a matching `cleanup()` in the existing defer (or create one immediately before `runModal`).

- [ ] **Step 3.4 — Build both + test**

Run the build + test commands from Step 2.3. Expected: pass.

- [ ] **Step 3.5 — Commit**

```bash
git add hooks/claude-approve.swift hooks/claude-stop.swift
git commit -m "Wire focus-recovery observers into all three dialogs"
```

---

## Task 4 — Multi-line deny morph

**Files:**
- Modify: `hooks/claude-approve.swift` — `ButtonHandler.morphToTextField(index:)` and `ButtonHandler.submitTextInput(index:)`; add a new `NSTextViewDelegate` method (or conform the class).

The goal: replace the single-line `NSTextField` inside the morphed container with a multi-line `NSTextView` inside an `NSScrollView`, and teach the text view to handle Return (submit), Shift/Option+Return (newline), and Esc (cancel) the same way `WizardOtherRow` does.

- [ ] **Step 4.1 — Find the morph code**

Grep: `grep -n 'private func morphToTextField\|private func submitTextInput' hooks/claude-approve.swift`. Read the full body of both. The current implementation creates an `NSTextField`, assigns it to `activeTextField`, and `submitTextInput` reads `activeTextField?.stringValue`.

Also grep: `grep -n 'var activeTextField\|func control(_ control: NSControl' hooks/claude-approve.swift` — to find the delegate conformance that today handles `insertNewline:` and `cancelOperation:` for `NSControl`.

- [ ] **Step 4.2 — Swap the storage**

Inside `final class ButtonHandler`, change:

```swift
private var activeTextField: NSTextField?
```

to:

```swift
// Held onto so submitTextInput can read the typed string. Swapped from
// NSTextField to NSTextView + NSScrollView to support Shift+Return newlines.
private var activeTextView: NSTextView?
```

If there are any other references to `activeTextField` outside the two methods in Step 4.1, follow them and repoint to `activeTextView`. (Usually only `submitTextInput` and the delegate method read it.)

- [ ] **Step 4.3 — Rewrite `morphToTextField`**

Locate the method. Replace the body (keep the method signature — `@objc private func morphToTextField(index: Int)` or whatever the current signature is). The new body builds the scroll-view + text-view pair inside the morph container and wires the text view's delegate to receive `doCommandBy`:

```swift
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

    let scrollHeight = frame.height - 8
    let scrollView = NSScrollView(frame: NSRect(
        x: leftPad, y: 4,
        width: frame.width - leftPad - rightPad, height: scrollHeight))
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.documentView = textView

    // Placeholder label, hidden once typing starts.
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
```

Note the `placeholder` NSTextField — it's a new static hint string shown when the text view is empty. The text view's delegate method `textDidChange(_:)` (Step 4.5) hides/shows it.

- [ ] **Step 4.4 — Rewrite `submitTextInput`**

Change the source of `feedbackText` to the text view's string:

```swift
private func submitTextInput(index: Int) {
    guard index >= 0, index < options.count else { return }
    pressing = true
    result = options[index].resultKey
    feedbackText = activeTextView?.string ?? ""
    NSApp.stopModal()
}
```

- [ ] **Step 4.5 — Add NSTextViewDelegate conformance and handlers**

Find the `control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool` method in `ButtonHandler`. It's the current NSControl delegate hook. Leave it in place (the old NSTextField path isn't used anymore but keeping the method is harmless).

Add alongside it:

```swift
// NSTextViewDelegate — handles commands from the morphed multi-line input.
func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        if shift {
            textView.insertText("\n", replacementRange: textView.selectedRange())
        } else {
            submitTextInput(index: textView.tag)
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
        if let index = options.firstIndex(where: { $0.resultKey == result }) ?? (activeTextView?.tag ?? 0).nonNegative() {
            _ = index // tag stored on sendBtn, not textView — look it up via activeTextView?
        }
        feedbackText = ""
        NSApp.stopModal()
        return true
    }
    return false
}

func textDidChange(_ notification: Notification) {
    guard let tv = activeTextView, let container = tv.enclosingScrollView?.superview else { return }
    // Toggle placeholder visibility.
    if let placeholder = container.subviews.first(where: {
        $0.identifier == NSUserInterfaceItemIdentifier("morph-placeholder")
    }) {
        placeholder.isHidden = !tv.string.isEmpty
    }
    // Keep the caret in view as content grows.
    tv.scrollRangeToVisible(tv.selectedRange())
}
```

Then ensure `ButtonHandler` conforms to `NSTextViewDelegate`:

Find the class declaration:

```swift
final class ButtonHandler: NSObject, NSTextFieldDelegate {
```

Change to:

```swift
final class ButtonHandler: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
```

For `textView.tag` retrieval in the Esc path: since we don't set a `tag` on `NSTextView` directly (it doesn't expose one), store the index on the text view's `identifier` instead:

```swift
// In morphToTextField, right after `activeTextView = textView`:
textView.identifier = NSUserInterfaceItemIdentifier(String(index))
```

And in the Esc handler, replace the complicated firstIndex fallback with:

```swift
if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
    pressing = true
    let idx = Int(textView.identifier?.rawValue ?? "") ?? 0
    result = options[idx].resultKey
    feedbackText = ""
    NSApp.stopModal()
    return true
}
```

- [ ] **Step 4.6 — Build + test**

Run the build + test commands from Step 2.3. Expected: pass.

- [ ] **Step 4.7 — Commit**

```bash
git add hooks/claude-approve.swift
git commit -m "Swap deny morph NSTextField for multi-line NSTextView"
```

---

## Task 5 — Dynamic terminal-button label

**Files:**
- Modify: `hooks/claude-approve.swift` — extend `WizardLabels`, add `terminalButtonLabel()`, wire into wizard footer.
- Modify: `hooks/claude-stop.swift` — extend `StopLabels`, add `terminalButtonLabel()`, wire into `addStopButtons`.

- [ ] **Step 5.1 — Extend `WizardLabels` in `claude-approve.swift`**

Locate `enum WizardLabels`. Add a new case:

```swift
enum WizardLabels {
    static let back                    = "Back"
    static let next                    = "Next"
    static let submit                  = "Submit answers"
    static let terminal                = "Go to Terminal"
    static let terminalForClaudeDesktop = "Go to Claude Desktop"
    static let ok                      = "Ok"
}
```

- [ ] **Step 5.2 — Add the helper in `claude-approve.swift`**

Right below `enum WizardLabels` closing brace, add:

```swift
/// Returns the label for the "go to parent app" footer button, adapted to
/// the detected parent. Falls back to the terminal wording when the parent
/// can't be identified or is a genuine terminal emulator.
func terminalButtonLabel() -> String {
    let (_, parentApp) = resolveProcessAncestry()
    let app = parentApp ?? capturedTerminalApp
    if app?.bundleIdentifier == "com.anthropic.claudefordesktop" {
        return WizardLabels.terminalForClaudeDesktop
    }
    return WizardLabels.terminal
}
```

- [ ] **Step 5.3 — Wire into wizard footer**

Grep: `grep -n 'WizardLabels.terminal' hooks/claude-approve.swift`. Each occurrence is either the enum declaration or a call site. At the call sites (inside `buildWizardQuestionPanel` and, for completeness, `buildWizardReviewPanel`), change:

```swift
title: WizardLabels.terminal,
```

to:

```swift
title: terminalButtonLabel(),
```

Leave the enum constants in place — they're the source of truth; the helper just picks which one to return.

- [ ] **Step 5.4 — Extend `StopLabels` + helper in `claude-stop.swift`**

Locate `enum StopLabels`. Add:

```swift
enum StopLabels {
    static let terminal                = "Go to Terminal"
    static let terminalForClaudeDesktop = "Go to Claude Desktop"
    static let ok                      = "Ok"
}
```

Below the enum, add:

```swift
/// Returns the label for the "go to parent app" button in the Done dialog,
/// adapted to the detected parent app. Same pattern as the copy in
/// `claude-approve.swift`.
func terminalButtonLabel() -> String {
    let (_, parentApp) = resolveProcessAncestry()
    let app = parentApp ?? capturedTerminalApp
    if app?.bundleIdentifier == "com.anthropic.claudefordesktop" {
        return StopLabels.terminalForClaudeDesktop
    }
    return StopLabels.terminal
}
```

If `resolveProcessAncestry()` and `capturedTerminalApp` are not present in `claude-stop.swift`, copy them over from `claude-approve.swift` verbatim (per single-file convention). They might already exist — grep first: `grep -n 'resolveProcessAncestry\|capturedTerminalApp' hooks/claude-stop.swift`.

- [ ] **Step 5.5 — Wire into Done dialog**

Grep: `grep -n 'StopLabels.terminal' hooks/claude-stop.swift`. Find the `specs` array in `addStopButtons`:

```swift
let specs: [(title: String, color: NSColor)] = [
    (StopLabels.terminal, Theme.buttonGreen),
    (StopLabels.ok,       Theme.buttonBlue),
]
```

Change the terminal row to:

```swift
let specs: [(title: String, color: NSColor)] = [
    (terminalButtonLabel(), Theme.buttonGreen),
    (StopLabels.ok,         Theme.buttonBlue),
]
```

- [ ] **Step 5.6 — Update existing tests**

Run: `grep -n 'WizardLabels\|StopLabels' tests/test-approve.swift tests/test-stop.swift 2>/dev/null`. If `testLabelEnums` exists, add assertions for the new constants:

```swift
// In testLabelEnums (add after existing wizard asserts):
assertEq(WizardLabels.terminalForClaudeDesktop, "Go to Claude Desktop")
```

No new test file needed.

- [ ] **Step 5.7 — Build + test**

Run the build + test commands from Step 2.3. Expected: pass.

- [ ] **Step 5.8 — Commit**

```bash
git add hooks/claude-approve.swift hooks/claude-stop.swift tests/test-approve.swift
git commit -m "Adapt terminal button label to parent app (Claude Desktop)"
```

---

## Task 6 — Manual QA + CLAUDE.md update

**Files:**
- Modify: `CLAUDE.md` — `## Testing` section's `### Manual Test Cases`.

- [ ] **Step 6.1 — Run every existing manual test case**

Reset sessions: `rm -rf /tmp/claude-hook-sessions/`.

Walk through the CLAUDE.md manual test list end-to-end. In particular:

- 12a–h — AskUserQuestion wizard (single, multi, Other row, 2-row footer, Submit-disabled-until-answered).
- 13 — Unified look across Permission, Done, Wizard.
- 14 — Press animation.
- 15 — Keyboard-shortcut badges 1/2/3.

Plus the new cases for this plan:

- **14a** — in the wizard, press ↑/↓ — the newly-focused row shows the scale-down animation just like a mouse click would. Same for pressing 1/2/3/N.
- **15a** — trigger a dialog, switch Space, return — focus restored without clicking.
- **15b** — trigger a dialog, ⌘+Tab to another app, ⌘+Tab back — focus restored.
- **15c** — trigger a dialog, lock the screen, unlock — focus restored.
- **16** — in the Permission dialog, click "No…". Type a line, press Shift+Return, type another, press Enter. Claude receives the multi-line feedback verbatim (newline preserved in the `permissionDecisionReason`).
- **17a** — when Claude Code is launched from Claude Desktop, the wizard and Done dialog footer show "Go to Claude Desktop".
- **17b** — when launched from a terminal, same footer shows "Go to Terminal".

Record any regressions immediately and stop — do not proceed until resolved.

- [ ] **Step 6.2 — Add items to `CLAUDE.md`**

Append after the existing item 15 (keyboard-shortcut badges) the new cases above:

```markdown
14a. **Wizard keyboard animation** — in the AskUserQuestion wizard, pressing
    ↑ / ↓ or a digit shortcut 1…N animates the newly-selected row with the
    same scale-down + release the mouse-click path uses.
15a. **Focus after Space switch** — with any dialog visible, switch macOS
    Space and return; focus is reclaimed without a manual click.
15b. **Focus after app switch** — with any dialog visible, ⌘+Tab to another
    app and back; focus is reclaimed.
15c. **Focus after screen wake** — with any dialog visible, lock and unlock
    the screen; focus is reclaimed.
16. **Multi-line deny feedback** — in the Permission dialog, click "No…";
    type a line, press Shift+Return, type another, press Enter. The
    resulting `permissionDecisionReason` contains the newline.
17. **Claude Desktop terminal label** — when Claude Code is launched from
    Claude Desktop, the wizard's and Done dialog's "go to parent" button
    reads `Go to Claude Desktop`. From a terminal, it still reads
    `Go to Terminal`.
```

- [ ] **Step 6.3 — Final build + test**

Run:
```bash
cd hooks && \
  swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift && \
  swiftc -O -parse-as-library -framework AppKit -o claude-stop    claude-stop.swift    && \
  cd ..
bash tests/run.sh
```
Expected: all green.

- [ ] **Step 6.4 — Commit**

```bash
git add CLAUDE.md
git commit -m "Extend manual test checklist for QA fixes"
```

---

## Self-review

- **Spec coverage:**
  - §4.1 press animation on keyboard paths → Task 1.
  - §4.2 focus recovery helper + wiring → Tasks 2, 3.
  - §4.3 multi-line deny morph → Task 4.
  - §4.4 dynamic terminal label → Task 5.
  - §6 manual QA + checklist update → Task 6.
- **Placeholders:** None. Every step specifies concrete code, concrete paths, concrete commands.
- **Type consistency:** `installFocusRecoveryObservers`, `terminalButtonLabel`, `activeTextView`, `WizardLabels.terminalForClaudeDesktop`, `StopLabels.terminalForClaudeDesktop`, `NSTextViewDelegate` — all spelled identically across tasks.
- **Guardrail:** every task acts only on fixes (added animation calls, added observers with matching cleanup, text-view swap, label helper). No changes to timers, resultKeys, outcomes, keyboard bindings, SIGUSR1, deep-link behavior, state machine, or session identity.
