#!/usr/bin/env bash
# mayhem/test.sh — RUN upstream's Qt-free libdxfrw Catch2 lane (built by build.sh, normal flags); never compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


# The Catch2 runner asserts parsed/encoded values for DXF + DWG (round trips, golden fields, framing). A
# neutered or missing runner prints no summary line, so it fails loudly instead of "passing".
BIN="$SRC/build/tests/libdxfrw_fast_tests"
if [ ! -x "$BIN" ]; then echo "missing test runner $BIN (build.sh bug)" >&2; emit_ctrf "catch2-libdxfrw" 0 1 0; exit $?; fi
out="$("$BIN" 2>&1)"; rc=$?
printf '%s\n' "$out" | tail -n 40

if printf '%s\n' "$out" | grep -q '^All tests passed'; then
  total=$(printf '%s\n' "$out" | sed -n 's/.* in \([0-9][0-9]*\) test case.*/\1/p' | tail -n1)
  passed=${total:-0}; failed=0; skipped=0
else
  line=$(printf '%s\n' "$out" | grep -E '^test cases:' | tail -n1)
  if [ -z "$line" ]; then echo "FAIL: no Catch2 summary (rc=$rc)" >&2; emit_ctrf "catch2-libdxfrw" 0 1 0; exit $?; fi
  passed=$(printf '%s' "$line"  | sed -n 's/.*| *\([0-9][0-9]*\) passed.*/\1/p');  passed=${passed:-0}
  failed=$(printf '%s' "$line"  | sed -n 's/.*| *\([0-9][0-9]*\) failed.*/\1/p');  failed=${failed:-0}
  skipped=$(printf '%s' "$line" | sed -n 's/.*| *\([0-9][0-9]*\) skipped.*/\1/p'); skipped=${skipped:-0}
fi
if [ "$rc" -ne 0 ] && [ "$failed" -eq 0 ]; then failed=1; fi
if [ "$passed" -lt 100 ]; then echo "FAIL: only $passed Catch2 cases passed (expected >=100)" >&2; failed=$((failed + 1)); fi
emit_ctrf "catch2-libdxfrw" "$passed" "$failed" "$skipped"
