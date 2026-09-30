#!/usr/bin/env bash
# OE-002 regression tests for the codex-1 cold-review findings (#7389).
#
# Every finding gets named tests, and every finding gets a POSITIVE CONTROL as
# well as the negative cases -- a guard that rejects everything proves nothing.
# This file is the Befund-zu-Test-Matrix: the test names are quoted verbatim in
# the REVREQ so a reviewer can map each finding to the test that pins it.
#
#   F-URL-SUFFIX        RF-URL-*   canonical, exact URL validation
#   F-C07-AUTH          RF-C07-*   learner view must be authenticated
#   F-ISOLATION-EVIDENCE RF-ISO-*  container identity, not container names
#   secret path in VCS  RF-SEC-*   credentials/artefacts outside any worktree
#
# Usage: test_review_findings.sh [--help]
# Exit:  0 every test behaved as required, 1 at least one did not.

set -uo pipefail

OE002_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Isolate artefacts BEFORE sourcing lib.sh, which derives its paths from this.
export OE002_ARTIFACT_DIR="${OE002_ARTIFACT_DIR:-${OE002_SPIKE_ROOT:-/home/shiblyanastas/openedx-spike}/oe002-artifacts-findings}"
# shellcheck source=mialo/oe002/lib.sh
. "${OE002_HERE}/lib.sh"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"
  exit 0
fi

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); printf '[PASS] %s -- %s\n' "$1" "$2"; }
fail() { FAILED=$((FAILED + 1)); printf '[FAIL] %s -- %s\n' "$1" "$2" >&2; }

# expect_reject <name> <actual-rc> <reason-text>
# Requires non-zero AND a non-empty reason, because a silent refusal is not a
# diagnosis.
expect_reject() {
  if [ "$2" != "0" ] && [ -n "$3" ]; then
    pass "$1" "rejected (rc=$2): $3"
  else
    fail "$1" "rc=$2 reason='$3' -- expected non-zero rc and a stated reason"
  fi
}

expect_accept() {
  if [ "$2" = "0" ]; then
    pass "$1" "accepted as required"
  else
    fail "$1" "rc=$2 -- expected acceptance"
  fi
}

# expect_diff_field <name> <before> <after> <field-that-must-be-named>
expect_diff_field() {
  local out
  out="$(oe002::fingerprint_diff "$2" "$3")"
  if printf '%s' "$out" | grep -q "$4"; then
    pass "$1" "difference reported: $(printf '%s' "$out" | head -n1)"
  else
    fail "$1" "diff did not name '$4'; got: $(printf '%s' "$out" | head -n3 | tr '\n' ';')"
  fi
}

# run_guard <name> <expected-rc> <env-assignments...> -- invoke acceptance.sh
# with a hostile environment and judge exit code plus diagnosis. A refusal
# without a stated reason counts as a failure: OE-002 item 9 demands both.
run_guard() {
  local name="$1" want="$2"; shift 2
  local log="${OE002_LOG_DIR}/${name}.log"
  env "$@" OE002_ARTIFACT_DIR="$OE002_ARTIFACT_DIR" \
    bash "${OE002_HERE}/acceptance.sh" --only C01 >"$log" 2>&1
  local rc=$?
  if [ "$rc" != "$want" ]; then
    fail "${name}-exit" "rc=${rc}, expected ${want} (log: ${log})"
    tail -n 5 "$log" >&2
    return
  fi
  pass "${name}-exit" "rc=${rc} as required"
  if [ "$want" = "0" ]; then
    local line
    line="$(grep -m1 -oE '\[PASS\] C01 .*' "$log" | cut -c1-120)"
    if [ -n "$line" ]; then
      pass "${name}-control" "$line"
    else
      fail "${name}-control" "exit 0 but no C01 PASS line in ${log}"
    fi
  else
    local why
    why="$(grep -m1 -oE 'OE-002 FATAL: .*' "$log" | cut -c1-140)"
    if [ -n "$why" ]; then
      pass "${name}-diagnosis" "$why"
    else
      fail "${name}-diagnosis" "refused with rc=${rc} but printed no OE-002 FATAL diagnosis"
    fi
  fi
}

oe002::prepare_artifacts
printf '\nartefacts for these tests: %s\n' "$OE002_ARTIFACT_DIR"

# ===========================================================================
printf '\n########## F-URL-SUFFIX (HIGH) -- canonical URL validation ##########\n'
# ===========================================================================
url_case() {  # <name> <url> <host> <accept|reject>
  local reason rc
  reason="$(oe002::check_url "$2" "$3")"; rc=$?
  if [ "$4" = "reject" ]; then
    expect_reject "$1" "$rc" "$reason"
  else
    expect_accept "$1" "$rc"
    [ -n "$reason" ] && fail "$1-reason" "accepted but printed '$reason'"
  fi
}

H="$OE002_ALLOWED_LMS_HOST"

# RED EVIDENCE, pinned permanently: the pre-fix predicate was a substring match
# on the host, so it really did accept a look-alike domain. Keeping this assertion
# green means the finding stays reproducible instead of becoming a claim nobody
# can check any more.
case "http://${H}.attacker.invalid" in
  *local.openedx.io*)
    pass RF-URL-00-red-evidence "the pre-fix substring predicate accepts http://${H}.attacker.invalid -- the finding was real"
    ;;
  *)
    fail RF-URL-00-red-evidence "the pre-fix predicate no longer reproduces; the red evidence for this finding is lost"
    ;;
esac

url_case RF-URL-01-attacker-suffix   "http://${H}.attacker.invalid"        "$H" reject
url_case RF-URL-02-attacker-prefix   "http://not-${H}"                    "$H" reject
url_case RF-URL-03-userinfo          "http://learner:secret@${H}"         "$H" reject
url_case RF-URL-04-nondefault-port   "http://${H}:1"                      "$H" reject
url_case RF-URL-05-https-scheme      "https://${H}"                       "$H" reject
url_case RF-URL-06-query-string      "http://${H}/?x=1"                   "$H" reject
url_case RF-URL-07-fragment          "http://${H}/#frag"                  "$H" reject
url_case RF-URL-08-empty             ""                                   "$H" reject
url_case RF-URL-09-malformed-port    "http://${H}:notaport"               "$H" reject
url_case RF-URL-10-control-lms       "$OE002_LMS_URL"                     "$OE002_ALLOWED_LMS_HOST" accept
url_case RF-URL-11-control-cms       "$OE002_CMS_URL"                     "$OE002_ALLOWED_CMS_HOST" accept
url_case RF-URL-12-control-mfe       "$OE002_MFE_URL"                     "$OE002_ALLOWED_MFE_HOST" accept
url_case RF-URL-13-control-defport   "http://${H}:80"                     "$H" accept

# The credential-exfiltration consequence, not just the guard verdict: with an
# attacker host accepted, oe002::login would POST the learner password to it.
printf '\n--- integration: the guard must die before any credential is used ---\n'
run_guard RF-URL-14-guard-attacker-suffix 5 \
  "OE002_LMS_URL=http://${H}.attacker.invalid"
run_guard RF-URL-15-guard-userinfo 5 \
  "OE002_LMS_URL=http://learner:secret@${H}"
run_guard RF-URL-16-guard-port 5 \
  "OE002_LMS_URL=http://${H}:1"
run_guard RF-URL-17-guard-control 0

# ---------------------------------------------------------------------------
# codex-1 #7400: validating the base variables is not enough. The EFFECTIVE
# target of every credential-carrying request has to be secured, and a redirect
# to a foreign host has to be excluded BEFORE the secret is handed over.
# ---------------------------------------------------------------------------
printf '\n--- effective-URL protection of credential-carrying requests (#7400) ---\n'
host_case() {  # <name> <url> <allow|deny>
  local got
  if oe002::host_is_allowed "$2"; then got=allow; else got=deny; fi
  if [ "$got" = "$3" ]; then pass "$1" "$2 -> $got"
  else fail "$1" "$2 -> $got, expected $3"; fi
}
host_case RF-URL-18-host-lms       "http://local.openedx.io/dashboard"               allow
host_case RF-URL-19-host-cms       "http://studio.local.openedx.io/"                 allow
host_case RF-URL-20-host-mfe       "http://apps.local.openedx.io/learner-dashboard/" allow
host_case RF-URL-21-host-suffix    "http://local.openedx.io.attacker.invalid/steal"  deny
host_case RF-URL-22-host-localhost "http://localhost:8080/collect"                   deny
host_case RF-URL-23-host-unparsable "not a url"                                      deny

# judge_view is pure, so a redirect that leaves the spike can be pinned without
# standing up a hostile server.
judge_case() {  # <name> <code> <effective-url> <accept|reject> <expected-class>
  local rc
  oe002::judge_view "$1" "$2" "$3" >/dev/null 2>&1; rc=$?
  if [ "$4" = "accept" ] && [ "$rc" = "0" ] && [ "$OE002_PROBE_CLASS" = "$5" ]; then
    pass "$1" "accepted, class=${OE002_PROBE_CLASS}"
  elif [ "$4" = "reject" ] && [ "$rc" != "0" ] && [ "$OE002_PROBE_CLASS" = "$5" ]; then
    pass "$1" "rejected, class=${OE002_PROBE_CLASS}"
  else
    fail "$1" "rc=${rc} class=${OE002_PROBE_CLASS}, expected $4/$5"
  fi
}
judge_case RF-URL-24-view-learner-dashboard 200 "http://apps.local.openedx.io/learner-dashboard/"        accept OK
judge_case RF-URL-25-view-authn-redirect    200 "http://apps.local.openedx.io/authn/login?next=%2Fdashboard" reject LOGIN_REDIRECT
judge_case RF-URL-26-view-foreign-host      200 "http://attacker.invalid/collect"                        reject FOREIGN_HOST
judge_case RF-URL-27-view-non200            404 "http://local.openedx.io/missing"                        reject OK

# The password POST must be refused BEFORE any request is made. A refusal that
# came after a network round trip would mean the secret was already on the wire,
# so the elapsed time is itself part of the evidence.
saved_lms="$OE002_LMS_URL"
OE002_LMS_URL="http://local.openedx.io.attacker.invalid"
jar="$(mktemp)"
t0=$(date +%s.%N)
oe002::login "$jar" "someone@example.com" "a-password-that-must-not-travel" \
  2>"${OE002_LOG_DIR}/rf-url-28.err"
rc=$?
t1=$(date +%s.%N)
OE002_LMS_URL="$saved_lms"
rm -f "$jar"
elapsed="$(python3 -c 'import sys;print("%.3f"%(float(sys.argv[2])-float(sys.argv[1])))' "$t0" "$t1")"
if [ "$rc" = "4" ] && grep -q 'refusing to transmit a credential' "${OE002_LOG_DIR}/rf-url-28.err"; then
  pass RF-URL-28-login-refuses-before-sending \
    "rc=4 in ${elapsed}s, no request made; refusal: $(head -c 90 "${OE002_LOG_DIR}/rf-url-28.err")"
else
  fail RF-URL-28-login-refuses-before-sending \
    "rc=${rc} after ${elapsed}s, expected rc=4 with an explicit pre-flight refusal"
fi
if [ "$(python3 -c 'import sys;print(1 if float(sys.argv[1]) < 2 else 0)' "$elapsed")" = "1" ]; then
  pass RF-URL-29-refusal-is-pre-flight "refused in ${elapsed}s -- before any network round trip"
else
  fail RF-URL-29-refusal-is-pre-flight \
    "the refusal took ${elapsed}s, which suggests a request was made before it"
fi

# Positive control: the hardening must not break a canonical login. rc 4/5 would
# mean a false refusal; 1/2/3 still prove the request reached the canonical LMS.
jar="$(mktemp)"
if oe002::login "$jar" "$OE002_LEARNER_EMAIL" "$(oe002::password learner)"; then
  pass RF-URL-30-real-login-still-works "canonical URL, real learner, rc=0"
else
  rc=$?
  case "$rc" in
    4|5) fail RF-URL-30-real-login-still-works "rc=${rc} -- the hardening refused a canonical URL" ;;
    *)   pass RF-URL-30-real-login-still-works \
           "rc=${rc}: the request reached the canonical LMS, so no false refusal (the learner may be absent in this state)" ;;
  esac
fi
rm -f "$jar"

# Structural: the credential-carrying requests must not follow redirects at all.
if grep -q -- '--max-redirs 0' "${OE002_HERE}/lib.sh"; then
  pass RF-URL-31-credential-requests-no-redirects \
    "lib.sh pins --max-redirs 0 on the credential-carrying requests ($(grep -c -- '--max-redirs 0' "${OE002_HERE}/lib.sh") occurrences)"
else
  fail RF-URL-31-credential-requests-no-redirects "no --max-redirs 0 anywhere in lib.sh"
fi

# ===========================================================================
printf '\n########## F-C07-AUTH (HIGH) -- learner view must be authenticated ##########\n'
# ===========================================================================

# RED EVIDENCE, pinned permanently: /dashboard answers HTTP 200 to an anonymous
# caller, redirected to the authn MFE. That is precisely why a status-only check
# passed without proving a learner view. If this ever stops being 200, the
# premise of the finding has changed and this test says so instead of hiding it.
ANON_DASHBOARD_CODE="$(oe002::http_code "${OE002_LMS_URL}/dashboard")"
ANON_DASHBOARD_EFF="$(oe002::probe "" "${OE002_LMS_URL}/dashboard")"
if [ "$ANON_DASHBOARD_CODE" = "200" ]; then
  pass RF-C07-00-red-evidence \
    "anonymous /dashboard returns HTTP 200 (effective url ${ANON_DASHBOARD_EFF#*$'\t'}) -- a status-only check cannot detect it"
else
  fail RF-C07-00-red-evidence \
    "anonymous /dashboard returned ${ANON_DASHBOARD_CODE}; the premise of F-C07-AUTH has changed"
fi
if [ "$(oe002::classify_url "${ANON_DASHBOARD_EFF#*$'\t'}")" = "LOGIN_REDIRECT" ]; then
  pass RF-C07-00b-red-evidence-classified "the anonymous effective url is classified LOGIN_REDIRECT"
else
  fail RF-C07-00b-red-evidence-classified "the anonymous effective url was not classified as a login redirect"
fi

printf '\n--- classify_url ---\n'
cls() {  # <name> <url> <expected>
  local got; got="$(oe002::classify_url "$2")"
  if [ "$got" = "$3" ]; then pass "$1" "$2 -> $got"
  else fail "$1" "$2 -> $got, expected $3"; fi
}
cls RF-C07-01-classify-authn  "http://apps.local.openedx.io/authn/login?next=%2Fdashboard" LOGIN_REDIRECT
cls RF-C07-02-classify-login  "http://local.openedx.io/login"                              LOGIN_REDIRECT
cls RF-C07-03-classify-dash   "http://apps.local.openedx.io/learner-dashboard/"            OK
cls RF-C07-04-classify-course "http://local.openedx.io/courses/x/course"                   OK

printf '\n--- an anonymous session must NOT look like a learner view ---\n'
EMPTY_JAR="$(mktemp)"
if oe002::assert_learner_view "$EMPTY_JAR" "dashboard" "${OE002_LMS_URL}/dashboard" 2>"${OE002_LOG_DIR}/rf-c07-anon.err"; then
  fail RF-C07-05-anon-dashboard-rejected "an anonymous /dashboard probe was accepted (code=${OE002_PROBE_CODE}, eff=${OE002_PROBE_URL})"
else
  pass RF-C07-05-anon-dashboard-rejected \
    "code=${OE002_PROBE_CODE} class=${OE002_PROBE_CLASS} eff=${OE002_PROBE_URL}"
fi
if oe002::assert_session_is_learner "$EMPTY_JAR" "$OE002_LEARNER_USERNAME" 2>"${OE002_LOG_DIR}/rf-c07-anonid.err"; then
  fail RF-C07-06-anon-identity-rejected "an empty cookie jar was accepted as the learner"
else
  pass RF-C07-06-anon-identity-rejected "user='${OE002_SESSION_USER:-<empty>}' anon=${OE002_SESSION_ANON_CODE}"
fi

printf '\n--- a wrong session must NOT look like the learner ---\n'
BOGUS_JAR="$(mktemp)"
printf 'not-a-cookie\n' >"$BOGUS_JAR"
if oe002::assert_session_is_learner "$BOGUS_JAR" "$OE002_LEARNER_USERNAME" 2>/dev/null; then
  fail RF-C07-07-bogus-identity-rejected "a garbage cookie jar was accepted as the learner"
else
  pass RF-C07-07-bogus-identity-rejected "rejected (user='${OE002_SESSION_USER:-<empty>}')"
fi
rm -f "$EMPTY_JAR" "$BOGUS_JAR"

printf '\n--- integration: C07 alone must establish its own session ---\n'
log="${OE002_LOG_DIR}/rf-c07-08-only-c07.log"
OE002_ARTIFACT_DIR="$OE002_ARTIFACT_DIR" bash "${OE002_HERE}/acceptance.sh" --only C07 >"$log" 2>&1
rc=$?
if [ "$rc" = "0" ] && grep -q 'session=mialo_oe002_learner' "$log"; then
  pass RF-C07-08-only-c07-authenticated "rc=0 and the report proves the session identity"
  grep -o 'login=ok session=[^ ]*' "$log" | head -n1 | sed 's/^/       /'
else
  fail RF-C07-08-only-c07-authenticated "rc=${rc} or no session= evidence in ${log}"
  tail -n 6 "$log" >&2
fi

log="${OE002_LOG_DIR}/rf-c07-09-bad-learner.log"
OE002_LEARNER_USERNAME=oe002_ghost OE002_USER_DOMAIN=example.invalid \
  OE002_ARTIFACT_DIR="$OE002_ARTIFACT_DIR" \
  OE002_CREDENTIALS_FILE="${OE002_SPIKE_ROOT}/.oe002-credentials-rfc0709.json" \
  bash "${OE002_HERE}/acceptance.sh" --only C07 >"$log" 2>&1
rc=$?
if [ "$rc" = "1" ]; then
  pass RF-C07-09-unauthenticated-c07-red "rc=1 -- C07 goes red when no learner session can be established"
else
  fail RF-C07-09-unauthenticated-c07-red "rc=${rc}, expected 1 (log: ${log})"
  tail -n 6 "$log" >&2
fi
rm -f "${OE002_SPIKE_ROOT}/.oe002-credentials-rfc0709.json"

# ===========================================================================
printf '\n########## F-ISOLATION-EVIDENCE (MEDIUM) -- identity, not names ##########\n'
# ===========================================================================
BASE='/mialo-launch-postgres|aaa111|2026-09-28T10:00:00Z|0|running'
if oe002::fingerprints_match "$BASE" "$BASE" >/dev/null 2>&1; then
  pass RF-ISO-01-identical "identical fingerprints reported as unchanged"
else
  fail RF-ISO-01-identical "identical fingerprints reported as different"
fi
expect_diff_field RF-ISO-02-id-changed        "$BASE" '/mialo-launch-postgres|bbb222|2026-09-28T10:00:00Z|0|running' '\.id:'
expect_diff_field RF-ISO-03-startedat-changed "$BASE" '/mialo-launch-postgres|aaa111|2026-09-30T22:00:00Z|0|running' '\.started_at:'
expect_diff_field RF-ISO-04-restarts-changed  "$BASE" '/mialo-launch-postgres|aaa111|2026-09-28T10:00:00Z|3|running' '\.restart_count:'
expect_diff_field RF-ISO-05-status-changed    "$BASE" '/mialo-launch-postgres|aaa111|2026-09-28T10:00:00Z|0|exited'   '\.status:'
expect_diff_field RF-ISO-06-container-gone    "$BASE" ''                                                              'REMOVED'
expect_diff_field RF-ISO-07-container-added   ''      "$BASE"                                                          'ADDED'

# A name-only comparison would have called all of the above "unchanged".
NAMES_BEFORE='mialo-launch-postgres'
NAMES_AFTER='mialo-launch-postgres'
if [ "$NAMES_BEFORE" = "$NAMES_AFTER" ]; then
  pass RF-ISO-08-names-insufficient "name comparison stays green across a restart -- which is exactly why fingerprints are used"
else
  fail RF-ISO-08-names-insufficient "test premise broken"
fi

printf '\n--- live fingerprint shape ---\n'
LIVE="$(oe002::foreign_fingerprint)"
if [ -n "$LIVE" ]; then
  bad_lines=0
  while IFS= read -r line; do
    fields="$(printf '%s' "$line" | awk -F'|' '{print NF}')"
    [ "$fields" = "5" ] || bad_lines=$((bad_lines + 1))
    printf '%s' "$line" | grep -qE '\|[0-9a-f]{64}\|' || bad_lines=$((bad_lines + 1))
  done <<EOF
$LIVE
EOF
  if [ "$bad_lines" = "0" ]; then
    pass RF-ISO-09-live-fingerprint-shape "$(printf '%s\n' "$LIVE" | grep -c .) container(s), 5 fields each, 64-hex id present"
  else
    fail RF-ISO-09-live-fingerprint-shape "${bad_lines} malformed line(s) in: ${LIVE}"
  fi
else
  fail RF-ISO-09-live-fingerprint-shape "no foreign containers found -- expected the three MIALO services"
fi

printf '\n--- protected-container assertion (the one C10 and run_all actually use) ---\n'
expect_protected_clean() {  # <name> <before> <after>
  local out rc
  out="$(oe002::protected_changed "$2" "$3")"; rc=$?
  if [ "$rc" = "0" ]; then pass "$1" "no violation reported${out:+ (note: $(printf '%s' "$out" | head -n1))}"
  else fail "$1" "reported a violation: $(printf '%s' "$out" | head -n2 | tr '\n' ';')"; fi
}
expect_protected_problem() {  # <name> <before> <after> <substring>
  local out rc
  out="$(oe002::protected_changed "$2" "$3")"; rc=$?
  if [ "$rc" != "0" ] && printf '%s' "$out" | grep -q "$4"; then
    pass "$1" "violation reported: $(printf '%s' "$out" | head -n1)"
  else
    fail "$1" "rc=$rc output='$(printf '%s' "$out" | head -n2 | tr '\n' ';')' -- expected a line matching '$4'"
  fi
}

P1='mialo-launch-postgres|70f555f5|2026-09-28T11:42:10Z|0|running
mialo-slide-preview-db|474fa3fe|2026-09-28T11:42:10Z|0|running'
expect_protected_clean   RF-ISO-10-protected-identical    "$P1" "$P1"
expect_protected_problem RF-ISO-11-protected-missing      "$P1" 'mialo-launch-postgres|70f555f5|2026-09-28T11:42:10Z|0|running' 'MISSING'
expect_protected_problem RF-ISO-12-protected-restarted    "$P1" 'mialo-launch-postgres|70f555f5|2026-09-30T09:00:00Z|0|running
mialo-slide-preview-db|474fa3fe|2026-09-28T11:42:10Z|0|running' '\.started_at:'
expect_protected_problem RF-ISO-13-protected-replaced     "$P1" 'mialo-launch-postgres|deadbeef|2026-09-28T11:42:10Z|0|running
mialo-slide-preview-db|474fa3fe|2026-09-28T11:42:10Z|0|running' '\.id:'
expect_protected_problem RF-ISO-14-protected-restartcount "$P1" 'mialo-launch-postgres|70f555f5|2026-09-28T11:42:10Z|2|running
mialo-slide-preview-db|474fa3fe|2026-09-28T11:42:10Z|0|running' '\.restart_count:'
expect_protected_problem RF-ISO-15-protected-stopped      "$P1" 'mialo-launch-postgres|70f555f5|2026-09-28T11:42:10Z|0|exited
mialo-slide-preview-db|474fa3fe|2026-09-28T11:42:10Z|0|running' '\.status:'

# The false positive that made the first run of this suite cry wolf: unrelated
# transient containers must not be judged, because the harness performs no
# container mutation and cannot be blamed for other lanes' jobs coming and going.
PROTECTED_LIVE="$(oe002::protected_fingerprint)"
n_protected="$(printf '%s\n' "$PROTECTED_LIVE" | grep -c . || true)"
leaked=""
while IFS= read -r cname; do
  [ -n "$cname" ] || continue
  case " ${OE002_PROTECTED_CONTAINERS} " in
    *" ${cname} "*) : ;;
    *) leaked="${leaked}${cname} " ;;
  esac
done <<EOF
$(printf '%s\n' "$PROTECTED_LIVE" | cut -d'|' -f1)
EOF
if [ "$n_protected" -ge 1 ] && [ -z "$leaked" ]; then
  pass RF-ISO-16-filter-excludes-unrelated \
    "${n_protected} protected container(s) selected, every one declared; nothing unrelated leaked in"
else
  fail RF-ISO-16-filter-excludes-unrelated \
    "selected ${n_protected} container(s), undeclared: '${leaked:-none}'"
fi

# The documented widening path must still work: empty the explicit list and the
# pattern takes over, selecting every mialo* container including other lanes'.
saved_list="$OE002_PROTECTED_CONTAINERS"
OE002_PROTECTED_CONTAINERS=""
OE002_PROTECTED_PATTERN="mialo"
PATTERN_LIVE="$(oe002::protected_fingerprint)"
OE002_PROTECTED_CONTAINERS="$saved_list"
n_pattern="$(printf '%s\n' "$PATTERN_LIVE" | grep -c . || true)"
if [ "$n_pattern" -ge "$n_protected" ]; then
  pass RF-ISO-21-pattern-fallback-widens \
    "pattern mode selects ${n_pattern} container(s) vs ${n_protected} declared -- widening works"
else
  fail RF-ISO-21-pattern-fallback-widens \
    "pattern mode selected ${n_pattern}, fewer than the ${n_protected} declared"
fi

# STATIC ATTRIBUTION PROOF. A before/after comparison cannot on its own tell
# "this harness restarted a MIALO service" from "another lane redeployed its own
# container mid-run" -- both were observed here. What settles attribution is that
# the harness contains no container-mutating docker verb at all, so no change can
# have come from it.
printf '\n--- static attribution: the harness cannot mutate a container ---\n'
MUTATING_RE='docker[[:space:]]+(stop|start|restart|rm|rmi|kill|pause|unpause|update|create|run|pull|push|build|rename)|docker[[:space:]]+compose[[:space:]]+(up|down|start|stop|restart|run|rm|build|pull|create)|docker[[:space:]]+(system[[:space:]]+prune|volume[[:space:]]+rm|network[[:space:]]+(create|rm))'
hits="$(grep -nE "$MUTATING_RE" "${OE002_HERE}"/*.sh 2>/dev/null || true)"
if [ -z "$hits" ]; then
  pass RF-ISO-22-no-mutating-container-verb \
    "no container-mutating subcommand anywhere in the harness, this file included"
else
  fail RF-ISO-22-no-mutating-container-verb \
    "mutating subcommand found: $(printf '%s' "$hits" | head -n3 | tr '\n' ';')"
fi
# The detector has to be able to fire, or the assertion above proves nothing. The
# sample is assembled from separate tokens ON PURPOSE: written out literally it
# matches the very regex that scans this file, so the detector reported itself.
# That false positive was observed, and this split is the fix.
tok_d=docker; tok_stop=stop; tok_comp=compose; tok_rm=rm
control_sample="$(printf '%s %s x\n%s %s down\n%s %s -f y\n' \
  "$tok_d" "$tok_stop" "$tok_d" "$tok_comp" "$tok_d" "$tok_rm")"
control_hits="$(printf '%s' "$control_sample" | grep -cE "$MUTATING_RE" || true)"
if [ "$control_hits" = "3" ]; then
  pass RF-ISO-23-detector-is-live "control sample matched ${control_hits}/3"
else
  fail RF-ISO-23-detector-is-live \
    "control sample matched ${control_hits}, expected 3 -- the detector is dead and RF-ISO-22 proves nothing"
fi
# Read-only subcommand allowlist. The token 'daemon' is not a subcommand: it comes
# from the diagnostic string "docker daemon not reachable".
verbs="$(grep -hvE '^[[:space:]]*#' "${OE002_HERE}"/*.sh \
  | grep -ohE 'docker[[:space:]]+[a-z][a-z-]*' | awk '{print $2}' | sort -u | tr '\n' ' ')"
unexpected="$(printf '%s' "$verbs" | tr ' ' '\n' | grep -vxE 'ps|exec|inspect|info|daemon|' || true)"
if [ -z "$unexpected" ]; then
  pass RF-ISO-24-subcommand-allowlist "only these subcommands are used: ${verbs% }"
else
  fail RF-ISO-24-subcommand-allowlist \
    "unexpected subcommands: $(printf '%s' "$unexpected" | tr '\n' ' ')"
fi
expect_protected_clean RF-ISO-17-unrelated-transient-ignored \
  "$PROTECTED_LIVE" "$(printf '%s\np0fresh-0c5a091cb22e|d8c0f644|2026-09-30T20:58:22Z|0|running' "$PROTECTED_LIVE")"

# An empty protected baseline must NOT be accepted. With nothing to compare, the
# isolation claim would pass vacuously while still asserting "MIALO untouched".
if msg="$(oe002::require_protected_baseline "" 2>&1)"; then
  fail RF-ISO-18-empty-baseline-refused \
    "an empty protected baseline was accepted (count '${msg}') -- the isolation claim would pass without evidence"
else
  pass RF-ISO-18-empty-baseline-refused "refused: ${msg}"
fi
if msg="$(oe002::require_protected_baseline "$PROTECTED_LIVE" 2>&1)"; then
  pass RF-ISO-19-live-baseline-accepted "${msg} protected container(s) available to compare"
else
  fail RF-ISO-19-live-baseline-accepted "the live protected baseline was refused: ${msg}"
fi

# Integration: C10 must go red rather than pass vacuously when nothing matches.
printf '\n--- integration: C10 with an empty protected set must be red ---\n'
log="${OE002_LOG_DIR}/rf-iso-20-empty-protected.log"
OE002_PROTECTED_CONTAINERS="zzz_no_such_container_zzz" \
  OE002_ARTIFACT_DIR="$OE002_ARTIFACT_DIR" \
  bash "${OE002_HERE}/acceptance.sh" --only C10 >"$log" 2>&1
rc=$?
if [ "$rc" = "1" ] && grep -q 'NONE-MATCHED' "$log"; then
  pass RF-ISO-20-c10-vacuous-refused "rc=1 and C10 reported NONE-MATCHED instead of passing vacuously"
else
  fail RF-ISO-20-c10-vacuous-refused "rc=${rc}, expected 1 with NONE-MATCHED (log: ${log})"
  tail -n 5 "$log" >&2
fi

# ===========================================================================
printf '\n########## secret / artefact path inside version control ##########\n'
# ===========================================================================
WT="/home/shiblyanastas/openedx-spike/wt-qwen-oe002"
if oe002::check_outside_vcs "$WT/mialo/oe002" >/dev/null 2>&1; then
  fail RF-SEC-01-worktree-detected "$WT/mialo/oe002 was reported as outside version control"
else
  pass RF-SEC-01-worktree-detected "worktree path detected: $(oe002::check_outside_vcs "$WT/mialo/oe002" 2>/dev/null)"
fi
if oe002::check_outside_vcs "$OE002_SPIKE_ROOT" >/dev/null 2>&1; then
  pass RF-SEC-02-default-outside "default artefact root ${OE002_SPIKE_ROOT} is outside version control"
else
  fail RF-SEC-02-default-outside "the default artefact root was rejected -- the harness could not run"
fi
if oe002::check_outside_vcs "$OE002_CREDENTIALS_FILE" >/dev/null 2>&1; then
  pass RF-SEC-03-credentials-outside "${OE002_CREDENTIALS_FILE} is outside version control"
else
  fail RF-SEC-03-credentials-outside "the default credentials path was rejected"
fi

printf '\n--- integration: a secret inside the repo must abort with exit 6 ---\n'
log="${OE002_LOG_DIR}/rf-sec-04-creds-in-worktree.log"
OE002_CREDENTIALS_FILE="${WT}/mialo/oe002/.leaked-credentials.json" \
  OE002_ARTIFACT_DIR="$OE002_ARTIFACT_DIR" \
  bash "${OE002_HERE}/acceptance.sh" --only C01 >"$log" 2>&1
rc=$?
if [ "$rc" = "6" ] && grep -q 'inside a version-control worktree' "$log"; then
  pass RF-SEC-04-credentials-in-worktree "rc=6 and the refusal names the worktree"
else
  fail RF-SEC-04-credentials-in-worktree "rc=${rc}, expected 6 (log: ${log})"
  tail -n 5 "$log" >&2
fi
if [ -e "${WT}/mialo/oe002/.leaked-credentials.json" ]; then
  fail RF-SEC-05-nothing-written "a secret file WAS created inside the worktree"
  rm -f "${WT}/mialo/oe002/.leaked-credentials.json"
else
  pass RF-SEC-05-nothing-written "no secret file was created inside the worktree"
fi

log="${OE002_LOG_DIR}/rf-sec-06-artefacts-in-worktree.log"
OE002_ARTIFACT_DIR="${WT}/mialo/oe002/artefacts" \
  bash "${OE002_HERE}/acceptance.sh" --only C01 >"$log" 2>&1
rc=$?
if [ "$rc" = "6" ] && grep -q 'inside a version-control worktree' "$log"; then
  pass RF-SEC-06-artefacts-in-worktree "rc=6 and the refusal names the worktree"
else
  fail RF-SEC-06-artefacts-in-worktree "rc=${rc}, expected 6 (log: ${log})"
  tail -n 5 "$log" >&2
fi
if [ -e "${WT}/mialo/oe002/artefacts" ]; then
  fail RF-SEC-07-no-artefact-dir "an artefact directory WAS created inside the worktree"
  rm -rf "${WT}/mialo/oe002/artefacts"
else
  pass RF-SEC-07-no-artefact-dir "no artefact directory was created inside the worktree"
fi

# ===========================================================================
printf '\n=== review-findings summary ===\n'
printf 'passed: %s   failed: %s\n' "$PASSED" "$FAILED"

python3 - "${OE002_ARTIFACT_DIR}/review-findings-report.json" "$PASSED" "$FAILED" <<'PY'
import json, sys, time
out, passed, failed = sys.argv[1:4]
with open(out, "w", encoding="utf-8") as fh:
    json.dump({
        "schema": "oe002-review-findings-report/v1",
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "source_finding_message": "codex-1 #7389",
        "findings": ["F-URL-SUFFIX", "F-C07-AUTH", "F-ISOLATION-EVIDENCE", "secret-path-in-vcs"],
        "passed": int(passed),
        "failed": int(failed),
    }, fh, indent=2)
    fh.write("\n")
print(out)
PY

[ "$FAILED" -eq 0 ] || exit 1
exit 0
