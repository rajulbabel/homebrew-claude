# Claude Notifier

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
curl -fsSL https://raw.githubusercontent.com/rajulbabel/homebrew-claude/main/install.py | python3
```

**Homebrew:**

```bash
brew install rajulbabel/claude/permit
```

**git clone:**

```bash
git clone git@github.com:rajulbabel/homebrew-claude.git /tmp/.claude-hooks && python3 /tmp/.claude-hooks/install.py && rm -rf /tmp/.claude-hooks
```

Restart Claude Code after installing.

> **Intel Mac?** Recompile: `cd ~/.claude/hooks && swiftc -framework AppKit -o claude-approve claude-approve.swift`

## Uninstall

**Homebrew:**

```bash
brew uninstall rajulbabel/claude/permit
```

**curl:**

```bash
curl -fsSL https://raw.githubusercontent.com/rajulbabel/homebrew-claude/main/install.py | python3 - --uninstall
```

**git clone:**

```bash
python3 /path/to/homebrew-claude/install.py --uninstall
```

All three remove the hook binaries from `~/.claude/hooks/` and strip the hook entries from `~/.claude/settings.json`. Restart Claude Code after uninstalling.

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
| Completion notification | "Done" dialog when Claude finishes — auto-dismisses in 15s |
| Question prompts | `AskUserQuestion` pops up natively — one click jumps back to terminal |

## Permission Options

Each dialog shows **tool-specific** buttons matching Claude Code's native prompts:

| Tool | Options |
|------|---------|
| **Bash** | Allow once · Allow `<cmd>` permanently in project · Allow this session |
| **Edit / Write** | Allow once · Allow all edits this session |
| **WebFetch** | Allow once · Allow `<domain>` permanently |
| **WebSearch** | Allow once · Allow permanently |
| **AskUserQuestion** | Go to Terminal (jumps to the terminal that launched Claude) |
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
"matcher": "Bash|Edit|Write|Read|NotebookEdit|Task|WebFetch|WebSearch|Glob|Grep|AskUserQuestion"
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

A **Stop hook** also fires after every completed turn, showing a "Done" notification with the last message summary. It auto-dismisses after 15 seconds, or click "Go to Terminal" to jump straight back to your terminal.

Uses Claude Code's [PreToolUse hook](https://docs.anthropic.com/en/docs/claude-code/hooks) and [Stop hook](https://docs.anthropic.com/en/docs/claude-code/hooks). The installer adds both hook configs to your `settings.json` automatically.

## Requirements

- **macOS** (tested on macOS 15 Sequoia)
- **Claude Code** CLI
- **Xcode Command Line Tools** (only if recompiling from source)

## License

MIT
