#!/usr/bin/env bash
# OE-002 idempotency test.
#
# Proves the two halves of OE-002 item 8 that a single acceptance run cannot:
#   * from a clean slate the path CREATES every entity exactly once, and
#   * a second run REUSES them and creates no duplicates.
#
# It does that by tearing the entities down first, so the create path is really
# exercised instead of only the reuse path.
#
# Usage: test_idempotency.sh [--help]
# Exit:  0 both halves proved, 1 an assertion failed, 3-5 environment failure.

set -uo pipefail

OE002_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mialo/oe002/lib.sh
. "${OE002_HERE}/lib.sh"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"
  exit 0
fi

IDEM_ROOT="${OE002_SPIKE_ROOT}/oe002-artifacts-idempotency"
RUN_A_DIR="${IDEM_ROOT}/run-a"
RUN_B_DIR="${IDEM_ROOT}/run-b"
mkdir -p "$RUN_A_DIR" "$RUN_B_DIR" || oe002::die 3 "cannot create ${IDEM_ROOT}"

PASSED=0
FAILED=0

assert_eq() {  # <name> <want> <got>
  if [ "$2" = "$3" ]; then
    PASSED=$((PASSED + 1)); printf '[PASS] %s -- %s\n' "$1" "$3"
  else
    FAILED=$((FAILED + 1)); printf '[FAIL] %s -- expected "%s", got "%s"\n' "$1" "$2" "$3" >&2
  fi
}

assert_grep() {  # <name> <file> <regex>
  if [ -f "$2" ] && grep -qE "$3" "$2"; then
    PASSED=$((PASSED + 1))
    printf '[PASS] %s -- found /%s/\n' "$1" "$3"
  else
    FAILED=$((FAILED + 1))
    printf '[FAIL] %s -- /%s/ not found in %s\n' "$1" "$3" "$2" >&2
  fi
}

# assert_line <name> <file> <literal whole line>
# Fixed-string, whole-line match. Course ids contain '+', which is a quantifier
# under grep -E and silently stops matching -- this helper cannot be fooled by it.
assert_line() {
  if [ -f "$2" ] && grep -qxF "$3" "$2"; then
    PASSED=$((PASSED + 1))
    printf '[PASS] %s -- exact line "%s"\n' "$1" "$3"
  else
    FAILED=$((FAILED + 1))
    printf '[FAIL] %s -- exact line "%s" not found in %s\n' "$1" "$3" "$2" >&2
  fi
}

# counts_into <file>   -- entity counts, normalised to KEY=N lines
counts_into() { oe002::entity_counts | sort > "$1"; }

# ---------------------------------------------------------------------------
oe002::prepare_artifacts
oe002::require_spike
oe002::ensure_credentials

oe002::step "step 0: tear down to a clean slate"
bash "${OE002_HERE}/teardown.sh" --apply >"${IDEM_ROOT}/teardown.log" 2>&1
rc=$?
assert_eq "teardown-exit-code" "0" "$rc"
counts_into "${IDEM_ROOT}/counts-clean.txt"
nonzero="$(grep -vE '^[A-Z_]+=0$' "${IDEM_ROOT}/counts-clean.txt" || true)"
assert_eq "slate-is-clean" "" "$nonzero"

oe002::step "step 1: acceptance run A (create path)"
OE002_ARTIFACT_DIR="$RUN_A_DIR" bash "${OE002_HERE}/acceptance.sh" >"${RUN_A_DIR}/run.log" 2>&1
rc_a=$?
assert_eq "run-A-exit-code" "0" "$rc_a"
counts_into "${IDEM_ROOT}/counts-a.txt"

# Run A must have really created the course and the learner, not reused them.
assert_line "run-A-created-course" "${RUN_A_DIR}/logs/c02-create-course.log" \
  "Created ${OE002_COURSE_ID}"
assert_line "run-A-created-learner" "${RUN_A_DIR}/logs/c04-create-learner.log" \
  "Created user ${OE002_LEARNER_USERNAME}"
assert_grep "run-A-published-now" "${RUN_A_DIR}/logs/c03-force-publish.log" \
  "Success! Published the course"
assert_grep "run-A-enrollment-activated" "${RUN_A_DIR}/logs/c05-enroll.log" \
  "edx\.course\.enrollment\.activated"

# Every entity exactly once. COURSE_ENROLLMENTS is 2 because create_course also
# enrolls the author as instructor.
for pair in ORG=1 COURSE=1 STAFF_NAME=1 STAFF_MAIL=1 LEARNER_NAME=1 \
            LEARNER_MAIL=1 ENROLLMENT=1 COURSE_ENROLLMENTS=2; do
  key="${pair%%=*}"; want="${pair#*=}"
  got="$(sed -n "s/^${key}=//p" "${IDEM_ROOT}/counts-a.txt")"
  assert_eq "run-A-count-${key}" "$want" "${got:-<absent>}"
done

oe002::step "step 2: acceptance run B (reuse path)"
OE002_ARTIFACT_DIR="$RUN_B_DIR" bash "${OE002_HERE}/acceptance.sh" >"${RUN_B_DIR}/run.log" 2>&1
rc_b=$?
assert_eq "run-B-exit-code" "0" "$rc_b"
counts_into "${IDEM_ROOT}/counts-b.txt"

assert_grep "run-B-reused-course" "${RUN_B_DIR}/logs/c02-create-course.log" \
  "Course already exists"
assert_grep "run-B-reused-learner" "${RUN_B_DIR}/logs/c04-create-learner.log" \
  "Test user ${OE002_LEARNER_USERNAME} already exists"
assert_grep "run-B-already-published" "${RUN_B_DIR}/logs/c03-force-publish.log" \
  "already in published state"

oe002::step "step 3: counts must be byte-identical after the second run"
if diff -u "${IDEM_ROOT}/counts-a.txt" "${IDEM_ROOT}/counts-b.txt" >"${IDEM_ROOT}/counts.diff" 2>&1; then
  PASSED=$((PASSED + 1))
  printf '[PASS] counts-unchanged-between-runs\n'
else
  FAILED=$((FAILED + 1))
  printf '[FAIL] counts-unchanged-between-runs -- difference:\n' >&2
  cat "${IDEM_ROOT}/counts.diff" >&2
fi

# ---------------------------------------------------------------------------
oe002::step "idempotency summary"
printf 'passed: %s   failed: %s\n' "$PASSED" "$FAILED"
printf 'counts after run A:\n'; cat "${IDEM_ROOT}/counts-a.txt"
printf 'counts after run B:\n'; cat "${IDEM_ROOT}/counts-b.txt"

python3 - "${IDEM_ROOT}/idempotency-report.json" "$PASSED" "$FAILED" \
          "${IDEM_ROOT}/counts-a.txt" "${IDEM_ROOT}/counts-b.txt" <<'PY'
import json, sys, time
out, passed, failed, ca, cb = sys.argv[1:6]


def counts(path):
    result = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if "=" in line:
                k, v = line.split("=", 1)
                result[k] = int(v)
    return result


with open(out, "w", encoding="utf-8") as fh:
    json.dump({
        "schema": "oe002-idempotency-report/v1",
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "passed": int(passed),
        "failed": int(failed),
        "counts_after_run_a": counts(ca),
        "counts_after_run_b": counts(cb),
        "identical": counts(ca) == counts(cb),
    }, fh, indent=2)
    fh.write("\n")
print(out)
PY

[ "$FAILED" -eq 0 ] || exit 1
exit 0
