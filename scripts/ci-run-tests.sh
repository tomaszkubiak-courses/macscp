#!/bin/bash
set -uo pipefail
swift build --build-tests >/dev/null || exit 1
LOG=$(mktemp)
stdbuf -oL -eL swift test --skip-build --disable-swift-testing "$@" > >(tee "$LOG") 2>&1 &
PID=$!
while kill -0 $PID 2>/dev/null; do
  if grep -qE "Test Suite '(All|Selected) tests' (passed|failed) at" "$LOG"; then
    sleep 15
    if kill -0 $PID 2>/dev/null; then
      XCTEST=$(pgrep -f '\.xctest' | head -1)
      echo "=== test process still running after the summary; backtrace of ${XCTEST:-?} ==="
      [ -n "$XCTEST" ] && command -v gdb >/dev/null && gdb -p "$XCTEST" -batch -ex 'thread apply all bt' 2>&1 | grep -E '^Thread|^#' | head -150
      kill -9 $PID $XCTEST 2>/dev/null
    fi
    break
  fi
  sleep 2
done
wait $PID 2>/dev/null
grep -qE "Test Suite '(All|Selected) tests' passed" "$LOG"
