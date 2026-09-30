#!/usr/bin/env bash
# OE-002 -- reproducible local Open edX acceptance path.
#
# Proves, against the isolated MIALO Open edX spike and nothing else, that a
# test organisation, a test course, a publish, a test learner, an enrollment and
# an independent read-back of that enrollment all work and are idempotent.
#
# Usage:
#   acceptance.sh                 run all ten checks
#   acceptance.sh --only C01      run a single check (diagnostics / error tests)
#   acceptance.sh --list          list check ids and exit
#
# Exit codes:
#   0  every selected check PASSed
#   1  at least one selected check FAILed
#   2  bad usage
#   3  artefact/credential directory problem
#   4  docker unavailable
#   5  spike guard refused the target (see OE-002 item 10)
#   6  a credentials or artefact path lies inside a version-control worktree
#
# Set OE002_FORCE_FAIL=<check-id> to inject a synthetic failure; that is how
# test_error_paths.sh proves the harness itself exits non-zero with a diagnosis.

set -uo pipefail

OE002_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mialo/oe002/lib.sh
. "${OE002_HERE}/lib.sh"

OE002_ALL_CHECKS=(C01 C02 C03 C04 C05 C06 C07 C08 C09 C10)
OE002_SELECTED=("${OE002_ALL_CHECKS[@]}")
FAILED=0
COOKIE_JAR=""
FOREIGN_BEFORE=""
PROTECTED_BEFORE=""

# Print the leading comment block, whatever its length -- a fixed line range
# silently rots as soon as the header is edited.
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list)
      printf '%s\n' "${OE002_ALL_CHECKS[@]}"
      exit 0
      ;;
    --only)
      [ $# -ge 2 ] || { printf 'OE-002 FATAL: --only needs a check id\n' >&2; exit 2; }
      case " ${OE002_ALL_CHECKS[*]} " in
        *" $2 "*) OE002_SELECTED=("$2") ;;
        *) printf 'OE-002 FATAL: unknown check id %s (known: %s)\n' "$2" "${OE002_ALL_CHECKS[*]}" >&2; exit 2 ;;
      esac
      shift 2
      ;;
    *) printf 'OE-002 FATAL: unknown argument %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
done

cleanup() {
  if [ -n "$COOKIE_JAR" ] && [ -f "$COOKIE_JAR" ]; then rm -f "$COOKIE_JAR"; fi
  return 0
}
trap cleanup EXIT

# force_fail <check-id> -- true when the operator injected a synthetic failure
force_fail() { [ "${OE002_FORCE_FAIL:-}" = "$1" ]; }

# finish <id> <requirement> <name> <ok:0|1> <detail>
# Single place where a check becomes a recorded result, so the injected-failure
# path and the real path cannot diverge.
finish() {
  local id="$1" req="$2" name="$3" ok="$4" detail="$5"
  local secs status
  secs="$(oe002::timer_end)"
  if force_fail "$id"; then
    status="FAIL"
    detail="INJECTED FAILURE (OE002_FORCE_FAIL=${id}) -- real detail was: ${detail}"
  elif [ "$ok" = "0" ]; then
    status="PASS"
  else
    status="FAIL"
    FAILED=$((FAILED + 1))
  fi
  oe002::record "$id" "$req" "$name" "$status" "$detail" "$secs"
  if [ "$status" = "FAIL" ]; then
    printf 'OE-002 DIAGNOSIS %s: %s\n' "$id" "$detail" >&2
    printf 'OE-002 DIAGNOSIS %s: raw log excerpts in %s\n' "$id" "$OE002_LOG_DIR" >&2
  fi
}

# ---------------------------------------------------------------------------
# C01 -- requirement 1: LMS, Studio, Login and MFE are reachable
# ---------------------------------------------------------------------------
check_C01() {
  oe002::step "C01 reachability (LMS / Studio / Login / MFE)"
  oe002::timer_start
  local ok=0 detail="" probe label url code
  for probe in "lms:${OE002_LMS_URL}/" "studio:${OE002_CMS_URL}/" \
               "login:${OE002_LMS_URL}/login" "mfe-catalog:${OE002_MFE_URL}"; do
    label="${probe%%:*}"; url="${probe#*:}"
    code="$(oe002::http_code "$url")"
    detail="${detail}${label}=${code} "
    if [ "$code" != "200" ]; then
      ok=1
      printf 'OE-002 DIAGNOSIS C01: %s (%s) returned HTTP %s, expected 200\n' "$label" "$url" "$code" >&2
    fi
  done
  finish C01 "1 LMS/Studio/Login/MFE erreichbar" "http-reachability" "$ok" "${detail% }"
}

# ---------------------------------------------------------------------------
# C02 -- requirement 2: test organisation and test course, idempotent.
#         Also creates the course author, which create_course needs as a
#         positional argument and which no other requirement covers.
# ---------------------------------------------------------------------------
check_C02() {
  oe002::step "C02 organisation + course (idempotent create or reuse)"
  oe002::timer_start
  local ok=0 detail="" rc log

  log="${OE002_LOG_DIR}/c02-staff-user.log"
  oe002::manage cms "$log" create_test_users "$OE002_STAFF_USERNAME" \
    --domain "$OE002_USER_DOMAIN" --password "$(oe002::password staff)" \
    --ignore_user_already_exists
  rc=$?
  if [ $rc -ne 0 ]; then
    ok=1
    printf 'OE-002 DIAGNOSIS C02: create_test_users for the course author (%s) exited %s\n' \
      "$OE002_STAFF_USERNAME" "$rc" >&2
    oe002::clean "$log" >&2
  fi
  detail="${detail}author=$(grep -oE 'Created user [^ ]+|Test user [^ ]+ already exists' "$log" | head -n1) "

  log="${OE002_LOG_DIR}/c02-add-organization.log"
  oe002::manage cms "$log" add_organization "$OE002_ORG_SHORT" "$OE002_ORG_NAME"
  rc=$?
  if [ $rc -ne 0 ]; then
    ok=1
    printf 'OE-002 DIAGNOSIS C02: add_organization %s exited %s\n' "$OE002_ORG_SHORT" "$rc" >&2
    oe002::clean "$log" >&2
  fi
  detail="${detail}org=$(grep -oE 'Created or activated organization: id=[0-9]+' "$log" | head -n1) "

  log="${OE002_LOG_DIR}/c02-create-course.log"
  oe002::manage cms "$log" create_course split "$OE002_STAFF_EMAIL" \
    "$OE002_ORG_SHORT" "$OE002_COURSE_NUMBER" "$OE002_COURSE_RUN" "$OE002_COURSE_TITLE"
  rc=$?
  if [ $rc -ne 0 ]; then
    ok=1
    printf 'OE-002 DIAGNOSIS C02: create_course exited %s\n' "$rc" >&2
    oe002::clean "$log" >&2
  fi
  if grep -q "^Created ${OE002_COURSE_ID}\$" "$log"; then
    detail="${detail}course=created"
  elif grep -q "Course already exists" "$log"; then
    detail="${detail}course=reused"
  else
    ok=1
    detail="${detail}course=UNRECOGNISED-OUTPUT"
    printf 'OE-002 DIAGNOSIS C02: create_course printed neither "Created %s" nor "Course already exists"\n' \
      "$OE002_COURSE_ID" >&2
    oe002::clean "$log" >&2
  fi
  finish C02 "2 Testorganisation + Testkurs idempotent" "org-and-course" "$ok" "${detail% }"
}

# ---------------------------------------------------------------------------
# C03 -- requirement 3: the course can be published
# ---------------------------------------------------------------------------
check_C03() {
  oe002::step "C03 publish course"
  oe002::timer_start
  local ok=0 detail="" rc log="${OE002_LOG_DIR}/c03-force-publish.log"
  # force_publish prompts through input() with default="no"; with closed stdin it
  # dies on EOFError, so the confirmation has to be fed explicitly.
  oe002::manage_stdin cms "$log" "y" force_publish "$OE002_COURSE_ID" --commit
  rc=$?
  if [ $rc -ne 0 ]; then
    ok=1; detail="force_publish exited ${rc}"
    printf 'OE-002 DIAGNOSIS C03: force_publish %s --commit exited %s\n' "$OE002_COURSE_ID" "$rc" >&2
    oe002::clean "$log" >&2
  elif grep -q "Success! Published the course" "$log"; then
    detail="published-now $(grep -oE "published-branch': ObjectId\('[a-f0-9]+'\)" "$log" | tail -n1)"
  elif grep -q "already in published state" "$log"; then
    detail="already-published (idempotent)"
  elif grep -q "Error! Could not publish" "$log"; then
    ok=1; detail="force_publish reported it could not publish"
    printf 'OE-002 DIAGNOSIS C03: %s\n' "$detail" >&2
    oe002::clean "$log" >&2
  else
    ok=1; detail="force_publish output not recognised"
    printf 'OE-002 DIAGNOSIS C03: no known success/idempotency/error marker in output\n' >&2
    oe002::clean "$log" >&2
  fi
  finish C03 "3 Kurs veroeffentlichbar" "force-publish" "$ok" "$detail"
}

# ---------------------------------------------------------------------------
# C04 -- requirement 4: own test learner, idempotent
# ---------------------------------------------------------------------------
check_C04() {
  oe002::step "C04 learner (idempotent create or reuse)"
  oe002::timer_start
  local ok=0 detail="" rc log="${OE002_LOG_DIR}/c04-create-learner.log"
  oe002::manage cms "$log" create_test_users "$OE002_LEARNER_USERNAME" \
    --domain "$OE002_USER_DOMAIN" --password "$(oe002::password learner)" \
    --ignore_user_already_exists
  rc=$?
  if [ $rc -ne 0 ]; then
    ok=1; detail="create_test_users exited ${rc}"
    printf 'OE-002 DIAGNOSIS C04: create_test_users for %s exited %s\n' "$OE002_LEARNER_USERNAME" "$rc" >&2
    oe002::clean "$log" >&2
  else
    detail="$(grep -oE 'Created user [^ ]+|Test user [^ ]+ already exists' "$log" | head -n1)"
    if [ -z "$detail" ]; then ok=1; detail="no create/reuse marker in output"; fi
  fi
  finish C04 "4 eigener Test-Learner idempotent" "learner-user" "$ok" "$detail"
}

# ---------------------------------------------------------------------------
# C05 -- requirement 5: learner can be enrolled
# ---------------------------------------------------------------------------
check_C05() {
  oe002::step "C05 enroll learner"
  oe002::timer_start
  local ok=0 detail="" rc log="${OE002_LOG_DIR}/c05-enroll.log"
  oe002::manage lms "$log" enroll_user_in_course -e "$OE002_LEARNER_EMAIL" -c "$OE002_COURSE_ID"
  rc=$?
  if [ $rc -ne 0 ]; then
    ok=1; detail="enroll_user_in_course exited ${rc}"
    printf 'OE-002 DIAGNOSIS C05: enroll_user_in_course -e %s -c %s exited %s\n' \
      "$OE002_LEARNER_EMAIL" "$OE002_COURSE_ID" "$rc" >&2
    oe002::clean "$log" >&2
  elif grep -q 'edx.course.enrollment.activated' "$log"; then
    detail="enrollment-activated-event emitted for ${OE002_LEARNER_USERNAME}"
  else
    # No activation event means the enrollment already existed, which the command
    # documents as its idempotent path (it swallows CourseEnrollmentExistsError).
    detail="no new activation event -- already enrolled (idempotent path)"
  fi
  finish C05 "5 Learner einschreibbar" "enroll" "$ok" "$detail"
}

# ---------------------------------------------------------------------------
# C06 -- requirement 6: enrollment provable by an INDEPENDENT read-back
#          primary:   authenticated HTTP enrollment API -- different process,
#                     different code path, real service boundary
#          secondary: ORM query through manage.py shell (not raw SQL)
# ---------------------------------------------------------------------------
check_C06() {
  oe002::step "C06 independent enrollment read-back"
  oe002::timer_start
  local ok=0 detail="" rc code verdict http_enr orm_counts rows active meta eff
  COOKIE_JAR="$(mktemp)"

  if oe002::login "$COOKIE_JAR" "$OE002_LEARNER_EMAIL" "$(oe002::password learner)"; then
    detail="${detail}login=ok "
  else
    rc=$?
    ok=1
    detail="${detail}login=FAILED(rc=${rc}) "
    printf 'OE-002 DIAGNOSIS C06: learner session login failed rc=%s (1=no CSRF cookie, 2=login_ajax not 200, 3=success!=true). The password is never printed.\n' "$rc" >&2
  fi

  if [ $ok -eq 0 ]; then
    http_enr="${OE002_ARTIFACT_DIR}/c06-enrollment-api.json"
    # The session cookie is a credential, so this request gets the same treatment
    # as the password POST: the canonical URL is re-checked at the point of use,
    # redirects are not followed, and the effective host is asserted.
    if ! oe002::require_lms_url "present a session cookie"; then
      ok=1; code="000"; eff="-"
      detail="${detail}enrollment-api=REFUSED(bad-url) "
      printf 'OE-002 DIAGNOSIS C06: refusing to present the learner session cookie to a non-canonical URL\n' >&2
    else
      meta="$(curl -s -b "$COOKIE_JAR" -o "$http_enr" --max-redirs 0 \
              -w '%{http_code} %{url_effective}' --max-time "$OE002_HTTP_TIMEOUT" \
              "${OE002_LMS_URL}/api/enrollment/v1/enrollment" 2>/dev/null || printf '000 -')"
      code="${meta%% *}"
      eff="${meta#* }"
    fi
    if [ "$code" != "200" ]; then
      ok=1; detail="${detail}enrollment-api=HTTP${code} "
      printf 'OE-002 DIAGNOSIS C06: GET /api/enrollment/v1/enrollment returned HTTP %s\n' "$code" >&2
    elif ! oe002::host_is_allowed "$eff"; then
      ok=1; detail="${detail}enrollment-api=FOREIGN-HOST "
      printf 'OE-002 DIAGNOSIS C06: the enrollment read-back ended at %s, which is not an allowed host\n' "$eff" >&2
    else
      verdict="$(python3 - "$http_enr" "$OE002_COURSE_ID" <<'PY'
import json, sys
path, cid = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
if not isinstance(data, list):
    print("NOT-A-LIST"); raise SystemExit
hits = [e for e in data
        if e.get("course_details", {}).get("course_id") == cid and e.get("is_active")]
print("FOUND mode=%s total=%d" % (hits[0].get("mode"), len(data)) if hits
      else "ABSENT total=%d" % len(data))
PY
)"
      case "$verdict" in
        FOUND*) detail="${detail}enrollment-api=${verdict} " ;;
        *)
          ok=1; detail="${detail}enrollment-api=${verdict} "
          printf 'OE-002 DIAGNOSIS C06: %s is not an active entry in the learner enrollment list (%s)\n' \
            "$OE002_COURSE_ID" "$verdict" >&2
          ;;
      esac
    fi
  fi

  orm_counts="$(oe002::orm lms "
from django.contrib.auth import get_user_model
from common.djangoapps.student.models import CourseEnrollment
U = get_user_model()
cid = '${OE002_COURSE_ID}'
try:
    u = U.objects.get(email='${OE002_LEARNER_EMAIL}')
    qs = CourseEnrollment.objects.filter(user=u, course_id=cid)
    print('OE002_RB_ENROLLMENT_ROWS=%d' % qs.count())
    print('OE002_RB_ENROLLMENT_ACTIVE=%d' % qs.filter(is_active=True).count())
    for e in qs:
        print('OE002_RB_ENROLLMENT_ROW=id=%s,mode=%s,active=%s' % (e.id, e.mode, e.is_active))
except U.DoesNotExist:
    print('OE002_RB_ENROLLMENT_ROWS=MISSING_USER')
" 2>/dev/null)"
  rows="$(printf '%s\n' "$orm_counts" | sed -n 's/^OE002_RB_ENROLLMENT_ROWS=//p')"
  active="$(printf '%s\n' "$orm_counts" | sed -n 's/^OE002_RB_ENROLLMENT_ACTIVE=//p')"
  detail="${detail}orm-rows=${rows:-?},orm-active=${active:-?}"
  if [ "$rows" != "1" ] || [ "$active" != "1" ]; then
    ok=1
    printf 'OE-002 DIAGNOSIS C06: ORM read-back expected exactly 1 active enrollment row, got rows=%s active=%s\n' \
      "${rows:-none}" "${active:-none}" >&2
  fi
  finish C06 "6 unabhaengiger Enrollment-Readback" "independent-readback" "$ok" "${detail% }"
}

# ---------------------------------------------------------------------------
# C07 -- requirement 7: course reachable from the learner's point of view
#
# Establishes its OWN learner session and judges every probe on status AND
# effective URL. A status-only check is not evidence: /dashboard answers 200 for
# an anonymous caller too, redirected to apps.local.openedx.io/authn/login, which
# is how an earlier version of this check passed without proving anything.
# ---------------------------------------------------------------------------
check_C07() {
  oe002::step "C07 learner-view reachability"
  oe002::timer_start
  local ok=0 detail="" probe label url jar rc
  jar="$(mktemp)"

  if oe002::login "$jar" "$OE002_LEARNER_EMAIL" "$(oe002::password learner)"; then
    detail="${detail}login=ok "
  else
    rc=$?
    ok=1
    detail="${detail}login=FAILED(rc=${rc}) "
    printf 'OE-002 DIAGNOSIS C07: C07 could not establish its own learner session (rc=%s: 1=no CSRF cookie, 2=login_ajax not 200, 3=success!=true). Without it no learner view can be claimed. The password is never printed.\n' "$rc" >&2
  fi

  # Prove the session is the expected learner, not merely "some" session. The
  # helper also requires the identity endpoint to answer 401 anonymously, so the
  # discriminator itself is verified rather than assumed.
  if [ $ok -eq 0 ]; then
    if oe002::assert_session_is_learner "$jar" "$OE002_LEARNER_USERNAME"; then
      detail="${detail}session=${OE002_SESSION_USER},anon=${OE002_SESSION_ANON_CODE} "
    else
      rc=$?
      ok=1
      detail="${detail}session=UNVERIFIED(rc=${rc},anon=${OE002_SESSION_ANON_CODE},user='${OE002_SESSION_USER:-<empty>}') "
      printf 'OE-002 DIAGNOSIS C07: the learner session could not be proven to belong to %s (rc=%s)\n' \
        "$OE002_LEARNER_USERNAME" "$rc" >&2
    fi
  fi

  for probe in "dashboard:${OE002_LMS_URL}/dashboard" \
               "course-about:${OE002_LMS_URL}/courses/${OE002_COURSE_ID}/about" \
               "course-view:${OE002_LMS_URL}/courses/${OE002_COURSE_ID}/course" \
               "public-course-api:${OE002_LMS_URL}/api/courses/v1/courses/${OE002_COURSE_ID}"; do
    label="${probe%%:*}"; url="${probe#*:}"
    if oe002::assert_learner_view "$jar" "$label" "$url"; then
      detail="${detail}${label}=${OE002_PROBE_CODE} "
    else
      ok=1
      detail="${detail}${label}=REJECTED(code=${OE002_PROBE_CODE},class=${OE002_PROBE_CLASS}) "
      printf 'OE-002 DIAGNOSIS C07: %s (%s) rejected -- HTTP %s, effective url %s\n' \
        "$label" "$url" "$OE002_PROBE_CODE" "$OE002_PROBE_URL" >&2
    fi
  done

  rm -f "$jar"
  finish C07 "7 Kurs aus Learner-Sicht erreichbar" "learner-view" "$ok" "${detail% }"
}

# ---------------------------------------------------------------------------
# C08 -- requirement 8: no duplicates after repeated execution
# ---------------------------------------------------------------------------
check_C08() {
  oe002::step "C08 duplicate detection"
  oe002::timer_start
  local ok=0 detail="" counts line key val
  counts="$(oe002::entity_counts)"
  if [ -z "$counts" ]; then
    printf 'OE-002 DIAGNOSIS C08: the ORM duplicate query produced no marker lines; see %s\n' "$OE002_LOG_DIR" >&2
    finish C08 "8 keine Duplikate bei Wiederholung" "no-duplicates" 1 \
      "ORM duplicate query returned no marker lines"
    return
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"; val="${line#*=}"
    detail="${detail}${key}=${val} "
    # COURSE_ENROLLMENTS counts every enrollment on the course, which includes
    # the course author that create_course enrolls as instructor. It is recorded
    # as evidence but is not a duplicate signal.
    case "$key" in
      COURSE_ENROLLMENTS) continue ;;
    esac
    if [ "$val" != "1" ]; then
      ok=1
      printf 'OE-002 DIAGNOSIS C08: %s = %s, expected exactly 1 (duplicate or missing)\n' "$key" "$val" >&2
    fi
  done <<EOF
$counts
EOF
  finish C08 "8 keine Duplikate bei Wiederholung" "no-duplicates" "$ok" "${detail% }"
}

# ---------------------------------------------------------------------------
# C09 -- requirement 9: errors yield a non-zero exit code and a diagnosis
# ---------------------------------------------------------------------------
check_C09() {
  oe002::step "C09 error propagation"
  oe002::timer_start
  local ok=0 detail="" rc msg log="${OE002_LOG_DIR}/c09-invalid-course-key.log"
  oe002::manage_stdin cms "$log" "y" force_publish "not-a-valid-course-key" --commit
  rc=$?
  if [ $rc -eq 0 ]; then
    ok=1; detail="an invalid course key was accepted with exit 0"
    printf 'OE-002 DIAGNOSIS C09: force_publish on an invalid course key exited 0; Open edX did not reject it\n' >&2
  else
    msg="$(grep -oE 'Invalid course key\.|Course not found\.' "$log" | head -n1)"
    if [ -n "$msg" ]; then
      detail="invalid key rejected: exit ${rc}, message '${msg}'"
    else
      ok=1; detail="exit ${rc} but no readable diagnosis in output"
      printf 'OE-002 DIAGNOSIS C09: non-zero exit %s without a recognisable message\n' "$rc" >&2
      oe002::clean "$log" >&2
    fi
  fi
  finish C09 "9 Fehler -> Exitcode != 0 + Diagnose" "error-propagation" "$ok" "$detail"
}

# ---------------------------------------------------------------------------
# C10 -- requirement 10: spike only, pre-existing MIALO services untouched
# ---------------------------------------------------------------------------
check_C10() {
  oe002::step "C10 spike-only guarantee"
  oe002::timer_start
  local ok=0 detail="" platform_name after foreign_after problems n_protected
  platform_name="$(oe002::orm_value lms "
from django.conf import settings
print('OE002_RB_PLATFORM_NAME=%s' % settings.PLATFORM_NAME)
" OE002_RB_PLATFORM_NAME)"
  detail="platform='${platform_name}' project=${OE002_COMPOSE_PROJECT}"
  if [ "$platform_name" != "$OE002_EXPECTED_PLATFORM_NAME" ]; then
    ok=1
    printf 'OE-002 DIAGNOSIS C10: PLATFORM_NAME is %s, expected %s\n' \
      "${platform_name:-<unreadable>}" "$OE002_EXPECTED_PLATFORM_NAME" >&2
  fi

  # The assertion is about the pre-existing MIALO services, which is what "MIALO
  # untouched" actually claims. Each must still be running with an identical Id,
  # StartedAt, RestartCount and Status. An empty protected set is a failure:
  # otherwise the claim would pass without comparing anything at all.
  after="$(oe002::protected_fingerprint)"
  if n_protected="$(oe002::require_protected_baseline "$PROTECTED_BEFORE" 2>&1)"; then
    if problems="$(oe002::protected_changed "$PROTECTED_BEFORE" "$after")"; then
      detail="${detail} protected-containers=unchanged(${n_protected}, by id+startedAt+restartCount+status)"
    else
      ok=1
      detail="${detail} protected-containers=CHANGED"
      printf 'OE-002 DIAGNOSIS C10: a pre-existing MIALO container was stopped, restarted or replaced:\n%s\n' \
        "$problems" >&2
    fi
  else
    ok=1
    detail="${detail} protected-containers=NONE-MATCHED"
    printf 'OE-002 DIAGNOSIS C10: %s\n' "$n_protected" >&2
  fi

  # The full non-spike picture is recorded as evidence only. Unrelated transient
  # jobs come and go on a shared host, and this harness performs no container
  # mutation at all, so their appearance or disappearance is not a violation.
  foreign_after="$(oe002::foreign_fingerprint)"
  if ! oe002::fingerprints_match "$FOREIGN_BEFORE" "$foreign_after" >/dev/null 2>&1; then
    detail="${detail} other-non-spike=changed(informational)"
    printf 'OE-002 NOTE C10: non-protected containers changed during the run (informational, not a violation):\n' >&2
    oe002::fingerprint_diff "$FOREIGN_BEFORE" "$foreign_after" >&2
  fi
  finish C10 "10 nur lokaler Spike, MIALO unberuehrt" "spike-only" "$ok" "$detail"
}

# ===========================================================================
# Driver
# ===========================================================================
OE002_START_EPOCH=$(date +%s)
oe002::prepare_artifacts
oe002::require_spike
oe002::ensure_credentials
oe002::log "artefacts:   ${OE002_ARTIFACT_DIR}"
oe002::log "credentials: ${OE002_CREDENTIALS_FILE} (0600, outside version control)"
oe002::log "selected:    ${OE002_SELECTED[*]}"
oe002::log "protected MIALO containers now: $(oe002::protected_fingerprint | cut -d'|' -f1 | tr '\n' ' ')"
FOREIGN_BEFORE="$(oe002::foreign_fingerprint)"
PROTECTED_BEFORE="$(oe002::protected_fingerprint)"

for check_id in "${OE002_SELECTED[@]}"; do
  "check_${check_id}"
done

if [ -n "$COOKIE_JAR" ] && [ -f "$COOKIE_JAR" ]; then rm -f "$COOKIE_JAR"; COOKIE_JAR=""; fi

elapsed=$(( $(date +%s) - OE002_START_EPOCH ))
exit_code=0
[ "$FAILED" -eq 0 ] || exit_code=1
[ -z "${OE002_FORCE_FAIL:-}" ] || exit_code=1

oe002::step "summary"
oe002::log "elapsed: ${elapsed}s   failed checks: ${FAILED}   forced-failure: ${OE002_FORCE_FAIL:-none}"
report_path="$(oe002::write_report "$exit_code")"
oe002::log "report: ${report_path}"
oe002::log "logs:   ${OE002_LOG_DIR}"
exit "$exit_code"
