# .claude

Native macOS permission dialog for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Never miss a permission prompt again — even across multiple sessions and Spaces.

## Why?

Claude Code's permission prompts are **buried in the terminal**. If you run multiple sessions across different Spaces, you won't know which one is waiting for input. You end up babysitting tabs.

This hook replaces those prompts with a **floating macOS dialog** that:

- Pops up **on top of everything** — every Space, every fullscreen app
- Plays a **sound** so you hear it even when not looking
- Shows **syntax-highlighted commands** and **unified diffs**
- Responds with **one click or keystroke**

## Install

**curl (recommended):**

```bash
curl -fsSL https://raw.githubusercontent.com/rajulbabel/.claude/main/install.py | python3
```

**Homebrew:**

```bash
brew install rajulbabel/tap/claude-permit
```

**git clone:**

```bash
git clone git@github.com:rajulbabel/.claude.git /tmp/.claude-hooks && python3 /tmp/.claude-hooks/install.py && rm -rf /tmp/.claude-hooks
```

Restart Claude Code after installing.

> **Intel Mac?** Recompile: `cd ~/.claude/hooks && swiftc -framework AppKit -o claude-approve claude-approve.swift`

## What You Get

| Feature | |
|---------|--|
| Floating panel on every Space | Always visible, never buried |
| Syntax-highlighted commands | Keywords, flags, strings colored |
| Unified diffs for edits | Line numbers, red/green coloring |
| Keyboard shortcuts | `1`/`2`/`3` select, `Enter` accept, `Esc` reject |
| Session memory | Approve once, skip for rest of session |
| Project-level persistence | Save permanent rules per project |
| Multi-dialog queuing | Dialogs appear one at a time, auto-focus |
| Sound notification | Hear it from any app |

## Permission Options

Each dialog shows **tool-specific** buttons matching Claude Code's native prompts:

| Tool | Options |
|------|---------|
| **Bash** | Allow once · Allow `<cmd>` permanently in project · Allow this session |
| **Edit / Write** | Allow once · Allow all edits this session |
| **WebFetch** | Allow once · Allow `<domain>` permanently |
| **WebSearch** | Allow once · Allow permanently |
| **Other** | Allow once · Allow this session |

Approvals are stored per scope:

| Scope | Where |
|-------|-------|
| Once | Not stored |
| Session | `/tmp/claude-hook-sessions/<session_id>` |
| Project | `<project>/.claude/settings.local.json` |

## Customize

**Auto-approve read-only tools** — edit `~/.claude/hooks/auto-approve.json`:

```json
["WebSearch", "WebFetch", "Read", "Grep", "Glob"]
```

These tools skip the dialog entirely. Remove any you want to approve manually.

**Change which tools show the dialog** — edit the `matcher` in `~/.claude/settings.json`:

```json
"matcher": "Bash|Edit|Write|Read|NotebookEdit|Task|WebFetch|WebSearch|Glob|Grep"
```

**Timeout** — dialog auto-denies after `timeout` seconds (default: 600).

## How It Works

```
Claude wants to run a tool
        │
   Auto-approve list? ──── Yes ──→ Allow (no dialog)
        │ No
        ▼
   Session approved? ──── Yes ──→ Allow (no dialog)
        │ No
        ▼
   Show native dialog ──→ User responds ──→ Allow / Deny
```

Uses Claude Code's [PreToolUse hook](https://docs.anthropic.com/en/docs/claude-code/hooks). The installer adds the hook config to your `settings.json` automatically.

## Requirements

- **macOS** (tested on macOS 15 Sequoia)
- **Claude Code** CLI
- **Xcode Command Line Tools** (only if recompiling from source)

## License

MIT
