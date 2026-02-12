#!/bin/bash

# Claude Code PreToolUse hook
# Returns "ask" so terminal shows its NATIVE permission prompt (all real options)
# Launches notification dialog in background to bring attention from any Space

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
TOOL_USE_ID=$(echo "$INPUT" | jq -r '.tool_use_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# --- Marker file (PostToolUse deletes it; dialog polls and auto-closes) ---
MARKER="/tmp/claude-hook-pending/${TOOL_USE_ID:-$$}"
mkdir -p /tmp/claude-hook-pending
touch "$MARKER"

# --- Save input for dialog ---
TMPFILE=$(mktemp /tmp/claude-hook-input.XXXXXX)
echo "$INPUT" > "$TMPFILE"

# --- Detect terminal app ---
TERM_APP="Terminal"
case "${TERM_PROGRAM:-}" in
  iTerm.app)    TERM_APP="iTerm2" ;;
  WarpTerminal) TERM_APP="Warp" ;;
  vscode)       TERM_APP="Code" ;;
  *kitty*)      TERM_APP="kitty" ;;
esac

# --- Launch notification dialog in background ---
~/.claude/hooks/claude-notify "$TMPFILE" "$MARKER" "$TERM_APP" &
disown $! 2>/dev/null

# --- Return "ask" → terminal shows its native permission prompt ---
jq -n '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: "Respond in terminal"
  }
}'
exit 0
