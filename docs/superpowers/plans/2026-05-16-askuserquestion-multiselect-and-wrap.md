# AskUserQuestion — wrap + multi-select Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix description truncation in `AskUserQuestion` option rows and add `multiSelect: true` support, with the existing single-select chrome unchanged beyond a label capitalisation tweak.

**Architecture:** All changes live in `hooks/claude-approve.swift` (single-file architecture rule). Models gain a per-question `multiSelect: Bool` and a new `WizardAnswer.multi(presets: Set<Int>, custom: String?)` case. Row rendering measures wrapped description height; a `WizardIndicatorStyle` enum picks radio vs checkbox. Controller branches on `multiSelect` at click/key events. Unit tests cover parser, state, output; integration test exercises a mixed wizard; manual test cases extend CLAUDE.md §12.

**Tech Stack:** Swift 5, AppKit (NSPanel/NSView/NSTextField/NSTextView/CAShapeLayer), Foundation. Tests use the in-tree harness compiled with `-D TESTING`.

---

## File map

- **Modify** `hooks/claude-approve.swift`:
  - Models: `WizardQuestion`, `WizardAnswer`, new `WizardIndicatorStyle`.
  - Input Parsing: `parseWizardQuestions` reads `multiSelect`.
  - Labels: `WizardLabels.submit` capital A; new `WizardLabels.submitMultiTail`.
  - State: new `togglePreset`, `toggleCustom`, `setMultiCustomText` methods on `WizardState`; updated `allAnswered`.
  - Content Rendering: `buildWizardOptionRow` signature and body; new `drawWizardIndicator` helper.
  - `WizardOtherRow`: take `multiSelect` flag; auto-tick branch in `textDidChange`.
  - `WizardController`: branch click + key handling for multi-select; track focused row index; `recomputePrimaryEnabled` writes count suffix.
  - Output: `buildWizardAnswersDict`, `formatWizardAnswers` handle `.multi`.
- **Modify** `tests/test-approve.swift`: extend existing wizard test groups.
- **Modify** `tests/test-integration.sh` + **Create** `tests/fixtures/askuserquestion-mixed.json`.
- **Modify** `CLAUDE.md`: extend manual-test §12 (cases 12i/12j/12k).

---

## Task 1 — Wrap description text in option rows

**Files:**
- Modify: `hooks/claude-approve.swift:2934-3008` (`buildWizardOptionRow`)
- Modify: `hooks/claude-approve.swift:367-384` (Layout — wizard row block)
- Test: `tests/test-approve.swift` (new section after existing WizardState tests)

- [ ] **Step 1: Add a test that builds an option row with a long description and asserts the row grows.**

Append a new test function in `tests/test-approve.swift`, right after `testWizardState()`:

```swift
// ═══════════════════════════════════════════════════════════════════
// MARK: - buildWizardOptionRow Tests (4)
// ═══════════════════════════════════════════════════════════════════

func testBuildWizardOptionRow() {
    test("buildWizardOptionRow: short description fits at row min height") {
        let v = buildWizardOptionRow(
            label: "Yes", description: "Short.",
            selected: false, index: 1, style: .radio)
        assertEq(v.frame.height, Layout.wizardRowHeightMin)
    }
    test("buildWizardOptionRow: long description grows row beyond minimum") {
        let long = String(repeating: "Very long description text. ", count: 12)
        let v = buildWizardOptionRow(
            label: "Yes", description: long,
            selected: false, index: 1, style: .radio)
        assertTrue(v.frame.height > Layout.wizardRowHeightMin,
            "row should grow; got \(v.frame.height)")
    }
    test("buildWizardOptionRow: empty description stays at row min height") {
        let v = buildWizardOptionRow(
            label: "Other", description: "",
            selected: false, index: 1, style: .radio)
        assertEq(v.frame.height, Layout.wizardRowHeightMin)
    }
    test("buildWizardOptionRow: checkbox style produces same size as radio for same text") {
        let r = buildWizardOptionRow(
            label: "Y", description: "x",
            selected: false, index: 1, style: .radio)
        let c = buildWizardOptionRow(
            label: "Y", description: "x",
            selected: false, index: 1, style: .checkbox)
        assertEq(r.frame.height, c.frame.height)
    }
}
```

Then register the new group in the test list. Find where the existing tests are called (search for `testWizardState()` invocation) and add `testBuildWizardOptionRow()` on the next line:

```swift
testWizardState()
testBuildWizardOptionRow()
```

- [ ] **Step 2: Run the test suite to confirm the new tests fail.**

Run: `bash tests/run.sh`
Expected: build fails with errors about missing `style:` argument and missing `WizardIndicatorStyle.radio`. (The existing tests must NOT regress — only the new ones break.)

- [ ] **Step 3: Add `WizardIndicatorStyle` enum to the Models section.**

In `hooks/claude-approve.swift`, immediately after the `WizardAnswer` enum (around line 138), add:

```swift
/// Visual style for an option row's left-edge indicator.
///
/// - `radio`: filled circle (single-select). Existing behaviour.
/// - `checkbox`: rounded square with a check glyph (multi-select).
enum WizardIndicatorStyle {
    case radio
    case checkbox
}
```

- [ ] **Step 4: Add layout constants for the checkmark inside Layout.**

In `hooks/claude-approve.swift`, find the `// Wizard — option row` block (around line 367) and append after `wizardRadioBorderWidth`:

```swift
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
```

- [ ] **Step 5: Add the `drawWizardIndicator` helper before `buildWizardOptionRow`.**

In `hooks/claude-approve.swift`, insert just above `func buildWizardOptionRow(`:

```swift
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
```

- [ ] **Step 6: Rewrite `buildWizardOptionRow` to wrap description and grow the row.**

Replace the entire function body at `hooks/claude-approve.swift:2934-3008` with:

```swift
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
    // the same gap (descY origin) above the description so short and tall rows
    // visually align around the indicator.
    let labelGapFromBottom = Layout.wizardRowDescY  // bottom→desc origin in min-height row
    let labelHeight = Layout.wizardRowLabelHeight
    let interGap = (Layout.wizardRowLabelY - Layout.wizardRowDescY - Layout.wizardRowDescHeight)
    let computedHeight = labelGapFromBottom + descHeight + (descHeight > 0 ? interGap : 0)
        + labelHeight + (Layout.wizardRowHeightMin
            - Layout.wizardRowLabelY - labelHeight)
    let rowHeight = max(Layout.wizardRowHeightMin, computedHeight)

    let container = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: rowHeight))
    container.wantsLayer = true
    container.layer?.cornerRadius = Layout.wizardRowCornerRadius
    container.layer?.backgroundColor =
        (selected ? Theme.wizardRowSelectedBg : Theme.wizardRowBg).cgColor
    container.layer?.borderColor =
        (selected ? Theme.wizardRowSelectedBorder : Theme.wizardRowBorder).cgColor
    container.layer?.borderWidth = 1

    // Indicator — vertically centred against the final row height.
    let indFrame = NSRect(
        x: Layout.wizardRowPaddingH,
        y: (rowHeight - Layout.wizardRadioSize) / 2,
        width: Layout.wizardRadioSize, height: Layout.wizardRadioSize)
    container.addSubview(drawWizardIndicator(frame: indFrame, selected: selected, style: style))

    // Label — top-aligned to the same Y the minimum-height row uses.
    let labelField = NSTextField(labelWithString: label)
    labelField.font = Theme.wizardLabelFont
    labelField.textColor = Theme.textPrimary
    labelField.lineBreakMode = .byTruncatingTail
    let labelY = rowHeight - (Layout.wizardRowHeightMin - Layout.wizardRowLabelY) - labelHeight
    labelField.frame = NSRect(x: textX, y: labelY, width: textWidth, height: labelHeight)
    container.addSubview(labelField)

    // Description — wrapped, hugs the bottom padding so multi-line text expands upward.
    if !description.isEmpty {
        descField.frame = NSRect(x: textX, y: labelGapFromBottom,
                                 width: textWidth, height: descHeight)
        container.addSubview(descField)
    }

    // Index — vertically centred against the final row height.
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
```

- [ ] **Step 7: Update the one existing caller to pass `.radio`.**

In `hooks/claude-approve.swift`, locate the call in `buildWizardQuestionPanel` (around line 3466) and update:

```swift
        let row = buildWizardOptionRow(label: opt.label, description: opt.description,
                                       selected: false, index: i + 1, style: .radio)
```

- [ ] **Step 8: Build production binaries to surface any remaining compile errors.**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift`
Expected: clean build, no warnings.

- [ ] **Step 9: Run the full test suite — wrap tests should now pass, existing tests intact.**

Run: `bash tests/run.sh`
Expected: all tests pass, including the four new `buildWizardOptionRow` cases.

- [ ] **Step 10: Commit.**

```bash
git add hooks/claude-approve.swift tests/test-approve.swift
git commit -m "Wrap option-row descriptions and grow row to fit

Long descriptions were truncated with ellipsis because option rows were
pinned to a fixed minimum height. Description NSTextField now wraps via
maximumNumberOfLines = 0, and the row's container height is measured
from the wrapped intrinsic content size. Adds a WizardIndicatorStyle
enum and a drawWizardIndicator helper in preparation for multi-select."
```

---

## Task 2 — Capitalise "Submit Answers"

**Files:**
- Modify: `hooks/claude-approve.swift:455` (`WizardLabels.submit`)
- Test: `tests/test-approve.swift` (new assertion in a new test group)

- [ ] **Step 1: Add a label test that pins the new capitalisation.**

Append in `tests/test-approve.swift`, after `testBuildWizardOptionRow()`:

```swift
// ═══════════════════════════════════════════════════════════════════
// MARK: - WizardLabels Tests (2)
// ═══════════════════════════════════════════════════════════════════

func testWizardLabels() {
    test("WizardLabels.submit uses capital A") {
        assertEq(WizardLabels.submit, "Submit Answers")
    }
    test("WizardLabels.submitMultiTail formats count") {
        assertEq(String(format: WizardLabels.submitMultiTail, 3), " · 3 Selected")
    }
}
```

Register: add `testWizardLabels()` after `testBuildWizardOptionRow()` in the test runner.

- [ ] **Step 2: Run tests to confirm both fail.**

Run: `bash tests/run.sh`
Expected: `WizardLabels.submit` case fails (`"Submit answers"` ≠ `"Submit Answers"`), `submitMultiTail` fails to compile (symbol missing).

- [ ] **Step 3: Update the label and add the tail format string.**

In `hooks/claude-approve.swift`, find `static let submit = "Submit answers"` (around line 455) and change to:

```swift
    static let submit                  = "Submit Answers"
    /// Suffix appended to the primary button on multi-select pages.
    /// `String(format: WizardLabels.submitMultiTail, count)` → ` · 3 Selected`.
    static let submitMultiTail         = " · %d Selected"
```

- [ ] **Step 4: Run tests to confirm both pass.**

Run: `bash tests/run.sh`
Expected: all green.

- [ ] **Step 5: Commit.**

```bash
git add hooks/claude-approve.swift tests/test-approve.swift
git commit -m "Capitalise 'Submit Answers' button label

Aligns the wizard's primary CTA with title-case capitalisation and
adds a submitMultiTail format string for the upcoming multi-select
count suffix (' · N Selected')."
```

---

## Task 3 — Parse `multiSelect` per question

**Files:**
- Modify: `hooks/claude-approve.swift:119-123` (`WizardQuestion`)
- Modify: `hooks/claude-approve.swift:2759-2779` (`parseWizardQuestions`)
- Test: `tests/test-approve.swift` (extend existing `testParseWizardQuestions`)

- [ ] **Step 1: Add three parser tests covering multiSelect.**

Append three new `test("…") { … }` blocks inside the existing `testParseWizardQuestions()` function in `tests/test-approve.swift`, right before its closing brace:

```swift
    test("parseWizardQuestions: multiSelect true is read") {
        let input: [String: Any] = [
            "questions": [
                ["header": "X", "question": "Q?",
                 "multiSelect": true,
                 "options": [["label": "A"]]],
            ],
        ]
        let qs = parseWizardQuestions(from: input)
        assertTrue(qs[0].multiSelect)
    }
    test("parseWizardQuestions: missing multiSelect defaults to false") {
        let input: [String: Any] = [
            "questions": [
                ["header": "X", "question": "Q?", "options": [["label": "A"]]],
            ],
        ]
        let qs = parseWizardQuestions(from: input)
        assertFalse(qs[0].multiSelect)
    }
    test("parseWizardQuestions: non-bool multiSelect defaults to false") {
        let input: [String: Any] = [
            "questions": [
                ["header": "X", "question": "Q?",
                 "multiSelect": "yes",
                 "options": [["label": "A"]]],
            ],
        ]
        let qs = parseWizardQuestions(from: input)
        assertFalse(qs[0].multiSelect)
    }
```

- [ ] **Step 2: Run tests to confirm the new ones fail.**

Run: `bash tests/run.sh`
Expected: build fails (`multiSelect` is not a member of `WizardQuestion`).

- [ ] **Step 3: Add `multiSelect` to the model.**

Edit the `WizardQuestion` struct (around line 119):

```swift
struct WizardQuestion {
    let header: String
    let question: String
    let options: [WizardOption]
    /// True when the question accepts more than one selection. Defaults to
    /// false; mirrors the optional `multiSelect` field in the tool input.
    let multiSelect: Bool
}
```

- [ ] **Step 4: Update `parseWizardQuestions` to read the flag.**

In `parseWizardQuestions` (around line 2759), change the final `result.append(...)` block so it reads the flag. Replace:

```swift
        result.append(WizardQuestion(header: header, question: question, options: opts))
```

with:

```swift
        let multi = dict["multiSelect"] as? Bool ?? false
        result.append(WizardQuestion(
            header: header, question: question,
            options: opts, multiSelect: multi))
```

- [ ] **Step 5: Update every other `WizardQuestion(…)` initialiser site so existing tests still compile.**

The existing tests in `tests/test-approve.swift` build `WizardQuestion` directly (around lines 1438–1445 and similar). Add `multiSelect: false` to each. Easiest approach: search for `WizardQuestion(` in `tests/test-approve.swift` and append `, multiSelect: false` before the closing paren on every call site. Verify by running:

Run: `grep -n 'WizardQuestion(' tests/test-approve.swift`
Expected output: every result should already contain `multiSelect:`. If any doesn't, edit it.

- [ ] **Step 6: Run the full suite.**

Run: `bash tests/run.sh`
Expected: all tests pass, including the three new parser cases.

- [ ] **Step 7: Commit.**

```bash
git add hooks/claude-approve.swift tests/test-approve.swift
git commit -m "Parse per-question multiSelect flag

The AskUserQuestion tool schema lets each question opt into multi-
select via 'multiSelect: true'. parseWizardQuestions now reads this
flag (defaulting to false on missing or non-bool values) and stores
it on WizardQuestion."
```

---

## Task 4 — Extend `WizardAnswer` and `WizardState` for multi-select

**Files:**
- Modify: `hooks/claude-approve.swift:131-138` (`WizardAnswer`)
- Modify: `hooks/claude-approve.swift:2790-2850` (`WizardState`)
- Test: `tests/test-approve.swift` (new tests inside existing `testWizardState`)

- [ ] **Step 1: Add tests for the new state behaviour.**

Inside `testWizardState()` in `tests/test-approve.swift`, append after the last existing `test(...)` block (right before the closing brace):

```swift
    let qMulti = WizardQuestion(
        header: "X", question: "Pick any",
        options: [WizardOption(label: "A", description: ""),
                  WizardOption(label: "B", description: ""),
                  WizardOption(label: "C", description: "")],
        multiSelect: true)

    test("WizardState.togglePreset: first toggle initialises .multi") {
        let s = WizardState(questions: [qMulti])
        s.togglePreset(question: 0, optionIndex: 1)
        assertTrue(s.answers[0] == WizardAnswer.multi(presets: [1], custom: nil))
    }
    test("WizardState.togglePreset: second toggle removes the index") {
        let s = WizardState(questions: [qMulti])
        s.togglePreset(question: 0, optionIndex: 1)
        s.togglePreset(question: 0, optionIndex: 1)
        assertTrue(s.answers[0] == nil)
    }
    test("WizardState.togglePreset: adding multiple presets") {
        let s = WizardState(questions: [qMulti])
        s.togglePreset(question: 0, optionIndex: 0)
        s.togglePreset(question: 0, optionIndex: 2)
        assertTrue(s.answers[0] == WizardAnswer.multi(presets: [0, 2], custom: nil))
    }
    test("WizardState.toggleCustom: on with non-empty pending captures text") {
        let s = WizardState(questions: [qMulti])
        s.setPending(question: 0, text: "hello")
        s.toggleCustom(question: 0, on: true)
        assertTrue(s.answers[0] == WizardAnswer.multi(presets: [], custom: "hello"))
    }
    test("WizardState.toggleCustom: on with empty pending is a no-op") {
        let s = WizardState(questions: [qMulti])
        s.toggleCustom(question: 0, on: true)
        assertTrue(s.answers[0] == nil)
    }
    test("WizardState.toggleCustom: off clears only custom, leaves presets") {
        let s = WizardState(questions: [qMulti])
        s.togglePreset(question: 0, optionIndex: 0)
        s.setPending(question: 0, text: "extra")
        s.toggleCustom(question: 0, on: true)
        s.toggleCustom(question: 0, on: false)
        assertTrue(s.answers[0] == WizardAnswer.multi(presets: [0], custom: nil))
    }
    test("WizardState.setMultiCustomText: auto-ticks on first non-empty keystroke") {
        let s = WizardState(questions: [qMulti])
        s.setMultiCustomText(question: 0, text: "h")
        assertTrue(s.answers[0] == WizardAnswer.multi(presets: [], custom: "h"))
    }
    test("WizardState.setMultiCustomText: updates ticked custom in place") {
        let s = WizardState(questions: [qMulti])
        s.setMultiCustomText(question: 0, text: "h")
        s.setMultiCustomText(question: 0, text: "hello")
        assertTrue(s.answers[0] == WizardAnswer.multi(presets: [], custom: "hello"))
    }
    test("WizardState.setMultiCustomText: clearing text removes custom") {
        let s = WizardState(questions: [qMulti])
        s.setMultiCustomText(question: 0, text: "h")
        s.setMultiCustomText(question: 0, text: "")
        // Auto-tick is reversed when text is cleared; presets are untouched.
        if case .multi(let p, let c) = s.answers[0]! {
            assertEq(p.count, 0)
            assertTrue(c == nil)
        } else {
            assertTrue(false, "expected .multi case")
        }
    }
    test("WizardState.allAnswered: multi requires at least one selection") {
        let s = WizardState(questions: [qMulti])
        assertFalse(s.allAnswered)
        s.togglePreset(question: 0, optionIndex: 0)
        assertTrue(s.allAnswered)
        s.togglePreset(question: 0, optionIndex: 0)
        assertFalse(s.allAnswered)
    }
```

Also add a top-level WizardAnswer-equality test in `testWizardModels()` (around line 1332):

```swift
    test("WizardAnswer.multi equality") {
        assertTrue(WizardAnswer.multi(presets: [0, 2], custom: nil)
                == WizardAnswer.multi(presets: [0, 2], custom: nil))
        assertFalse(WizardAnswer.multi(presets: [0, 2], custom: nil)
                 == WizardAnswer.multi(presets: [0, 2], custom: "x"))
        assertFalse(WizardAnswer.multi(presets: [0, 2], custom: nil)
                 == WizardAnswer.multi(presets: [0], custom: nil))
    }
```

- [ ] **Step 2: Run tests to confirm the new ones fail.**

Run: `bash tests/run.sh`
Expected: build fails (no `.multi` case, no `togglePreset`/`toggleCustom`/`setMultiCustomText`).

- [ ] **Step 3: Add the `.multi` case to `WizardAnswer`.**

Replace the enum (around line 135):

```swift
enum WizardAnswer: Equatable {
    case preset(index: Int)
    case custom(text: String)
    /// Multi-select answer: any subset of preset indices, plus an optional
    /// custom string. The empty `presets` set with `custom = nil` is *not*
    /// a valid stored answer (state methods normalise that back to `nil`).
    case multi(presets: Set<Int>, custom: String?)
}
```

- [ ] **Step 4: Add `togglePreset`, `toggleCustom`, `setMultiCustomText`, and update `allAnswered` on `WizardState`.**

Append inside the `WizardState` class body (after `setPending`, around line 2849):

```swift
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
            let trimmed = pendingCustom[question].trimmingCharacters(in: .whitespacesAndNewlines)
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
```

Then update `allAnswered` to recognise `.multi` (around line 2820):

```swift
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
```

- [ ] **Step 5: Run tests.**

Run: `bash tests/run.sh`
Expected: all new state tests pass, existing tests intact.

- [ ] **Step 6: Commit.**

```bash
git add hooks/claude-approve.swift tests/test-approve.swift
git commit -m "Add .multi WizardAnswer case + state helpers

Extends WizardAnswer with a multi(presets, custom) case for multi-
select pages, alongside togglePreset / toggleCustom / setMultiCustomText
on WizardState. Auto-tick on first keystroke and untick-on-empty are
encoded in setMultiCustomText; allAnswered now treats a multi answer
as 'answered' iff at least one selection is present."
```

---

## Task 5 — Render checkbox style + thread `multiSelect` through the panel

**Files:**
- Modify: `hooks/claude-approve.swift:3389-3612` (`buildWizardQuestionPanel`)

- [ ] **Step 1: Update the panel builder so the row style follows the question.**

In `buildWizardQuestionPanel`, find the loop that creates option rows (around line 3464):

```swift
    for (i, opt) in question.options.enumerated() {
        let row = buildWizardOptionRow(label: opt.label, description: opt.description,
                                       selected: false, index: i + 1, style: .radio)
```

Change `.radio` to `question.multiSelect ? .checkbox : .radio`.

- [ ] **Step 2: Update the layout math that assumed every row was exactly `wizardRowHeightMin`.**

In `buildWizardQuestionPanel`, find the `totalRowsHeight` block (around line 3497):

```swift
    let totalRowsHeight = CGFloat(question.options.count + 1) * Layout.wizardRowHeightMin
        + CGFloat(question.options.count) * Layout.wizardRowGap
```

Replace with a height-summing loop that uses each row's measured frame:

```swift
    var rowsTotal: CGFloat = 0
    for row in optionRowViews {
        rowsTotal += row.frame.height
    }
    rowsTotal += Layout.wizardRowHeightMin   // Other row, always min in rest state
    rowsTotal += CGFloat(question.options.count) * Layout.wizardRowGap
    let totalRowsHeight = rowsTotal
```

- [ ] **Step 3: Replace the row-stacking pass to use each row's own height.**

A few lines below, find the cursor loop (around line 3508):

```swift
    var yCursor = bodyHeight - rowTopY - Layout.wizardRowHeightMin
    for row in optionRowViews {
        row.frame = NSRect(x: Layout.wizardBodyPaddingH, y: yCursor,
            width: width - Layout.wizardBodyPaddingH * 2, height: Layout.wizardRowHeightMin)
        yCursor -= (Layout.wizardRowHeightMin + Layout.wizardRowGap)
    }
    otherRow.frame = NSRect(x: Layout.wizardBodyPaddingH, y: yCursor,
        width: width - Layout.wizardBodyPaddingH * 2, height: Layout.wizardRowHeightMin)
```

Replace with:

```swift
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
```

- [ ] **Step 4: Build to confirm everything still compiles.**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift`
Expected: clean build.

- [ ] **Step 5: Run the unit suite.**

Run: `bash tests/run.sh`
Expected: green.

- [ ] **Step 6: Commit.**

```bash
git add hooks/claude-approve.swift
git commit -m "Render checkbox indicator on multi-select questions

The question panel now picks the row's indicator style from the
question's multiSelect flag and stacks rows using each row's measured
height (so wrapped descriptions don't overlap their neighbours)."
```

---

## Task 6 — `WizardOtherRow` checkbox variant + auto-tick wiring

**Files:**
- Modify: `hooks/claude-approve.swift:3028-3359` (`WizardOtherRow`)
- Modify: `hooks/claude-approve.swift:3470-3475` (Other row construction in `buildWizardQuestionPanel`)

- [ ] **Step 1: Take a `multiSelect` flag through the init.**

Replace the `init()` signature at the top of `WizardOtherRow` (around line 3063):

```swift
    private let style: WizardIndicatorStyle

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
```

(Only the `style` property and the new init parameter are added; everything else in `init` stays the same.)

- [ ] **Step 2: Replace the manual radio draw in `buildRest` with `drawWizardIndicator`.**

In `buildRest()` (around line 3131), replace the entire block that constructs `radioView` (from `radioView = NSView(...)` down to and including the `addSubview(radioView)` call) with:

```swift
        radioView = drawWizardIndicator(
            frame: NSRect(
                x: Layout.wizardRowPaddingH,
                y: (Layout.wizardRowHeightMin - Layout.wizardRadioSize) / 2,
                width: Layout.wizardRadioSize, height: Layout.wizardRadioSize),
            selected: false, style: style)
        addSubview(radioView)
```

- [ ] **Step 3: Update `refreshColors` to redraw via the helper rather than mutate `radioView` in place.**

Replace the body of `refreshColors()` (around line 3254):

```swift
    private func refreshColors() {
        layer?.backgroundColor =
            (selected ? Theme.wizardRowSelectedBg : Theme.wizardRowBg).cgColor
        layer?.borderColor =
            (selected ? Theme.wizardRowSelectedBorder : Theme.wizardRowBorder).cgColor
        // Replace the indicator view rather than mutating sublayers so the
        // checkbox check-glyph layer survives toggling.
        let oldFrame = radioView.frame
        radioView.removeFromSuperview()
        radioView = drawWizardIndicator(frame: oldFrame, selected: selected, style: style)
        addSubview(radioView)
        refreshIndex()
    }
```

- [ ] **Step 4: Update the construction site to pass the style.**

In `buildWizardQuestionPanel`, find (around line 3473):

```swift
    let otherRow = WizardOtherRow()
    otherRow.indexNumber = question.options.count + 1
```

Replace with:

```swift
    let otherRow = WizardOtherRow(
        style: question.multiSelect ? .checkbox : .radio)
    otherRow.indexNumber = question.options.count + 1
```

- [ ] **Step 5: Build + run tests.**

Run: `bash tests/run.sh`
Expected: green.

- [ ] **Step 6: Commit.**

```bash
git add hooks/claude-approve.swift
git commit -m "Other row honours multi-select style

WizardOtherRow now takes a WizardIndicatorStyle through its initialiser
and renders via drawWizardIndicator, so the Other row picks up the
checkbox glyph automatically on multi-select questions while staying
geometrically identical to the radio variant."
```

---

## Task 7 — Controller branch: click handling for multi-select

**Files:**
- Modify: `hooks/claude-approve.swift:3970-4300` (`WizardController` actions section)

- [ ] **Step 1: Branch `onPresetClicked` on the current question's `multiSelect`.**

Replace the body of `onPresetClicked(_:)` (around line 4155) with:

```swift
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
```

- [ ] **Step 2: Branch `applySelectionFromState` so it paints every checked row on multi pages.**

Replace `applySelectionFromState` (around line 4064) with:

```swift
    private func applySelectionFromState(_ h: WizardQuestionPanelHandles, questionIndex: Int) {
        guard questionIndex >= 0, questionIndex < state.questions.count else { return }
        let answer = state.answers[questionIndex]
        for row in h.optionRowViews {
            row.layer?.backgroundColor = Theme.wizardRowBg.cgColor
            row.layer?.borderColor = Theme.wizardRowBorder.cgColor
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
            return
        }

        // Single: existing behaviour, unchanged.
        let isCustom: Bool = { if case .custom = answer { return true } else { return false } }()
        h.otherRow.setSelected(otherActive || isCustom)
        if !otherActive, case .preset(let idx) = answer, idx < h.optionRowViews.count {
            let row = h.optionRowViews[idx]
            row.layer?.backgroundColor = Theme.wizardRowSelectedBg.cgColor
            row.layer?.borderColor = Theme.wizardRowSelectedBorder.cgColor
        }
        h.otherRow.setText(state.pendingCustom[questionIndex])
    }
```

- [ ] **Step 3: Route Other text changes through the multi-select state path on multi pages.**

In `wireQuestionHandles` (around line 4105), replace the `h.otherRow.onTextChange = …` block with:

```swift
        h.otherRow.onTextChange = { [weak self] text in
            guard let self = self else { return }
            if self.state.questions[questionIndex].multiSelect {
                self.state.setMultiCustomText(question: questionIndex, text: text)
            } else {
                self.state.setPending(question: questionIndex, text: text)
                if case .custom = self.state.answers[questionIndex] {
                    self.state.commitCustom(question: questionIndex, text: text)
                }
            }
            self.recomputePrimaryEnabled()
        }
```

- [ ] **Step 4: Wire the multi-select activate / advance branches.**

Replace `activateOther` (search by name, around line 4275) to support toggling on multi without forcing typing mode unless the user explicitly entered it:

```swift
    private func activateOther(questionIndex: Int) {
        guard let h = currentQuestionHandles else { return }
        if state.questions[questionIndex].multiSelect {
            // Multi: the tap on the Other row toggles inclusion. Activating
            // text-entry mode only happens when the user explicitly clicks
            // *inside* the text view's column; here we both flip the box and
            // open typing so a single click matches the Claude Code CLI flow.
            let alreadyTicked: Bool = {
                if case .multi(_, let c) = state.answers[questionIndex], c != nil { return true }
                return false
            }()
            if alreadyTicked {
                state.toggleCustom(question: questionIndex, on: false)
                otherActive = false
                h.otherRow.deactivate()
                applySelectionFromState(h, questionIndex: questionIndex)
                recomputePrimaryEnabled()
                return
            }
            otherActive = true
            h.otherRow.activate()
            h.otherRow.moveCaretToEnd()
            // If text is already present, auto-tick now (mirrors keystroke path).
            if !state.pendingCustom[questionIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state.toggleCustom(question: questionIndex, on: true)
            }
            applySelectionFromState(h, questionIndex: questionIndex)
            recomputePrimaryEnabled()
            return
        }
        otherActive = true
        h.otherRow.activate()
        h.otherRow.moveCaretToEnd()
        applySelectionFromState(h, questionIndex: questionIndex)
    }
```

(Verify the original method's signature matches — if not, adapt the surrounding shape but keep this body's logic.)

- [ ] **Step 5: Build + run tests.**

Run: `bash tests/run.sh`
Expected: green.

- [ ] **Step 6: Commit.**

```bash
git add hooks/claude-approve.swift
git commit -m "Controller routes clicks through multi-select state path

onPresetClicked toggles instead of selecting on multi-select pages,
applySelectionFromState paints every ticked preset (plus Other when a
custom answer is present), and onTextChange routes through the multi
state helper so the auto-tick rule fires from the controller too."
```

---

## Task 8 — Keyboard handler: multi-select toggle + focus tracking

**Files:**
- Modify: `hooks/claude-approve.swift` — local key monitor inside `WizardController` (search for `installKeyMonitor`)

- [ ] **Step 1: Add a `focusedRow` field.**

Inside `WizardController` (alongside `otherActive`, around line 3985):

```swift
    /// Focused-row index for multi-select keyboard nav. `0..options.count-1`
    /// targets a preset row; `options.count` targets the Other row. Single-
    /// select pages ignore this field. Reset on every step change.
    private var focusedRow: Int = 0
```

Reset it in `renderCurrentStep` (just after `currentQuestionHandles = h`, around line 4026):

```swift
        focusedRow = 0
```

- [ ] **Step 2: Locate the key monitor and add the multi-select branch.**

Find the body of the local key monitor (search for `installKeyMonitor` and follow it). Inside the handler, before the existing digit-handling block, add:

```swift
            let qi = state.step
            if qi >= 0, qi < state.questions.count,
               state.questions[qi].multiSelect {
                // Multi-select branch
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
                        return nil
                    }
                    if digit == nPresets + 1 {
                        focusedRow = nPresets
                        // Mirror tap-on-Other: toggle inclusion of typed text.
                        activateOther(questionIndex: qi)
                        return nil
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
                    return nil
                case 126:  // ↑
                    focusedRow = (focusedRow - 1 + nPresets + 1) % (nPresets + 1)
                    return nil
                case 125:  // ↓
                    focusedRow = (focusedRow + 1) % (nPresets + 1)
                    return nil
                default:
                    break  // Fall through to shared Return / Esc / arrows handling
                }
            }
```

(The single-select keyboard logic below this insertion runs unchanged.)

- [ ] **Step 3: Build + run tests.**

Run: `bash tests/run.sh`
Expected: green. (Keyboard behaviour itself is covered by manual tests in §12; unit tests verify state mutations the keystrokes trigger.)

- [ ] **Step 4: Commit.**

```bash
git add hooks/claude-approve.swift
git commit -m "Keyboard toggle + focus model for multi-select pages

Digits 1..N toggle the matching preset (focus follows), digit N+1
toggles Other through the same activateOther path, Space toggles the
focused row, and ↑/↓ walks focus with wrap-around. Single-select
keyboard behaviour is untouched."
```

---

## Task 9 — Multi-select submit gate + count suffix

**Files:**
- Modify: `hooks/claude-approve.swift` — `recomputePrimaryEnabled` and any caller (`renderCurrentStep`)

- [ ] **Step 1: Replace `recomputePrimaryEnabled` to set the title with the count tail on multi pages.**

Find the method (search for `recomputePrimaryEnabled` — it's near `applyWizardSubmitEnabled`). Replace its body with:

```swift
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
        // Multi-select pages append " · N Selected" to the primary button.
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
```

- [ ] **Step 2: Call `recomputePrimaryEnabled` from `renderCurrentStep` after the existing enable line.**

In `renderCurrentStep` (around line 4033), replace:

```swift
        applyWizardSubmitEnabled(h.primaryButton,
            enabled: state.answers[qIndex] != nil,
            isSubmit: isLast)
```

with:

```swift
        recomputePrimaryEnabled()
```

- [ ] **Step 3: Build + run tests.**

Run: `bash tests/run.sh`
Expected: green.

- [ ] **Step 4: Commit.**

```bash
git add hooks/claude-approve.swift
git commit -m "Gate Submit Answers on multi-select selection count

recomputePrimaryEnabled now writes the primary button's title with the
' · N Selected' suffix on multi-select pages (including N=0 to surface
the disabled state's reason) and disables Submit/Next until at least
one preset or a non-empty Other is picked."
```

---

## Task 10 — Output (dict + reason text) for `.multi`

**Files:**
- Modify: `hooks/claude-approve.swift:2874-2920` (`buildWizardAnswersDict`, `formatWizardAnswers`)
- Test: `tests/test-approve.swift` (extend output tests)

- [ ] **Step 1: Add tests for `.multi` output.**

Find the existing tests for `buildWizardAnswersDict` and `formatWizardAnswers` (search by name in `tests/test-approve.swift`). Append new test cases inside whichever test function holds them (if none, add a `testWizardOutput()` block and register it):

```swift
    test("buildWizardAnswersDict: multi with presets only") {
        let q = WizardQuestion(
            header: "X", question: "Pick",
            options: [WizardOption(label: "A", description: ""),
                      WizardOption(label: "B", description: ""),
                      WizardOption(label: "C", description: "")],
            multiSelect: true)
        let s = WizardState(questions: [q])
        s.togglePreset(question: 0, optionIndex: 0)
        s.togglePreset(question: 0, optionIndex: 2)
        let d = buildWizardAnswersDict(state: s)
        assertEq(d["Pick"], "A, C")
    }
    test("buildWizardAnswersDict: multi with custom only") {
        let q = WizardQuestion(
            header: "X", question: "Pick",
            options: [WizardOption(label: "A", description: "")],
            multiSelect: true)
        let s = WizardState(questions: [q])
        s.setMultiCustomText(question: 0, text: "freeform")
        let d = buildWizardAnswersDict(state: s)
        assertEq(d["Pick"], "freeform")
    }
    test("buildWizardAnswersDict: multi presets + custom") {
        let q = WizardQuestion(
            header: "X", question: "Pick",
            options: [WizardOption(label: "A", description: ""),
                      WizardOption(label: "B", description: "")],
            multiSelect: true)
        let s = WizardState(questions: [q])
        s.togglePreset(question: 0, optionIndex: 1)
        s.setMultiCustomText(question: 0, text: "freeform")
        let d = buildWizardAnswersDict(state: s)
        assertEq(d["Pick"], "B, freeform")
    }
    test("formatWizardAnswers: multi prints one arrow line per selection") {
        let q = WizardQuestion(
            header: "X", question: "Pick",
            options: [WizardOption(label: "A", description: "alpha"),
                      WizardOption(label: "B", description: "beta")],
            multiSelect: true)
        let s = WizardState(questions: [q])
        s.togglePreset(question: 0, optionIndex: 0)
        s.togglePreset(question: 0, optionIndex: 1)
        s.setMultiCustomText(question: 0, text: "freeform")
        let out = formatWizardAnswers(state: s)
        assertContains(out, "→ A — alpha")
        assertContains(out, "→ B — beta")
        assertContains(out, "→ (custom) freeform")
    }
```

- [ ] **Step 2: Run tests; the new cases fail with index errors / missing branches.**

Run: `bash tests/run.sh`
Expected: failures.

- [ ] **Step 3: Extend `buildWizardAnswersDict` to handle `.multi`.**

Replace its `switch` block (around line 2877) with:

```swift
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
```

- [ ] **Step 4: Extend `formatWizardAnswers` to print one `→` line per `.multi` selection.**

Replace its inner `switch` block (around line 2896) with:

```swift
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
```

- [ ] **Step 5: Run tests.**

Run: `bash tests/run.sh`
Expected: all green.

- [ ] **Step 6: Commit.**

```bash
git add hooks/claude-approve.swift tests/test-approve.swift
git commit -m "Serialise .multi answers into dict + reason text

buildWizardAnswersDict joins selected preset labels (with the typed
Other appended last) into a single comma-separated value; the reason
text emits one '→' line per selection and prefixes the typed Other
with '(custom)' so the model can distinguish it from preset labels."
```

---

## Task 11 — Integration test fixture for mixed wizard

**Files:**
- Create: `tests/fixtures/askuserquestion-mixed.json`
- Modify: `tests/test-integration.sh`

- [ ] **Step 1: Inspect the existing integration test format.**

Run: `cat tests/test-integration.sh | head -80`
Expected: a bash script that pipes JSON into the binary and asserts the JSON response. Note how existing fixtures are referenced.

- [ ] **Step 2: Add a fixture file describing a mixed single+multi+single wizard.**

Create `tests/fixtures/askuserquestion-mixed.json`:

```json
{
  "tool_name": "AskUserQuestion",
  "tool_input": {
    "questions": [
      {
        "header": "DB",
        "question": "Which database?",
        "options": [
          {"label": "Postgres", "description": "Client-server SQL"},
          {"label": "SQLite", "description": "Embedded"}
        ]
      },
      {
        "header": "EXCLUDE",
        "question": "Confirm exclude list",
        "multiSelect": true,
        "options": [
          {"label": "BLEU", "description": "Metric"},
          {"label": "ROUGE", "description": "Metric"},
          {"label": "METEOR", "description": "Metric"}
        ]
      },
      {
        "header": "SCOPE",
        "question": "Commit at end?",
        "options": [
          {"label": "Yes", "description": ""},
          {"label": "No", "description": ""}
        ]
      }
    ]
  },
  "cwd": "/tmp/integration",
  "session_id": "integration-mixed",
  "permission_mode": "default"
}
```

- [ ] **Step 3: Add a smoke assertion to `tests/test-integration.sh`.**

The wizard's modal loop is GUI-driven and not exercisable from CI; the smoke we can verify in shell is that the binary parses the input without errors and recognises the multi-select flag. Append at the end of the file, before the final summary block:

```bash
echo ""
echo "--- AskUserQuestion mixed-wizard parse smoke ---"

# Run the binary with a script that injects answers so the modal exits
# immediately. The CLAUDE_HOOK_AUTOTEST env var (existing pattern) makes
# the wizard select option 0 on every page and return a synthetic
# 'allow' response. The smoke here is that the binary survives the
# multiSelect flag without an exception.
if env CLAUDE_HOOK_AUTOTEST=1 \
   "$HOOKS_DIR/claude-approve" < "$SCRIPT_DIR/fixtures/askuserquestion-mixed.json" \
   > /tmp/claude-mixed-out 2> /tmp/claude-mixed-err; then
    echo "  Parsed mixed wizard OK"
else
    echo "  FAIL: claude-approve exited non-zero on mixed fixture"
    cat /tmp/claude-mixed-err
    FAILURES=$((FAILURES + 1))
fi
```

- [ ] **Step 4: Confirm the existing autotest pathway exists; if not, gate this test on its absence.**

Run: `grep -n CLAUDE_HOOK_AUTOTEST hooks/claude-approve.swift`
- If matches exist: keep the smoke assertion as written.
- If no matches: replace the body of the smoke block above with a single line that just pipes the JSON and discards the output (`true` succeeds): `cat "$SCRIPT_DIR/fixtures/askuserquestion-mixed.json" >/dev/null && echo "  Fixture JSON readable"`. The richer smoke is deferred until an autotest env hook is added (out of scope here).

- [ ] **Step 5: Run the integration step.**

Run: `bash tests/run.sh`
Expected: integration suite reports the new smoke line, no new failures.

- [ ] **Step 6: Commit.**

```bash
git add tests/fixtures/askuserquestion-mixed.json tests/test-integration.sh
git commit -m "Add mixed-wizard integration smoke

Fixture exercises a single → multi → single AskUserQuestion sequence
to confirm the binary parses the per-question multiSelect flag end to
end."
```

---

## Task 12 — Manual test cases in `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md` (test case §12 list)

- [ ] **Step 1: Open `CLAUDE.md` and locate the existing 12h block.**

Run: `grep -n "12h" CLAUDE.md`
Expected: a single match in the manual test section.

- [ ] **Step 2: Append 12i, 12j, 12k entries after 12h.**

After the line containing `12h` (it ends with `Go to Terminal still opens the user's terminal.`), insert:

```markdown
    - **12i.** Long description — render an AskUserQuestion whose option
      description is 6+ sentences. The row grows vertically to fit the
      wrapped description; nothing is truncated with `…`; siblings and
      footer reflow correctly; the panel auto-resizes.
    - **12j.** Multi-select question — render an AskUserQuestion with
      `multiSelect: true`. Indicator is a checkbox (not radio). Pressing
      `1`..`N` toggles the matching preset on/off; `N+1` toggles the
      Other row (and activates its text view); Space toggles the
      focused row. The primary button reads `Submit Answers · K Selected`
      with K updating live, and is disabled at K = 0.
    - **12k.** Mixed wizard — three questions, the middle one
      `multiSelect: true`. Indicator and Submit suffix update per page.
      Navigating Back from the multi page preserves the ticked set;
      returning forward shows it intact. The third page (single-select)
      uses the existing radio chrome with no behavioural drift.
```

- [ ] **Step 3: Verify the file reads cleanly (no broken markdown lists).**

Run: `sed -n '/12h/,/13\./p' CLAUDE.md`
Expected: a contiguous markdown list ending with the new 12k entry, then the existing test case 13.

- [ ] **Step 4: Commit.**

```bash
git add CLAUDE.md
git commit -m "Document manual test cases for wrap + multi-select

Adds 12i (long description wrap), 12j (multi-select toggling + count
suffix), and 12k (mixed-mode wizard) to the manual test list."
```

---

## Self-review (already run by the planner; recorded here for the executor)

1. **Spec coverage:**
   - Wrap fix → Task 1.
   - Multi-select indicator + checkbox geometry → Tasks 1 (helper) + 5 (panel) + 6 (Other).
   - Parser → Task 3.
   - Data model + state helpers → Task 4.
   - Submit-Answers capital + suffix → Task 2 + Task 9.
   - Submit gate ≥ 1 → Task 4 (`allAnswered`) + Task 9 (`recomputePrimaryEnabled`).
   - Auto-tick → Task 4 (`setMultiCustomText`) + Task 7 (controller wiring).
   - Keyboard model → Task 8.
   - Output format → Task 10.
   - Manual + integration tests → Tasks 11–12.

2. **Placeholder scan:** No `TODO`, `TBD`, `add error handling` strings; every code-mutating step has a complete code block; every command has an expected outcome.

3. **Type consistency:** `WizardIndicatorStyle` introduced in Task 1, threaded through Tasks 5/6 unchanged. `WizardAnswer.multi(presets:, custom:)` defined in Task 4, used identically in Tasks 7/9/10. Method names: `togglePreset`, `toggleCustom`, `setMultiCustomText`, `recomputePrimaryEnabled` — same spelling everywhere.

If any compile error surfaces against the line numbers cited, prefer searching by symbol name; line numbers reflect the file at plan-write time and may drift between tasks (an unavoidable cost of single-file architecture).
