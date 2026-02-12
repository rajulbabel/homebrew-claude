# .claude

A macOS native permission dialog for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) hooks. Replaces the terminal-based permission prompts with a floating dialog that works across all macOS Spaces — so you never miss a permission request, even when you're on a different desktop.

## The Problem

If you use Claude Code seriously, you're running **multiple sessions in parallel** — one refactoring a backend, another writing tests, a third exploring a codebase. Each session runs in its own terminal tab or window, often across different macOS Spaces or fullscreen apps.

Claude Code pauses and waits for your permission before running commands, editing files, or making web requests. But the permission prompt is **buried inside the terminal** — a text-based prompt with no notification, no sound, no visual cue outside that specific tab.

So what actually happens:

1. You kick off a task in Session A and switch to Session B
2. Session A hits a permission prompt and **silently waits**
3. You have no idea it's blocked — there's no notification, no dock badge, nothing
4. Minutes later you check back and realize it's been sitting idle the whole time
5. Multiply this across 3–4 sessions and you're constantly context-switching just to babysit permission prompts

**You lose track of which sessions need attention.** The more sessions you run, the worse it gets. What should be efficient parallel workflows turns into a game of whack-a-mole — checking tabs, hunting for the one that's waiting for input.

## The Solution

This hook replaces the terminal prompt with a **native macOS dialog** that:

- **Pops up on top of everything** — visible on every Space, every fullscreen app
- **Plays a sound** — you hear it even when you're not looking at the screen
- Shows **exactly what Claude wants to do** — syntax-highlighted commands, unified diffs, file paths
- Lets you **respond with one click or keystroke** — then immediately get back to what you were doing

You stop babysitting terminals. You work on whatever you want, and when any Claude session needs you, it tells you.

## Features

- **Floating panel** visible on every Space and fullscreen app
- **Syntax-highlighted** Bash commands with keyword, flag, and string coloring
- **Unified diffs** with line numbers for file edits
- **Tool-specific buttons** matching Claude Code's native permission options exactly
- **Session memory** — approve a tool once for the session and it won't ask again
- **Project-level persistence** — save permanent rules to `.claude/settings.local.json`
- **Keyboard shortcuts** — `1`/`2`/`3` to pick an option, `Enter` to accept, `Esc` to reject
- **Button press feedback** — visual highlight on both mouse click and keyboard shortcut
- **Multi-dialog queuing** — when multiple dialogs appear, they activate one at a time via SIGUSR1 signaling
- **Space-switch resilience** — dialog automatically regains focus when switching macOS desktops
- Notification sound to grab your attention

## Install

```bash
git clone git@github.com:rajulbabel/.claude.git ~/.claude
```

If `~/.claude` already exists, merge the hooks into it:

```bash
git clone git@github.com:rajulbabel/.claude.git /tmp/.claude-hooks && cp -r /tmp/.claude-hooks/hooks ~/.claude/ && rm -rf /tmp/.claude-hooks
```

Then add the hooks config to your `~/.claude/settings.json` — see [Configuration](#configuration) below.

Restart Claude Code for hooks to take effect.

> **Intel Mac?** Recompile the binary: `cd ~/.claude/hooks && swiftc -framework AppKit -o claude-approve claude-approve.swift`

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
| **Layout** | Panel dimensions, spacing, timing, and sizing constants |
| **Input Parsing** | Reads and deserializes hook JSON from stdin |
| **Session Management** | Auto-approve checks, session/project persistence |
| **Hook Response Output** | JSON response serialization to stdout |
| **Gist Generation** | One-line tool summaries (e.g., `cd && swiftc`) |
| **Syntax Highlighting** | Bash tokenizer + ANSI escape code parser |
| **Diff Engine** | LCS-based unified diff with context collapsing |
| **Content Rendering** | Per-tool attributed string builders |
| **Permission Options** | Tool-specific button generation |
| **Button Layout** | Greedy row-packing algorithm for permission buttons |
| **Content Measurement** | Text height calculation for code block sizing |
| **Focus Management** | SIGUSR1 sibling signaling + Space-switch re-activation |
| **Dialog Construction** | NSPanel layout, button rows, keyboard handling |
| **Result Processing** | Persists approvals, writes hook response |
| **Main Entry Point** | Top-level execution flow |

## Requirements

- **macOS** (tested on macOS 15 Sequoia)
- **Xcode Command Line Tools** (only if building from source)
- **Claude Code** CLI

## License

MIT
