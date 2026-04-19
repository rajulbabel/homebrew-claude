# AskUserQuestion Inline-Answer Wizard — Design

**Date:** 2026-04-19
**Scope:** `hooks/claude-approve.swift`, `tests/test-approve.swift`
**Status:** Approved, ready for implementation plan

## 1. Problem

The permission dialog currently renders Claude's `AskUserQuestion` tool as a static text block with a single **Go to Terminal** button. Users must click through to the terminal just to answer a question that's already visible on screen.

We want to answer inline while preserving the terminal path for users who prefer it.

## 2. Goals

- Answer one or many `AskUserQuestion` questions directly inside the existing macOS permission panel.
- Preserve the existing "Go to Terminal" path as a first-class alternative.
- Match Claude Code CLI / Desktop's UX conventions (multi-question flow, "Other" free-text answer, Shift+Return newline, keyboard-first navigation).
- Everything data-driven from the tool's `questions` array — no hardcoded question text, options, labels, counts, or styling.

## 3. Non-Goals

- Changing other tool dialogs (Bash, Edit, Write, etc.) — they remain untouched.
- Adding new permission modes or settings keys.
- Persisting answers across sessions.
- Multi-select questions (only single-select per CLI/Desktop parity).

## 4. User Flow

1. Claude invokes `AskUserQuestion` with `questions: [{ header, question, options: [{ label, description }] }, …]`.
2. The hook shows a wizard panel for the first question.
3. User picks a preset option (click or keyboard) or selects **Other** and types a custom answer (single or multi-line).
4. User advances with **Next** (Return / → / click). Back is available from question 2 onwards.
5. After the last question, if `questions.count > 1`, a **Review** panel shows every answer. Clicking a row jumps back to that question. Pressing **Submit** (Return / → / click) sends all answers.
6. If `questions.count == 1`, **Submit** replaces **Next** on the single question's panel — no review step.
7. At any time, **Terminal** opens the user's terminal (existing behavior), and **Cancel** dismisses with a generic denial.

## 5. Visual Design

### 5.1 Question panel

- Header band: tool tag pill (yellow `AskUserQuestion` color) + `"ASKUSERQUESTION"` + step counter `"N of M"` on the right.
- Body:
  - Yellow tag pill with the question's `header` (uppercased).
  - Question text in system font (primary text color).
  - One rounded radio-card row per entry in `options[]` plus a generated **Other** row as the last entry.
  - Radio cards: 14px circle on the left (filled green when selected), label (bold 12pt SF), description (11pt secondary) on its own line.
  - Rows are vertically center-aligned (`align-items:center`) so the radio sits in the middle of the label + description block.
  - Progress strip of `M` thin dots centered below the rows; green for answered, grey for pending.
- Footer band: `← Back` (disabled on step 0) · `Next →` / `Submit ⏎` · `Terminal` · `Cancel`.

### 5.2 Other row

- **Rest state** is identical to preset rows: unfilled radio + label `"Other"` + description `"Type your own answer"`.
- **Active state** (user clicked the row or pressed its number): radio fills green, the label cell becomes an inline multi-line editable text area using the *same* font, size, weight, and color as preset labels. A thin 11px blinking caret sits at the end. Description slot stays as `"Type your own answer"`.
- The row grows vertically as newlines are added (Shift+Return). Dialog resizes to fit.
- Typed text is preserved across option-navigation within the same question *and* across step-navigation between questions (stored in `pendingCustom[i]`). It is discarded only when the dialog is dismissed (Cancel, Terminal, or Submit — Submit only discards other questions' pending text; the committed Other answer is sent).

### 5.3 Review panel

- Same header band with `"ASKUSERQUESTION · REVIEW"` and `"M of M answered"` on the right.
- Body: one row per question, the whole row is clickable and keyboard-focusable (jumps to that question). Row content:
  - Yellow tag pill (question header),
  - Question text in secondary color,
  - Inline "edit" affordance on the right (text link, same action as clicking the row),
  - Answer line: green checkmark, then the chosen option's label (or the custom typed string), then `· description` / `· custom` as appropriate. Multi-line custom answers wrap and indent under the checkmark.
- Full green progress strip.
- Footer: `← Back` · `Submit Answers ⏎` · `Terminal` · `Cancel`. Submit is disabled while any answer is missing.

## 6. Keyboard Model

### 6.1 Option-selection mode (default; no text field focused)

| Key | Action |
|-----|--------|
| ↑ / ↓ | Move selection up/down, wrapping at ends |
| ← | Press Back button (no-op if on step 0) |
| → | Press Next / Submit button (no-op if disabled) |
| Return | Same as → |
| 1…N | Jump to that option (N = last option, i.e. Other) |
| Esc | Cancel dialog |
| Tab | Focus Terminal button (macOS convention) |

### 6.2 Text-input mode (Other selected and its text area has focus)

| Key | Action |
|-----|--------|
| ← / → | Move text caret within the line |
| ↑ / ↓ | Move text caret between lines (macOS convention for multi-line) |
| Return | Submit current question (advance) |
| Shift+Return | Insert newline |
| 1…N | Type the digit into the text area (no navigation) |
| Esc | Exit text-input mode back to option-selection mode; typed text is preserved |

### 6.3 Submit-disabled rule

On the review panel (and on a single-question panel before its answer is chosen), the Submit / Next button is rendered with the disabled style (greyed background and border, desaturated text). Clicks and Return are no-ops in that state.

## 7. Data Model

### 7.1 Hook input

No protocol change. We consume the existing payload:

```json
{
  "tool_name": "AskUserQuestion",
  "tool_input": {
    "questions": [
      {
        "header": "DATABASE",
        "question": "Which database?",
        "options": [
          { "label": "Postgres", "description": "SQL, relational" },
          { "label": "SQLite",   "description": "Embedded, zero-config" }
        ]
      }
    ]
  },
  "cwd": "…", "session_id": "…", "permission_mode": "…"
}
```

### 7.2 In-memory state (dialog-local)

```
struct WizardState {
  questions: [Question]     // parsed from tool_input
  step: Int                 // 0..questions.count (questions.count == review step)
  answers: [Answer?]        // parallel to questions; nil = unanswered
  pendingCustom: [String]   // parallel to questions; typed-but-not-yet-committed Other text
}

enum Answer {
  case preset(index: Int)
  case custom(text: String)
}
```

- `pendingCustom[i]` holds whatever the user has typed into question `i`'s Other field, even when they navigate away. It is promoted into `answers[i] = .custom(text)` only when the user commits by advancing with Return or by picking Other then leaving it non-empty.
- The review panel considers a question "answered" iff `answers[i] != nil`. Submit-disabled rule checks `answers.allSatisfy { $0 != nil }`.

### 7.3 Hook response

- **Submit** → `deny` with `permissionDecisionReason` = formatted answer summary. Each question renders as a two-line block (header+question on line 1, `→ answer` on line 2), blocks separated by a blank line. Custom answers preserve their newlines; continuation lines are indented four spaces to visually group under the `→` marker:

  ```
  User answered inline via dialog:

  1. [DATABASE] Which database?
     → SQLite — Embedded, zero-config

  2. [NOTES] Any extra requirements?
     → Needs to support:
       pgvector extension,
       horizontal read replicas

  3. [TESTING] Run tests now?
     → Yes
  ```

  Claude reads the reason as tool-denial feedback and proceeds on the user's intent. The existing `deny-with-reason` mechanism is what Bash/Edit already use for the "No, and tell Claude what to do differently" path — no new plumbing.

- **Terminal** → `allow` + open terminal (unchanged behavior, existing `allow_goto_terminal` path).

- **Cancel** (and Esc in option-selection mode) → `deny` with a generic reason such as `"User cancelled the question dialog"`.

## 8. Code Organization

All changes in a single file following the project's single-file convention (`CLAUDE.md` §Architecture Rules).

New section under the existing `// MARK: -` structure, inserted after `// MARK: - Permission Options` and before `// MARK: - Button Layout`:

```
// MARK: - AskUserQuestion Wizard
```

Contents:

1. `struct Question` / `enum Answer` / `final class WizardState` — parsed structures and mutable state.
2. `parseQuestions(from: [String: Any]) -> [Question]` — converts raw JSON to typed structs. Ignores malformed entries; returns empty array if `questions` missing.
3. `buildWizardPanel(state: WizardState) -> NSView` — constructs the question panel view hierarchy.
4. `buildReviewPanel(state: WizardState) -> NSView` — constructs the review panel.
5. `WizardController: NSObject` — event handler for key presses, row clicks, footer button clicks, text-field commits. Owns the panel swap animation between steps.
6. `formatAnswersForClaude(_ state: WizardState) -> String` — produces the `permissionDecisionReason` text.

Integration points:

- `showPermissionDialog(...)` (existing) checks `input.toolName == "AskUserQuestion"` and dispatches to a new `showWizardDialog(input:)` that bypasses `buildPermOptions` + `computeButtonRows` entirely. Other tools keep their existing rendering path.
- `processResult(...)` gains a new case `"submit_wizard"` that packages the wizard state into the response.
- `openTerminalApp(...)` is reused for the Terminal footer button.

Each added function gets a `///` doc comment per project convention. No magic numbers; all dimensions go in `Layout`, all colors in `Theme`.

## 9. Theming Additions

Added to `Theme` (dark palette only):

- `buttonDisabledBg` — 10% white on dark, used for disabled Submit/Next.
- `buttonDisabledBorder` — 12% white on dark.
- `buttonDisabledText` — 45% white.
- `optionRowBg` — 3% white.
- `optionRowBorder` — 8% white.
- `optionRowSelectedBg` — 14% of `buttonAllow`.
- `optionRowSelectedBorder` — 55% of `buttonAllow`.
- `progressDotActive` / `progressDotInactive` — green 100% / 18% white.

Added to `Layout`:

- `wizardOptionRowHeight`, `wizardOptionRowGap`, `wizardOptionRowPadding`.
- `wizardRadioSize`, `wizardRadioInnerDot`.
- `wizardFooterHeight`, `wizardFooterButtonGap`.
- `wizardProgressDotWidth`, `wizardProgressDotHeight`, `wizardProgressDotGap`.
- `wizardOtherMinHeight`, `wizardOtherMaxHeight` — the Other row's text area grows up to this cap, above which it scrolls.

## 10. Testing

### 10.1 Unit tests (`tests/test-approve.swift`)

- `parseQuestions`
  - empty input → `[]`
  - malformed options entries skipped
  - preserves header/question/option ordering
- `WizardState`
  - starts with all answers `nil`
  - selecting a preset sets `.preset(i)`
  - committing an Other string sets `.custom(text)`
  - navigating back and forth preserves `pendingCustom`
  - `allAnswered` flag flips only when all non-nil
- `formatAnswersForClaude`
  - renders exactly one line per question with `[HEADER] question → answer`
  - custom answers render their raw string (newlines preserved)
- Existing `buildGist` / `buildContent` / `buildPermOptions` tests keep passing — the wizard path is separate and does not touch them.

### 10.2 Manual test cases (add to `CLAUDE.md §Testing`)

Extend existing #12 (`AskUserQuestion dialog`) with:

- **12a.** Single question → Submit replaces Next; Return submits. Answer reaches Claude.
- **12b.** Three questions → wizard, review step, Submit. Answers reach Claude in order.
- **12c.** Other row: click → morphs to text area. Type multi-line with Shift+Return. Return submits.
- **12d.** Other text preserved when navigating away and back.
- **12e.** Submit disabled until all answers present; greyed visual and Return no-op when disabled.
- **12f.** Keyboard: ↑/↓ navigate options, ←/→ Back/Next, 1…N jump (not while typing in Other — digits type normally there), Esc exits text-field first then cancels.
- **12g.** Terminal button still works and opens terminal (regression check).

## 11. Migration & Rollout

No migration. Shipping the new behavior replaces the read-only view for `AskUserQuestion` in one release. The hook protocol with Claude Code is unchanged.

Version bump to the next patch after this ships, formula updated per `CLAUDE.md §Releases`.

## 12. Risks & Open Questions

- **Reason-as-feedback semantics.** Claude treats a denied tool's `permissionDecisionReason` as feedback. The submitted-answers path intentionally denies with a structured reason, relying on Claude to parse it as the user's intent. This is the same mechanism the deny-with-text-feedback pattern already uses for Bash/Edit/Write, so the risk is low, but if a future Claude Code version ever treats `AskUserQuestion` denials differently (e.g. refuses to read the reason and retries the tool), we'd revisit.
- **Dialog resize.** The Other row growing to multi-line and the panel swap animation both change the panel's preferred height. Existing dialog is a fixed-size NSPanel; we'll switch its content area to a self-sizing stack that calls `setContentSize` after each resize event. Tested by #12c.
- **Focus stealing.** `nonactivatingPanel` + `canJoinAllSpaces` is already the norm; new text area uses the same first-responder plumbing as the existing deny morph. No new focus model.

## 13. Decisions Log

| Decision | Choice | Why |
|---|---|---|
| Flow | Wizard (one per panel) + review | User preference; keeps panels compact |
| Inner style | Desktop radio cards | User preference; matches other dialog's polish |
| Other placement | Last row, in-place morph | Numbered-row rhythm preserved; reuses deny-morph code |
| Multi-line | Shift+Return inserts newline | Matches Claude Code CLI / Desktop |
| Digit keys while typing | Type into text area | User choice (option b) |
| Arrow keys while typing | Caret only | User choice (don't trigger Back/Next) |
| Answer transport | `deny` + structured reason | Reuses existing feedback mechanism; no protocol change |
