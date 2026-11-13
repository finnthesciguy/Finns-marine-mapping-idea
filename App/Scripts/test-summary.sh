#!/usr/bin/env bash
# Compact summary of an `xcodebuild test` log, at most ~60 lines, for the end of the CI step:
#   - one line per test case: PASS/FAIL/SKIP, name, duration;
#   - each failure's file:line and assertion message (trimmed);
#   - map.status / app.status values the UI tests printed (GULFNAV-MAP-STATUS / GULFNAV-APP-STATUS lines):
#     those printed at a timeout (failing waits) first, then the last ones; long lines are wrapped, never cut;
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
  printf '%s\n' "$cases" | head -n 30
else
  echo "--- no test case results in the log ---"
fi

# /path/GulfNavUITests.swift:83: error: -[GulfNavUITests.GulfNavUITests testX] : XCTAssertTrue failed - message
failures=$(grep -E "^[^ ].*\.swift:[0-9]+: error: " "$log" \
  | sed -E 's#^.*/([^/]+\.swift:[0-9]+): error: (-\[[^]]*\] : )?#\1: #' \
  | cut -c1-2000 | awk '!seen[$0]++' | head -n 10)
if [ -n "$failures" ]; then
  echo "--- failures ---"
  printf '%s\n' "$failures" | fold -w 200
fi

# Status lines printed at a timeout belong to failing waits: show those first (up to 4), then the last ones.
for kind in MAP APP; do
  name=$( [ "$kind" = MAP ] && echo map.status || echo app.status )
  timeouts=$(grep -o "GULFNAV-$kind-STATUS \[timeout\].*" "$log" | awk '!seen[$0]++' | tail -n 4)
  last=$(grep -o "GULFNAV-$kind-STATUS .*" "$log" | grep -v "\[timeout\]" | tail -n 2)
  if [ -n "$timeouts" ]; then
    echo "--- $name at timeouts (failing waits) ---"
    printf '%s\n' "$timeouts" | cut -c1-2000 | fold -w 200
  fi
  if [ -n "$last" ]; then
    echo "--- last $name values ---"
    printf '%s\n' "$last" | cut -c1-2000 | fold -w 200
  fi
done

if [ -z "$cases" ]; then
  echo "--- last error lines ---"
  grep -E "error:|Testing failed|\*\* TEST|Failing tests|Early unexpected exit|crash" "$log" | cut -c1-300 | tail -n 12
fi
grep -E "^\*\* TEST .* \*\*$" "$log" | tail -n 1
exit 0
