# AskUserQuestion — description wrap + multi-select support

**Date:** 2026-05-16
**Author:** Rajul (with Claude, brainstormed via visual companion)

## Problem

Two issues with the current `AskUserQuestion` wizard in `hooks/claude-approve.swift`:

1. **Description truncation.** Option rows are pinned to `wizardRowHeightMin = 44pt` and the description NSTextField uses `.byTruncatingTail`. Long descriptions are silently cut off with `…`, hiding information the model intended the user to see.

2. **Missing `multiSelect` support.** The schema for `AskUserQuestion` allows `multiSelect: true` on a per-question basis ("Set to true to allow the user to select multiple options instead of just one"). Today the wizard renders every question as single-select (radio), so a multi-select question from Claude is silently downgraded.

## Goals

- Fix description truncation: long descriptions wrap, the row grows to fit, and the panel resizes (same auto-resize mechanism the Other text area already uses when active).
- Support per-question `multiSelect: true`: render a checkbox indicator instead of the radio, allow any subset of options to be ticked, accept a typed Other entry alongside checked presets, and feed the joined result back to the tool.
- Zero change to the existing single-select chrome beyond:
  - Description-wrap behaviour (the bug fix above), which applies to both modes.
  - Capitalisation of the primary button: `"Submit answers"` → `"Submit Answers"`.

## Non-goals

- Per-option `preview` field rendering (schema-optional; not exercised by current Claude flows; out of scope).
- Per-question `annotations` (preview-specific; out of scope).
- Changing the Done dialog, Permission dialog, or any non-wizard surface.

## Decisions (locked during brainstorm)

| # | Topic | Decision |
|---|-------|----------|
| 1 | Description wrap strategy | Full wrap, no line cap. Row grows to fit. |
| 2 | Multi-select indicator | 14×14 rounded-square outline; selected = green fill + black ✓. |
| 3 | Multi-page wizards | `multiSelect` is per question; mixed wizards (e.g. Q1 single, Q2 multi) are supported. Indicator + Submit-suffix update per page. |
| 4 | Multi-select keyboard | Digits `1..N` toggle preset N (focus follows); `N+1` toggles Other (focus follows; activates the text view so the user can immediately type, matching Claude Code CLI's flow); ↑/↓ moves focus only (wraps); Space toggles focused row; ↵ advances; Esc cancels. |
| 5 | Other row chrome | Identical to preset row — same label/desc layout, no border or background change, only the indicator differs. Active state still swaps description for the NSTextView in the same column. |
| 6 | Submit button label | `"Submit Answers"` (capital A) in both modes. Multi-select pages append `" · N Selected"`; single-select pages keep the bare title. |
| 7 | Multi-select submit gate | Require ≥ 1 selection (preset or non-empty Other) before Submit/Next is enabled. |
| 8 | Auto-tick Other on type | First keystroke in the Other text view auto-ticks the Other checkbox. Manually unticking is allowed and excludes the custom text from the submitted set. |
| 9 | Data model | Extend `WizardAnswer` with a new `.multi(presets: Set<Int>, custom: String?)` case. Single-select cases (`.preset`, `.custom`) stay untouched. |

## Design

### Data model (`hooks/claude-approve.swift`, Models section)

```swift
struct WizardQuestion {
    let header: String
    let question: String
    let options: [WizardOption]
    let multiSelect: Bool          // NEW — defaults to false at parse time
}

enum WizardAnswer: Equatable {
    case preset(index: Int)                                  // unchanged
    case custom(text: String)                                // unchanged
    case multi(presets: Set<Int>, custom: String?)           // NEW
}
```

`parseWizardQuestions` reads `multiSelect: Bool` per question (default `false`). Malformed values fall back to `false` — same tolerant pattern as the rest of the parser.

### `WizardState` additions

- `selectPreset` and `commitCustom` are untouched for single-select pages.
- New helpers for multi-select pages:
  - `togglePreset(question: Int, optionIndex: Int)` — flips `optionIndex` in the `.multi.presets` set. Initialises `.multi(presets: [optionIndex], custom: nil)` if the slot was nil.
  - `toggleCustom(question: Int, on: Bool)` — flips Other inclusion. When toggled on, captures the current `pendingCustom[question]` text into `.multi.custom`; when off, sets `.multi.custom = nil`. Empty/whitespace pending text never auto-includes.
  - `setMultiCustomText(question: Int, text: String)` — called on every keystroke; updates both `pendingCustom` (existing) and, if Other is currently ticked, the `.multi.custom` field. On first keystroke of an untouched Other (pending empty, custom nil), auto-ticks (the auto-tick rule).
- `allAnswered` branches on the new case: a `.multi` slot counts as answered iff `presets.count + (custom != nil ? 1 : 0) ≥ 1`.

### Row rendering (`buildWizardOptionRow`)

Currently:
- Fixed row height `wizardRowHeightMin`.
- Description with `.byTruncatingTail`.
- Radio drawn unconditionally on the left.

New:
- Take a `multiSelect: Bool` parameter (or a `selectionStyle` enum if it reads cleaner).
- Description NSTextField becomes wrapping: `usesSingleLineMode = false`, `maximumNumberOfLines = 0`, `lineBreakMode = .byWordWrapping`, `preferredMaxLayoutWidth = textWidth`. Measure its `intrinsicContentSize.height` and grow the row to fit. The label keeps its existing single-line + tail-truncation behaviour (labels are short by spec).
- Indicator is drawn by a new helper, e.g. `drawWizardIndicator(in: NSView, selected: Bool, style: .radio | .checkbox)`:
  - `.radio`: existing filled circle, unchanged.
  - `.checkbox`: 14×14 rounded square (`cornerRadius = 3`), 2pt border. Selected = filled `buttonAllow` green; the ✓ glyph is a `CAShapeLayer` containing a two-segment path (short leg from `(3, 7)` to `(6, 4)`, long leg from `(6, 4)` to `(11, 9)`, in the indicator's local coordinate space), stroked at 2pt with `Theme.background` (the same near-black used for the radio's inner hole), squared line caps, no fill.
- Indicator + index field are re-centred vertically against the row's final height (not against `wizardRowHeightMin`).

### `WizardOtherRow`

- Add `multiSelect: Bool` (init-time).
- In `buildRest()`, swap the radio for the checkbox variant when `multiSelect == true`. All other geometry (sizes, positions, padding) unchanged.
- `refreshHeight()` keeps its existing logic; row growth on typing already works.
- `textDidChange` (multi-select path) calls the new `WizardState.setMultiCustomText`, which triggers the auto-tick rule.
- New `setMultiToggled(_:)` mirrors `setSelected(_:)` — clicking the indicator (or pressing the row's digit) on a multi-select page toggles inclusion without entering/leaving the text view's typing mode. Esc on the active text view deactivates it but does not untick the box.

### Controller (`WizardController`)

- `wireQuestionHandles` adds a separate click handler path for multi-select preset rows: `togglePreset` instead of `selectPreset`. `WizardClickGesture` already carries the `payload` (option index), no new gesture class needed.
- `onPresetClicked` branches on the current question's `multiSelect`.
- Keyboard handler (the local key monitor installed by `installKeyMonitor`) gets a new branch for multi-select pages. Multi-select introduces a tracked "focused row" (option index, defaulting to `0` on first paint; `N` represents the Other row):
  - Digits `1..N` → toggle preset N. Focus moves to row N.
  - Digit `N+1` → toggles Other inclusion via `activateOther(questionIndex:)`. Focus moves to Other. When the Other was not previously ticked, this both ticks the box (after the first keystroke per the auto-tick rule) **and** opens the text view so the user can type immediately. When the Other was already ticked, the digit unticks and deactivates typing. This mirrors the click-on-Other path and matches Claude Code CLI's flow.
  - Space → toggle the focused row.
  - ↑/↓ → move focus only; never mutates selection. Focus wraps (↓ past last → row 0).
  - ↵ Return → advance/submit (gated by the ≥ 1 rule).
  - Esc → cancel wizard.
  - Single-select keyboard paths stay literally the same — no focus model change there.
- `applySelectionFromState` for multi-select pages iterates the `.multi.presets` set and tints every matching row, plus the Other row when `.multi.custom != nil`.
- `recomputePrimaryEnabled` for multi pages computes `count` and always writes the title as `WizardLabels.submit + " · \(count) Selected"` — including when `count == 0`. Showing `Submit Answers · 0 Selected` next to a disabled (greyed) button is the clearest signal to the user that "you need to tick something."

### Labels (`WizardLabels`)

```swift
static let submit          = "Submit Answers"     // capitalised; was "Submit answers"
static let submitMultiTail = " · %d Selected"     // formatted with count
```

`submitMultiTail` is appended on every multi-select page (including `count == 0`); see `recomputePrimaryEnabled` above for the rationale.

### Output (`buildWizardAnswersDict`, `formatWizardAnswers`)

`AskUserQuestion`'s `answers` dictionary is keyed by question text and the value is a single string. For multi-select pages the value is the comma-separated joined labels, with the custom text appended last when present:

```
"Confirm the exclude list" → "Exclude BLEU/ROUGE/METEOR for eval, Absorb RAG-Fusion into multi-query, Also drop CRAG and Self-RAG"
```

`formatWizardAnswers` (the reason text shown back to Claude) lists each selection on its own indented line under the `→` arrow, matching the existing single-select format style. The literal `(custom)` prefix marks the typed Other entry so the model can distinguish it from a preset label that happens to be similar:

```
1. [EXCLUDE LIST] Confirm the exclude list
   → Exclude BLEU/ROUGE/METEOR for eval — Use LLM-as-judge + RAGAS metrics
   → Absorb RAG-Fusion into multi-query — Cover under multi-query expansion
   → (custom) Also drop CRAG and Self-RAG — too brittle for production
```

Zero selections (which the gate disallows but the format must handle defensively) renders `→ (no selection)`.

## Test plan (added to `tests/test-approve.swift`)

Unit tests:
1. `parseWizardQuestions` reads `multiSelect: true` and `multiSelect: false` correctly; missing key defaults to `false`; non-bool value defaults to `false`.
2. `togglePreset` flips set membership; second toggle removes it; preserves other entries.
3. `toggleCustom` on then off clears `.multi.custom`; auto-tick fires on first keystroke when pending was empty.
4. `allAnswered` returns false for `.multi(presets: [], custom: nil)` and true once any inclusion exists.
5. `buildWizardAnswersDict` for `.multi`: presets-only, custom-only, presets+custom variants.
6. `formatWizardAnswers` for `.multi`: matches the multi-line `→` layout above.

Integration test (`tests/test-integration.sh`):
7. Fixture JSON with one single-select + one multi-select question; verify the rendered indicator differs per page, that Submit on the multi page is disabled at count 0 and enabled at count ≥ 1.

Manual test additions (CLAUDE.md test case list extends test case 12):
- **12i.** Single-select with a long description — row grows to fit; nothing truncates.
- **12j.** Multi-select question — checkbox indicator; digit keys toggle; Other auto-ticks on first keystroke; Submit Answers disabled at 0, enabled at ≥1 with `· N Selected` suffix.
- **12k.** Mixed wizard — Q1 single (radio), Q2 multi (checkbox), Q3 single. Indicator + Submit suffix update per page. Back/Next state preserved on navigation.

## Out-of-scope follow-ups (intentionally deferred)

- `preview` per-option side-by-side rendering (would need a major panel layout shift).
- `annotations` capture and feedback (depends on `preview`).
- "Select all" / "Clear all" affordances for multi-select.
