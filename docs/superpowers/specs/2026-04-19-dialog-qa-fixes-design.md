# Dialog QA Fixes — Design

**Date:** 2026-04-19
**Scope:** `hooks/claude-approve.swift` + `hooks/claude-stop.swift`
**Status:** Approved, ready for implementation plan

> **Non-negotiable guardrail:** strictly fixes to four concrete issues
> reported during manual QA. No change to any click target, `resultKey`,
> outcome, tool-permission decision, timer, keyboard binding, session
> identity, persistence, state-machine transition, or unrelated layout.

## 1. Problem

Four issues surfaced during manual QA of the unified dialog visuals:

1. The AskUserQuestion wizard's press animation is only fired on mouse-click paths. Keyboard navigation (↑/↓ arrows and digit shortcuts) silently moves the selection without any press animation on the newly-targeted row.
2. All three dialogs can lose keyboard focus and fail to recover it — most visibly after Mac Space switching, but also after ⌘+Tab to another app and back, after screen wake, and when another window briefly covers the panel.
3. The Permission dialog's "No, and tell Claude what to do differently" morph replaces the button with a single-line `NSTextField`. The user wants multi-line input with Shift+Enter inserting newlines, matching the wizard's Other row behavior.
4. The wizard's and Done dialog's `Go to Terminal` button label is misleading when the parent app is Claude Desktop. The underlying behavior works (a `claude://resume` deep link fires), but the button text should reflect the actual destination.

## 2. Goals

- Fix each reported issue to the letter of the user's feedback.
- No visual regressions in the four surfaces that already look correct (Permission + Done button presses, wizard Other row typing, wizard's current animation intensity).
- Keep labels in named enums. Support a dynamic terminal-button label without dropping the "no inline strings" rule.

## 3. Non-Goals

- Changing the wizard's press-animation intensity (user explicitly selected option A — the current 0.96 scale).
- Refactoring Claude-Desktop deep-link behavior (user will handle separately).
- Adjusting terminal-detection logic in `openTerminalApp`.
- Adding observers or timers to the existing Permission/Done dialog beyond the shared focus-recovery helper.

## 4. Fix Details

### 4.1 Press animation on wizard keyboard paths (Issue 1)

`WizardController` has six press-animation sites today, all triggered from mouse clicks or footer-button actions:

```
onPresetClicked  → animateButtonPress(h.optionRowViews[g.payload])
onBack           → animateButtonPress(h.backButton)
onPrimary        → animateButtonPress(h.primaryButton)
onTerminal       → animateButtonPress(h.terminalButton)
onCancel         → animateButtonPress(h.cancelButton)
activateOther    → animateButtonPress(h.otherRow)
```

Two keyboard paths skip it:

- `moveSelection(by:)` — fires on ↑/↓ keys. Moves selection to a different preset row or the Other row, but does not animate the newly-targeted view.
- `selectOption(byNumber:)` — fires on `1..N` digit keys. Same gap.

**Fix.** In each of those two methods, immediately after the selection state is committed and `applySelectionFromState` has applied the highlight, call:

```swift
animateButtonPress(h.optionRowViews[nextIndex])   // when a preset row is targeted
// or
animateButtonPress(h.otherRow)                    // when the Other row is targeted
```

The 0.96 scale + 180 ms duration is unchanged. Mouse-click paths are unchanged.

### 4.2 Focus recovery across all scenarios (Issue 2)

Currently:

| Dialog | Space-switch observer | App-active observer | Screen-wake observer | Initial-present guard |
|---|---|---|---|---|
| Permission | ✅ | ❌ | ❌ | via `activatePanel` |
| Done | ✅ | ❌ | ❌ | via `activatePanel` |
| Wizard | ❌ | ❌ | ❌ | via `activatePanel` |

Even the dialogs that *do* observe space-switching have been observed to fail to regain focus in practice — the observer exists but the single call into `activatePanel` isn't always sufficient (likely a timing issue between when the space-change event fires and when the window-server has finished presenting our Space).

**Fix.** Introduce a shared focus-recovery helper installed per dialog:

```swift
/// Installs observers on every notification that can plausibly correspond to
/// the dialog losing keyboard focus, and re-activates the panel when any of
/// them fires. Returns a cleanup closure that removes every observer.
///
/// Observed notifications:
///   - `NSWorkspace.activeSpaceDidChangeNotification` (Space switch)
///   - `NSApplication.didBecomeActiveNotification` (app re-foregrounded)
///   - `NSWorkspace.screensDidWakeNotification` (screen unlock / wake)
///   - `NSWindow.didBecomeKeyNotification` (first-present settle guard)
///
/// Each observer's handler calls `activatePanel(panel)` wrapped in a short
/// `DispatchQueue.main.async` so the window-server finishes its own transition
/// before we try to re-take key. If the panel is no longer visible the call
/// is a no-op.
///
/// A 250 ms one-shot fallback (via `DispatchQueue.main.asyncAfter`) fires
/// once after install to cover the case where the very first `orderFront`
/// completes without picking up key status.
func installFocusRecoveryObservers(on panel: NSPanel) -> () -> Void
```

The helper lives in `claude-approve.swift` (alongside `activatePanel`). `claude-stop.swift` gets its own copy with the same signature and body, following the single-file convention already established for the other helpers shared between the two files.

Call-site pattern for all three dialogs:

```swift
let cleanup = installFocusRecoveryObservers(on: panel)
defer { cleanup() }
```

This replaces the existing ad-hoc `activeSpaceDidChangeNotification` block in Permission and Done; adds the full set to the wizard.

Behavior guarantee: on any of the four observed events, the panel re-activates on the next run-loop tick. If the user is legitimately clicking another window to ignore the dialog, we do not force-grab key status until the *next* focus-returning event (e.g. app re-foreground) — `didResignKeyNotification` is deliberately NOT observed, so focus-returning to our panel is event-driven, not polled.

### 4.3 Multi-line Permission dialog deny morph (Issue 3)

`ButtonHandler.morphToTextField` today builds:

```
┌─[ button frame ]──────────────────────────────┐
│ [ NSTextField (single line) ]      [ Send ⏎ ] │
└───────────────────────────────────────────────┘
```

Keyboard handling: the NSTextField's control delegate handles `insertNewline:` (submit) and `cancelOperation:` (Esc cancel). No handling for `insertLineBreak:` / `insertNewlineIgnoringFieldEditor:` (what Shift+Enter/Option+Enter send). The text field is single-line anyway, so even if they were handled they wouldn't render.

**Fix.** Replace `NSTextField` with `NSTextView` inside `NSScrollView`, following the pattern in `WizardOtherRow.buildTextView` verbatim:

- NSScrollView with `drawsBackground = false`, `hasVerticalScroller = true`, `autohidesScrollers = true`, `borderType = .noBorder`.
- NSTextView with `isEditable = true`, `isSelectable = true`, `isRichText = false`, `allowsUndo = true`, `isHorizontallyResizable = false`, `isVerticallyResizable = true`, `minSize = .zero`, `maxSize = .greatestFiniteMagnitude`, `autoresizingMask = [.width]`, `textContainer?.widthTracksTextView = true`.
- `textContainerInset = NSSize(width: 0, height: 2)`.
- Placeholder: we keep the existing placeholder text (`option.placeholder`) — rendered as a separate "dim" label that fades out once the text view starts receiving input (same pattern as NSTextView placeholders in the wizard).
- Delegate: NSTextView's `textView(_:doCommandBy:)`. Handles:
  - `insertNewline:` → submit via `submitTextInput(index:)` (existing behavior)
  - `insertLineBreak:` / `insertNewlineIgnoringFieldEditor:` → `textView.insertText("\n", replacementRange: selectedRange())` (new behavior — Shift+Return and Option+Return)
  - `cancelOperation:` → dismiss with empty feedback (existing Esc behavior)

Row-height growth: the container morphs from the original button frame to a growing frame as new lines are added. The `Send ⏎` button stays pinned at the right edge, vertically centered in the growing container. Growth strategy: same as wizard's `WizardOtherRow.refreshHeight` — content-driven up to a 140 pt cap, beyond which the scroll view handles overflow.

Integration into the permission dialog's button-row grid: when the morph expands past the original button height, the dialog's root view and panel grow by the same delta, and views below the morph (if any) shift accordingly. Since the "No..." button is always on the last row of the button grid, this means growing the panel from the top without disturbing the buttons above.

### 4.4 Dynamic terminal-button label (Issue 4)

Helper (one copy in each file, per single-file convention):

```swift
/// Label for the "go to parent app" button, adapted to the detected parent.
/// Falls back to "Go to Terminal" when the parent cannot be identified or
/// is a genuine terminal emulator.
func terminalButtonLabel() -> String {
    let (_, parentApp) = resolveProcessAncestry()
    let app = parentApp ?? capturedTerminalApp
    if app?.bundleIdentifier == "com.anthropic.claudefordesktop" {
        return "Go to Claude Desktop"
    }
    return "Go to Terminal"
}
```

Call sites:

- Wizard footer: the `terminal` button's title is `terminalButtonLabel()` instead of the static `WizardLabels.terminal`.
- Done dialog: the `specs` array's terminal entry uses `terminalButtonLabel()` instead of `StopLabels.terminal`.

Labels enum update. The static constants stay (internally used where the label is unambiguous), but add:

```swift
// In claude-approve.swift
enum WizardLabels {
    static let back                    = "Back"
    static let next                    = "Next"
    static let submit                  = "Submit answers"
    static let terminal                = "Go to Terminal"        // fallback default
    static let terminalForClaudeDesktop = "Go to Claude Desktop"
    static let ok                      = "Ok"
}
```

Same in `StopLabels`. The helper references these constants rather than inlining the strings — so the "no inline strings" rule holds.

The existing bundle-ID case in `openTerminalApp` (`com.anthropic.claudefordesktop`) is unchanged; the helper only affects the label text.

## 5. Code Organization

- `installFocusRecoveryObservers(on:)` — in `claude-approve.swift` Focus Management section; mirrored in `claude-stop.swift` with the same signature.
- `terminalButtonLabel()` — same pattern, one in each file.
- `ButtonHandler.morphToTextField` — rewritten in place to use `NSTextView` + `NSScrollView`. Its helper properties (`activeTextField`, `activeTextView`) gain a new sibling to hold the text view. `submitTextInput(index:)` reads from the text view's `string` instead of the text field's `stringValue`.
- `WizardController.moveSelection` and `WizardController.selectOption` — gain a one-line `animateButtonPress` call in the preset-row and Other-row branches.

No new files. No new sections beyond those already established.

## 6. Testing

- **Unit tests:** no new behavior added to pure-logic functions. `WizardLabels.terminal` / `StopLabels.terminal` still equal `"Go to Terminal"`, so existing `testLabelEnums` keeps passing. New constants for Claude-Desktop labels get a one-liner assertion added.
- **Manual QA** is the authoritative gate. Add to `CLAUDE.md §Testing`:
  - **Item 14a — keyboard animation**: in the wizard, press ↑/↓ to move selection. The newly-focused row scales-down-and-back just like it does on mouse click. Same for digit keys 1…N.
  - **Item 15a — focus recovery (Space)**: trigger a dialog, switch Space, return — focus is restored without clicking.
  - **Item 15b — focus recovery (app switch)**: trigger a dialog, ⌘+Tab to another app, ⌘+Tab back — focus is restored.
  - **Item 15c — focus recovery (screen wake)**: trigger a dialog, lock the screen, unlock — focus is restored.
  - **Item 16 — multi-line deny feedback**: in the Permission dialog, click "No…", type a line, press Shift+Enter, type another, press Enter — the submitted feedback string contains the newline.
  - **Item 17 — Claude-Desktop label**: when Claude is launched from Claude Desktop, the wizard and Done dialog show "Go to Claude Desktop" instead of "Go to Terminal". From a terminal parent, still "Go to Terminal".

## 7. Risks

- **Focus recovery might over-activate.** The helper observes four distinct notifications. If several fire in quick succession (e.g. app re-foreground immediately after Space switch), `activatePanel` runs multiple times in a single run loop tick. Harmless but worth noting — the `DispatchQueue.main.async` wrap collapses them into the same tick so we only see one activation per event loop turn.
- **NSTextView inside a narrow morph container** may behave differently at very small widths. The morph container's width is `button.frame.width - sendButtonWidth - padding`. Because `NSTextView` autoresizes its text container width and wraps, this should render fine, but manual QA against the longest Bash-pre-suffix and a typical "Yes, and don't ask again for …" label is prudent.
- **`com.anthropic.claudefordesktop`** bundle ID is hard-coded in two places (the `openTerminalApp` switch and the new `terminalButtonLabel`). If Anthropic ever ships a new bundle ID, both places need updating. Extract to `Theme`/constant? Not now — spec §3 explicitly defers this to a follow-up.

## 8. Decisions Log

| Decision | Choice | Why |
|---|---|---|
| Press animation intensity | Keep 0.96 (option A) | User explicitly confirmed A in brainstorming |
| Focus helper scope | All three dialogs | User asked for "all possible scenarios"; the single helper gives uniform behavior |
| Extra observers | Space + app-active + screen-wake + window-key | Covers every focus-loss scenario considered |
| `didResignKeyNotification` handling | NOT observed | Re-taking focus when user legitimately clicks away would fight the user |
| Single-line vs multi-line deny morph | Multi-line (NSTextView) | Matches wizard; user explicitly requested "same as wizard" |
| Dynamic terminal label | Function returning enum constants | Preserves "no inline strings" rule |
| Cross-file code sharing | None (duplicate helpers) | Preserves `CLAUDE.md` single-file rule as we did in prior plans |
