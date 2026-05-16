# Claude Code Project Instructions

## Overview

This is a macOS native permission dialog hook for Claude Code. The main file is
`hooks/claude-approve.swift` — a single-file Swift script compiled into a binary
that runs as a PreToolUse hook.

## Build

```bash
cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift
cd hooks && swiftc -O -parse-as-library -framework AppKit -o claude-stop    claude-stop.swift
```

Always recompile after editing Swift source. Binaries must be at
`hooks/claude-approve` and `hooks/claude-stop` for the hooks to work.

## Architecture Rules

- **Single-file script** — all code lives in `claude-approve.swift`. Do not split
  into multiple files or create a Swift Package. The script must compile with a
  single `swiftc` invocation.
- **No external dependencies** — only AppKit and Foundation. No SPM, CocoaPods, or
  third-party libraries.
- **All constants are named** — colors in `Theme`, dimensions in `Layout`. Never
  use magic numbers inline.
- **Document all public functions** — use `///` doc comments explaining purpose,
  parameters, and behavior.

## Code Organization

The source is organized into `// MARK: -` sections in this order:

1. Models (`HookInput`, `PermOption`, `DiffOp`)
2. Theme (colors, fonts)
3. Layout (dimensions, spacing)
4. Input Parsing
5. Session Management
6. Hook Response Output
7. Gist Generation
8. Syntax Highlighting (ANSI + Bash)
9. Diff Engine (LCS)
10. Content Rendering
11. Permission Options
12. Button Layout
13. Content Measurement
14. Focus Management
15. Dialog Construction
16. Result Processing
17. Main Entry Point

New code should go in the appropriate section. Do not add code at the top level
between sections.

## Hook Protocol

- **Input:** JSON on stdin with keys `tool_name`, `tool_input`, `cwd`, `session_id`, `permission_mode`
- **Output:** JSON on stdout:
  ```json
  {
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "allow",
      "permissionDecisionReason": "Reason string"
    }
  }
  ```
- Decision must be `"allow"` or `"deny"` (not `"ask"`)

## Key Design Decisions

- **No hardcoded permission options** — buttons are generated dynamically per tool
  type via `buildPermOptions()`, matching Claude Code's native prompt text exactly.
- **NSButton for tag pills** — not NSTextField, because NSButton reliably centers
  text at any size.
- **NSPanel (not NSWindow)** — with `.nonactivatingPanel` so it doesn't steal focus
  from the terminal.
- **`.canJoinAllSpaces`** — dialog appears on every macOS Space.
- **Session auto-approve** — checked before showing the dialog. If a tool is already
  approved for the session, the hook returns immediately without any UI.
- **Gist shows command summary** — for Bash, only command names + operators
  (e.g., `cd && swiftc`), not the full command with arguments.

## Testing

### Automated Tests

Run the full test suite (unit + integration) with:

```bash
bash tests/run.sh
```

Test builds use conditional compilation (`-D TESTING`) so the test harness can call
internal functions directly. The test binaries compile the source + test files together:

```bash
# Test build (source + test files compiled together):
swiftc -D TESTING -parse-as-library -framework AppKit \
  hooks/claude-approve.swift tests/harness.swift tests/test-approve.swift \
  -o tests/test-approve-bin
```

Tests live in `tests/` which is invisible to users (`install.py` only copies from `hooks/`).

### Manual Test Cases

After any change to `claude-approve.swift`, recompile and run through all test cases.
Reset session approvals first: `rm -rf /tmp/claude-hook-sessions/`

1. **Consecutive Bash dialogs (5+)** — fire 5+ parallel `echo` commands. Dialogs appear
   one at a time, next gets focus automatically after dismissal, no flickering.
2. **Button press feedback** — on each dialog test mouse click AND keyboard shortcuts
   (1/2/3). Button should visually highlight. Must work on all consecutive dialogs,
   not just the last one.
3. **Desktop/Space switching** — while dialog is visible, switch macOS Spaces and back.
   Dialog regains focus automatically. Test with single and consecutive dialogs.
4. **File edit diffs** — trigger an Edit tool. Dialog shows unified diff with line
   numbers and red/green coloring. Revert edit after testing.
5. **File write** — trigger a Write tool. Dialog shows file path and content preview.
6. **Mixed tool batch** — fire parallel Bash + Glob + Grep + Edit. All dialogs resolve
   correctly, no crashes or hangs.
7. **Read tool** — trigger a Read. Dialog shows the file path.
8. **Session auto-approve** — approve "allow all edits this session", then trigger
   another Edit. It should pass silently with no dialog.
9. **Large content** — edit a file with many lines changed or run a long command.
   Dialog handles it without hanging (diff capped at 500 lines).
10. **Keyboard shortcuts** — `1`/`2`/`3` select buttons, `Enter` accepts, `Esc` rejects.
11. **Stop dialog** — finish any Claude task (Q&A, agentic run, plan). The "Done"
    panel appears with a green pill, gist from the last message, and a scrollable
    content block. Auto-dismisses in 15 seconds; `Enter`/`Esc`/`1` dismiss early.
12. **AskUserQuestion wizard** — trigger `AskUserQuestion` with one or more questions.
    Wizard panel appears with the lavender `ASKUSERQUESTION` header tag. Work through
    every sub-case:
    - **12a.** Single question → primary button says `Submit Answers`, Return submits.
    - **12b.** Three questions → per-question panels, last question's primary button
      says `Submit Answers` and submits the whole bundle.
    - **12c.** "Other" row → click it to morph into a multi-line text area. Type,
      use Shift+Return for newlines, row grows to fit. Single-line text sits
      vertically centred inside the row.
    - **12d.** Type in Other, navigate away and back — typed text is still there.
    - **12e.** Primary button greys out when current question has no answer;
      Return is a no-op in that state.
    - **12f.** Keyboard in option mode: `1..N` jumps, ↑/↓ walks options including Other,
      ←/→ Back/Next, Return Next/Submit.
    - **12g.** Keyboard in Other text mode: digits type into the text, ←/→ caret,
      ↑/↓ line navigation, Esc exits back to option mode.
    - **12h.** Footer is two rows: row 1 `Back` + `Next` / `Submit Answers`,
      row 2 `Go to Terminal` + `Ok`. Ok dismisses the dialog (deny with
      "user cancelled" reason). Go to Terminal still opens the user's terminal.
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
13. **Unified dialog family** — trigger in sequence: a Bash permission, finish an
    Edit permission, let Claude finish to get the Done dialog, then a multi-
    question AskUserQuestion. All four panels share: borderless rounded chrome
    (no title bar, 10pt corners), wizard-style pill buttons with semibold 12pt
    text and 8pt corners, content container with the subtle `wizardRowBg` /
    `wizardRowBorder` palette, hairline separator between identity block and
    tag row. Project name + cwd still visible on Permission and Done.
14. **Button press animation** — on every button in every dialog, clicking or
    pressing its keyboard shortcut triggers a brief scale-down + release
    animation (~180 ms total). No regressions in the click outcome, the deny
    text-field morph, or any keyboard shortcut.
15. **Keyboard shortcut badges** — on Permission and Done dialogs each button
    shows a small monospaced `1` / `2` / `3` numeral at the vertically
    centred left edge. Pressing the corresponding key triggers the button
    with the same press animation as a mouse click.

## Releases

To publish a new version:

1. Tag the release: `git tag vX.Y.Z && git push origin vX.Y.Z`
2. Compute the SHA: `curl -fsSL https://github.com/rajulbabel/homebrew-claude/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256`
3. Update `Formula/permit.rb` with the new tag URL, `sha256`, and `version`
4. Commit and push the formula update

The tag is immutable, so the SHA will never go stale.

## Commit Conventions

- Use imperative mood in commit messages ("Add feature", not "Added feature")
- Keep subject line under 72 characters
- Use body for details when the change is non-trivial
- **NEVER include `Co-Authored-By` lines** — no attribution trailers of any kind
