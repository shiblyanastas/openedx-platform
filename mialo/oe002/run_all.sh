#!/usr/bin/env bash
# OE-002 -- run the whole acceptance batch and produce one combined summary.
#
# Order matters: the plain acceptance run proves the current state, the error
# paths prove failure behaviour, and the idempotency test runs last because it
# tears the entities down and recreates them, leaving the spike in the accepted
# state.
#
# Usage: run_all.sh [--help]
# Exit:  0 every stage passed, 1 a stage failed.

set -uo pipefail

OE002_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mialo/oe002/lib.sh
. "${OE002_HERE}/lib.sh"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"
  exit 0
fi

BATCH_DIR="${OE002_SPIKE_ROOT}/oe002-artifacts-batch"
oe002::require_outside_vcs "OE002_SPIKE_ROOT (batch artefacts)" "$BATCH_DIR"
mkdir -p "$BATCH_DIR" || oe002::die 3 "cannot create ${BATCH_DIR}"

oe002::require_docker
# Fingerprints, not names: a stop+start or a replacement under the same name
# leaves a name list identical, so names alone cannot support the claim that the
# pre-existing MIALO services were left alone.
FOREIGN_BEFORE="$(oe002::foreign_fingerprint)"
PROTECTED_BEFORE="$(oe002::protected_fingerprint)"
SPIKE_BEFORE="$(docker ps --format '{{.Names}}' --filter "label=com.docker.compose.project=${OE002_COMPOSE_PROJECT}" | sort)"
printf '%s\n' "$FOREIGN_BEFORE" >"${BATCH_DIR}/foreign-fingerprint-before.txt"
printf '%s\n' "$PROTECTED_BEFORE" >"${BATCH_DIR}/protected-fingerprint-before.txt"
printf '%s\n' "$SPIKE_BEFORE" >"${BATCH_DIR}/spike-containers-before.txt"

STAGE_RC=()
run_stage() {  # <name> <script> [args...]
  local name="$1" script="$2"; shift 2
  local log="${BATCH_DIR}/${name}.log"
  oe002::step "STAGE ${name}"
  printf 'log: %s\n' "$log"
  local start end rc
  start=$(date +%s)
  bash "${OE002_HERE}/${script}" "$@" >"$log" 2>&1
  rc=$?
  end=$(date +%s)
  STAGE_RC+=("${name}=${rc}")
  if [ "$rc" = "0" ]; then
    printf '[PASS] stage %s -- exit 0 in %ss\n' "$name" "$((end - start))"
  else
    printf '[FAIL] stage %s -- exit %s after %ss\n' "$name" "$rc" "$((end - start))" >&2
    printf '       last 30 lines of %s:\n' "$log" >&2
    tail -n 30 "$log" >&2
  fi
  return 0
}

run_stage acceptance      acceptance.sh
run_stage error-paths     test_error_paths.sh
run_stage review-findings test_review_findings.sh
run_stage idempotency     test_idempotency.sh

oe002::step "container isolation check"
FOREIGN_AFTER="$(oe002::foreign_fingerprint)"
PROTECTED_AFTER="$(oe002::protected_fingerprint)"
SPIKE_AFTER="$(docker ps --format '{{.Names}}' --filter "label=com.docker.compose.project=${OE002_COMPOSE_PROJECT}" | sort)"
printf '%s\n' "$FOREIGN_AFTER" >"${BATCH_DIR}/foreign-fingerprint-after.txt"
printf '%s\n' "$PROTECTED_AFTER" >"${BATCH_DIR}/protected-fingerprint-after.txt"
printf '%s\n' "$SPIKE_AFTER" >"${BATCH_DIR}/spike-containers-after.txt"

ISOLATION_OK=1

# The claim under test is "the pre-existing MIALO services were left alone", so
# that is what is asserted: every protected container must still be running with
# an identical Id, StartedAt, RestartCount and Status.
if n_protected="$(oe002::require_protected_baseline "$PROTECTED_BEFORE" 2>&1)"; then
  if problems="$(oe002::protected_changed "$PROTECTED_BEFORE" "$PROTECTED_AFTER")"; then
    printf '[PASS] pre-existing MIALO containers unchanged (%s container(s), compared by id+startedAt+restartCount+status)\n' \
      "$n_protected"
  else
    ISOLATION_OK=0
    printf '[FAIL] a pre-existing MIALO container was stopped, restarted or replaced:\n%s\n' "$problems" >&2
  fi
else
  ISOLATION_OK=0
  printf '[FAIL] %s\n' "$n_protected" >&2
fi

# Everything else that is not part of the spike project is evidence, not an
# assertion: unrelated short-lived jobs start and finish on a shared host and
# this harness performs no container mutation whatsoever.
if oe002::fingerprints_match "$FOREIGN_BEFORE" "$FOREIGN_AFTER" >/dev/null 2>&1; then
  printf '[PASS] full non-spike container set also unchanged (%s container(s))\n' \
    "$(printf '%s' "$FOREIGN_BEFORE" | grep -c . || true)"
else
  printf '[NOTE] non-protected containers changed during the batch (informational, not a violation):\n'
  oe002::fingerprint_diff "$FOREIGN_BEFORE" "$FOREIGN_AFTER"
fi

if [ "$SPIKE_BEFORE" = "$SPIKE_AFTER" ]; then
  printf '[PASS] spike containers still all running (%s)\n' \
    "$(printf '%s' "$SPIKE_BEFORE" | grep -c . || true)"
else
  ISOLATION_OK=0
  printf '[FAIL] the set of running spike containers changed\n' >&2
  diff -u "${BATCH_DIR}/spike-containers-before.txt" "${BATCH_DIR}/spike-containers-after.txt" >&2 || true
fi

oe002::step "batch summary"
printf 'stages: %s\n' "${STAGE_RC[*]}"
printf 'container isolation: %s\n' "$([ "$ISOLATION_OK" = "1" ] && printf 'OK' || printf 'VIOLATED')"

batch_rc=0
for entry in "${STAGE_RC[@]}"; do
  [ "${entry#*=}" = "0" ] || batch_rc=1
done
[ "$ISOLATION_OK" = "1" ] || batch_rc=1

python3 - "${BATCH_DIR}/batch-summary.json" "$batch_rc" "${STAGE_RC[*]}" "$ISOLATION_OK" <<'PY'
import json, sys, time
out, rc, stages, isolation = sys.argv[1:5]
parsed = {}
for entry in stages.split():
    if "=" in entry:
        k, v = entry.split("=", 1)
        parsed[k] = int(v)
with open(out, "w", encoding="utf-8") as fh:
    json.dump({
        "schema": "oe002-batch-summary/v1",
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "exit_code": int(rc),
        "stages": parsed,
        "container_isolation_ok": isolation == "1",
    }, fh, indent=2)
    fh.write("\n")
print(out)
PY

exit "$batch_rc"
