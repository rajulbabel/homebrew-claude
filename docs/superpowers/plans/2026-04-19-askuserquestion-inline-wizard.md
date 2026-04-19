# AskUserQuestion Inline-Answer Wizard — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the read-only `AskUserQuestion` dialog with a wizard that lets the user answer preset options or type a free-text "Other" answer inline, with multi-question support, a review step, and full keyboard navigation — while keeping the existing "Go to Terminal" and "Cancel" escape hatches.

**Architecture:** All changes in the single-file hook `hooks/claude-approve.swift`. Pure-logic pieces (types, state machine, text formatter) get unit tests in `tests/test-approve.swift`. UI pieces (panel views, morphing text area, panel swap animation) get added to the source as a new `// MARK: - AskUserQuestion Wizard` section and are verified by the manual test checklist in `CLAUDE.md`. The wizard replaces only the `AskUserQuestion` rendering path; every other tool keeps its existing dialog unchanged.

**Tech Stack:** Swift 5, AppKit (`NSPanel`, `NSView`, `NSButton`, `NSTextView` in an `NSScrollView`, `NSStackView`, `NSAnimationContext`), no external dependencies. Compiled with `swiftc -O -parse-as-library -framework AppKit`. Tests compiled with `-D TESTING`.

---

## Reference: Spec

Full spec: `docs/superpowers/specs/2026-04-19-askuserquestion-inline-wizard-design.md`. Keep it open — it defines the visual design, keyboard model, and decisions log referenced here.

## Reference: Orientation

- **Main hook source:** `hooks/claude-approve.swift` (~2579 lines, single file per `CLAUDE.md §Architecture Rules`).
- **Section structure** (`// MARK: -` comments): Models → Theme → Layout → Input Parsing → Session Management → Hook Response Output → Gist Generation → Syntax Highlighting → Diff Engine → Content Rendering → Permission Options → Button Layout → Content Measurement → Focus Management → Dialog Construction → Result Processing → Main Entry Point. New wizard code goes in a new section after `// MARK: - Focus Management` (line 1239) and before `// MARK: - Dialog Construction` (line 2298).
- **Test harness:** `tests/harness.swift` (`test(name:body:)`, `assertEq`, `assertTrue`, `assertContains`). Test registration happens in `ApproveTests.main()` at the bottom of `tests/test-approve.swift`.
- **Build command (production):** `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift`
- **Build + run test suite:** `bash tests/run.sh`

## Working convention

- TDD for every testable pure function: write failing test, watch it fail, implement minimal code, watch it pass, commit.
- For view/UI code where unit tests don't add value (AppKit hierarchies), write code, recompile with the production build command, add the item to the manual test checklist, and commit.
- Commit after every task (last step of each task).
- Follow existing code conventions: `///` doc comments on every new public/internal function, named constants in `Theme` / `Layout` (no magic numbers), imperative commit messages, no `Co-Authored-By` trailers (`CLAUDE.md §Commit Conventions`).

---

## Task 1: Add Question / Answer data types

**Files:**
- Modify: `hooks/claude-approve.swift` — insert after `struct PermOption { … }` ends (currently line 111).
- Test: `tests/test-approve.swift` — add `testWizardTypes()` function and register it in `ApproveTests.main()`.

- [ ] **Step 1.1: Write the failing test**

Add this block to `tests/test-approve.swift` just above `MARK: - Main Entry Point` (currently ~line 1305). Immediately after the closing brace of the previous test function.

```swift
// ═══════════════════════════════════════════════════════════════════
// MARK: - Wizard Types Tests (4)
// ═══════════════════════════════════════════════════════════════════

func testWizardTypes() {
    test("WizardQuestion: fields populated") {
        let q = WizardQuestion(
            header: "DB",
            question: "Which database?",
            options: [
                WizardOption(label: "Postgres", description: "SQL"),
                WizardOption(label: "SQLite",   description: "Embedded"),
            ]
        )
        assertEq(q.header, "DB")
        assertEq(q.question, "Which database?")
        assertEq(q.options.count, 2)
        assertEq(q.options[0].label, "Postgres")
        assertEq(q.options[1].description, "Embedded")
    }
    test("WizardOption: empty description allowed") {
        let opt = WizardOption(label: "Yes", description: "")
        assertEq(opt.label, "Yes")
        assertEq(opt.description, "")
    }
    test("WizardAnswer.preset equality") {
        assertTrue(WizardAnswer.preset(index: 1) == WizardAnswer.preset(index: 1))
        assertFalse(WizardAnswer.preset(index: 1) == WizardAnswer.preset(index: 2))
    }
    test("WizardAnswer.custom equality") {
        assertTrue(WizardAnswer.custom(text: "hello") == WizardAnswer.custom(text: "hello"))
        assertFalse(WizardAnswer.custom(text: "hello") == WizardAnswer.custom(text: "world"))
        assertFalse(WizardAnswer.custom(text: "x") == WizardAnswer.preset(index: 0))
    }
}
```

Then register it: find the `ApproveTests.main()` function body (currently ~line 1313) and add `testWizardTypes()` as the **first** call inside `main()` (before `testBuildGist()`).

- [ ] **Step 1.2: Run tests to verify failure**

Run: `bash tests/run.sh`
Expected: build failure (`use of unresolved identifier 'WizardQuestion'`). That proves the test is wired up and the types don't exist yet.

- [ ] **Step 1.3: Add the types in claude-approve.swift**

Insert this block in `hooks/claude-approve.swift` **immediately after** the closing `}` of `struct PermOption` (currently line 111). Keep it inside the Models section — the next `// MARK: -` line should remain `// MARK: - Theme`.

```swift
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
}
```

- [ ] **Step 1.4: Run tests to verify pass**

Run: `bash tests/run.sh`
Expected: `All N tests passed` (N is the new total, including the 4 wizard-type tests).

- [ ] **Step 1.5: Commit**

```bash
git add hooks/claude-approve.swift tests/test-approve.swift
git commit -m "Add WizardQuestion/WizardOption/WizardAnswer types"
```

---

## Task 2: `parseWizardQuestions` — convert tool input JSON into `[WizardQuestion]`

**Files:**
- Modify: `hooks/claude-approve.swift` — new function in a new `// MARK: - AskUserQuestion Wizard` section, inserted between `// MARK: - Focus Management` (currently line 1239) and `// MARK: - Dialog Construction` (currently line 2298). From now on, all new wizard functions go in this section.
- Test: `tests/test-approve.swift` — add `testParseWizardQuestions()`.

- [ ] **Step 2.1: Write the failing test**

Add this block to `tests/test-approve.swift` just below `testWizardTypes()`:

```swift
func testParseWizardQuestions() {
    test("parseWizardQuestions: missing key → empty array") {
        assertEq(parseWizardQuestions(from: [:]).count, 0)
    }
    test("parseWizardQuestions: empty array → empty array") {
        assertEq(parseWizardQuestions(from: ["questions": [[String: Any]]()]).count, 0)
    }
    test("parseWizardQuestions: valid single question") {
        let input: [String: Any] = [
            "questions": [
                [
                    "header": "DB",
                    "question": "Which database?",
                    "options": [
                        ["label": "Postgres", "description": "SQL"],
                        ["label": "SQLite",   "description": "Embedded"],
                    ],
                ],
            ],
        ]
        let qs = parseWizardQuestions(from: input)
        assertEq(qs.count, 1)
        assertEq(qs[0].header, "DB")
        assertEq(qs[0].question, "Which database?")
        assertEq(qs[0].options.count, 2)
        assertEq(qs[0].options[0].label, "Postgres")
        assertEq(qs[0].options[1].description, "Embedded")
    }
    test("parseWizardQuestions: missing option description defaults to empty") {
        let input: [String: Any] = [
            "questions": [
                ["header": "X", "question": "Q?", "options": [["label": "A"]]],
            ],
        ]
        let qs = parseWizardQuestions(from: input)
        assertEq(qs.count, 1)
        assertEq(qs[0].options[0].label, "A")
        assertEq(qs[0].options[0].description, "")
    }
    test("parseWizardQuestions: malformed option entry skipped") {
        let input: [String: Any] = [
            "questions": [
                [
                    "header": "X",
                    "question": "Q?",
                    "options": [
                        ["label": "A", "description": "a-desc"],
                        "not-a-dict",
                        ["description": "no-label"],
                        ["label": "B", "description": "b-desc"],
                    ],
                ],
            ],
        ]
        let qs = parseWizardQuestions(from: input)
        assertEq(qs[0].options.count, 2)
        assertEq(qs[0].options[0].label, "A")
        assertEq(qs[0].options[1].label, "B")
    }
    test("parseWizardQuestions: preserves question order") {
        let input: [String: Any] = [
            "questions": [
                ["header": "A", "question": "Q1", "options": [["label": "x"]]],
                ["header": "B", "question": "Q2", "options": [["label": "y"]]],
                ["header": "C", "question": "Q3", "options": [["label": "z"]]],
            ],
        ]
        let qs = parseWizardQuestions(from: input)
        assertEq(qs.count, 3)
        assertEq(qs[0].header, "A")
        assertEq(qs[1].header, "B")
        assertEq(qs[2].header, "C")
    }
    test("parseWizardQuestions: malformed question entry skipped") {
        let input: [String: Any] = [
            "questions": [
                "not-a-dict",
                ["header": "X", "question": "Q?", "options": [["label": "A"]]],
            ],
        ]
        let qs = parseWizardQuestions(from: input)
        assertEq(qs.count, 1)
        assertEq(qs[0].header, "X")
    }
}
```

Register it in `ApproveTests.main()` right after `testWizardTypes()`.

- [ ] **Step 2.2: Run tests to verify failure**

Run: `bash tests/run.sh`
Expected: build failure (`use of unresolved identifier 'parseWizardQuestions'`).

- [ ] **Step 2.3: Add the new MARK section and the function**

Insert this at line 1239 of `hooks/claude-approve.swift` (i.e. **before** the existing `// MARK: - Dialog Construction` marker — find the blank line just above it). Keep this section's header in this exact form so it matches the project's convention.

```swift
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
        result.append(WizardQuestion(header: header, question: question, options: opts))
    }
    return result
}
```

- [ ] **Step 2.4: Run tests to verify pass**

Run: `bash tests/run.sh`
Expected: all tests pass.

- [ ] **Step 2.5: Commit**

```bash
git add hooks/claude-approve.swift tests/test-approve.swift
git commit -m "Add parseWizardQuestions"
```

---

## Task 3: `WizardState` state machine

**Files:**
- Modify: `hooks/claude-approve.swift` — add class to the new wizard section.
- Test: `tests/test-approve.swift` — add `testWizardState()`.

`WizardState` owns the mutable state of a wizard run. It is driven by `WizardController` (Task 10), but its transitions are pure-logic and therefore unit-testable on their own.

- [ ] **Step 3.1: Write the failing test**

Add this block to `tests/test-approve.swift` below `testParseWizardQuestions()`:

```swift
func testWizardState() {
    let q1 = WizardQuestion(
        header: "DB", question: "Which database?",
        options: [WizardOption(label: "PG", description: ""),
                  WizardOption(label: "SQLite", description: "")])
    let q2 = WizardQuestion(
        header: "ENV", question: "Prod?",
        options: [WizardOption(label: "Yes", description: ""),
                  WizardOption(label: "No", description: "")])

    test("WizardState: starts unanswered") {
        let s = WizardState(questions: [q1, q2])
        assertEq(s.answers.count, 2)
        assertTrue(s.answers[0] == nil)
        assertTrue(s.answers[1] == nil)
        assertFalse(s.allAnswered)
        assertEq(s.step, 0)
    }
    test("WizardState: selectPreset commits preset answer") {
        let s = WizardState(questions: [q1])
        s.selectPreset(question: 0, optionIndex: 1)
        assertTrue(s.answers[0] == WizardAnswer.preset(index: 1))
        assertTrue(s.allAnswered)
    }
    test("WizardState: commitCustom commits custom answer when non-empty") {
        let s = WizardState(questions: [q1])
        s.commitCustom(question: 0, text: "my_db")
        assertTrue(s.answers[0] == WizardAnswer.custom(text: "my_db"))
    }
    test("WizardState: commitCustom with empty string clears answer") {
        let s = WizardState(questions: [q1])
        s.selectPreset(question: 0, optionIndex: 0)
        s.commitCustom(question: 0, text: "")
        assertTrue(s.answers[0] == nil)
    }
    test("WizardState: pendingCustom persists across navigation") {
        let s = WizardState(questions: [q1, q2])
        s.setPending(question: 0, text: "my_graph_db")
        s.step = 1
        s.step = 0
        assertEq(s.pendingCustom[0], "my_graph_db")
    }
    test("WizardState: selectPreset does NOT clear pendingCustom") {
        let s = WizardState(questions: [q1])
        s.setPending(question: 0, text: "typed")
        s.selectPreset(question: 0, optionIndex: 0)
        assertEq(s.pendingCustom[0], "typed")
        assertTrue(s.answers[0] == WizardAnswer.preset(index: 0))
    }
    test("WizardState: allAnswered true only when every question answered") {
        let s = WizardState(questions: [q1, q2])
        s.selectPreset(question: 0, optionIndex: 0)
        assertFalse(s.allAnswered)
        s.commitCustom(question: 1, text: "y")
        assertTrue(s.allAnswered)
    }
    test("WizardState: isReviewStep only when step == questions.count AND count > 1") {
        let s1 = WizardState(questions: [q1])
        s1.step = 0
        assertFalse(s1.isReviewStep)
        let s2 = WizardState(questions: [q1, q2])
        s2.step = 2
        assertTrue(s2.isReviewStep)
    }
    test("WizardState: lastStep index depends on question count") {
        assertEq(WizardState(questions: [q1]).lastStep, 0)
        assertEq(WizardState(questions: [q1, q2]).lastStep, 2)
    }
}
```

Register in `main()` below `testParseWizardQuestions()`.

- [ ] **Step 3.2: Run tests to verify failure**

Run: `bash tests/run.sh`
Expected: build failure (`WizardState` undefined).

- [ ] **Step 3.3: Add `WizardState` in the wizard section**

Append to the `// MARK: - AskUserQuestion Wizard` section (below `parseWizardQuestions`):

```swift
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
    let questions: [WizardQuestion]
    var answers: [WizardAnswer?]
    var pendingCustom: [String]
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
        answers.allSatisfy { $0 != nil }
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
}
```

- [ ] **Step 3.4: Run tests to verify pass**

Run: `bash tests/run.sh`
Expected: all tests pass.

- [ ] **Step 3.5: Commit**

```bash
git add hooks/claude-approve.swift tests/test-approve.swift
git commit -m "Add WizardState with preset/custom/pending transitions"
```

---

## Task 4: `formatWizardAnswers` — build the `permissionDecisionReason` string

**Files:**
- Modify: `hooks/claude-approve.swift` — append to wizard section.
- Test: `tests/test-approve.swift` — add `testFormatWizardAnswers()`.

- [ ] **Step 4.1: Write the failing test**

Append to `tests/test-approve.swift` below `testWizardState()`:

```swift
func testFormatWizardAnswers() {
    let q1 = WizardQuestion(
        header: "DB", question: "Which database?",
        options: [WizardOption(label: "Postgres", description: "SQL"),
                  WizardOption(label: "SQLite", description: "Embedded")])
    let q2 = WizardQuestion(
        header: "TEST", question: "Run tests?",
        options: [WizardOption(label: "Yes", description: ""),
                  WizardOption(label: "No", description: "")])

    test("formatWizardAnswers: single preset") {
        let s = WizardState(questions: [q1])
        s.selectPreset(question: 0, optionIndex: 1)
        let out = formatWizardAnswers(state: s)
        assertContains(out, "User answered inline via dialog:")
        assertContains(out, "1. [DB] Which database?")
        assertContains(out, "→ SQLite")
        assertContains(out, "Embedded")
    }
    test("formatWizardAnswers: custom answer") {
        let s = WizardState(questions: [q1])
        s.commitCustom(question: 0, text: "my_graph_db")
        let out = formatWizardAnswers(state: s)
        assertContains(out, "→ my_graph_db")
    }
    test("formatWizardAnswers: multi-line custom preserves newlines with indent") {
        let s = WizardState(questions: [q1])
        s.commitCustom(question: 0, text: "line one\nline two\nline three")
        let out = formatWizardAnswers(state: s)
        assertContains(out, "→ line one")
        // continuation lines should be indented 4 spaces to visually group under →
        assertContains(out, "    line two")
        assertContains(out, "    line three")
    }
    test("formatWizardAnswers: multiple questions numbered sequentially") {
        let s = WizardState(questions: [q1, q2])
        s.selectPreset(question: 0, optionIndex: 0)
        s.selectPreset(question: 1, optionIndex: 0)
        let out = formatWizardAnswers(state: s)
        assertContains(out, "1. [DB]")
        assertContains(out, "2. [TEST]")
        assertContains(out, "Postgres")
        assertContains(out, "Yes")
    }
    test("formatWizardAnswers: unanswered question rendered as (no answer)") {
        let s = WizardState(questions: [q1, q2])
        s.selectPreset(question: 0, optionIndex: 0)
        let out = formatWizardAnswers(state: s)
        assertContains(out, "2. [TEST]")
        assertContains(out, "→ (no answer)")
    }
}
```

Register in `main()`.

- [ ] **Step 4.2: Run tests to verify failure**

Run: `bash tests/run.sh`
Expected: build failure (`formatWizardAnswers` undefined).

- [ ] **Step 4.3: Implement the formatter**

Append to the wizard section of `hooks/claude-approve.swift`:

```swift
/// Builds the `permissionDecisionReason` string that Claude reads as feedback
/// when the user submits answers via the wizard.
///
/// Layout (one block per question, separated by a blank line):
/// ```
///   1. [HEADER] Question text?
///      → answer line (option label — description, OR custom text)
/// ```
/// Multi-line custom answers preserve their newlines; continuation lines are
/// indented four spaces so they line up under the `→` marker.
///
/// Unanswered questions render `→ (no answer)` — should not normally occur
/// because Submit is disabled until all answers are present, but the safety
/// branch keeps the output unambiguous if a submission ever happens anyway.
func formatWizardAnswers(state: WizardState) -> String {
    var lines: [String] = ["User answered inline via dialog:", ""]
    for (i, q) in state.questions.enumerated() {
        let headerPart = q.header.isEmpty ? "" : "[\(q.header)] "
        lines.append("\(i + 1). \(headerPart)\(q.question)")
        switch state.answers[i] {
        case .preset(let idx):
            let opt = q.options[idx]
            let suffix = opt.description.isEmpty ? "" : " — \(opt.description)"
            lines.append("   → \(opt.label)\(suffix)")
        case .custom(let text):
            let parts = text.components(separatedBy: "\n")
            lines.append("   → \(parts[0])")
            for cont in parts.dropFirst() {
                lines.append("     \(cont)")
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
```

- [ ] **Step 4.4: Run tests to verify pass**

Run: `bash tests/run.sh`
Expected: all tests pass.

- [ ] **Step 4.5: Commit**

```bash
git add hooks/claude-approve.swift tests/test-approve.swift
git commit -m "Add formatWizardAnswers reason builder"
```

---

## Task 5: Theme + Layout constants for the wizard

**Files:**
- Modify: `hooks/claude-approve.swift` — append inside the `Theme` enum (before its closing brace, currently line 193) and inside the `Layout` enum (before its closing brace, currently line 280).

No tests — these are just constants. Compilation verifies the names resolve.

- [ ] **Step 5.1: Add Theme constants**

Find the closing `}` of `enum Theme` (line 193 at time of writing). Immediately **above** that closing brace — after the existing `static func tagColor(for:)` — append:

```swift
    // Wizard — disabled button state
    static let wizardButtonDisabledBg      = NSColor(calibratedWhite: 1.0, alpha: 0.10)
    static let wizardButtonDisabledBorder  = NSColor(calibratedWhite: 1.0, alpha: 0.12)
    static let wizardButtonDisabledText    = NSColor(calibratedWhite: 0.45, alpha: 1.0)

    // Wizard — option row
    static let wizardRowBg                 = NSColor(calibratedWhite: 1.0, alpha: 0.03)
    static let wizardRowBorder             = NSColor(calibratedWhite: 1.0, alpha: 0.08)
    static let wizardRowSelectedBg         = NSColor(calibratedRed: 0.18, green: 0.80, blue: 0.44, alpha: 0.14)
    static let wizardRowSelectedBorder     = NSColor(calibratedRed: 0.18, green: 0.80, blue: 0.44, alpha: 0.55)
    static let wizardRadioInnerGap         = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)

    // Wizard — progress dots
    static let wizardProgressActive        = NSColor(calibratedRed: 0.18, green: 0.80, blue: 0.44, alpha: 1.0)
    static let wizardProgressInactive      = NSColor(calibratedWhite: 1.0, alpha: 0.18)

    // Wizard — typography
    static let wizardQuestionFont          = NSFont.systemFont(ofSize: 13.5, weight: .medium)
    static let wizardLabelFont             = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let wizardDescFont              = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let wizardOtherTextFont         = NSFont.systemFont(ofSize: 12, weight: .semibold)
```

- [ ] **Step 5.2: Add Layout constants**

Find the closing `}` of `enum Layout` (line 280). Immediately **above** the `static let fixedChrome: …` line (which is the last entry), append:

```swift
    // Wizard — panel regions
    static let wizardHeaderHeight: CGFloat = 34
    static let wizardFooterHeight: CGFloat = 56
    static let wizardBodyPaddingH: CGFloat = 14
    static let wizardBodyPaddingV: CGFloat = 16
    static let wizardBodyBottomPadding: CGFloat = 14

    // Wizard — option row
    static let wizardRowHeightMin: CGFloat = 44
    static let wizardRowGap: CGFloat = 6
    static let wizardRowPaddingH: CGFloat = 12
    static let wizardRowPaddingV: CGFloat = 10
    static let wizardRowCornerRadius: CGFloat = 8
    static let wizardRadioSize: CGFloat = 14
    static let wizardRadioInnerRing: CGFloat = 2.5
    static let wizardRadioGap: CGFloat = 10

    // Wizard — progress dots
    static let wizardProgressDotWidth: CGFloat = 22
    static let wizardProgressDotHeight: CGFloat = 3
    static let wizardProgressDotGap: CGFloat = 6
    static let wizardProgressTopPadding: CGFloat = 18

    // Wizard — footer
    static let wizardFooterGap: CGFloat = 8
    static let wizardFooterButtonHeight: CGFloat = 36
    static let wizardFooterSideButtonWidth: CGFloat = 82

    // Wizard — Other row text area
    static let wizardOtherMinHeight: CGFloat = 20
    static let wizardOtherMaxHeight: CGFloat = 140
    static let wizardOtherCaretWidth: CGFloat = 1.5
    static let wizardOtherCaretHeight: CGFloat = 12
```

- [ ] **Step 5.3: Recompile**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift`
Expected: success, no errors.

Also run the test suite to confirm nothing is broken:
Run: `bash tests/run.sh`
Expected: all tests pass.

- [ ] **Step 5.4: Commit**

```bash
git add hooks/claude-approve.swift
git commit -m "Add Theme/Layout constants for wizard"
```

---

## Task 6: `buildWizardOptionRow` — a single radio-card row view

**Files:**
- Modify: `hooks/claude-approve.swift` — append to the wizard section.

No unit tests — AppKit view construction. Verified by the manual Qa test in Task 12.

- [ ] **Step 6.1: Add the function**

Append to the wizard section:

```swift
/// Builds a single radio-card row view used in the question panel.
///
/// The row is a horizontal layout: radio circle (14×14), then a vertical
/// stack holding the bolded label on top and a secondary-colored description
/// below. The whole row is center-aligned vertically so the radio sits midway
/// between the two text lines.
///
/// - Parameters:
///   - label: Bold label text (e.g. `"SQLite"` or `"Other"`).
///   - description: Secondary description text under the label. Empty hides the line.
///   - selected: If true, radio is filled and the row uses selected colors.
///   - index: 1-based display index shown on the right; pass 0 to hide.
/// - Returns: A configured `NSView` sized to the panel width × wizardRowHeightMin.
func buildWizardOptionRow(label: String, description: String, selected: Bool, index: Int) -> NSView {
    let container = NSView(frame: NSRect(x: 0, y: 0,
        width: Layout.panelWidth - Layout.wizardBodyPaddingH * 2,
        height: Layout.wizardRowHeightMin))
    container.wantsLayer = true
    container.layer?.cornerRadius = Layout.wizardRowCornerRadius
    container.layer?.backgroundColor = (selected ? Theme.wizardRowSelectedBg : Theme.wizardRowBg).cgColor
    container.layer?.borderColor = (selected ? Theme.wizardRowSelectedBorder : Theme.wizardRowBorder).cgColor
    container.layer?.borderWidth = 1

    // Radio
    let radio = NSView(frame: NSRect(
        x: Layout.wizardRowPaddingH,
        y: (Layout.wizardRowHeightMin - Layout.wizardRadioSize) / 2,
        width: Layout.wizardRadioSize,
        height: Layout.wizardRadioSize))
    radio.wantsLayer = true
    radio.layer?.cornerRadius = Layout.wizardRadioSize / 2
    radio.layer?.borderWidth = 2
    if selected {
        radio.layer?.borderColor = Theme.buttonAllow.cgColor
        radio.layer?.backgroundColor = Theme.buttonAllow.cgColor
        // Inner ring hole
        let ring = NSView(frame: NSRect(
            x: Layout.wizardRadioInnerRing,
            y: Layout.wizardRadioInnerRing,
            width: Layout.wizardRadioSize - Layout.wizardRadioInnerRing * 2,
            height: Layout.wizardRadioSize - Layout.wizardRadioInnerRing * 2))
        ring.wantsLayer = true
        ring.layer?.backgroundColor = Theme.wizardRadioInnerGap.cgColor
        ring.layer?.cornerRadius = (Layout.wizardRadioSize - Layout.wizardRadioInnerRing * 2) / 2
        radio.addSubview(ring)
    } else {
        radio.layer?.borderColor = Theme.textSecondary.withAlphaComponent(0.55).cgColor
        radio.layer?.backgroundColor = NSColor.clear.cgColor
    }
    container.addSubview(radio)

    // Text stack (label + description)
    let textX = Layout.wizardRowPaddingH + Layout.wizardRadioSize + Layout.wizardRadioGap
    let indexLabelWidth: CGFloat = 16
    let textWidth = container.frame.width - textX - Layout.wizardRowPaddingH - indexLabelWidth

    let labelField = NSTextField(labelWithString: label)
    labelField.font = Theme.wizardLabelFont
    labelField.textColor = Theme.textPrimary
    labelField.frame = NSRect(x: textX, y: 21, width: textWidth, height: 16)
    container.addSubview(labelField)

    if !description.isEmpty {
        let descField = NSTextField(labelWithString: description)
        descField.font = Theme.wizardDescFont
        descField.textColor = Theme.textSecondary
        descField.frame = NSRect(x: textX, y: 5, width: textWidth, height: 14)
        container.addSubview(descField)
    }

    // Index number on the right
    if index > 0 {
        let idxField = NSTextField(labelWithString: "\(index)")
        idxField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        idxField.textColor = selected ? Theme.buttonAllow : Theme.textSecondary.withAlphaComponent(0.55)
        idxField.alignment = .right
        idxField.frame = NSRect(
            x: container.frame.width - Layout.wizardRowPaddingH - indexLabelWidth,
            y: (Layout.wizardRowHeightMin - 14) / 2,
            width: indexLabelWidth, height: 14)
        container.addSubview(idxField)
    }

    return container
}
```

- [ ] **Step 6.2: Recompile and run tests**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift && cd ..`
Run: `bash tests/run.sh`
Expected: both succeed.

- [ ] **Step 6.3: Commit**

```bash
git add hooks/claude-approve.swift
git commit -m "Add buildWizardOptionRow view builder"
```

---

## Task 7: `WizardOtherRow` — the "Other" row with multi-line text input

**Files:**
- Modify: `hooks/claude-approve.swift` — append to the wizard section.

This is the trickiest view. It encapsulates:
- A rest state visually identical to a preset row (radio + "Other" label).
- An active state where the label area becomes a multi-line `NSTextView` inside an `NSScrollView`, auto-growing up to `wizardOtherMaxHeight`.
- `Return` submits (via controller callback), `Shift+Return` inserts a newline, `Esc` exits active state.

We wrap it in a class so the controller can push/pull focus and get the current text out.

- [ ] **Step 7.1: Add the class**

Append to the wizard section:

```swift
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
/// The row calls back to the controller via three closures:
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

    /// Bound number shown on the right (1-based); 0 hides.
    var indexNumber: Int = 0

    /// Is this row the currently selected option in its question?
    private(set) var selected: Bool = false

    /// Is the text view currently accepting input?
    private(set) var isActive: Bool = false

    private let scrollView: NSScrollView
    private let textView: NSTextView
    private var labelField: NSTextField!
    private var descField: NSTextField!
    private var radioView: NSView!

    /// Current string contents of the text view.
    var currentText: String { textView.string }

    init() {
        let container = NSTextContainer(size: NSSize(width: 0, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)

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
        refreshHeight()
    }

    // MARK: Subview construction

    private func buildRest() {
        // Radio
        radioView = NSView(frame: NSRect(
            x: Layout.wizardRowPaddingH,
            y: (Layout.wizardRowHeightMin - Layout.wizardRadioSize) / 2,
            width: Layout.wizardRadioSize,
            height: Layout.wizardRadioSize))
        radioView.wantsLayer = true
        radioView.layer?.cornerRadius = Layout.wizardRadioSize / 2
        radioView.layer?.borderWidth = 2
        addSubview(radioView)

        let textX = Layout.wizardRowPaddingH + Layout.wizardRadioSize + Layout.wizardRadioGap
        let indexLabelWidth: CGFloat = 16
        let textWidth = frame.width - textX - Layout.wizardRowPaddingH - indexLabelWidth

        labelField = NSTextField(labelWithString: "Other")
        labelField.font = Theme.wizardLabelFont
        labelField.textColor = Theme.textPrimary
        labelField.frame = NSRect(x: textX, y: 21, width: textWidth, height: 16)
        addSubview(labelField)

        descField = NSTextField(labelWithString: "Type your own answer")
        descField.font = Theme.wizardDescFont
        descField.textColor = Theme.textSecondary
        descField.frame = NSRect(x: textX, y: 5, width: textWidth, height: 14)
        addSubview(descField)

        refreshColors()

        // Whole-row click → activate
        let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked))
        addGestureRecognizer(click)
    }

    private func buildTextView() {
        let textX = Layout.wizardRowPaddingH + Layout.wizardRadioSize + Layout.wizardRadioGap
        let indexLabelWidth: CGFloat = 16
        let textWidth = frame.width - textX - Layout.wizardRowPaddingH - indexLabelWidth

        scrollView.frame = NSRect(x: textX, y: 4, width: textWidth, height: Layout.wizardOtherMinHeight)
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

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
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        addSubview(scrollView)
    }

    @objc private func rowClicked() {
        onActivate()
    }

    private func updateVisibility() {
        labelField.isHidden = isActive
        descField.stringValue = isActive ? "Type your own answer" : "Type your own answer"
        scrollView.isHidden = !isActive
        refreshHeight()
    }

    private func refreshColors() {
        layer?.backgroundColor = (selected ? Theme.wizardRowSelectedBg : Theme.wizardRowBg).cgColor
        layer?.borderColor = (selected ? Theme.wizardRowSelectedBorder : Theme.wizardRowBorder).cgColor
        if selected {
            radioView.layer?.borderColor = Theme.buttonAllow.cgColor
            radioView.layer?.backgroundColor = Theme.buttonAllow.cgColor
            radioView.subviews.forEach { $0.removeFromSuperview() }
            let ring = NSView(frame: NSRect(
                x: Layout.wizardRadioInnerRing, y: Layout.wizardRadioInnerRing,
                width: Layout.wizardRadioSize - Layout.wizardRadioInnerRing * 2,
                height: Layout.wizardRadioSize - Layout.wizardRadioInnerRing * 2))
            ring.wantsLayer = true
            ring.layer?.backgroundColor = Theme.wizardRadioInnerGap.cgColor
            ring.layer?.cornerRadius = ring.frame.width / 2
            radioView.addSubview(ring)
        } else {
            radioView.layer?.borderColor = Theme.textSecondary.withAlphaComponent(0.55).cgColor
            radioView.layer?.backgroundColor = NSColor.clear.cgColor
            radioView.subviews.forEach { $0.removeFromSuperview() }
        }
    }

    /// Recalculates row height based on text content when active.
    /// Caps at `wizardOtherMaxHeight`; scroll view starts scrolling beyond that.
    private func refreshHeight() {
        guard isActive else {
            setFrameSize(NSSize(width: frame.width, height: Layout.wizardRowHeightMin))
            return
        }
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
        let contentHeight = max(Layout.wizardOtherMinHeight, ceil(used.height) + 4)
        let capped = min(contentHeight, Layout.wizardOtherMaxHeight)
        let rowHeight = max(Layout.wizardRowHeightMin,
            capped + (Layout.wizardRowHeightMin - Layout.wizardOtherMinHeight))
        setFrameSize(NSSize(width: frame.width, height: rowHeight))

        // Re-center radio; shift scroll view frame
        radioView.frame.origin.y = (rowHeight - Layout.wizardRadioSize) / 2
        let textX = Layout.wizardRowPaddingH + Layout.wizardRadioSize + Layout.wizardRadioGap
        let indexLabelWidth: CGFloat = 16
        let textWidth = frame.width - textX - Layout.wizardRowPaddingH - indexLabelWidth
        scrollView.frame = NSRect(x: textX, y: 4, width: textWidth, height: capped)
        scrollView.hasVerticalScroller = (contentHeight > Layout.wizardOtherMaxHeight)
        // Description sits below text, center-align logic only in rest mode;
        // in active mode we hide descField in updateVisibility() via isHidden check.
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        onTextChange(textView.string)
        refreshHeight()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Return → submit. Shift+Return sends insertNewlineIgnoringFieldEditor
            // or insertLineBreak, both of which we let through to default behavior
            // (they insert a newline via the text storage).
            onSubmit()
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
```

- [ ] **Step 7.2: Recompile**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift && cd ..`
Expected: success.

Then test suite:
Run: `bash tests/run.sh`
Expected: all tests pass.

- [ ] **Step 7.3: Commit**

```bash
git add hooks/claude-approve.swift
git commit -m "Add WizardOtherRow with multi-line NSTextView morph"
```

---

## Task 8: `buildWizardQuestionPanel` — full question panel

**Files:**
- Modify: `hooks/claude-approve.swift` — append to the wizard section.

Composes: header band + body (tag pill + question + option rows + Other row + progress dots) + footer (buttons). Button actions get wired by the controller in Task 10; this function just builds the view tree and exposes handles via a small struct.

- [ ] **Step 8.1: Add a panel struct + builder**

Append to the wizard section:

```swift
/// Handles into a freshly built question panel so the controller can hook
/// event targets and later update selected state and Submit-enabled.
struct WizardQuestionPanelHandles {
    let root: NSView
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
///   - isLastStep: True if Return / → should say "Submit ⏎" instead of "Next →".
/// - Returns: Handles to the root and every interactive view.
func buildWizardQuestionPanel(
    question: WizardQuestion,
    stepIndex: Int,
    totalSteps: Int,
    isLastStep: Bool
) -> WizardQuestionPanelHandles {
    let width = Layout.panelWidth
    let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
    root.wantsLayer = true

    // --- Header band ---
    let header = NSView(frame: NSRect(x: 0, y: 0, width: width, height: Layout.wizardHeaderHeight))
    header.wantsLayer = true
    header.layer?.backgroundColor = Theme.background.cgColor

    let tag = NSTextField(labelWithString: "ASKUSERQUESTION")
    tag.font = NSFont.systemFont(ofSize: 11, weight: .bold)
    tag.textColor = Theme.toolTagColors["AskUserQuestion"] ?? Theme.mcpTag
    tag.frame = NSRect(x: Layout.wizardBodyPaddingH, y: 9,
                        width: 180, height: 16)
    header.addSubview(tag)

    let stepCounter = NSTextField(labelWithString: "\(stepIndex + 1) of \(totalSteps)")
    stepCounter.font = NSFont.systemFont(ofSize: 11, weight: .medium)
    stepCounter.textColor = Theme.textSecondary
    stepCounter.alignment = .right
    stepCounter.frame = NSRect(x: width - Layout.wizardBodyPaddingH - 100, y: 9,
                               width: 100, height: 16)
    header.addSubview(stepCounter)
    root.addSubview(header)

    // --- Body ---
    let body = NSView(frame: .zero)

    // Header tag pill
    let pill = NSButton(frame: .zero)
    pill.title = question.header.uppercased()
    pill.font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
    pill.isBordered = false
    pill.wantsLayer = true
    pill.layer?.cornerRadius = 4
    pill.layer?.backgroundColor = (Theme.toolTagColors["AskUserQuestion"] ?? Theme.mcpTag).cgColor
    pill.contentTintColor = Theme.background
    let pillSize = (question.header.uppercased() as NSString)
        .size(withAttributes: [.font: pill.font!])
    pill.frame = NSRect(x: Layout.wizardBodyPaddingH, y: 0,
                        width: ceil(pillSize.width) + 16, height: 18)
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
                                       selected: false, index: i + 1)
        optionRowViews.append(row)
        body.addSubview(row)
    }

    // Other row (last)
    let otherRow = WizardOtherRow()
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
    var y = Layout.wizardBodyPaddingV
    // (we stack from top down; AppKit uses bottom-left origin, so we lay out at end)
    let pillTopY = Layout.wizardBodyPaddingV
    let qTopY = pillTopY + 18 + 6
    var rowTopY = qTopY + qHeight + 10
    // reserve space for option rows + other row + progress dots
    let totalRowsHeight = CGFloat(question.options.count + 1) *
        Layout.wizardRowHeightMin + CGFloat(question.options.count) * Layout.wizardRowGap
    let progressAreaHeight: CGFloat = Layout.wizardProgressTopPadding +
        Layout.wizardProgressDotHeight
    let bodyHeight = rowTopY + totalRowsHeight + progressAreaHeight + Layout.wizardBodyBottomPadding
    body.frame = NSRect(x: 0, y: Layout.wizardFooterHeight, width: width, height: bodyHeight)

    // Flip y (AppKit origin bottom-left)
    pill.frame.origin.y = bodyHeight - pillTopY - 18
    qField.frame.origin.y = bodyHeight - qTopY - qHeight

    var yCursor = bodyHeight - rowTopY - Layout.wizardRowHeightMin
    for row in optionRowViews {
        row.frame = NSRect(x: Layout.wizardBodyPaddingH, y: yCursor,
            width: width - Layout.wizardBodyPaddingH * 2, height: Layout.wizardRowHeightMin)
        yCursor -= (Layout.wizardRowHeightMin + Layout.wizardRowGap)
    }
    otherRow.frame = NSRect(x: Layout.wizardBodyPaddingH, y: yCursor,
        width: width - Layout.wizardBodyPaddingH * 2, height: Layout.wizardRowHeightMin)

    // Progress dots centered
    let dotsTotalWidth = CGFloat(totalSteps) * Layout.wizardProgressDotWidth +
        CGFloat(max(0, totalSteps - 1)) * Layout.wizardProgressDotGap
    var dx = (width - dotsTotalWidth) / 2
    let dotY = yCursor - Layout.wizardProgressTopPadding - Layout.wizardProgressDotHeight
    for dot in progressDots {
        dot.frame.origin = NSPoint(x: dx, y: dotY)
        dx += Layout.wizardProgressDotWidth + Layout.wizardProgressDotGap
    }

    root.addSubview(body)

    // --- Footer ---
    let footer = NSView(frame: NSRect(x: 0, y: 0, width: width, height: Layout.wizardFooterHeight))
    footer.wantsLayer = true
    footer.layer?.backgroundColor = Theme.codeBackground.cgColor

    let back = makeWizardFooterButton(title: "← Back",
        fill: Theme.buttonPersist.withAlphaComponent(0.06),
        border: Theme.buttonPersist.withAlphaComponent(0.12),
        textColor: Theme.textPrimary)
    back.frame = NSRect(x: Layout.wizardBodyPaddingH,
        y: (Layout.wizardFooterHeight - Layout.wizardFooterButtonHeight) / 2,
        width: Layout.wizardFooterSideButtonWidth, height: Layout.wizardFooterButtonHeight)
    footer.addSubview(back)

    let primary = makeWizardFooterButton(
        title: isLastStep ? "Submit ⏎" : "Next →",
        fill: Theme.buttonPersist.withAlphaComponent(0.22),
        border: Theme.buttonPersist.withAlphaComponent(0.50),
        textColor: Theme.textPrimary)
    footer.addSubview(primary)

    let terminal = makeWizardFooterButton(title: "Terminal",
        fill: Theme.buttonAllow.withAlphaComponent(0.18),
        border: Theme.buttonAllow.withAlphaComponent(0.45),
        textColor: Theme.textPrimary)
    terminal.frame = NSRect(x: 0, y: (Layout.wizardFooterHeight - Layout.wizardFooterButtonHeight) / 2,
        width: Layout.wizardFooterSideButtonWidth, height: Layout.wizardFooterButtonHeight)
    footer.addSubview(terminal)

    let cancel = makeWizardFooterButton(title: "Cancel",
        fill: Theme.buttonDeny.withAlphaComponent(0.10),
        border: Theme.buttonDeny.withAlphaComponent(0.35),
        textColor: Theme.textPrimary)
    cancel.frame = NSRect(x: 0, y: (Layout.wizardFooterHeight - Layout.wizardFooterButtonHeight) / 2,
        width: Layout.wizardFooterSideButtonWidth, height: Layout.wizardFooterButtonHeight)
    footer.addSubview(cancel)

    // Place: Back (left) · Primary (fill) · Terminal · Cancel (right)
    let backRightEdge = back.frame.maxX + Layout.wizardFooterGap
    let rightReserved = Layout.wizardFooterSideButtonWidth * 2 + Layout.wizardFooterGap * 2
    primary.frame = NSRect(
        x: backRightEdge,
        y: (Layout.wizardFooterHeight - Layout.wizardFooterButtonHeight) / 2,
        width: width - backRightEdge - rightReserved - Layout.wizardBodyPaddingH,
        height: Layout.wizardFooterButtonHeight)
    terminal.frame.origin.x = primary.frame.maxX + Layout.wizardFooterGap
    cancel.frame.origin.x = terminal.frame.maxX + Layout.wizardFooterGap

    root.addSubview(footer)

    // Size root
    let rootHeight = Layout.wizardHeaderHeight + bodyHeight + Layout.wizardFooterHeight
    root.frame.size = NSSize(width: width, height: rootHeight)
    header.frame.origin.y = rootHeight - Layout.wizardHeaderHeight
    body.frame.origin.y = Layout.wizardFooterHeight

    return WizardQuestionPanelHandles(
        root: root,
        optionRowViews: optionRowViews,
        otherRow: otherRow,
        backButton: back,
        primaryButton: primary,
        terminalButton: terminal,
        cancelButton: cancel,
        progressDots: progressDots)
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
        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        .foregroundColor: textColor,
    ])
    return b
}
```

- [ ] **Step 8.2: Recompile and run tests**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift && cd ..`
Run: `bash tests/run.sh`
Expected: both succeed.

- [ ] **Step 8.3: Commit**

```bash
git add hooks/claude-approve.swift
git commit -m "Add buildWizardQuestionPanel view builder"
```

---

## Task 9: `buildWizardReviewPanel` — review panel with answer summary

**Files:**
- Modify: `hooks/claude-approve.swift` — append to the wizard section.

- [ ] **Step 9.1: Add the builder**

Append:

```swift
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
    tag.font = NSFont.systemFont(ofSize: 11, weight: .bold)
    tag.textColor = Theme.toolTagColors["AskUserQuestion"] ?? Theme.mcpTag
    tag.frame = NSRect(x: Layout.wizardBodyPaddingH, y: 9, width: 260, height: 16)
    header.addSubview(tag)
    let answered = state.answers.filter { $0 != nil }.count
    let counter = NSTextField(labelWithString: "\(answered) of \(state.questions.count) answered")
    counter.font = NSFont.systemFont(ofSize: 11, weight: .medium)
    counter.textColor = Theme.textSecondary
    counter.alignment = .right
    counter.frame = NSRect(x: width - Layout.wizardBodyPaddingH - 180, y: 9, width: 180, height: 16)
    header.addSubview(counter)
    root.addSubview(header)

    // Body
    let body = NSView(frame: .zero)

    let title = NSTextField(labelWithString: "Review your answers")
    title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
    title.textColor = Theme.textPrimary
    title.frame = NSRect(x: Layout.wizardBodyPaddingH, y: 0, width: width - 2 * Layout.wizardBodyPaddingH, height: 18)
    body.addSubview(title)

    var reviewRows: [NSView] = []
    var editButtons: [NSButton] = []
    let rowSpacing: CGFloat = 8
    let rowHeight: CGFloat = 60

    for (i, q) in state.questions.enumerated() {
        let row = NSView(frame: .zero)
        row.wantsLayer = true
        row.layer?.cornerRadius = 6
        row.layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.02).cgColor
        row.layer?.borderWidth = 1
        row.layer?.borderColor = Theme.wizardRowBorder.cgColor

        let pill = NSButton(title: q.header.uppercased(), target: nil, action: nil)
        pill.isBordered = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 3
        pill.layer?.backgroundColor = (Theme.toolTagColors["AskUserQuestion"] ?? Theme.mcpTag).cgColor
        pill.attributedTitle = NSAttributedString(string: q.header.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
            .foregroundColor: Theme.background,
        ])
        let pillSize = (q.header.uppercased() as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .bold)])
        pill.frame = NSRect(x: 12, y: 37,
            width: ceil(pillSize.width) + 14, height: 16)
        row.addSubview(pill)

        let qLabel = NSTextField(labelWithString: q.question)
        qLabel.font = NSFont.systemFont(ofSize: 11)
        qLabel.textColor = Theme.textSecondary
        qLabel.lineBreakMode = .byTruncatingTail
        qLabel.frame = NSRect(x: pill.frame.maxX + 8, y: 37,
            width: width - pill.frame.maxX - 80, height: 16)
        row.addSubview(qLabel)

        let edit = NSButton(title: "edit", target: nil, action: nil)
        edit.isBordered = false
        edit.attributedTitle = NSAttributedString(string: "edit", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: Theme.buttonAllow,
        ])
        edit.frame = NSRect(x: width - Layout.wizardBodyPaddingH * 2 - 50, y: 37,
            width: 50, height: 16)
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
        case .none:
            answerText = "⋯ (not answered yet)"
        }
        let ans = NSTextField(labelWithString: answerText)
        ans.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        ans.textColor = Theme.textPrimary
        ans.lineBreakMode = .byTruncatingTail
        ans.frame = NSRect(x: 12, y: 10,
            width: width - 2 * Layout.wizardBodyPaddingH - 24, height: 16)
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
    let rowsTopStart = titleTop + 18 + 10
    let rowsTotalHeight = CGFloat(state.questions.count) * rowHeight +
        CGFloat(max(0, state.questions.count - 1)) * rowSpacing
    let progressTop = rowsTopStart + rowsTotalHeight + Layout.wizardProgressTopPadding
    let bodyHeight = progressTop + Layout.wizardProgressDotHeight + Layout.wizardBodyBottomPadding

    body.frame = NSRect(x: 0, y: Layout.wizardFooterHeight, width: width, height: bodyHeight)
    title.frame.origin.y = bodyHeight - titleTop - 18

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

    let back = makeWizardFooterButton(title: "← Back",
        fill: Theme.buttonPersist.withAlphaComponent(0.06),
        border: Theme.buttonPersist.withAlphaComponent(0.12),
        textColor: Theme.textPrimary)
    back.frame = NSRect(x: Layout.wizardBodyPaddingH,
        y: (Layout.wizardFooterHeight - Layout.wizardFooterButtonHeight) / 2,
        width: Layout.wizardFooterSideButtonWidth, height: Layout.wizardFooterButtonHeight)
    footer.addSubview(back)

    let submit = makeWizardFooterButton(title: "Submit Answers ⏎",
        fill: Theme.buttonAllow.withAlphaComponent(0.22),
        border: Theme.buttonAllow.withAlphaComponent(0.55),
        textColor: Theme.textPrimary)
    footer.addSubview(submit)

    let terminal = makeWizardFooterButton(title: "Terminal",
        fill: Theme.buttonAllow.withAlphaComponent(0.10),
        border: Theme.buttonAllow.withAlphaComponent(0.35),
        textColor: Theme.textPrimary)
    terminal.frame = NSRect(x: 0, y: (Layout.wizardFooterHeight - Layout.wizardFooterButtonHeight) / 2,
        width: Layout.wizardFooterSideButtonWidth, height: Layout.wizardFooterButtonHeight)
    footer.addSubview(terminal)

    let cancel = makeWizardFooterButton(title: "Cancel",
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
        let color = isSubmit ? Theme.buttonAllow : Theme.buttonPersist
        button.layer?.backgroundColor = color.withAlphaComponent(isSubmit ? 0.22 : 0.22).cgColor
        button.layer?.borderColor = color.withAlphaComponent(isSubmit ? 0.55 : 0.50).cgColor
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: Theme.textPrimary,
        ])
    } else {
        button.layer?.backgroundColor = Theme.wizardButtonDisabledBg.cgColor
        button.layer?.borderColor = Theme.wizardButtonDisabledBorder.cgColor
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: Theme.wizardButtonDisabledText,
        ])
    }
}
```

- [ ] **Step 9.2: Recompile and run tests**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift && cd ..`
Run: `bash tests/run.sh`
Expected: both succeed.

- [ ] **Step 9.3: Commit**

```bash
git add hooks/claude-approve.swift
git commit -m "Add buildWizardReviewPanel and applyWizardSubmitEnabled"
```

---

## Task 10: `WizardController` — event wiring and state→view sync

**Files:**
- Modify: `hooks/claude-approve.swift` — append to the wizard section.

The controller:
- Owns the `NSPanel` (reusing the existing panel creation helpers) and a mutable content container.
- Builds the current step's view and swaps it into the container on step change.
- Attaches click targets to option rows, footer buttons, and edit links.
- Intercepts key events via a monitor (`NSEvent.addLocalMonitorForEvents`).
- Runs the modal via `NSApp.runModal(for:)` and returns a result struct when the user submits / cancels / opens terminal.

- [ ] **Step 10.1: Add the controller**

Append:

```swift
/// Outcome of a wizard run, returned by `WizardController.run()`.
enum WizardOutcome {
    case submit(reason: String)        // Claude gets this reason as deny-feedback
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
    private var currentQuestionHandles: WizardQuestionPanelHandles?
    private var currentReviewHandles: WizardReviewPanelHandles?
    private var outcome: WizardOutcome = .cancel
    private var localKeyMonitor: Any?

    init(state: WizardState, panel: NSPanel, contentContainer: NSView) {
        self.state = state
        self.panel = panel
        self.container = contentContainer
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
        currentReviewHandles = nil

        if state.isReviewStep {
            let h = buildWizardReviewPanel(state: state)
            container.addSubview(h.root)
            resizePanelToFit(rootHeight: h.root.frame.height)
            currentReviewHandles = h
            wireReviewHandles(h)
            applyWizardSubmitEnabled(h.submitButton, enabled: state.allAnswered, isSubmit: true)
            h.backButton.isEnabled = true
        } else {
            let qIndex = state.step
            let q = state.questions[qIndex]
            let isLast = (state.questions.count == 1)  // single-question wizard → primary is Submit
            let h = buildWizardQuestionPanel(
                question: q, stepIndex: qIndex,
                totalSteps: state.questions.count,
                isLastStep: isLast)
            container.addSubview(h.root)
            resizePanelToFit(rootHeight: h.root.frame.height)
            currentQuestionHandles = h
            wireQuestionHandles(h, questionIndex: qIndex)
            applySelectionFromState(h, questionIndex: qIndex)
            applyProgress(dots: h.progressDots)
            // Back disabled on step 0
            h.backButton.isEnabled = (qIndex > 0)
            // Primary disabled until current question has an answer
            applyWizardSubmitEnabled(h.primaryButton,
                enabled: state.answers[qIndex] != nil,
                isSubmit: isLast)
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
        for (i, dot) in dots.enumerated() {
            let filled = state.answers[i] != nil
            dot.layer?.backgroundColor = (filled ? Theme.wizardProgressActive : Theme.wizardProgressInactive).cgColor
        }
    }

    private func applySelectionFromState(_ h: WizardQuestionPanelHandles, questionIndex: Int) {
        let answer = state.answers[questionIndex]
        // Deselect all preset rows
        for row in h.optionRowViews {
            row.layer?.backgroundColor = Theme.wizardRowBg.cgColor
            row.layer?.borderColor = Theme.wizardRowBorder.cgColor
        }
        h.otherRow.setSelected(false)
        if case .preset(let idx) = answer, idx < h.optionRowViews.count {
            let row = h.optionRowViews[idx]
            row.layer?.backgroundColor = Theme.wizardRowSelectedBg.cgColor
            row.layer?.borderColor = Theme.wizardRowSelectedBorder.cgColor
        } else if case .custom = answer {
            h.otherRow.setSelected(true)
        }
        // Restore pending custom text
        h.otherRow.setText(state.pendingCustom[questionIndex])
    }

    // MARK: Wiring

    private func wireQuestionHandles(_ h: WizardQuestionPanelHandles, questionIndex: Int) {
        // Preset row clicks
        for (i, row) in h.optionRowViews.enumerated() {
            row.gestureRecognizers.forEach { row.removeGestureRecognizer($0) }
            let click = NSClickGestureRecognizer(
                target: self, action: #selector(onPresetClicked(_:)))
            click.setAssociatedValue(i, forKey: "optionIndex")  // helper below
            row.addGestureRecognizer(click)
        }
        // Other row
        h.otherRow.onActivate = { [weak self] in
            guard let self = self else { return }
            self.activateOther(questionIndex: questionIndex)
        }
        h.otherRow.onTextChange = { [weak self] text in
            guard let self = self else { return }
            self.state.setPending(question: questionIndex, text: text)
            // If Other is the selected answer, update answers in real-time too
            if case .custom = self.state.answers[questionIndex] {
                self.state.commitCustom(question: questionIndex, text: text)
            }
            self.recomputePrimaryEnabled()
        }
        h.otherRow.onSubmit = { [weak self] in self?.advance() }
        h.otherRow.onEscape = { [weak self] in self?.exitOtherEditing() }

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
            let click = NSClickGestureRecognizer(
                target: self, action: #selector(onReviewRowClicked(_:)))
            click.setAssociatedValue(i, forKey: "questionIndex")
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

    @objc private func onPresetClicked(_ g: NSClickGestureRecognizer) {
        guard let h = currentQuestionHandles else { return }
        let qi = state.step
        guard let optIdx = g.associatedValue(forKey: "optionIndex") as? Int else { return }
        h.otherRow.deactivate()
        state.selectPreset(question: qi, optionIndex: optIdx)
        applySelectionFromState(h, questionIndex: qi)
        applyProgress(dots: h.progressDots)
        recomputePrimaryEnabled()
    }

    @objc private func onReviewRowClicked(_ g: NSClickGestureRecognizer) {
        guard let qi = g.associatedValue(forKey: "questionIndex") as? Int else { return }
        jumpTo(step: qi)
    }

    @objc private func onEditClicked(_ sender: NSButton) {
        jumpTo(step: sender.tag)
    }

    @objc private func onBack() {
        if state.step > 0 {
            state.step -= 1
            renderCurrentStep()
        }
    }

    @objc private func onPrimary() {
        if state.isReviewStep {
            guard state.allAnswered else { return }
            outcome = .submit(reason: formatWizardAnswers(state: state))
            stopModal()
        } else {
            advance()
        }
    }

    @objc private func onTerminal() {
        outcome = .terminal
        stopModal()
    }

    @objc private func onCancel() {
        outcome = .cancel
        stopModal()
    }

    private func advance() {
        // If at last question and review step exists → go to review
        // If single question, submit now
        let qi = state.step
        guard state.answers[qi] != nil else { return }
        if state.questions.count == 1 {
            outcome = .submit(reason: formatWizardAnswers(state: state))
            stopModal()
            return
        }
        if qi < state.questions.count - 1 {
            state.step = qi + 1
        } else {
            state.step = state.questions.count  // review
        }
        renderCurrentStep()
    }

    private func jumpTo(step: Int) {
        guard step >= 0 && step < state.questions.count else { return }
        state.step = step
        renderCurrentStep()
    }

    private func activateOther(questionIndex qi: Int) {
        guard let h = currentQuestionHandles else { return }
        h.otherRow.activate()
        // Treat Other as an answer commit only if text is non-empty
        if !h.otherRow.currentText.isEmpty {
            state.commitCustom(question: qi, text: h.otherRow.currentText)
        }
        applySelectionFromState(h, questionIndex: qi)
        recomputePrimaryEnabled()
    }

    private func exitOtherEditing() {
        guard let h = currentQuestionHandles else { return }
        h.otherRow.deactivate()
    }

    private func recomputePrimaryEnabled() {
        if let h = currentQuestionHandles {
            applyWizardSubmitEnabled(h.primaryButton,
                enabled: state.answers[state.step] != nil,
                isSubmit: state.questions.count == 1)
        }
        if let r = currentReviewHandles {
            applyWizardSubmitEnabled(r.submitButton,
                enabled: state.allAnswered, isSubmit: true)
        }
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
        if let h = currentQuestionHandles, h.otherRow.isActive {
            return false
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
        case .none:           current = -1
        }
        let next = (current + delta + total) % total
        if next == total - 1 {
            // Other row — activate but don't auto-type
            activateOther(questionIndex: qi)
        } else {
            h.otherRow.deactivate()
            state.selectPreset(question: qi, optionIndex: next)
            applySelectionFromState(h, questionIndex: qi)
        }
        applyProgress(dots: h.progressDots)
        recomputePrimaryEnabled()
    }

    private func selectOption(byNumber n: Int) {
        guard let h = currentQuestionHandles else { return }
        let qi = state.step
        let total = state.questions[qi].options.count
        if n <= total {
            h.otherRow.deactivate()
            state.selectPreset(question: qi, optionIndex: n - 1)
            applySelectionFromState(h, questionIndex: qi)
        } else if n == total + 1 {
            activateOther(questionIndex: qi)
        }
        applyProgress(dots: h.progressDots)
        recomputePrimaryEnabled()
    }
}

// Small helper: attach arbitrary values to NSGestureRecognizer via objc_setAssociatedObject
// so that one action can be reused for many rows without per-row subclassing.
private var wizardAssocKeys: [String: UnsafeRawPointer] = [:]
private let wizardAssocLock = NSLock()
private func wizardAssocKey(_ name: String) -> UnsafeRawPointer {
    wizardAssocLock.lock(); defer { wizardAssocLock.unlock() }
    if let p = wizardAssocKeys[name] { return p }
    let raw = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    let ptr = UnsafeRawPointer(raw)
    wizardAssocKeys[name] = ptr
    return ptr
}
extension NSObject {
    func setAssociatedValue(_ value: Any, forKey key: String) {
        objc_setAssociatedObject(self, wizardAssocKey(key), value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    func associatedValue(forKey key: String) -> Any? {
        objc_getAssociatedObject(self, wizardAssocKey(key))
    }
}
```

- [ ] **Step 10.2: Recompile and run tests**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift && cd ..`
Run: `bash tests/run.sh`
Expected: both succeed.

- [ ] **Step 10.3: Commit**

```bash
git add hooks/claude-approve.swift
git commit -m "Add WizardController with state/view sync and key monitor"
```

---

## Task 11: Dispatch `AskUserQuestion` into the wizard from the main flow

**Files:**
- Modify: `hooks/claude-approve.swift` — `approveMain()` around line 2470, `processResult()` around line 2410, and the dialog-construction path around line 2298.

Key question: where does the existing code build the panel and run the modal? Answer: inside `showPermissionDialog(...)` which is in the Dialog Construction section. We intercept BEFORE that and branch for AskUserQuestion.

- [ ] **Step 11.1: Find the dispatch point**

Open `hooks/claude-approve.swift` and locate `// MARK: - Main Entry Point` (currently line 2461). Inside `approveMain()`, after all fast paths but before the dialog is shown, we'll branch.

Read the existing code around the line `if checkAlwaysApprove(input: input)` (currently line 2517) and the line that calls into the dialog (search for `buildPermOptions` usage or the function that shows the panel).

Run: `grep -n "showDialog\|runModal\|buildPermOptions" hooks/claude-approve.swift | head -20`
Note the function name that shows the panel — typically `showPermissionDialog(input:options:)` or similar. Call it `SHOW_FN` in the steps below.

- [ ] **Step 11.2: Add the wizard dispatch**

In `approveMain()`, immediately **before** the existing `SHOW_FN(…)` call (or whatever runs the modal), insert:

```swift
    if input.toolName == "AskUserQuestion" {
        let questions = parseWizardQuestions(from: input.toolInput)
        if !questions.isEmpty {
            let outcome = runAskUserQuestionWizard(input: input, questions: questions)
            switch outcome {
            case .submit(let reason):
                writeHookResponse(decision: "deny", reason: reason)
                exit(0)
            case .terminal:
                openTerminalApp(cwd: input.cwd, sessionId: input.sessionId)
                writeHookResponse(decision: "allow", reason: "Allowed — terminal activated for user input")
                exit(0)
            case .cancel:
                writeHookResponse(decision: "deny", reason: "User cancelled the question dialog")
                exit(0)
            }
        }
        // Fallthrough: malformed AskUserQuestion with no questions → show the
        // old read-only dialog so the user still has Go to Terminal.
    }
```

Below that, add a helper that wraps the controller. Place this in the `// MARK: - AskUserQuestion Wizard` section, at the end:

```swift
/// Creates the NSPanel, installs a content container, and runs the wizard.
/// Returns the user's outcome.
func runAskUserQuestionWizard(input: HookInput, questions: [WizardQuestion]) -> WizardOutcome {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // Panel shell (mirrors existing dialog behavior: non-activating, all-spaces)
    let initialHeight: CGFloat = 400   // will be replaced by resizePanelToFit
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: Layout.panelWidth, height: initialHeight),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hasShadow = true
    panel.backgroundColor = Theme.background
    panel.isOpaque = false
    panel.contentView?.wantsLayer = true
    panel.contentView?.layer?.cornerRadius = 10

    let container = NSView(frame: NSRect(x: 0, y: 0, width: Layout.panelWidth, height: initialHeight))
    panel.contentView?.addSubview(container)

    // Center on screen
    if let screen = NSScreen.main {
        let scr = screen.visibleFrame
        let x = scr.origin.x + (scr.width - panel.frame.width) / 2
        let y = scr.origin.y + (scr.height - panel.frame.height) * 0.55
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    panel.orderFrontRegardless()

    let state = WizardState(questions: questions)
    let controller = WizardController(state: state, panel: panel, contentContainer: container)
    let outcome = controller.run()
    panel.orderOut(nil)
    return outcome
}
```

- [ ] **Step 11.3: Recompile and run tests**

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift && cd ..`
Run: `bash tests/run.sh`
Expected: both succeed. If compile errors reference a missing symbol in the `approveMain` branch, confirm the insertion point is inside `approveMain()` and the helper is visible at that scope.

- [ ] **Step 11.4: Commit**

```bash
git add hooks/claude-approve.swift
git commit -m "Dispatch AskUserQuestion to wizard in main flow"
```

---

## Task 12: Manual QA + update CLAUDE.md test checklist

**Files:**
- Modify: `CLAUDE.md` — the `## Testing` section, specifically test case #12.

The wizard is entirely UI — proper verification is manual. This task fixes any bugs found during manual testing, then updates the project's test checklist.

- [ ] **Step 12.1: Run every manual test case**

Reset session approvals: `rm -rf /tmp/claude-hook-sessions/`

Then, with Claude Code running, exercise each case:

1. **Single question** — ask Claude to use `AskUserQuestion` with 1 question / 2 options. Expected: panel opens without a review step. Primary button says `Submit ⏎`. Clicking an option enables Submit. Return submits.
2. **Three questions** — ask Claude to use `AskUserQuestion` with 3 questions. Navigate with ↑↓ to pick. Advance with → and Return. After Q3, the review panel appears with 3 rows. Submit is enabled. Back returns to Q3.
3. **Other row typing** — on any question, click the Other row. It becomes a text field with a green caret. Type a few characters. Press Shift+Return to insert a newline, type more. Row grows to fit.
4. **Other persists across navigation** — type in Other on Q1, press → to Q2, press ← back to Q1. Your text is still in the Other field.
5. **Submit disabled** — on review, press Back, on Q3 change the answer back to unselected by jumping to a nonexistent state (can only happen via "edit" click). Alternatively, cancel and restart. Simpler: skip step 12.1 #2 but press Submit from the review step with one question still unanswered — Submit must be greyed out and Return must no-op.
6. **Keyboard — option mode** — `1 2 3` jumps to the corresponding option (1..N). `4` (or N+1) jumps into Other. ↑/↓ walk through options including Other. ←/→ navigate Back/Next.
7. **Keyboard — Other text mode** — while typing, `1 2 3` are typed as text. ← → move the caret. ↑ ↓ move between lines (macOS default). Esc exits text mode (goes back to option-selection mode). Second Esc cancels the dialog.
8. **Terminal button** — click Terminal on any panel. Regression check: the original terminal-activation behavior still works.
9. **Cancel** — click Cancel. Panel dismisses. Claude sees the denial reason `User cancelled the question dialog`.
10. **Mixed with other tools** — trigger a Bash, then an Edit, then an AskUserQuestion in the same session. Each uses its own dialog style; no crashes.

Fix any bugs. Commit fixes as standalone commits with imperative messages (`Fix wizard Other row caret position`, etc.). After a fix, re-run `bash tests/run.sh` to make sure unit tests still pass.

- [ ] **Step 12.2: Update CLAUDE.md test checklist**

In `/Users/rajul/habuild/homebrew-claude/CLAUDE.md`, find the existing test case `#12. **AskUserQuestion dialog**` in the `### Manual Test Cases` section and replace it (keep item numbering intact) with:

```markdown
12. **AskUserQuestion wizard** — trigger `AskUserQuestion` with one or more questions.
    Purple-tagged wizard panel appears. Work through every sub-case:
    - **12a.** Single question → primary button says `Submit ⏎`, Return submits, no review step.
    - **12b.** Three questions → per-question panels with Back/Next, then a Review panel
      summarising every answer. Submit Answers on Review submits.
    - **12c.** "Other" row → click it to morph into a multi-line text area. Type,
      use Shift+Return for newlines, row grows to fit.
    - **12d.** Type in Other, navigate away and back — typed text is still there.
    - **12e.** On Review with any question unanswered, Submit is visibly greyed,
      Return is a no-op.
    - **12f.** Keyboard in option mode: `1..N` jumps, ↑/↓ walks options including Other,
      ←/→ Back/Next, Return Next/Submit, Esc cancels.
    - **12g.** Keyboard in Other text mode: digits type into the text, ←/→ caret,
      ↑/↓ line navigation, Esc exits back to option mode (second Esc cancels).
    - **12h.** Terminal button still opens the user's terminal (regression check).
    - **12i.** Cancel closes the panel; Claude sees a "user cancelled" reason.
```

- [ ] **Step 12.3: Commit checklist update**

```bash
git add CLAUDE.md
git commit -m "Update manual test checklist for AskUserQuestion wizard"
```

- [ ] **Step 12.4: Final green build**

Run: `bash tests/run.sh`
Expected: all tests pass.

Run: `cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift && cd ..`
Expected: success.

---

## Self-review results

- **Spec coverage:**
  - User flow (spec §4) → Tasks 10, 11
  - Question-panel visual (spec §5.1) → Task 8
  - Other row visual + behavior (spec §5.2) → Task 7
  - Review-panel visual (spec §5.3) → Task 9
  - Keyboard model (spec §6) → Task 10 (key monitor + text view delegate)
  - Submit-disabled rule (spec §6.3) → Task 9 (`applyWizardSubmitEnabled`), Task 10 (`recomputePrimaryEnabled`)
  - Data model (spec §7.1, §7.2) → Tasks 1, 3
  - Hook response formatting (spec §7.3) → Tasks 4, 11
  - Code organization (spec §8) → All tasks target the single wizard section
  - Theming additions (spec §9) → Task 5
  - Unit tests (spec §10.1) → Tasks 1–4
  - Manual tests (spec §10.2) → Task 12
  - Dialog resize (spec §12) → Task 10 (`resizePanelToFit`), Task 7 (`refreshHeight`)
  - Focus-stealing (spec §12) → Task 11 (panel uses `nonactivatingPanel`)

- **Placeholder scan:** No TBD/TODO/"similar to" / "add appropriate X" / un-defined references. Every function used in a later task is defined in an earlier task.

- **Type consistency:** `WizardQuestion`, `WizardOption`, `WizardAnswer`, `WizardState`, `WizardOutcome`, `WizardController`, `WizardOtherRow`, `WizardQuestionPanelHandles`, `WizardReviewPanelHandles` are spelled identically across all tasks.

- **Scope check:** Single file, single feature, single release. Fits one implementation plan.
