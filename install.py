#!/usr/bin/env python3
"""Installer for claude-approve hook.

Copies hooks and merges config into settings.json.

Supports two modes:
  - Local: run from a git clone (hooks/ dir exists next to script)
  - Remote: piped via curl (downloads files from GitHub)
"""

import json
import os
import platform
import shutil
import stat
import subprocess
import urllib.error
import urllib.request

# ─── Constants ────────────────────────────────────────────────────────

GITHUB_RAW = "https://raw.githubusercontent.com/rajulbabel/homebrew-claude/main"

HOOK_FILES = [
    "hooks/claude-approve",
    "hooks/claude-approve.swift",
    "hooks/claude-notify",
    "hooks/claude-notify.swift",
    "hooks/claude-stop",
    "hooks/claude-stop.swift",
    "hooks/notify-and-approve.sh",
    "hooks/cleanup-pending.sh",
    "hooks/auto-approve.json",
]

EXECUTABLES = [
    "hooks/claude-approve",
    "hooks/claude-notify",
    "hooks/claude-stop",
    "hooks/notify-and-approve.sh",
    "hooks/cleanup-pending.sh",
]

SWIFT_BINARIES = [
    ("claude-approve.swift", "claude-approve"),
    ("claude-notify.swift", "claude-notify"),
    ("claude-stop.swift", "claude-stop"),
]

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
    "matcher": (
        "Bash|Edit|Write|Read|NotebookEdit"
        "|Task|WebFetch|WebSearch|Glob|Grep"
        "|AskUserQuestion"
    ),
}

STOP_HOOK_ENTRY = {
    "hooks": [
        {
            "command": "~/.claude/hooks/claude-stop",
            "timeout": 15,
            "type": "command",
        }
    ],
}

# ─── Detection ────────────────────────────────────────────────────────


def is_local():
    """Check if running from a local clone.

    Returns True if hooks/ dir exists next to script.
    """
    script_dir = os.path.dirname(os.path.abspath(__file__))
    return os.path.isdir(os.path.join(script_dir, "hooks"))


def needs_recompile():
    """Check if binaries need recompiling (Intel Mac or non-arm64)."""
    return platform.machine() != "arm64"


# ─── Hooks: Local ─────────────────────────────────────────────────────


def copy_hooks_local():
    """Copy hooks from local clone to ~/.claude/hooks/."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    src = os.path.realpath(os.path.join(script_dir, "hooks"))
    dst = os.path.realpath(os.path.join(CLAUDE_DIR, "hooks"))
    if src == dst:
        print(f"Hooks already in place at {dst}/")
        return
    os.makedirs(dst, exist_ok=True)
    for item in os.listdir(src):
        s = os.path.join(src, item)
        d = os.path.join(dst, item)
        if os.path.isdir(s):
            shutil.copytree(s, d, dirs_exist_ok=True)
        else:
            shutil.copy2(s, d)
    print(f"Copied hooks to {dst}/")


# ─── Hooks: Remote ────────────────────────────────────────────────────


def download_hooks_remote():
    """Download hook files from GitHub to ~/.claude/hooks/."""
    dst = os.path.join(CLAUDE_DIR, "hooks")
    os.makedirs(dst, exist_ok=True)
    for rel_path in HOOK_FILES:
        url = f"{GITHUB_RAW}/{rel_path}"
        dest = os.path.join(CLAUDE_DIR, rel_path)
        print(f"  Downloading {rel_path}...")
        try:
            urllib.request.urlretrieve(url, dest)
        except (urllib.error.URLError, OSError) as e:
            print(f"  Failed to download {rel_path}: {e}")
            raise SystemExit(1)
    # Set executable permissions
    for rel_path in EXECUTABLES:
        path = os.path.join(CLAUDE_DIR, rel_path)
        st = os.stat(path)
        os.chmod(path, st.st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    print(f"Downloaded hooks to {dst}/")


# ─── Compilation ──────────────────────────────────────────────────────


def recompile_binaries():
    """Recompile Swift binaries from source for the current architecture."""
    hooks_dir = os.path.join(CLAUDE_DIR, "hooks")
    if shutil.which("swiftc") is None:
        print(
            "\nswiftc not found — install Xcode"
            " Command Line Tools to compile:"
        )
        print("  xcode-select --install")
        print("Then recompile manually:")
        for src, dst in SWIFT_BINARIES:
            print(
                f"  cd {hooks_dir} && swiftc"
                f" -framework AppKit -o {dst} {src}"
            )
        return False
    print("Recompiling binaries for this architecture...")
    for src, dst in SWIFT_BINARIES:
        src_path = os.path.join(hooks_dir, src)
        dst_path = os.path.join(hooks_dir, dst)
        cmd = ["swiftc", "-framework", "AppKit", "-o", dst_path, src_path]
        print(f"  {' '.join(cmd)}")
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"  Error compiling {src}: {result.stderr.strip()}")
            return False
    print("Binaries compiled successfully.")
    return True


# ─── Settings ─────────────────────────────────────────────────────────


def has_claude_approve(settings):
    """Check if settings already has a claude-approve hook."""
    for entry in settings.get("hooks", {}).get("PreToolUse", []):
        for hook in entry.get("hooks", []):
            if "claude-approve" in hook.get("command", ""):
                return True
    return False


def has_claude_stop(settings):
    """Check if settings already has a claude-stop Stop hook."""
    for entry in settings.get("hooks", {}).get("Stop", []):
        for hook in entry.get("hooks", []):
            if "claude-stop" in hook.get("command", ""):
                return True
    return False


def merge_hook_config():
    """Add hook entries to settings.json if not already present."""
    if os.path.exists(SETTINGS):
        try:
            with open(SETTINGS, encoding="utf-8") as f:
                settings = json.load(f)
        except (json.JSONDecodeError, ValueError) as e:
            print(f"Error: {SETTINGS} contains invalid JSON: {e}")
            raise SystemExit(1)
    else:
        print(f"Creating {SETTINGS}")
        settings = {}

    changed = False
    hooks = settings.setdefault("hooks", {})

    if has_claude_approve(settings):
        print(f"PreToolUse hook already configured in {SETTINGS} — skipping")
    else:
        print(f"Adding PreToolUse hook config to {SETTINGS}")
        hooks.setdefault("PreToolUse", []).append(HOOK_ENTRY)
        changed = True

    if has_claude_stop(settings):
        print(f"Stop hook already configured in {SETTINGS} — skipping")
    else:
        print(f"Adding Stop hook config to {SETTINGS}")
        hooks.setdefault("Stop", []).append(STOP_HOOK_ENTRY)
        changed = True

    if changed:
        with open(SETTINGS, "w", encoding="utf-8") as f:
            json.dump(settings, f, indent=2)
            f.write("\n")


# ─── Main ─────────────────────────────────────────────────────────────


def main():
    if is_local():
        print("Installing from local clone...")
        copy_hooks_local()
    else:
        print("Installing from GitHub...")
        download_hooks_remote()
    if needs_recompile():
        if not recompile_binaries():
            print(
                "\nInstalled hooks but compilation"
                " failed — see errors above."
            )
            raise SystemExit(1)
    merge_hook_config()
    print("\nDone! Restart Claude Code for the hook to take effect.")


if __name__ == "__main__":
    main()
