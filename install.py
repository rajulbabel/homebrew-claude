#!/usr/bin/env python3
"""Installer for claude-approve hook. Copies hooks and merges config into settings.json."""

import json
import os
import shutil
import sys

REPO_DIR = os.path.dirname(os.path.abspath(__file__))
CLAUDE_DIR = os.path.expanduser("~/.claude")
SETTINGS = os.path.join(CLAUDE_DIR, "settings.json")

HOOK_ENTRY = {
    "hooks": [
        {
            "command": "~/.claude/hooks/claude-approve",
            "timeout": 600,
            "statusMessage": "Waiting for approval in dialog...",
            "type": "command",
        }
    ],
    "matcher": "Bash|Edit|Write|Read|NotebookEdit|Task|WebFetch|WebSearch|Glob|Grep",
}


def copy_hooks():
    src = os.path.join(REPO_DIR, "hooks")
    dst = os.path.join(CLAUDE_DIR, "hooks")
    os.makedirs(dst, exist_ok=True)
    for item in os.listdir(src):
        s = os.path.join(src, item)
        d = os.path.join(dst, item)
        if os.path.isdir(s):
            shutil.copytree(s, d, dirs_exist_ok=True)
        else:
            shutil.copy2(s, d)
    print(f"Copied hooks to {dst}/")


def has_claude_approve(settings):
    for entry in settings.get("hooks", {}).get("PreToolUse", []):
        for hook in entry.get("hooks", []):
            if "claude-approve" in hook.get("command", ""):
                return True
    return False


def merge_hook_config():
    if os.path.exists(SETTINGS):
        with open(SETTINGS) as f:
            settings = json.load(f)
    else:
        print(f"Creating {SETTINGS}")
        settings = {}

    if has_claude_approve(settings):
        print(f"Hook already configured in {SETTINGS} — skipping")
        return

    print(f"Adding hook config to {SETTINGS}")
    settings.setdefault("hooks", {}).setdefault("PreToolUse", []).append(HOOK_ENTRY)

    with open(SETTINGS, "w") as f:
        json.dump(settings, f, indent=2)


def main():
    copy_hooks()
    merge_hook_config()
    print("\nDone! Restart Claude Code for the hook to take effect.")
    print(
        "\nIntel Mac? Recompile: cd ~/.claude/hooks && swiftc -framework AppKit -o claude-approve claude-approve.swift"
    )


if __name__ == "__main__":
    main()
