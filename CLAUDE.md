# Claude Code Project Instructions

## Overview

This is a macOS native permission dialog hook for Claude Code. The main file is
`hooks/claude-approve.swift` — a single-file Swift script compiled into a binary
that runs as a PreToolUse hook.

## Build

```bash
cd hooks && swiftc -framework AppKit -o claude-approve claude-approve.swift
```

Always recompile after editing the Swift source. The binary must be at
`hooks/claude-approve` for the hook to work.

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

- **Input:** JSON on stdin with keys `tool_name`, `tool_input`, `cwd`, `session_id`
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

After any change to `claude-approve.swift`, recompile and run through all test cases.
Reset session approvals first: `rm -rf /tmp/claude-hook-sessions/`

### Test Cases

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

## Commit Conventions

- Use imperative mood in commit messages ("Add feature", not "Added feature")
- Keep subject line under 72 characters
- Use body for details when the change is non-trivial
- **NEVER include `Co-Authored-By` lines** — no attribution trailers of any kind
