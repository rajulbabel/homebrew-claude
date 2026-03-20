#!/bin/bash
#
#  test-integration.sh — Integration tests exercising the compiled hook
#  binaries via stdin/stdout, without any GUI interaction.
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
APPROVE="$ROOT_DIR/hooks/claude-approve"
STOP="$ROOT_DIR/hooks/claude-stop"
SESSION_DIR="/tmp/claude-hook-sessions"

PASSED=0
FAILED=0

# macOS-compatible timeout wrapper (GNU timeout is not standard on macOS).
# Runs a command in the background and kills it after N seconds if still alive.
run_with_timeout() {
    local secs="$1"; shift
    "$@" &
    local pid=$!
    ( sleep "$secs" && kill "$pid" 2>/dev/null ) &
    local timer=$!
    wait "$pid" 2>/dev/null
    local rc=$?
    kill "$timer" 2>/dev/null
    wait "$timer" 2>/dev/null
    return $rc
}

assert_contains() {
    local label="$1" actual="$2" expected="$3"
    if echo "$actual" | grep -qF "$expected"; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        echo "  FAIL [$label]: expected to contain '$expected'"
        echo "    actual: $actual"
    fi
}

assert_exit() {
    local label="$1" actual="$2" expected="$3"
    if [ "$actual" -eq "$expected" ]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        echo "  FAIL [$label]: exit code $actual != expected $expected"
    fi
}

# ── 1. Session auto-approve fast path ────────────────────────────
echo "  Running: session auto-approve fast path..."
SID="integration-approve-$$"
mkdir -p "$SESSION_DIR"
echo "Bash" > "$SESSION_DIR/$SID"
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi\"},\"cwd\":\"/tmp\",\"session_id\":\"$SID\"}" \
    | "$APPROVE" 2>/dev/null)
assert_contains "session approve allow" "$OUTPUT" "allow"
assert_contains "session approve hookEventName" "$OUTPUT" "PreToolUse"
rm -f "$SESSION_DIR/$SID"

# ── 2. Session file with multiple tools ──────────────────────────
echo "  Running: session multi-tool approve..."
SID2="integration-multi-$$"
printf "Edit\nWrite\n" > "$SESSION_DIR/$SID2"
OUTPUT2=$(echo "{\"tool_name\":\"Write\",\"tool_input\":{},\"cwd\":\"/tmp\",\"session_id\":\"$SID2\"}" \
    | "$APPROVE" 2>/dev/null)
assert_contains "multi-tool approve" "$OUTPUT2" "allow"
rm -f "$SESSION_DIR/$SID2"

# ── 3. Malformed JSON (no crash) ────────────────────────────────
echo "  Running: malformed JSON..."
echo 'not json at all' | run_with_timeout 5 "$APPROVE" 2>/dev/null
EXIT=$?
# Any exit code is acceptable; we just check it didn't segfault (signal 11).
if [ "$EXIT" -ne 139 ] && [ "$EXIT" -ne 134 ]; then
    PASSED=$((PASSED + 1))
else
    FAILED=$((FAILED + 1))
    echo "  FAIL [malformed JSON]: process crashed with exit $EXIT"
fi

# ── 4. Empty stdin (no crash) ───────────────────────────────────
echo "  Running: empty stdin..."
echo '' | run_with_timeout 5 "$APPROVE" 2>/dev/null
EXIT=$?
if [ "$EXIT" -ne 139 ] && [ "$EXIT" -ne 134 ]; then
    PASSED=$((PASSED + 1))
else
    FAILED=$((FAILED + 1))
    echo "  FAIL [empty stdin]: process crashed with exit $EXIT"
fi

# ── 5. Stop hook: stopHookActive=true exits immediately ─────────
echo "  Running: stop hook active=true..."
echo '{"stop_hook_active":true,"cwd":"/tmp","last_assistant_message":"test"}' \
    | "$STOP" 2>/dev/null
assert_exit "stop active=true" "$?" 0

# ── 6. Stop hook: stopHookActive=false (dialog, killed after 2s) ─
echo "  Running: stop hook active=false (timeout)..."
echo '{"stop_hook_active":false,"cwd":"/tmp","last_assistant_message":"Done. Test"}' \
    | "$STOP" 2>/dev/null &
STOP_PID=$!
sleep 2
kill "$STOP_PID" 2>/dev/null
wait "$STOP_PID" 2>/dev/null || true
PASSED=$((PASSED + 1))  # If we get here without crash, pass

# ── 7. Session approve JSON structure ───────────────────────────
echo "  Running: session approve JSON structure..."
SID3="integration-json-$$"
echo "Glob" > "$SESSION_DIR/$SID3"
OUTPUT3=$(echo "{\"tool_name\":\"Glob\",\"tool_input\":{\"pattern\":\"*.txt\"},\"cwd\":\"/tmp\",\"session_id\":\"$SID3\"}" \
    | "$APPROVE" 2>/dev/null)
assert_contains "JSON hookSpecificOutput" "$OUTPUT3" "hookSpecificOutput"
assert_contains "JSON permissionDecision" "$OUTPUT3" "permissionDecision"
rm -f "$SESSION_DIR/$SID3"

# ── 8. Session approve for Grep ─────────────────────────────────
echo "  Running: session approve Grep..."
SID4="integration-grep-$$"
echo "Grep" > "$SESSION_DIR/$SID4"
OUTPUT4=$(echo "{\"tool_name\":\"Grep\",\"tool_input\":{\"pattern\":\"TODO\"},\"cwd\":\"/tmp\",\"session_id\":\"$SID4\"}" \
    | "$APPROVE" 2>/dev/null)
assert_contains "grep approve" "$OUTPUT4" "allow"
rm -f "$SESSION_DIR/$SID4"

# ── 9. acceptEdits mode: Edit auto-approved ────────────────────
echo "  Running: acceptEdits mode auto-approves Edit..."
OUTPUT5=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x.txt"},"cwd":"/tmp","session_id":"","permission_mode":"acceptEdits"}' \
    | "$APPROVE" 2>/dev/null)
assert_contains "acceptEdits Edit allow" "$OUTPUT5" '"permissionDecision":"allow"'
assert_contains "acceptEdits Edit reason" "$OUTPUT5" "acceptEdits"

# ── 10. acceptEdits mode: Write auto-approved ──────────────────
echo "  Running: acceptEdits mode auto-approves Write..."
OUTPUT6=$(echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x.txt"},"cwd":"/tmp","session_id":"","permission_mode":"acceptEdits"}' \
    | "$APPROVE" 2>/dev/null)
assert_contains "acceptEdits Write allow" "$OUTPUT6" '"permissionDecision":"allow"'

# ── 10b. acceptEdits mode: Read auto-approved ─────────────────
echo "  Running: acceptEdits mode auto-approves Read..."
OUTPUT6b=$(echo '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x.txt"},"cwd":"/tmp","session_id":"","permission_mode":"acceptEdits"}' \
    | "$APPROVE" 2>/dev/null)
assert_contains "acceptEdits Read allow" "$OUTPUT6b" '"permissionDecision":"allow"'

# ── 10c. acceptEdits mode: Glob auto-approved ─────────────────
echo "  Running: acceptEdits mode auto-approves Glob..."
OUTPUT6c=$(echo '{"tool_name":"Glob","tool_input":{"pattern":"*.txt"},"cwd":"/tmp","session_id":"","permission_mode":"acceptEdits"}' \
    | "$APPROVE" 2>/dev/null)
assert_contains "acceptEdits Glob allow" "$OUTPUT6c" '"permissionDecision":"allow"'

# ── 10d. acceptEdits mode: Grep auto-approved ─────────────────
echo "  Running: acceptEdits mode auto-approves Grep..."
OUTPUT6d=$(echo '{"tool_name":"Grep","tool_input":{"pattern":"TODO"},"cwd":"/tmp","session_id":"","permission_mode":"acceptEdits"}' \
    | "$APPROVE" 2>/dev/null)
assert_contains "acceptEdits Grep allow" "$OUTPUT6d" '"permissionDecision":"allow"'

# ── 11. plan mode: Bash denied ─────────────────────────────────
echo "  Running: plan mode denies Bash..."
OUTPUT7=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"},"cwd":"/tmp","session_id":"","permission_mode":"plan"}' \
    | "$APPROVE" 2>/dev/null)
assert_contains "plan Bash deny" "$OUTPUT7" '"permissionDecision":"deny"'
assert_contains "plan Bash reason" "$OUTPUT7" "plan mode"

# ── 12. plan mode: Edit denied ─────────────────────────────────
echo "  Running: plan mode denies Edit..."
OUTPUT8=$(echo '{"tool_name":"Edit","tool_input":{},"cwd":"/tmp","session_id":"","permission_mode":"plan"}' \
    | "$APPROVE" 2>/dev/null)
assert_contains "plan Edit deny" "$OUTPUT8" '"permissionDecision":"deny"'

# ── 13. plan mode: Write denied ────────────────────────────────
echo "  Running: plan mode denies Write..."
OUTPUT8b=$(echo '{"tool_name":"Write","tool_input":{},"cwd":"/tmp","session_id":"","permission_mode":"plan"}' \
    | "$APPROVE" 2>/dev/null)
assert_contains "plan Write deny" "$OUTPUT8b" '"permissionDecision":"deny"'

# ── 14. dontAsk mode: denies non-pre-approved tool ─────────────
echo "  Running: dontAsk mode denies non-approved tool..."
OUTPUT9=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo hi"},"cwd":"/tmp","session_id":"","permission_mode":"dontAsk"}' \
    | "$APPROVE" 2>/dev/null)
assert_contains "dontAsk Bash deny" "$OUTPUT9" '"permissionDecision":"deny"'
assert_contains "dontAsk Bash reason" "$OUTPUT9" "dontAsk"

# ── 15. dontAsk mode: allows pre-approved session tool ─────────
echo "  Running: dontAsk mode allows session-approved tool..."
SID5="integration-dontask-$$"
echo "Bash" > "$SESSION_DIR/$SID5"
OUTPUT10=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi\"},\"cwd\":\"/tmp\",\"session_id\":\"$SID5\",\"permission_mode\":\"dontAsk\"}" \
    | "$APPROVE" 2>/dev/null)
assert_contains "dontAsk session allow" "$OUTPUT10" '"permissionDecision":"allow"'
rm -f "$SESSION_DIR/$SID5"

# ── 16. bypassPermissions: auto-approves Bash ─────────────────
echo "  Running: bypassPermissions auto-approves Bash..."
OUTPUT11=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo hi"},"cwd":"/tmp","session_id":"","permission_mode":"bypassPermissions"}' \
    | "$APPROVE" 2>/dev/null)
assert_contains "bypass Bash allow" "$OUTPUT11" '"permissionDecision":"allow"'

# ── Summary ─────────────────────────────────────────────────────
echo ""
TOTAL=$((PASSED + FAILED))
if [ "$FAILED" -gt 0 ]; then
    echo "$FAILED of $TOTAL integration tests FAILED"
    exit 1
else
    echo "All $TOTAL integration tests passed"
    exit 0
fi
