# .claude

A macOS native permission dialog for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) hooks. Replaces the terminal-based permission prompts with a floating dialog that works across all macOS Spaces — so you never miss a permission request, even when you're on a different desktop.

## Why

Claude Code asks for permission before running tools like Bash commands, file edits, and web requests. The default prompt lives inside your terminal — easy to miss if you switch to another Space or app. This hook intercepts those prompts and shows a native macOS dialog instead:

- Floating panel visible on **every Space and fullscreen app**
- **Syntax-highlighted** Bash commands with keyword, flag, and string coloring
- **Unified diffs** with line numbers for file edits
- **Tool-specific buttons** matching Claude Code's native permission options exactly
- **Session memory** — approve a tool once for the session and it won't ask again
- **Project-level persistence** — save permanent rules to `.claude/settings.local.json`
- **Keyboard shortcuts** — `1`/`2`/`3` to pick an option, `Enter` to accept, `Esc` to reject
- Notification sound to grab your attention

## Install

```bash
git clone git@github.com:rajulbabel/.claude.git ~/.claude
```

That's it. The `settings.json` is pre-configured to use the hook.

### Build from source

If you want to recompile the Swift binary (e.g., after making changes):

```bash
cd ~/.claude/hooks
swiftc -framework AppKit -o claude-approve claude-approve.swift
```

Requires Xcode Command Line Tools (`xcode-select --install`).

## How It Works

Claude Code supports a [hooks system](https://docs.anthropic.com/en/docs/claude-code/hooks) that runs commands before/after tool use. This project uses a **PreToolUse** hook:

```
Claude wants to run a tool
        │
        ▼
Hook receives JSON on stdin
(tool_name, tool_input, cwd, session_id)
        │
        ▼
Session auto-approve check ──── Already approved? ──→ Allow (skip dialog)
        │
        ▼ (not approved)
Show native macOS dialog
        │
        ▼
User clicks a button / presses key
        │
        ├── "Yes" ──────────────────→ Allow once
        ├── "Yes, don't ask again…" ─→ Allow + save rule to settings.local.json
        ├── "Yes, this session" ─────→ Allow + remember for session
        └── "No" ───────────────────→ Deny
        │
        ▼
Hook writes JSON to stdout
(permissionDecision: "allow" / "deny")
```

### Permission Options

The dialog generates **tool-specific** options that match Claude Code's native prompts:

| Tool | Persistent Option |
|------|------------------|
| **Bash** | *Yes, and don't ask again for `<cmd>` commands in `<project>`* |
| **Edit / Write** | *Yes, allow all edits during this session* |
| **WebFetch** | *Yes, and don't ask again for `<domain>`* |
| **WebSearch** | *Yes, and don't ask again for WebSearch* |
| **Other tools** | *Yes, during this session* |

### Persistence

| Scope | Storage |
|-------|---------|
| Once | No storage — one-time allow |
| Session | `/tmp/claude-hook-sessions/<session_id>` |
| Project | `<project>/.claude/settings.local.json` |

## Configuration

The hook is configured in `settings.json`. The default setup intercepts all major tools:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [
          {
            "command": "~/.claude/hooks/claude-approve",
            "timeout": 600,
            "statusMessage": "Waiting for approval in dialog...",
            "type": "command"
          }
        ],
        "matcher": "Bash|Edit|Write|Read|NotebookEdit|Task|WebFetch|WebSearch|Glob|Grep"
      }
    ]
  }
}
```

### Customizing

- **Change which tools require approval:** Edit the `matcher` regex pattern
- **Pre-allow specific tools/domains:** Add rules to the `permissions.allow` array:
  ```json
  "allow": ["Read", "WebSearch", "WebFetch(domain:docs.python.org)", "Bash(git *)"]
  ```
- **Timeout:** Adjust the `timeout` value (seconds) — dialog auto-denies when it expires

## Architecture

```
hooks/
├── claude-approve.swift   # Source — the main permission dialog
├── claude-approve         # Compiled arm64 binary
├── claude-notify.swift    # Notification-only dialog (alternative approach)
├── claude-notify          # Compiled binary
├── notify-and-approve.sh  # Shell wrapper (alternative hook entry point)
└── cleanup-pending.sh     # PostToolUse cleanup helper
settings.json              # Claude Code configuration with hook setup
```

### Source Structure (`claude-approve.swift`)

| Section | Purpose |
|---------|---------|
| **Models** | `HookInput`, `PermOption`, `DiffOp` data types |
| **Theme** | Complete dark-mode color palette and typography |
| **Layout** | Panel dimensions, spacing, and sizing constants |
| **Input Parsing** | Reads and deserializes hook JSON from stdin |
| **Session Management** | Auto-approve checks, session/project persistence |
| **Gist Generation** | One-line tool summaries (e.g., `cd && swiftc`) |
| **Syntax Highlighting** | Bash tokenizer + ANSI escape code parser |
| **Diff Engine** | LCS-based unified diff with context collapsing |
| **Content Rendering** | Per-tool attributed string builders |
| **Permission Options** | Tool-specific button generation |
| **Dialog Construction** | NSPanel layout, button rows, keyboard handling |
| **Result Processing** | Persists approvals, writes hook response |

## Requirements

- **macOS** (tested on macOS 15 Sequoia)
- **Xcode Command Line Tools** (only if building from source)
- **Claude Code** CLI

## License

MIT
