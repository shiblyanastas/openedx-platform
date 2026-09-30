#!/usr/bin/env bash
# OE-002 error-path tests.
#
# Every test asserts the same two things OE-002 item 9 demands of the harness:
# a non-zero exit code AND a readable diagnosis. Tests that invoke
# acceptance.sh redirect its artefacts to a separate directory so a deliberate
# failure can never clobber a real acceptance report.
#
# Usage: test_error_paths.sh [--help]
# Exit:  0 all error paths behaved, 1 at least one did not.

set -uo pipefail

OE002_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Isolate artefacts BEFORE sourcing lib.sh, which derives log/report paths from it.
export OE002_ARTIFACT_DIR="${OE002_ARTIFACT_DIR:-${OE002_SPIKE_ROOT:-/home/shiblyanastas/openedx-spike}/oe002-artifacts-errortests}"
# shellcheck source=mialo/oe002/lib.sh
. "${OE002_HERE}/lib.sh"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"
  exit 0
fi

PASSED=0
FAILED=0

# expect_fail <name> <rc> <log> <regex-that-must-appear>
expect_fail() {
  local name="$1" rc="$2" log="$3" want="$4"
  local found="(none)"
  if [ -n "$log" ] && [ -f "$log" ]; then
    found="$(grep -oE "$want" "$log" 2>/dev/null | head -n1)"
  fi
  if [ "$rc" != "0" ] && [ -n "$found" ]; then
    PASSED=$((PASSED + 1))
    printf '[PASS] %s -- exit=%s diagnosis="%s"\n' "$name" "$rc" "$found"
  else
    FAILED=$((FAILED + 1))
    printf '[FAIL] %s -- exit=%s (expected non-zero) diagnosis-match="%s" (expected /%s/)\n' \
      "$name" "$rc" "$found" "$want" >&2
    if [ -n "$log" ] && [ -f "$log" ]; then
      printf '       log excerpt (%s):\n' "$log" >&2
      oe002::clean "$log" >&2
    fi
  fi
}

# expect_rc <name> <expected-rc> <actual-rc> <note>
expect_rc() {
  local name="$1" want="$2" got="$3" note="$4"
  if [ "$want" = "$got" ]; then
    PASSED=$((PASSED + 1))
    printf '[PASS] %s -- exit=%s %s\n' "$name" "$got" "$note"
  else
    FAILED=$((FAILED + 1))
    printf '[FAIL] %s -- exit=%s, expected %s. %s\n' "$name" "$got" "$want" "$note" >&2
  fi
}

oe002::prepare_artifacts
oe002::require_spike
oe002::ensure_credentials
printf '\nartefacts for these tests: %s\n' "$OE002_ARTIFACT_DIR"

# ---------------------------------------------------------------------------
# E01 invalid course key must be rejected with a readable message
# ---------------------------------------------------------------------------
printf '\n=== E01 force_publish with an invalid course key ===\n'
log="${OE002_LOG_DIR}/e01-invalid-key.log"
oe002::manage_stdin cms "$log" "y" force_publish "not-a-valid-course-key" --commit
expect_fail "E01 invalid-course-key" "$?" "$log" "Invalid course key\."

# ---------------------------------------------------------------------------
# E02 well-formed but nonexistent course must be rejected
# ---------------------------------------------------------------------------
printf '\n=== E02 force_publish with a nonexistent course ===\n'
log="${OE002_LOG_DIR}/e02-missing-course.log"
oe002::manage_stdin cms "$log" "y" force_publish "course-v1:Nope+Nope+Nope" --commit
expect_fail "E02 nonexistent-course" "$?" "$log" "Course not found\."

# ---------------------------------------------------------------------------
# E03 enrolling an unknown learner must fail, not silently succeed
# ---------------------------------------------------------------------------
printf '\n=== E03 enroll_user_in_course with an unknown email ===\n'
log="${OE002_LOG_DIR}/e03-unknown-learner.log"
oe002::manage lms "$log" enroll_user_in_course \
  -e "oe002-nobody-$(date +%s)@example.invalid" -c "$OE002_COURSE_ID"
# Order matters: grep -oE reports the earliest match, and a bare "Traceback"
# would hide the actual reason. The specific message comes first on purpose.
expect_fail "E03 unknown-learner" "$?" "$log" "User matching query does not exist|User\.DoesNotExist"

# ---------------------------------------------------------------------------
# E04 create_course with an unknown author must fail
# ---------------------------------------------------------------------------
printf '\n=== E04 create_course with an unknown author ===\n'
log="${OE002_LOG_DIR}/e04-unknown-author.log"
oe002::manage cms "$log" create_course split "oe002-nobody-$(date +%s)@example.invalid" \
  "$OE002_ORG_SHORT" "OE002ERR" "2026_T1" "OE-002 error path course"
expect_fail "E04 unknown-author" "$?" "$log" "No user .* found\."

# ---------------------------------------------------------------------------
# E05 add_organization rejects a short_name longer than the name
# ---------------------------------------------------------------------------
printf '\n=== E05 add_organization with short_name longer than name ===\n'
log="${OE002_LOG_DIR}/e05-bad-org-args.log"
oe002::manage cms "$log" add_organization "OE002FAR TOOLONGSHORTNAME" "short"
expect_fail "E05 org-arg-order" "$?" "$log" "longer than the provided name"

# ---------------------------------------------------------------------------
# E06 the harness itself must exit non-zero and say why when a check fails
# ---------------------------------------------------------------------------
printf '\n=== E06 acceptance.sh with an injected failure ===\n'
log="${OE002_LOG_DIR}/e06-forced-fail.log"
OE002_FORCE_FAIL=C01 OE002_ARTIFACT_DIR="$OE002_ARTIFACT_DIR" \
  bash "${OE002_HERE}/acceptance.sh" --only C01 >"$log" 2>&1
rc=$?
expect_fail "E06 harness-exits-nonzero" "$rc" "$log" "INJECTED FAILURE"
expect_rc  "E06b harness-exit-code-is-1" 1 "$rc" "forced failure must map to exit 1"

# ---------------------------------------------------------------------------
# E07 spike guard must refuse a foreign compose project
# ---------------------------------------------------------------------------
printf '\n=== E07 spike guard refuses a wrong compose project ===\n'
log="${OE002_LOG_DIR}/e07-wrong-project.log"
OE002_COMPOSE_PROJECT="oe002_project_that_does_not_exist" OE002_ARTIFACT_DIR="$OE002_ARTIFACT_DIR" \
  bash "${OE002_HERE}/acceptance.sh" --only C01 >"$log" 2>&1
rc=$?
expect_fail "E07 wrong-compose-project" "$rc" "$log" "no running 'lms' service|Refusing to guess a target"
expect_rc  "E07b guard-exit-code-is-5" 5 "$rc" "guard refusal must map to exit 5"

# ---------------------------------------------------------------------------
# E08 spike guard must refuse a non-spike LMS URL
# ---------------------------------------------------------------------------
printf '\n=== E08 spike guard refuses a non-spike LMS URL ===\n'
log="${OE002_LOG_DIR}/e08-foreign-url.log"
OE002_LMS_URL="https://example.com" OE002_ARTIFACT_DIR="$OE002_ARTIFACT_DIR" \
  bash "${OE002_HERE}/acceptance.sh" --only C01 >"$log" 2>&1
rc=$?
expect_fail "E08 foreign-lms-url" "$rc" "$log" "rejected by the URL guard"
expect_rc  "E08b guard-exit-code-is-5" 5 "$rc" "guard refusal must map to exit 5"

# Same scheme, foreign host: the refusal must name the expected host exactly.
log="${OE002_LOG_DIR}/e08c-foreign-host.log"
OE002_LMS_URL="http://example.com" OE002_ARTIFACT_DIR="$OE002_ARTIFACT_DIR" \
  bash "${OE002_HERE}/acceptance.sh" --only C01 >"$log" 2>&1
rc=$?
expect_fail "E08c foreign-host" "$rc" "$log" "expected exactly 'local.openedx.io'"

# ---------------------------------------------------------------------------
# E09 a wrong learner password must not authenticate
# ---------------------------------------------------------------------------
printf '\n=== E09 login with a wrong password ===\n'
jar="$(mktemp)"
oe002::login "$jar" "$OE002_LEARNER_EMAIL" "definitely-not-the-password-$(date +%s)"
rc=$?
rm -f "$jar"
if [ "$rc" != "0" ]; then
  PASSED=$((PASSED + 1))
  printf '[PASS] E09 wrong-password-rejected -- oe002::login rc=%s (password never printed)\n' "$rc"
else
  FAILED=$((FAILED + 1))
  printf '[FAIL] E09 wrong-password-rejected -- login SUCCEEDED with a wrong password\n' >&2
fi

# ---------------------------------------------------------------------------
# E10 an endpoint that does not answer 200 must redden C01
# ---------------------------------------------------------------------------
printf '\n=== E10 endpoint answering 404 must redden C01 ===\n'
log="${OE002_LOG_DIR}/e10-non200-endpoint.log"
# Host is canonical so the URL guard passes; only the path is bogus. Studio
# answers a real 404 here -- the MFE would not, it serves its SPA shell with 200
# for any path, so it cannot be used to prove a non-200 is detected.
OE002_CMS_URL="http://${OE002_ALLOWED_CMS_HOST}/oe002-does-not-exist-404" \
  OE002_ARTIFACT_DIR="$OE002_ARTIFACT_DIR" \
  bash "${OE002_HERE}/acceptance.sh" --only C01 >"$log" 2>&1
rc=$?
expect_fail "E10 non-200-endpoint" "$rc" "$log" "returned HTTP 404"

# ---------------------------------------------------------------------------
# E10b an unreachable target must be reported as 000, not as success
# ---------------------------------------------------------------------------
printf '\n=== E10b unreachable target ===\n'
got="$(oe002::http_code "http://127.0.0.1:1/")"
if [ "$got" = "000" ]; then
  PASSED=$((PASSED + 1))
  printf '[PASS] E10b unreachable-target -- oe002::http_code returned %s\n' "$got"
else
  FAILED=$((FAILED + 1))
  printf '[FAIL] E10b unreachable-target -- oe002::http_code returned %s, expected 000\n' "$got" >&2
fi

# ---------------------------------------------------------------------------
# E10c a non-default port is a guard refusal, not an unreachable target
# ---------------------------------------------------------------------------
printf '\n=== E10c non-default port must die in the URL guard ===\n'
log="${OE002_LOG_DIR}/e10c-port.log"
OE002_LMS_URL="http://${OE002_ALLOWED_LMS_HOST}:1" OE002_ARTIFACT_DIR="$OE002_ARTIFACT_DIR" \
  bash "${OE002_HERE}/acceptance.sh" --only C01 >"$log" 2>&1
rc=$?
expect_rc "E10c port-refusal-exit-code" 5 "$rc" "a non-default port must be rejected before any request"
expect_fail "E10c port-refusal-diagnosis" "$rc" "$log" "not the http default|rejected by the URL guard"

# ---------------------------------------------------------------------------
# E11 unknown CLI arguments must be rejected
# ---------------------------------------------------------------------------
printf '\n=== E11 unknown argument ===\n'
log="${OE002_LOG_DIR}/e11-unknown-arg.log"
bash "${OE002_HERE}/acceptance.sh" --nonsense >"$log" 2>&1
expect_fail "E11 unknown-argument" "$?" "$log" "unknown argument"

# ---------------------------------------------------------------------------
printf '\n=== error-path summary ===\n'
printf 'passed: %s   failed: %s\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
