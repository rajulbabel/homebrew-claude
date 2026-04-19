# Dialog Visual Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Permission dialog and the Done dialog look and feel like the AskUserQuestion wizard (same chrome, same button skin, same typography, same press animation), plus tighten the wizard itself with a two-row footer, CLI-matching labels, a distinct header color, and vertical text centering inside the Other row — all without changing a single behavior, keyboard binding, or click target.

**Architecture:** Everything lives in the two existing single-file scripts (`hooks/claude-approve.swift`, `hooks/claude-stop.swift`). All visible button strings move to named `…Labels` enums. The wizard's existing `Theme.wizard*` and `Layout.wizard*` constants are reused by the permission dialog (same file) and mirrored into `claude-stop.swift` as parallel `Theme.stop*` / `Layout.stop*` blocks. A shared `animateButtonPress(_:)` helper is added to each file. The wizard's `WizardPanel` subclass is reused for the permission dialog; `claude-stop.swift` gets its own `StopPanel: NSPanel` subclass (equivalent class definition, needed because classes can't cross files per the single-file rule).

**Tech Stack:** Swift 5, AppKit. Compiled with `swiftc -O -parse-as-library -framework AppKit`. Tests run with `bash tests/run.sh`.

---

## Non-negotiable guardrail

This entire plan is **skin-and-text-layout only**. Every implementation step must preserve:

- Every button's click target, `resultKey`, action-dispatch path, and outcome semantics.
- Every keyboard shortcut (1/2/3, Enter, Esc, wizard's arrows).
- The "No…" button → inline text-field morph.
- Panel modal lifecycle (`NSApp.runModal(for:)`, `stopModal`).
- The 600-s dialog timeout, the 15-s Done auto-dismiss.
- Space-switch re-activation observer and SIGUSR1 sibling handler.
- Session identity (project name + cwd) display.
- Diff rendering, syntax highlighting, code-block scroll view.
- All `processResult` / `handleResult` branches, persistence (auto-approve, session files).
- Wizard state machine (steps, answers, pendingCustom, `isReviewStep`, `allAnswered`).
- Wizard Other-row typing, multi-line growth, `textDidChange` → partial layout adjustment.

If an implementation step appears to require touching any of those, **report BLOCKED** instead of modifying them.

---

## Reference

- Spec: `docs/superpowers/specs/2026-04-19-dialog-visual-unification-design.md`
- Existing wizard visual constants: `hooks/claude-approve.swift` Theme (~line 220) and Layout (~line 330) enums.
- Existing `WizardPanel` subclass: `hooks/claude-approve.swift` (search `private final class WizardPanel`).
- Existing `makeWizardFooterButton` factory and `applyWizardSubmitEnabled` helper: in the `AskUserQuestion Wizard` section.
- `StopHandler`: `hooks/claude-stop.swift` (search `final class StopHandler`).

## Working convention

- Every task ends with a commit. Commit messages are imperative mood, under 72 chars for subject, no `Co-Authored-By` trailer (see `CLAUDE.md §Commit Conventions`).
- Named constants for every color/dimension/string that appears more than once.
- `///` doc comments on every new function or enum.
- After every task: run `bash tests/run.sh`; it must pass.

---

## File structure

Each task lists the exact file + approximate line range. Line numbers drift as tasks land — use Grep on the nearest stable anchor (class name, `MARK:` header, function name).

- `hooks/claude-approve.swift` — all wizard + permission changes.
- `hooks/claude-stop.swift` — all done-dialog changes.
- `tests/test-approve.swift` — one or two small unit tests for the new label enums.

No new files are created. No code is shared between `claude-approve.swift` and `claude-stop.swift` — they duplicate the helper classes/constants on purpose, matching the existing single-file convention.

---

## Task 1 — Add label enums to `hooks/claude-approve.swift`

**Files:**
- Modify: `hooks/claude-approve.swift` — insert after `enum Layout { … }` closing brace (search for `^}` on the line immediately after the last Layout constant), before `// MARK: - Input Parsing`.
- Test: `tests/test-approve.swift` — add a tiny existence check.

- [ ] **Step 1.1 — Write the failing test**

Add to the end of `tests/test-approve.swift`, just above `@main enum ApproveTests`:

```swift
// ═══════════════════════════════════════════════════════════════════
// MARK: - Label Enums
// ═══════════════════════════════════════════════════════════════════

func testLabelEnums() {
    test("WizardLabels: exact strings") {
        assertEq(WizardLabels.back,     "Back")
        assertEq(WizardLabels.next,     "Next")
        assertEq(WizardLabels.submit,   "Submit answers")
        assertEq(WizardLabels.terminal, "Go to Terminal")
        assertEq(WizardLabels.ok,       "Ok")
    }
    test("PermissionLabels: exact strings") {
        assertEq(PermissionLabels.allowOnce,
                 "Yes")
        assertEq(PermissionLabels.denyWithFeedbackFallback,
                 "No, and tell Claude what to do differently")
    }
}
```

Register it as the first call in `ApproveTests.main()`:

```swift
static func main() {
    testLabelEnums()
    testWizardTypes()
    // … existing calls
}
```

- [ ] **Step 1.2 — Run tests to verify failure**

Run: `bash tests/run.sh`
Expected: compile failure, "cannot find 'WizardLabels' in scope".

- [ ] **Step 1.3 — Add the enums**

Insert in `hooks/claude-approve.swift` right after the `enum Layout { … }` closing brace (and its trailing blank line). The `// MARK: - Input Parsing` comment stays immediately after the new block.

```swift
// MARK: - Labels

/// Wizard footer button labels, matched verbatim to Claude Code CLI / Desktop
/// conventions. Single source of truth — never inline these strings elsewhere
/// so a future wording change touches this file only.
enum WizardLabels {
    static let back      = "Back"
    static let next      = "Next"
    static let submit    = "Submit answers"
    static let terminal  = "Go to Terminal"
    static let ok        = "Ok"
}

/// Permission-dialog labels that are tool-independent. Tool-dependent
/// labels (like "Yes, and don't ask again for `cd` *") stay generated
/// inside `buildPermOptions` where they can parameterize on tool/cmd/domain.
enum PermissionLabels {
    static let allowOnce                = "Yes"
    static let denyWithFeedbackFallback = "No, and tell Claude what to do differently"
}
```

- [ ] **Step 1.4 — Run tests to verify pass**

Run: `bash tests/run.sh`
Expected: all tests pass.

- [ ] **Step 1.5 — Commit**

```bash
git add hooks/claude-approve.swift tests/test-approve.swift
git commit -m "Add WizardLabels and PermissionLabels enums"
```

---

## Task 2 — Wire `WizardLabels` into existing wizard footer code (pure refactor)

**Files:**
- Modify: `hooks/claude-approve.swift` — `buildWizardQuestionPanel` footer strings.

No visual change yet — just swap string literals for enum cases.

- [ ] **Step 2.1 — Find and replace the hardcoded labels**

Grep to find the current strings:

```bash
grep -n 'title: "Back"\|title: "Next"\|title: "Submit\|title: "Terminal"\|title: "Cancel"' hooks/claude-approve.swift
```

Each match will be inside a `makeWizardFooterButton(title: …)` call. Replace them:

- `"← Back"` → `WizardLabels.back`
- `"Next →"` → `WizardLabels.next`
- `"Submit ⏎"` → `WizardLabels.submit`
- `"Terminal"` → `WizardLabels.terminal`
- `"Cancel"` → `WizardLabels.ok`

(If the current wizard source has the arrow glyphs, they go away — they're decoration, not part of the CLI strings.)

There is also a `title: isLastStep ? "Submit ⏎" : "Next →"` expression — replace with `isLastStep ? WizardLabels.submit : WizardLabels.next`.

- [ ] **Step 2.2 — Build + test**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift && cd ..`
Run: `bash tests/run.sh`
Expected: both pass.

- [ ] **Step 2.3 — Commit**

```bash
git add hooks/claude-approve.swift
git commit -m "Route wizard footer labels through WizardLabels enum"
```

---

## Task 3 — Add `Theme.wizardHeaderAccent` (lavender) and apply to wizard top-of-panel tag

**Files:**
- Modify: `hooks/claude-approve.swift` — Theme enum + `buildWizardQuestionPanel` + `buildWizardReviewPanel`.

- [ ] **Step 3.1 — Add the Theme constant**

In `hooks/claude-approve.swift`, inside the `// Wizard — typography` section of `enum Theme`, add:

```swift
/// Accent color for the wizard's top-of-panel "ASKUSERQUESTION" tag.
/// Lavender — distinct from the per-tool pill colors so the inquiry dialog
/// has its own identity within the shared visual family.
static let wizardHeaderAccent = NSColor(calibratedRed: 0.655, green: 0.545, blue: 0.980, alpha: 1.0)
```

- [ ] **Step 3.2 — Use it in the wizard panels**

Grep to locate the current usage:

```bash
grep -n 'ASKUSERQUESTION' hooks/claude-approve.swift
```

Two places set `tag.textColor = Theme.toolTagColors["AskUserQuestion"] ?? Theme.mcpTag` — one in `buildWizardQuestionPanel`, one in `buildWizardReviewPanel`. Change both to:

```swift
tag.textColor = Theme.wizardHeaderAccent
```

Also tighten the letter-spacing for a refined look. In both places where the `tag` label is created (lines are `tag.font = Theme.wizardHeaderTagFont`), add:

```swift
tag.font = Theme.wizardHeaderTagFont
tag.attributedStringValue = NSAttributedString(
    string: "ASKUSERQUESTION",
    attributes: [
        .font: Theme.wizardHeaderTagFont,
        .foregroundColor: Theme.wizardHeaderAccent,
        .kern: 1.2,
    ])
```

(Use `"ASKUSERQUESTION · REVIEW"` for the review panel's existing label.)

Remove the now-redundant `tag.textColor = …` assignment that followed.

- [ ] **Step 3.3 — Build + test**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift && cd ..`
Run: `bash tests/run.sh`
Expected: both pass.

- [ ] **Step 3.4 — Commit**

```bash
git add hooks/claude-approve.swift
git commit -m "Tint wizard ASKUSERQUESTION header in lavender with tracked kerning"
```

---

## Task 4 — Wizard footer: new 2-row layout

**Files:**
- Modify: `hooks/claude-approve.swift` — `buildWizardQuestionPanel` footer section; minor Layout additions.

This task changes the footer layout from one row of four buttons to two rows of two buttons. **Button outcomes are unchanged** — we move frames only, reusing the existing `backButton` / `primaryButton` / `terminalButton` / `cancelButton` handles.

- [ ] **Step 4.1 — Add Layout constants**

Inside `enum Layout` in `hooks/claude-approve.swift`, in the `// Wizard — footer` block, add:

```swift
/// Footer inner rows (2 stacked rows of 2 buttons each in the new layout).
static let wizardFooterRowGap: CGFloat = 6
/// Total footer height = 2 rows × buttonHeight + rowGap + top/bottom padding.
/// Replaces the single-row footer height used previously.
static let wizardFooterTwoRowHeight: CGFloat =
    wizardFooterButtonHeight * 2 + wizardFooterRowGap + 10 * 2
```

Leave the existing `wizardFooterHeight = 56` constant in place — it is still used for single-row layouts (permission / done dialogs). The wizard now uses `wizardFooterTwoRowHeight` instead.

- [ ] **Step 4.2 — Rewrite the footer block inside `buildWizardQuestionPanel`**

Locate the footer construction — the block that starts with:

```swift
// --- Footer ---
let footer = NSView(frame: NSRect(x: 0, y: 0, width: width, height: Layout.wizardFooterHeight))
```

and ends right before `root.addSubview(footer)` / the subsequent size calculations.

Replace it with:

```swift
// --- Footer (two rows) ---
let footer = NSView(frame: NSRect(x: 0, y: 0, width: width,
                                  height: Layout.wizardFooterTwoRowHeight))
footer.wantsLayer = true
footer.layer?.backgroundColor = Theme.codeBackground.cgColor

// Row 1: Back + Primary (Next / Submit answers)
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
    title: WizardLabels.terminal,
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
let topPad: CGFloat = 10

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
```

- [ ] **Step 4.3 — Add the two neutral-gray Theme constants**

Inside `enum Theme`, in the `// Wizard — disabled button state` block (or a new `// Wizard — neutral button` block if that reads cleaner), add:

```swift
/// Neutral (non-accented) button fill/border — used for Back and Ok, which
/// must be visually distinct from the blue primary button on the same row.
static let wizardNeutralFillRest   = NSColor(calibratedWhite: 1.0, alpha: 0.06)
static let wizardNeutralBorderRest = NSColor(calibratedWhite: 1.0, alpha: 0.18)
```

- [ ] **Step 4.4 — Root size adjustment**

Immediately after the footer is added to root, find the line that computes `rootHeight`:

```swift
let rootHeight = Layout.wizardHeaderHeight + bodyHeight + Layout.wizardFooterHeight
```

Change `Layout.wizardFooterHeight` → `Layout.wizardFooterTwoRowHeight`. Also update the `body.frame.origin.y = Layout.wizardFooterHeight` line a few lines earlier in the same function to `body.frame.origin.y = Layout.wizardFooterTwoRowHeight`.

- [ ] **Step 4.5 — Build + test + manual smoke**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift && cd ..`
Run: `bash tests/run.sh`
Expected: both pass.

Install the new binary and trigger a multi-question AskUserQuestion:

```bash
cp hooks/claude-approve ~/.claude/hooks/claude-approve
```

Verify manually: two rows visible, row 1 shows Back + Next, last question shows Back + "Submit answers", row 2 shows "Go to Terminal" + "Ok". Clicking Ok dismisses with the same "user cancelled" outcome as before.

- [ ] **Step 4.6 — Commit**

```bash
git add hooks/claude-approve.swift
git commit -m "Reflow wizard footer to two rows with CLI-matching labels"
```

---

## Task 5 — Wizard Other-row: vertically center typed text when shorter than available area

**Files:**
- Modify: `hooks/claude-approve.swift` — `WizardOtherRow.refreshHeight()`.

- [ ] **Step 5.1 — Adjust scroll view placement inside `refreshHeight`**

Grep: `grep -n 'private func refreshHeight' hooks/claude-approve.swift` → locate the method inside `final class WizardOtherRow`.

The current method sets `scrollView.frame.y = Layout.wizardOtherActivePaddingV` unconditionally. Replace that single line assignment with the block below. Keep everything else in the method (the radio `.origin.y` re-centering, the `idxField.origin.y` line, etc.) unchanged.

Locate the section near the end of `refreshHeight`:

```swift
if isActive {
    let scrollHeight = rowHeight - Layout.wizardOtherActivePaddingV * 2
    scrollView.frame = NSRect(
        x: textX, y: Layout.wizardOtherActivePaddingV,
        width: textWidth, height: scrollHeight)
}
```

Replace with:

```swift
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
```

This keeps the scroll view's effective area equal to the text's actual content height when the text is short, so the typed line is visually centered. As soon as the content grows past one line, `emptyBelow` returns to 0 and the scroll view fills its full frame again.

- [ ] **Step 5.2 — Build + test + manual smoke**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift && cd ..`
Run: `bash tests/run.sh`
Expected: both pass.

Install and verify: trigger an AskUserQuestion, pick the Other row, type one word. Caret + text should appear vertically centered inside the Other row rather than top-anchored.

- [ ] **Step 5.3 — Commit**

```bash
git add hooks/claude-approve.swift
git commit -m "Center typed text vertically inside Other row when content is short"
```

---

## Task 6 — Shared `animateButtonPress(_:)` helper in `claude-approve.swift`

**Files:**
- Modify: `hooks/claude-approve.swift` — add helper; wire into `ButtonHandler.animatePress` and `ButtonHandler.directPress`; wire into `WizardController` action methods.

- [ ] **Step 6.1 — Add the helper**

Add at the end of `// MARK: - Focus Management` (before `// MARK: - AskUserQuestion Wizard`):

```swift
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
```

- [ ] **Step 6.2 — Wire into `ButtonHandler.animatePress` and `directPress`**

Grep: `grep -n 'func animatePress\|func directPress' hooks/claude-approve.swift`.

Inside both methods, just after the line that sets `button.layer?.backgroundColor = option.color.withAlphaComponent(Theme.buttonPressAlpha).cgColor`, add:

```swift
animateButtonPress(button)
```

This chains the scale animation on top of the existing background-flash. Both paths are preserved — the color change already happens, we just add the scale layer.

- [ ] **Step 6.3 — Wire into `WizardController` footer-button paths**

Locate every `@objc private func onBack/onPrimary/onTerminal/onCancel` in `WizardController`. At the top of each, after the `guard let h = currentQuestionHandles else { return }` or equivalent, add:

```swift
// Press animation on the triggered button (mouse or keyboard path).
if let h = currentQuestionHandles {
    let btn: NSButton = {
        switch #function {
        case "onBack":     return h.backButton
        case "onPrimary":  return h.primaryButton
        case "onTerminal": return h.terminalButton
        case "onCancel":   return h.cancelButton
        default:           return h.primaryButton
        }
    }()
    animateButtonPress(btn)
}
```

(`#function` returns the declaring function's name, which is stable even with `@objc` attribution in Swift.)

Also update the preset-row + Other-row press paths: `onPresetClicked` calls should animate the clicked row; `activateOther` should animate the Other row.

- [ ] **Step 6.4 — Build + test + manual smoke**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift && cd ..`
Run: `bash tests/run.sh`
Expected: both pass.

Install and verify: clicking any footer button shows the subtle scale-and-flash. Pressing 1/2/3/Enter/Arrow keys triggers the same animation on the corresponding button.

- [ ] **Step 6.5 — Commit**

```bash
git add hooks/claude-approve.swift
git commit -m "Add animateButtonPress helper; wire into every button press path"
```

---

## Task 7 — Permission dialog: panel chrome (reuse `WizardPanel`)

**Files:**
- Modify: `hooks/claude-approve.swift` — `makePermissionPanel`.

- [ ] **Step 7.1 — Locate and rewrite `makePermissionPanel`**

Grep: `grep -n 'func makePermissionPanel' hooks/claude-approve.swift`.

Replace the whole function body with:

```swift
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
```

- [ ] **Step 7.2 — Build + test + manual smoke**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift && cd ..`
Run: `bash tests/run.sh`
Expected: both pass.

Install and trigger any permission dialog (e.g. ask Claude to run a Bash command). Verify: no title bar, rounded corners, same project/cwd header, same buttons, keyboard shortcuts 1/2/3 still work.

- [ ] **Step 7.3 — Commit**

```bash
git add hooks/claude-approve.swift
git commit -m "Borderless rounded chrome for permission dialog (WizardPanel)"
```

---

## Task 8 — Permission dialog: content block styling

**Files:**
- Modify: `hooks/claude-approve.swift` — `addCodeBlock` (search for `private func addCodeBlock`).

- [ ] **Step 8.1 — Rewrite the container styling inside `addCodeBlock`**

Grep: `grep -n 'private func addCodeBlock' hooks/claude-approve.swift`.

Find the lines that create the container (typically `let container = NSView(...)` and subsequent `container.layer?.backgroundColor = …` / `cornerRadius = …`).

Replace the styling assignments with:

```swift
container.wantsLayer = true
container.layer?.cornerRadius = Layout.wizardRowCornerRadius
container.layer?.backgroundColor = Theme.wizardRowBg.cgColor
container.layer?.borderColor = Theme.wizardRowBorder.cgColor
container.layer?.borderWidth = 1
```

Leave the container's `frame` and the scroll view / text inside completely alone.

- [ ] **Step 8.2 — Build + test**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift && cd ..`
Run: `bash tests/run.sh`
Expected: both pass.

- [ ] **Step 8.3 — Commit**

```bash
git add hooks/claude-approve.swift
git commit -m "Skin permission-dialog code block with wizardRow palette"
```

---

## Task 9 — Permission dialog: separator hairline

**Files:**
- Modify: `hooks/claude-approve.swift` — `addHeader`.

- [ ] **Step 9.1 — Replace the `NSBox` separator with a layer-backed hairline**

Grep: `grep -n 'separator.boxType = .separator' hooks/claude-approve.swift`.

Replace the three lines around that usage:

```swift
let separator = NSBox(frame: NSRect(x: Layout.panelInset, y: yPos,
                                    width: Layout.panelWidth - Layout.panelInset * 2,
                                    height: Layout.separatorHeight))
separator.boxType = .separator
contentView.addSubview(separator)
```

With:

```swift
// Hairline separator (matches the wizard body divider).
let separator = NSView(frame: NSRect(x: Layout.panelInset, y: yPos,
                                     width: Layout.panelWidth - Layout.panelInset * 2,
                                     height: Layout.separatorHeight))
separator.wantsLayer = true
separator.layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.10).cgColor
contentView.addSubview(separator)
```

- [ ] **Step 9.2 — Build + test**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift && cd ..`
Run: `bash tests/run.sh`
Expected: both pass.

- [ ] **Step 9.3 — Commit**

```bash
git add hooks/claude-approve.swift
git commit -m "Replace NSBox separator with hairline in permission dialog"
```

---

## Task 10 — Permission dialog: button skin (same frames, new fill/border/font/corner)

**Files:**
- Modify: `hooks/claude-approve.swift` — `addButtonRows`.

- [ ] **Step 10.1 — Add a skin helper next to the existing button-building code**

Search for `private func addButtonRows` and, just below it (still at file scope, before the next `// MARK:`), add:

```swift
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
```

- [ ] **Step 10.2 — Call the helper at the end of `addButtonRows`**

Inside `addButtonRows`, after every `NSButton` has been created and added to `contentView` — i.e. just before the closing brace of the outer `for row` loop — add a pass that restyles each button:

Grep for `private func addButtonRows` to locate it; find the body of the `for rowIndex in buttonRows.indices` loop. Currently each button has its `.layer?.backgroundColor`, `.layer?.cornerRadius`, and `.title` set inline. Preserve all of that code — just append **one** line after the `contentView.addSubview(button)` line:

```swift
applyUnifiedButtonSkin(button, tint: option.color, isDeny: option.resultKey == "deny")
```

The helper overwrites the prior in-place styling with the unified skin. Keep the existing `button.target`, `button.action`, `button.tag` lines as they are — none of them are touched by the helper.

- [ ] **Step 10.3 — Build + test + manual smoke**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift && cd ..`
Run: `bash tests/run.sh`
Expected: both pass.

Install and trigger a Bash permission. Verify: same 3 buttons, same text, same sizes, same row packing — but with rounded corners, the new fill/border alphas, semibold font. Press 1/2/3 — animation plays, click handler still dispatches correctly. Click the "No" button — text-field morph still fires normally.

- [ ] **Step 10.4 — Commit**

```bash
git add hooks/claude-approve.swift
git commit -m "Apply unified button skin to permission dialog buttons"
```

---

## Task 11 — Permission dialog: centered keyboard-shortcut badges (1/2/3)

**Files:**
- Modify: `hooks/claude-approve.swift` — `addButtonRows`.

- [ ] **Step 11.1 — Add a badge helper**

Below `applyUnifiedButtonSkin` (same file scope), add:

```swift
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
```

- [ ] **Step 11.2 — Call it at the end of `addButtonRows`**

Inside the same loop where you added `applyUnifiedButtonSkin` in Task 10, just after that call, add:

```swift
let displayNumber = indexInOptions + 1  // 1-based
addKeyboardBadge(to: button, number: displayNumber, tint: option.color)
```

`indexInOptions` is the running index of the button within `options` — it already exists in the surrounding loop (the index variable used to index `options[...]`); reuse whatever name the existing loop uses.

- [ ] **Step 11.3 — Build + test + manual smoke**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift && cd ..`
Run: `bash tests/run.sh`
Expected: both pass.

Install and trigger a permission dialog. Verify: tiny 1/2/3 numerals appear at the vertically-centered left edge of each button. Pressing 1/2/3 still triggers the correct button with animation.

- [ ] **Step 11.4 — Commit**

```bash
git add hooks/claude-approve.swift
git commit -m "Center keyboard-shortcut badges on permission dialog buttons"
```

---

## Task 12 — Done dialog: add Theme/Layout constants and `StopLabels`

**Files:**
- Modify: `hooks/claude-stop.swift` — Theme enum + Layout enum + new `StopLabels` enum + new `StopPanel` subclass.

- [ ] **Step 12.1 — Extend `enum Theme` with the stop-dialog palette**

Inside `enum Theme` in `hooks/claude-stop.swift`, add (grouping at the end, before the enum's closing brace):

```swift
// Stop — wizard-family palette (mirrors Theme.wizard* constants in claude-approve.swift).
static let stopRowBg           = NSColor(calibratedWhite: 1.0, alpha: 0.03)
static let stopRowBorder       = NSColor(calibratedWhite: 1.0, alpha: 0.08)
static let stopNeutralFillRest   = NSColor(calibratedWhite: 1.0, alpha: 0.06)
static let stopNeutralBorderRest = NSColor(calibratedWhite: 1.0, alpha: 0.18)
static let stopButtonFont      = NSFont.systemFont(ofSize: 12, weight: .semibold)
static let stopSeparatorColor  = NSColor(calibratedWhite: 1.0, alpha: 0.10)
```

- [ ] **Step 12.2 — Extend `enum Layout` with the stop-dialog dimensions**

Inside `enum Layout` in `hooks/claude-stop.swift`, add at the end:

```swift
// Stop — wizard-family dimensions.
static let stopPanelCornerRadius: CGFloat = 10
static let stopButtonCornerRadius: CGFloat = 8
```

- [ ] **Step 12.3 — Add `StopLabels` enum**

After the Layout enum closing brace (and before `// MARK: - Input Parsing`), add:

```swift
// MARK: - Labels

/// Done-dialog button labels. Kept as named constants so a future wording
/// change touches this file only.
enum StopLabels {
    static let terminal = "Go to Terminal"
    static let ok       = "Ok"
}
```

- [ ] **Step 12.4 — Add the `StopPanel` subclass**

After the Models section closing (search `// MARK: - Theme`, and add just before it), add:

```swift
/// Borderless `NSPanel` that can still become key. A borderless panel
/// defaults to `canBecomeKey == false`, which blocks keyboard shortcuts
/// from reaching the Done dialog. Equivalent to the `WizardPanel` class
/// in `claude-approve.swift` — duplicated here on purpose because the
/// project convention is single-file scripts with no shared Swift module.
private final class StopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
```

- [ ] **Step 12.5 — Build**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-stop claude-stop.swift && cd ..`
Run: `bash tests/run.sh`
Expected: both pass.

- [ ] **Step 12.6 — Commit**

```bash
git add hooks/claude-stop.swift
git commit -m "Mirror wizard palette/labels/WizardPanel into claude-stop.swift"
```

---

## Task 13 — Done dialog: panel chrome (use `StopPanel`)

**Files:**
- Modify: `hooks/claude-stop.swift` — `makeStopPanel`.

- [ ] **Step 13.1 — Rewrite `makeStopPanel`**

Grep: `grep -n 'func makeStopPanel' hooks/claude-stop.swift`.

Replace the body with:

```swift
private func makeStopPanel(height: CGFloat) -> NSPanel {
    let panel = StopPanel(
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
    panel.contentView?.layer?.cornerRadius = Layout.stopPanelCornerRadius
    panel.contentView?.layer?.masksToBounds = true
    if let screen = NSScreen.main {
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - Layout.panelWidth / 2,
                                     y: f.midY - height / 2))
    } else {
        panel.center()
    }
    return panel
}
```

- [ ] **Step 13.2 — Build + test + manual smoke**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-stop claude-stop.swift && cd ..`
Run: `bash tests/run.sh`
Expected: both pass.

Install and let Claude finish any task to trigger the Done dialog:

```bash
cp hooks/claude-stop ~/.claude/hooks/claude-stop
```

Verify: no title bar, rounded corners, 2 buttons still work, auto-dismiss timer still runs.

- [ ] **Step 13.3 — Commit**

```bash
git add hooks/claude-stop.swift
git commit -m "Borderless rounded chrome for Done dialog (StopPanel)"
```

---

## Task 14 — Done dialog: content block + separator styling

**Files:**
- Modify: `hooks/claude-stop.swift` — the function that creates the summary container (search for where the summary background is set) and `addStopHeader`.

- [ ] **Step 14.1 — Update the summary container styling**

Grep: `grep -n 'NSBox\|cornerRadius' hooks/claude-stop.swift` — find the summary container creation (there's typically an `addStopContent` or `addSummary` helper that creates the container). Replace its fill + border + corner assignments with:

```swift
container.wantsLayer = true
container.layer?.cornerRadius = Layout.stopButtonCornerRadius
container.layer?.backgroundColor = Theme.stopRowBg.cgColor
container.layer?.borderColor = Theme.stopRowBorder.cgColor
container.layer?.borderWidth = 1
```

- [ ] **Step 14.2 — Replace the header separator**

Grep: `grep -n 'separator.boxType = .separator' hooks/claude-stop.swift`.

Replace with the same pattern used in Task 9, but using `Theme.stopSeparatorColor`:

```swift
let separator = NSView(frame: NSRect(x: Layout.panelInset, y: y,
                                     width: Layout.panelWidth - Layout.panelInset * 2,
                                     height: Layout.separatorHeight))
separator.wantsLayer = true
separator.layer?.backgroundColor = Theme.stopSeparatorColor.cgColor
contentView.addSubview(separator)
```

- [ ] **Step 14.3 — Build + test**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-stop claude-stop.swift && cd ..`
Run: `bash tests/run.sh`
Expected: both pass.

- [ ] **Step 14.4 — Commit**

```bash
git add hooks/claude-stop.swift
git commit -m "Skin Done-dialog summary container and hairline separator"
```

---

## Task 15 — Done dialog: button skin + keyboard badges + labels

**Files:**
- Modify: `hooks/claude-stop.swift` — `addStopButtons`.

- [ ] **Step 15.1 — Add a skin helper + badge helper (mirror of Task 10/11)**

After `addStopButtons` (still at file scope, before the next MARK), add:

```swift
/// Same shape as `applyUnifiedButtonSkin` in `claude-approve.swift` — local
/// copy so both files follow the project's single-file convention.
private func applyUnifiedStopButtonSkin(_ button: NSButton, tint: NSColor) {
    button.isBordered = false
    button.bezelStyle = .rounded
    button.wantsLayer = true
    button.layer?.cornerRadius = Layout.stopButtonCornerRadius
    button.layer?.borderWidth = 1
    button.layer?.backgroundColor = tint.withAlphaComponent(0.22).cgColor
    button.layer?.borderColor     = tint.withAlphaComponent(0.55).cgColor
    button.attributedTitle = NSAttributedString(string: button.title, attributes: [
        .font: Theme.stopButtonFont,
        .foregroundColor: Theme.textPrimary,
        .paragraphStyle: {
            let ps = NSMutableParagraphStyle()
            ps.alignment = .center
            return ps
        }(),
    ])
    button.contentTintColor = Theme.textPrimary
}

/// Same shape as `addKeyboardBadge` in `claude-approve.swift`.
private func addStopKeyboardBadge(to button: NSButton, number: Int, tint: NSColor) {
    let badge = NSTextField(labelWithString: "\(number)")
    badge.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    badge.textColor = tint.withAlphaComponent(0.85)
    badge.backgroundColor = .clear
    badge.isBordered = false
    badge.isEditable = false
    badge.alignment = .center
    let size = badge.intrinsicContentSize
    badge.frame = NSRect(x: 10,
                         y: (button.frame.height - size.height) / 2,
                         width: size.width, height: size.height)
    button.addSubview(badge)
}
```

- [ ] **Step 15.2 — Update `addStopButtons` to use labels enum + helpers**

Grep: `grep -n 'func addStopButtons' hooks/claude-stop.swift`.

Inside the current `specs` array (which currently has `("Go to Terminal", Theme.buttonGreen)` and `("Ok", Theme.buttonBlue)`), change the string literals to the enum:

```swift
let specs: [(title: String, color: NSColor)] = [
    (StopLabels.terminal, Theme.buttonGreen),
    (StopLabels.ok,       Theme.buttonBlue),
]
```

At the end of the per-button `for (i, spec) in specs.enumerated()` body — after `handler.register(button: btn, color: spec.color)` and the `defaultButtonCell` line — add:

```swift
applyUnifiedStopButtonSkin(btn, tint: spec.color)
addStopKeyboardBadge(to: btn, number: i + 1, tint: spec.color)
```

Delete the older inline `btn.layer?.cornerRadius = Layout.buttonCornerRadius` / `btn.layer?.backgroundColor = spec.color.withAlphaComponent(Theme.buttonRestAlpha).cgColor` / `btn.contentTintColor = spec.color` / `btn.font = Theme.buttonFont` / `btn.focusRingType = .none` lines — they're superseded by `applyUnifiedStopButtonSkin`. Leave `btn.title`, `btn.alignment`, `btn.bezelStyle`, `btn.tag`, `btn.target`, `btn.action` alone.

- [ ] **Step 15.3 — Build + test + manual smoke**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-stop claude-stop.swift && cd ..`
Run: `bash tests/run.sh`
Expected: both pass.

Install and finish any Claude task to trigger Done. Verify: same 2 buttons, same text, same widths, same half-panel each — but with the unified skin + centered 1 / 2 badges on their left edges. Pressing 1 / 2 / Enter / Esc still triggers the correct button.

- [ ] **Step 15.4 — Commit**

```bash
git add hooks/claude-stop.swift
git commit -m "Apply unified button skin + keyboard badges to Done dialog"
```

---

## Task 16 — Done dialog: press animation

**Files:**
- Modify: `hooks/claude-stop.swift` — add the same `animateButtonPress(_:)` helper (local copy) and wire into `StopHandler.tapped` and its keyboard-shortcut fallback.

- [ ] **Step 16.1 — Add the helper**

Immediately after the `applyUnifiedStopButtonSkin` / `addStopKeyboardBadge` helpers, add the same `animateButtonPress` implementation shown in Task 6.1. Copy the function body verbatim from `hooks/claude-approve.swift` (same file scope, private, same signature).

- [ ] **Step 16.2 — Wire into `StopHandler.tapped`**

Grep: `grep -n 'func tapped' hooks/claude-stop.swift`.

Inside `@objc func tapped(_ sender: NSButton)`, at the very top of the body, add:

```swift
animateButtonPress(sender)
```

- [ ] **Step 16.3 — Wire into the keyboard-shortcut fallback**

Grep: `grep -n 'NSEvent.addLocalMonitorForEvents' hooks/claude-stop.swift` — find the `showStopDialog` local monitor that maps `1`/`2`/Enter/Esc to button presses. Wherever the monitor synthesizes a press (typically a call to `handler.button(at:).performClick(nil)` or a direct method dispatch), wrap it so `animateButtonPress` runs first, then the existing press dispatch:

```swift
if let btn = handler.buttons.first(where: { $0.tag == targetTag }) {
    animateButtonPress(btn)
    btn.performClick(nil)
}
```

(Adjust variable names to match the existing code — the pattern above is the template.)

- [ ] **Step 16.4 — Build + test + manual smoke**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-stop claude-stop.swift && cd ..`
Run: `bash tests/run.sh`
Expected: both pass.

Install and verify: pressing 1 or clicking "Go to Terminal" shows the scale-and-flash animation; pressing 2 or Enter animates "Ok".

- [ ] **Step 16.5 — Commit**

```bash
git add hooks/claude-stop.swift
git commit -m "Add press animation to Done dialog (mouse + keyboard)"
```

---

## Task 17 — Manual QA sweep + update `CLAUDE.md` test checklist

**Files:**
- Modify: `CLAUDE.md` — the `### Manual Test Cases` section.

- [ ] **Step 17.1 — Run every existing manual test case**

Reset sessions: `rm -rf /tmp/claude-hook-sessions/`.

Walk through every item in `CLAUDE.md §Testing → Manual Test Cases`:

- Consecutive Bash dialogs (5+); Button press feedback (mouse + keyboard); Desktop/Space switching; File-edit diffs; File write; Mixed tool batch; Read tool; Session auto-approve; Large content; Keyboard shortcuts 1/2/3/Enter/Esc; Stop dialog; AskUserQuestion wizard sub-cases (12a–12i).

Every case must still pass. Each press should now show the scale-and-flash animation. Every button label must match exactly. Record any regression immediately and stop — do not proceed to step 17.2.

- [ ] **Step 17.2 — Add new "unified look" manual tests**

Append this block inside `### Manual Test Cases` in `CLAUDE.md`, renumbered to take the next item number after the existing last case (12). The existing item 12 (AskUserQuestion wizard) already has sub-cases 12a–12i; append 13 and 14 after it:

```markdown
13. **Unified dialog family** — trigger in sequence: a Bash permission,
    finish an Edit permission, let Claude finish to get the Done dialog,
    and trigger a multi-question AskUserQuestion. All four panels share:
    borderless rounded chrome (no titlebar), wizard-style rounded pill
    buttons with semibold 12pt text, content container with the subtle
    row-bg palette, and the press animation on every button click. Panel
    project/cwd header still visible on Permission and Done.
14. **Press animation** — on every button in every dialog, clicking or
    pressing a keyboard shortcut triggers a brief scale-down + fill-
    brighten animation (~180 ms total). No regressions in the underlying
    click outcome.
```

- [ ] **Step 17.3 — Commit**

```bash
git add CLAUDE.md
git commit -m "Extend manual test checklist for unified dialog look"
```

- [ ] **Step 17.4 — Final green build**

Run: `bash tests/run.sh`
Expected: `=== All test suites passed ===`.

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift && swiftc -O -parse-as-library -framework AppKit -o claude-stop claude-stop.swift && cd ..`
Expected: both binaries build without warnings.

---

## Self-review results

- **Spec coverage:**
  - §4.1 panel chrome → Tasks 7 (permission) + 13 (done) + wizard chrome unchanged (already done).
  - §4.2 content block styling → Tasks 8 + 14.
  - §4.3 separator → Tasks 9 + 14.
  - §4.4 button skin → Tasks 10 + 15.
  - §4.5 keyboard badges → Tasks 11 + 15.
  - §4.6 wizard 2-row footer + labels → Tasks 2 + 4.
  - §4.7 wizard header color → Task 3.
  - §4.8 Other-row centering → Task 5.
  - §4.9 press animation → Tasks 6 + 16.
  - §5 label constants → Task 1 (approve) + Task 12 (stop).
  - §6 stop-file Theme/Layout additions → Task 12.
  - §7 code organization matches.
  - §9 testing → Task 17.

- **Placeholder scan:** no TBD / TODO / "similar to" language; every step specifies concrete code, concrete file paths, concrete commands.

- **Type consistency:** `WizardLabels`, `PermissionLabels`, `StopLabels`, `StopPanel`, `WizardPanel`, `applyUnifiedButtonSkin`, `applyUnifiedStopButtonSkin`, `addKeyboardBadge`, `addStopKeyboardBadge`, `animateButtonPress` — all spelled identically across tasks.

- **Non-negotiable guardrail:** every task touches only visual attributes, layout calculations the spec explicitly permits (wizard footer 2-row), label strings (all via enums), and animation overlays. No task modifies any click target, selector, `resultKey`, outcome, timer, observer, signal handler, session logic, or state-machine transition.
