#!/bin/bash
#
#  run.sh — Compile and run the full Claude hook test suite.
#
#  Usage:  bash tests/run.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
HOOKS_DIR="$ROOT_DIR/hooks"

echo "=== Claude Hook Test Suite ==="
echo ""

# ── Cleanup stale artifacts ──────────────────────────────────────
echo "Cleaning up stale test artifacts..."
rm -f "$SCRIPT_DIR"/test-approve-bin "$SCRIPT_DIR"/test-stop-bin
rm -rf /tmp/claude-hook-sessions/test-* /tmp/claude-hook-sessions/integration-*
rm -rf /tmp/claude-test-*

# ── Production builds ────────────────────────────────────────────
echo "Building production binaries..."
(cd "$HOOKS_DIR" && swiftc -O -parse-as-library -framework AppKit -o claude-approve claude-approve.swift)
(cd "$HOOKS_DIR" && swiftc -O -parse-as-library -framework AppKit -o claude-stop    claude-stop.swift)
echo "  Production builds OK"
echo ""

# ── Test builds ──────────────────────────────────────────────────
echo "Building test-approve-bin..."
swiftc -D TESTING -parse-as-library -framework AppKit \
    "$HOOKS_DIR/claude-approve.swift" \
    "$SCRIPT_DIR/harness.swift" \
    "$SCRIPT_DIR/test-approve.swift" \
    -o "$SCRIPT_DIR/test-approve-bin"
echo "  test-approve-bin OK"

echo "Building test-stop-bin..."
swiftc -D TESTING -parse-as-library -framework AppKit \
    "$HOOKS_DIR/claude-stop.swift" \
    "$SCRIPT_DIR/harness.swift" \
    "$SCRIPT_DIR/test-stop.swift" \
    -o "$SCRIPT_DIR/test-stop-bin"
echo "  test-stop-bin OK"
echo ""

# ── Run suites ───────────────────────────────────────────────────
FAILURES=0

echo "--- Approve Unit Tests ---"
if "$SCRIPT_DIR/test-approve-bin"; then :; else FAILURES=$((FAILURES + 1)); fi
echo ""

echo "--- Stop Unit Tests ---"
if "$SCRIPT_DIR/test-stop-bin"; then :; else FAILURES=$((FAILURES + 1)); fi
echo ""

echo "--- Integration Tests ---"
if bash "$SCRIPT_DIR/test-integration.sh"; then :; else FAILURES=$((FAILURES + 1)); fi
echo ""

# ── Final cleanup ────────────────────────────────────────────────
echo "Cleaning up test artifacts..."
rm -f "$SCRIPT_DIR"/test-approve-bin "$SCRIPT_DIR"/test-stop-bin
rm -rf /tmp/claude-hook-sessions/test-* /tmp/claude-hook-sessions/integration-*
rm -rf /tmp/claude-test-*

echo ""
if [ "$FAILURES" -gt 0 ]; then
    echo "=== $FAILURES test suite(s) FAILED ==="
    exit 1
else
    echo "=== All test suites passed ==="
    exit 0
fi
