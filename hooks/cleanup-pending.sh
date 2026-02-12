#!/bin/bash
# PostToolUse hook: delete marker so dialog knows terminal was answered
INPUT=$(cat)
TOOL_USE_ID=$(echo "$INPUT" | jq -r '.tool_use_id // empty')
rm -f "/tmp/claude-hook-pending/${TOOL_USE_ID:-notfound}" 2>/dev/null
# Also clean up any stale input temp files older than 5 min
find /tmp -name 'claude-hook-input.*' -mmin +5 -delete 2>/dev/null
exit 0
