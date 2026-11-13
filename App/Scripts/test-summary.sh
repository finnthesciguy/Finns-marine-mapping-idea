#!/usr/bin/env bash
# Compact summary of an `xcodebuild test` log, at most ~60 lines, for the end of the CI step:
#   - one line per test case: PASS/FAIL/SKIP, name, duration;
#   - each failure's file:line and assertion message (trimmed);
#   - the last map.status values the UI tests printed (GULFNAV-MAP-STATUS lines);
#   - if no test case ran at all, the last error-looking lines instead.
# Usage: test-summary.sh <xcodebuild-test-log> [exit-status]
set -u
log="${1:?usage: test-summary.sh <log> [status]}"
status="${2:-?}"

echo "===== iOS app test summary (xcodebuild exit status: $status) ====="
if [ ! -f "$log" ]; then
  echo "(no test log at $log)"
  exit 0
fi

# Two log formats: "Test Case '-[Module.Class testX]' passed (12.345 seconds)." and (newer xcodebuild)
# "Test case 'Class.testX()' passed on 'Clone 1 of iPhone …' (12.345 seconds)".
cases=$(grep -E "^Test [Cc]ase '.*' (passed|failed|skipped)" "$log" \
  | sed -E "s/^Test [Cc]ase '([^']+)' (passed|failed|skipped) on '[^']*' \(([0-9.]+) seconds\).*/\2 \1 (\3 s)/" \
  | sed -E "s/^Test [Cc]ase '-?\[?([^]' ]+)[ .]([^]' ]+)\]?' (passed|failed|skipped) \(([0-9.]+) seconds\).*/\3 \1.\2 (\4 s)/" \
  | sed -E 's/^passed/PASS/; s/^failed/FAIL/; s/^skipped/SKIP/' \
  | awk '!seen[$0]++')
if [ -n "$cases" ]; then
  echo "--- test cases ($(printf '%s\n' "$cases" | grep -c '^PASS') passed, $(printf '%s\n' "$cases" | grep -c '^FAIL') failed) ---"
  printf '%s\n' "$cases" | head -n 24
else
  echo "--- no test case results in the log ---"
fi

# /path/GulfNavUITests.swift:83: error: -[GulfNavUITests.GulfNavUITests testX] : XCTAssertTrue failed - message
failures=$(grep -E "^[^ ].*\.swift:[0-9]+: error: " "$log" \
  | sed -E 's#^.*/([^/]+\.swift:[0-9]+): error: (-\[[^]]*\] : )?#\1: #' \
  | cut -c1-400 | awk '!seen[$0]++' | head -n 10)
if [ -n "$failures" ]; then
  echo "--- failures ---"
  printf '%s\n' "$failures"
fi

statuses=$(grep -o "GULFNAV-MAP-STATUS .*" "$log" | cut -c1-420 | tail -n 4)
if [ -n "$statuses" ]; then
  echo "--- last map.status values ---"
  printf '%s\n' "$statuses"
fi
appstatuses=$(grep -o "GULFNAV-APP-STATUS .*" "$log" | cut -c1-420 | tail -n 4)
if [ -n "$appstatuses" ]; then
  echo "--- last app.status values ---"
  printf '%s\n' "$appstatuses"
fi

if [ -z "$cases" ]; then
  echo "--- last error lines ---"
  grep -E "error:|Testing failed|\*\* TEST|Failing tests|Early unexpected exit|crash" "$log" | cut -c1-300 | tail -n 12
fi
grep -E "^\*\* TEST .* \*\*$" "$log" | tail -n 1
exit 0
