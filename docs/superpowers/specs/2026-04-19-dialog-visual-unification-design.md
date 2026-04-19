# Dialog Visual Unification — Design

**Date:** 2026-04-19
**Scope:** `hooks/claude-approve.swift` + `hooks/claude-stop.swift`
**Status:** Approved, ready for implementation plan

> **Non-negotiable guardrail:** this refactor is strictly visual + the
> explicit layout/label changes the user called out (§4.6, §4.7). No button
> behaviour, no keyboard binding, no click target, no outcome code path, no
> permission-decision logic, no modal lifecycle, no timer, no session-identity
> code, no observer, no signal handler, no decision persistence, no result-
> processing branch may be touched. Any implementation step that requires
> changing non-visual code is out of scope and must be reported as a blocker
> instead of being silently applied.

## 1. Problem

Three user-facing dialogs live in this project. The AskUserQuestion wizard (recently built) uses a borderless, rounded-corner chrome with pill-shaped footer buttons and a refined typography palette. The other two — the Permission dialog (`showPermissionDialog` in `claude-approve.swift`) and the Done dialog (`showStopDialog` in `claude-stop.swift`) — use the older titled/closable NSPanel style with system-drawn buttons.

Result: the three dialogs feel like they come from different apps.

## 2. Goals

- Apply the wizard's visual language to the Permission and Done dialogs so all three look like a single family.
- Make the wizard's footer layout slightly friendlier (two rows) and align its button labels with Claude Code CLI conventions.
- Add a subtle press animation that plays on every button click in every dialog.
- **Preserve every existing feature:** labels, button counts, button frames (widths/heights), keyboard shortcuts (1/2/3), Enter/Esc defaults, the "No…" text-input morph, Space-switch re-activation, SIGUSR1 sibling coordination, the dialog timeout, and the 15-second auto-dismiss on Done.
- Move every piece of visible text into named constants — no inline string literals for labels anywhere.

## 3. Non-Goals

- Changing what any button does.
- Changing which buttons appear or in what order.
- Changing button frames (width, height, row layout) in Permission or Done.
- Removing any content currently shown (project name, cwd, gist, diffs, code blocks, etc.).
- Cross-file code sharing (both files stay single-file scripts per `CLAUDE.md`).

## 4. User-Facing Changes

### 4.1 Panel chrome (all three dialogs)

Replace `[.titled, .closable, .nonactivatingPanel]` with `[.titled, .nonactivatingPanel, .fullSizeContentView]`, hide the titlebar, hide the traffic-light buttons, and give the content view a 10 pt corner radius with `masksToBounds`. This mirrors the wizard's current chrome and produces a borderless, rounded look that still accepts keyboard input (via the existing `WizardPanel: NSPanel` subclass — `canBecomeKey = true`).

### 4.2 Content block styling (Permission + Done)

The code-block / summary container switches to the wizard's subtle row palette:

- Background: `Theme.wizardRowBg` (3% white alpha)
- Border: 1pt `Theme.wizardRowBorder` (8% white alpha)
- Corner radius: 8 pt (matches `Layout.wizardRowCornerRadius`)

Content inside the block (syntax-highlighted bash, diffs, summary text) is unchanged.

### 4.3 Header separator (Permission + Done)

The existing `NSBox .separator` between the project-identity block and the tag-pill row becomes a 1 pt `rgba(255, 255, 255, 0.10)` hairline to match the wizard's body dividers.

### 4.4 Button skin (all three dialogs)

Every footer/action button uses the wizard's pill look:

- Corner radius: 8 pt (`Layout.wizardRowCornerRadius`)
- Border: 1 pt; color follows the button's tint at the alpha given below
- Fill: flat, no NSButton bezel (`isBordered = false`, `bezelStyle = .rounded`, custom `layer.backgroundColor`)
- Font: `Theme.wizardFooterButtonFont` (SF system, 12 pt, semibold)
- Text color: `Theme.textPrimary` when enabled, `Theme.wizardButtonDisabledText` when disabled
- **Frame (x, y, width, height) is unchanged** — buttons still use their current positions from `computeButtonRows` / `addStopButtons` / wizard footer layout.

Fill / border alphas:

| Tint | Rest fill | Rest border |
|---|---|---|
| `buttonAllow` (green) | 0.22 | 0.55 |
| `buttonPersist` (blue, primary) | 0.22 | 0.50 |
| `buttonDeny` (red) | 0.12 | 0.40 |
| neutral gray (new) | 0.06 on white | 0.18 on white |

### 4.5 Keyboard-shortcut badges (Permission + Done)

The 1 / 2 / 3 digit badges on buttons move to the **vertical center of the button's left edge** (currently some are top-left or inconsistent). Style: 10 pt monospaced, 85% alpha of the button's tint color, 10 pt from the left, `translateY(-50%)` equivalent.

Done dialog keeps its existing per-button numbers too.

### 4.6 Wizard footer — new 2-row layout

Current footer: single row with four buttons (Back · Primary · Terminal · Cancel).

New footer: two rows, each row a grid of two equal-width buttons.

```
┌────────────┬──────────────────────────┐
│   Back     │   Next / Submit answers  │   ← row 1 (wizard navigation)
├────────────┼──────────────────────────┤
│ Go to      │   Ok                     │   ← row 2 (escape actions)
│ Terminal   │                          │
└────────────┴──────────────────────────┘
```

Label changes:

- "Terminal" → "Go to Terminal" (matches Done dialog's existing label)
- "Cancel" → "Ok" (matches Done dialog's existing label)

Behaviour unchanged: row-1 buttons drive wizard navigation; row-2 buttons are the escape hatches (Go to Terminal returns `.terminal`, Ok returns `.cancel`).

Colors (wizard specifically):

- Back: neutral gray rest fill
- Next / Submit answers: blue (primary)
- Go to Terminal: green (`buttonAllow` tint)
- Ok: neutral gray — distinct from Next so users don't see two same-colored blue buttons

### 4.7 Wizard header tag color

`ASKUSERQUESTION` header text currently renders in yellow (the existing tool-tag color). Change to a soft lavender (`#A78BFA`) with 0.08 em letter-spacing. This gives the wizard a distinct but refined identity vs the other dialogs' tool-specific tag pills. The in-body question-header pill (e.g. "DATABASE") stays yellow/tool-tinted — only the top-of-panel `ASKUSERQUESTION` tag changes.

### 4.8 Other-row text centering (wizard)

When the Other row is active and the typed text is shorter than the scroll view's available height, the scroll view is **vertically centered** within the row (rather than top-anchored with empty space below). As the text grows past one line the row expands to fit, and the gap is naturally consumed.

### 4.9 Button press animation (all three dialogs)

A shared press animation plays for every button, triggered on both mouse clicks and keyboard shortcuts:

1. **Press-in** (~60 ms): scale to 0.96 via `CATransform3D` on the button's layer, fill brightens (alpha goes from rest to `Theme.buttonPressAlpha` ≈ 0.55).
2. **Release** (~120 ms): scale back to 1.0 with ease-out; fill stays at the press alpha until the modal stops (confirming the click visually).

Implementation uses `CABasicAnimation` on `transform.scale` inside a `CATransaction`. Total ~180 ms. The existing press-feedback paths (`ButtonHandler.animatePress`, `StopHandler.tapped`, `WizardController.onPreset/onPrimary/onTerminal/onCancel`) all call a single shared `animateButtonPress(_:)` helper before dispatching their payload.

## 5. Label Constants

All visible button text becomes a named constant. No inline string literals for button titles anywhere.

### 5.1 Wizard labels (claude-approve.swift)

```swift
/// All wizard-footer button labels. Exact spellings match the Claude Code
/// CLI / Desktop convention so the native wizard and the hook dialog agree.
/// Kept in one place so a future wording change touches a single file.
enum WizardLabels {
    static let back      = "Back"
    static let next      = "Next"
    static let submit    = "Submit answers"
    static let terminal  = "Go to Terminal"
    static let ok        = "Ok"
}
```

### 5.2 Done dialog labels (claude-stop.swift)

```swift
enum StopLabels {
    static let terminal  = "Go to Terminal"
    static let ok        = "Ok"
}
```

### 5.3 Permission dialog labels (claude-approve.swift)

The existing labels are already generated per-tool in `buildPermOptions()`. That function stays authoritative; we simply add a lightweight enum for the two tool-independent phrases that do appear as literals today:

```swift
enum PermissionLabels {
    static let allowOnce                = "Yes"
    static let denyWithFeedbackFallback = "No, and tell Claude what to do differently"
    // Tool-specific "don't ask again" labels remain generated in
    // buildPermOptions() — they already parameterize on tool/cmd/domain.
}
```

## 6. Shared Visual Constants

Both Swift files already declare their own `Theme` and `Layout` enums per the single-file rule. The wizard's visual constants (`Theme.wizardRowBg`, `Theme.wizardFooterButtonFont`, `Layout.wizardRowCornerRadius`, etc.) already exist in `claude-approve.swift`. `claude-stop.swift` needs a matching set added — not a shared file, just a parallel block. This keeps the single-file convention.

Constants `claude-stop.swift` will gain (mirroring the wizard block in `claude-approve.swift`):

- `Theme.stopRowBg / stopRowBorder` — subtle fill / border for the Done summary container
- `Theme.stopButtonFont` — semibold 12 pt system
- `Theme.stopPanelCornerRadius` — 10 pt
- `Layout.stopButtonCornerRadius` — 8 pt

Naming uses a `stop*` prefix so the constants are locally meaningful; values match the wizard's.

## 7. Code Organization

### 7.1 `claude-approve.swift`

- **Wizard footer (Task 4.6)** — `buildWizardQuestionPanel` gains a two-row footer block, replacing its four-across row. Controller wiring of `backButton` / `primaryButton` / `terminalButton` / `cancelButton` is unchanged — only the layout math changes.
- **Wizard header color (Task 4.7)** — a new `Theme.wizardHeaderAccent` constant holds the lavender; `buildWizardQuestionPanel` and `buildWizardReviewPanel` reference it where they previously read `Theme.toolTagColors["AskUserQuestion"]` for the top-of-panel tag.
- **Wizard Other-row centering (Task 4.8)** — `WizardOtherRow.refreshHeight` centers `scrollView` vertically within the row when `scrollContentHeight < scrollViewHeight`.
- **Permission dialog chrome (Task 4.1)** — `makePermissionPanel` rewritten to use `.titled + .fullSizeContentView` and hide the titlebar + window buttons. `WizardPanel` subclass is reused.
- **Permission dialog content + buttons (Tasks 4.2, 4.3, 4.4, 4.5)** — `addCodeBlock` gets rounded+tinted container; `addHeader` replaces `NSBox` separator with a hairline view; `addButtonRows` uses a new helper `applyWizardButtonSkin(_:)` that restyles the existing buttons without touching their frames. Keyboard-shortcut badges are added via a new `addKeyboardBadge(to:)` helper centered on the left edge.
- **Click animation (Task 4.9)** — new `animateButtonPress(_:)` shared helper; all three controllers call it.
- **Label enums (Task 5)** — added at top of file in the existing Models section.

### 7.2 `claude-stop.swift`

- Parallel refactor of `makeStopPanel`, `addStopCodeBlock`, `addStopButtons`, and its own `animateButtonPress(_:)` helper. Labels move to a `StopLabels` enum.
- New `Theme.stop*` constants added to the existing Theme enum.

## 8. Out of Scope (explicit)

- Button frames are untouched everywhere. `computeButtonRows` / `addStopButtons` still compute positions exactly as today.
- No behavior change in the deny-text-morph — the existing `ButtonHandler.morphToTextField` still swaps the "No…" button's inner contents; only the outer button's corner radius / fill / border inherits the new skin.
- No change to the existing Space-switch observer, SIGUSR1 signal handler, or dialog timeout.
- Done dialog's auto-dismiss timer stays at 15 seconds.

## 9. Testing

- **Compilation:** `bash tests/run.sh` must still pass without touching test files (the skin change is in production code only).
- **Manual QA:** the manual test checklist in `CLAUDE.md §Testing` is exercised end-to-end after the refactor. Every existing case must still pass (keyboard shortcuts, Space switching, deny morph, mixed-dialog batches, single/multi-question wizard, Other row, Terminal button, Cancel/Ok button).
- **Visual QA:** a manual-test item is added for "dialogs look like one family" — trigger a Bash permission, finish it, then an Edit permission, then a Stop dialog, then a multi-question AskUserQuestion. All four should share panel chrome, button look, and typography.

## 10. Decisions Log

| Decision | Choice | Why |
|---|---|---|
| Panel style | `.titled + .fullSizeContentView` with hidden titlebar | Only reliable way to get borderless keyboard-accepting NSPanel on macOS |
| Button font weight | Semibold | Cleaner than bold at 12 pt, matches wizard already |
| Button corner radius | 8 pt everywhere | Single value, matches wizard |
| Ok (wizard) color | Neutral gray | User needs Next and Ok distinct; red felt wrong for "Ok" label |
| Header tag color (wizard) | `#A78BFA` lavender | Distinguishes the inquiry dialog from tool-specific tagged tools |
| Label storage | Enum constants | Single source of truth; matches user's non-negotiable "no hardcoded labels" requirement |
| Shared code between files | None (parallel blocks) | Preserves `CLAUDE.md` single-file rule |
| Animation duration | ~180 ms total | Long enough to feel, short enough to not delay clicks |
