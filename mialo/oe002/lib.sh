#!/usr/bin/env bash
# OE-002 -- shared library for the local Open edX acceptance harness.
#
# Sourced by acceptance.sh, test_idempotency.sh, test_error_paths.sh,
# teardown.sh and run_all.sh. Not executable on its own.
#
# Transport note: every Open edX management command is run through
# `docker exec`, NOT through `tutor local exec`. `tutor local exec` forwards to
# `docker compose exec`, which hangs indefinitely on this host (Docker Compose
# v5.5.1) even for `echo`, with and without -T. Verified, see RUNBOOK.md
# section "Known environment deviations".

# Deliberately no `set -e` here: callers decide, and the harness needs to keep
# recording results after a failed check.
set -uo pipefail

# ---------------------------------------------------------------------------
# Target configuration
# ---------------------------------------------------------------------------
OE002_SPIKE_ROOT="${OE002_SPIKE_ROOT:-/home/shiblyanastas/openedx-spike}"
OE002_COMPOSE_PROJECT="${OE002_COMPOSE_PROJECT:-mialo_openedx_spike_local}"
OE002_EDXAPP_DIR="${OE002_EDXAPP_DIR:-/openedx/edx-platform}"
OE002_LMS_URL="${OE002_LMS_URL:-http://local.openedx.io}"
OE002_CMS_URL="${OE002_CMS_URL:-http://studio.local.openedx.io}"
OE002_MFE_URL="${OE002_MFE_URL:-http://apps.local.openedx.io/catalog/}"
OE002_HTTP_TIMEOUT="${OE002_HTTP_TIMEOUT:-40}"
OE002_CMD_TIMEOUT="${OE002_CMD_TIMEOUT:-600}"

# The platform name is read back from the running LMS and compared against this
# value. It is the last line of defence against pointing the harness at
# something that is not the local spike.
OE002_EXPECTED_PLATFORM_NAME="${OE002_EXPECTED_PLATFORM_NAME:-MIALO Open edX Spike}"

# Canonical URL targets. Compared exactly, never as a substring: a substring
# match on the host accepted http://local.openedx.io.attacker.invalid, and
# oe002::login would then have POSTed the generated learner password to it.
OE002_ALLOWED_SCHEME="${OE002_ALLOWED_SCHEME:-http}"
OE002_ALLOWED_LMS_HOST="${OE002_ALLOWED_LMS_HOST:-local.openedx.io}"
OE002_ALLOWED_CMS_HOST="${OE002_ALLOWED_CMS_HOST:-studio.local.openedx.io}"
OE002_ALLOWED_MFE_HOST="${OE002_ALLOWED_MFE_HOST:-apps.local.openedx.io}"

# Endpoint that answers 401 anonymously and identifies the caller otherwise.
# Used to prove a session is really the expected learner and not "some" session.
OE002_IDENTITY_PATH="${OE002_IDENTITY_PATH:-/api/user/v1/me}"

# ---------------------------------------------------------------------------
# Test identity -- fixed on purpose so a re-run reuses instead of duplicating.
# ---------------------------------------------------------------------------
OE002_ORG_SHORT="${OE002_ORG_SHORT:-MIALOOE}"
OE002_ORG_NAME="${OE002_ORG_NAME:-MIALO Open edX OE-002 Test Organization}"
OE002_COURSE_NUMBER="${OE002_COURSE_NUMBER:-OE002}"
OE002_COURSE_RUN="${OE002_COURSE_RUN:-2026_T1}"
OE002_COURSE_TITLE="${OE002_COURSE_TITLE:-OE-002 Acceptance Course}"
OE002_COURSE_ID="course-v1:${OE002_ORG_SHORT}+${OE002_COURSE_NUMBER}+${OE002_COURSE_RUN}"
OE002_USER_DOMAIN="${OE002_USER_DOMAIN:-example.com}"
OE002_STAFF_USERNAME="${OE002_STAFF_USERNAME:-mialo_oe002_staff}"
OE002_LEARNER_USERNAME="${OE002_LEARNER_USERNAME:-mialo_oe002_learner}"
OE002_STAFF_EMAIL="${OE002_STAFF_USERNAME}@${OE002_USER_DOMAIN}"
OE002_LEARNER_EMAIL="${OE002_LEARNER_USERNAME}@${OE002_USER_DOMAIN}"

# Credentials live OUTSIDE the repository so they can never be committed.
# Passwords are generated on first use and never printed or logged.
OE002_CREDENTIALS_FILE="${OE002_CREDENTIALS_FILE:-${OE002_SPIKE_ROOT}/.oe002-credentials.json}"

# Generated artefacts (report + raw logs) also live outside the repository.
OE002_ARTIFACT_DIR="${OE002_ARTIFACT_DIR:-${OE002_SPIKE_ROOT}/oe002-artifacts}"
OE002_LOG_DIR="${OE002_ARTIFACT_DIR}/logs"
OE002_REPORT_FILE="${OE002_ARTIFACT_DIR}/oe002-report.json"
OE002_RESULTS_JSONL="${OE002_RESULTS_JSONL:-${OE002_ARTIFACT_DIR}/oe002-results.jsonl}"

# Noise that Open edX writes on every manage.py start-up. Filtered out of the
# human-readable transcript only; the raw logs keep everything.
OE002_LOG_NOISE='DeprecationWarning|warnings\.warn|RemovedInDjango|CheckConstraint|return form_class|import imghdr|casbin|BLOCK_STRUCTURES|fields\.W342|ForeignKey\(unique|System check identified|^WARNINGS:|accessed without a request|openedx_events\.tooling|RequestsDependencyWarning|Could not load OPENEDX_TELEMETRY|Reloaded policy to version|^\[|^[[:space:]]*$'

OE002_LMS_CONTAINER=""
OE002_CMS_CONTAINER=""
OE002_START_EPOCH=""

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
oe002::log()   { printf '%s\n' "$*"; }
oe002::step()  { printf '\n=== %s ===\n' "$*"; }
oe002::warn()  { printf 'WARN: %s\n' "$*" >&2; }

# oe002::die <exit-code> <message...>
# Non-zero exit plus a readable diagnosis, as required by OE-002 item 9.
oe002::die() {
  local rc="$1"; shift
  printf 'OE-002 FATAL: %s\n' "$*" >&2
  printf 'OE-002 FATAL: artefacts (if any) in %s\n' "$OE002_ARTIFACT_DIR" >&2
  exit "$rc"
}

# ---------------------------------------------------------------------------
# Artefact directories
# ---------------------------------------------------------------------------
oe002::prepare_artifacts() {
  # Generated artefacts must not be creatable inside the repository, or a report
  # could be committed by accident while the docs claim otherwise.
  oe002::require_outside_vcs "OE002_ARTIFACT_DIR" "$OE002_ARTIFACT_DIR"
  mkdir -p "$OE002_LOG_DIR" || oe002::die 3 "cannot create artefact dir $OE002_LOG_DIR"
  : >"$OE002_RESULTS_JSONL" || oe002::die 3 "cannot write $OE002_RESULTS_JSONL"
}

# ---------------------------------------------------------------------------
# Container resolution + spike-only safety guard (OE-002 item 10)
# ---------------------------------------------------------------------------

# oe002::container <compose-service>
oe002::container() {
  docker ps --format '{{.Names}}' \
    --filter "label=com.docker.compose.project=${OE002_COMPOSE_PROJECT}" \
    --filter "label=com.docker.compose.service=$1" \
    --filter status=running 2>/dev/null | head -n1
}

# Snapshot of every running container that is NOT part of the spike project.
# Used to prove the pre-existing MIALO services were left alone.
oe002::foreign_containers() {
  docker ps --format '{{.Names}}' 2>/dev/null \
    | grep -v "^${OE002_COMPOSE_PROJECT}-" | sort
}

# oe002::foreign_fingerprint
# One line per foreign running container: name|Id|StartedAt|RestartCount|Status.
# Names alone are not evidence (review finding F-ISOLATION-EVIDENCE): a stop and
# start, or a replacement under the same name, leaves a name list identical while
# the container is demonstrably not the same one. An inspect failure is recorded
# rather than swallowed, so it changes the fingerprint and fails the comparison.
oe002::foreign_fingerprint() {
  local names name line
  names="$(oe002::foreign_containers)"
  [ -n "$names" ] || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    line="$(docker inspect -f '{{.Name}}|{{.Id}}|{{.State.StartedAt}}|{{.RestartCount}}|{{.State.Status}}' \
             "$name" 2>/dev/null)" || line="/${name}|INSPECT-FAILED|||"
    printf '%s\n' "${line#/}"
  done <<< "$names"
}

# The pre-existing MIALO services whose continued, uninterrupted operation
# OE-002 has to prove -- as an EXPLICIT list, not a name pattern.
#
# This host runs several agent lanes that deploy and redeploy their own mialo-*
# containers. A pattern match turned one of them (mialo-unified-codex-app1-1,
# replaced by its own lane mid-batch: id and StartedAt both changed) into an
# isolation violation this harness neither caused nor could prevent. Set
# OE002_PROTECTED_CONTAINERS="" together with OE002_PROTECTED_PATTERN to widen
# the assertion back to a pattern; everything non-spike is diffed and recorded
# either way, so narrowing the assertion hides nothing.
OE002_PROTECTED_CONTAINERS="${OE002_PROTECTED_CONTAINERS-mialo-launch-postgres mialo-slide-preview-db mialo-stage-b-check-db-1}"
OE002_PROTECTED_PATTERN="${OE002_PROTECTED_PATTERN:-mialo}"

# oe002::protected_fingerprint -- fingerprint lines of the protected containers
oe002::protected_fingerprint() {
  local fp name
  fp="$(oe002::foreign_fingerprint)"
  [ -n "$fp" ] || return 0
  if [ -n "$OE002_PROTECTED_CONTAINERS" ]; then
    for name in $OE002_PROTECTED_CONTAINERS; do
      printf '%s\n' "$fp" | grep -F "${name}|" || true
    done
  else
    printf '%s\n' "$fp" | grep -E "^(${OE002_PROTECTED_PATTERN})" || true
  fi
}

# oe002::require_protected_baseline <before-text>
# An empty protected set would let the isolation claim pass VACUOUSLY: with
# nothing to compare, "the pre-existing MIALO services were left alone" would be
# asserted without a single piece of evidence. So an empty baseline is a failure,
# not a trivially satisfied condition.
oe002::require_protected_baseline() {
  local n
  n="$(printf '%s' "$1" | grep -c . || true)"
  if [ "${n:-0}" -ge 1 ]; then
    printf '%s' "$n"
    return 0
  fi
  printf 'no running container is in the protected set (OE002_PROTECTED_CONTAINERS="%s", OE002_PROTECTED_PATTERN="%s"), so the isolation claim would pass without comparing anything' \
    "$OE002_PROTECTED_CONTAINERS" "$OE002_PROTECTED_PATTERN" >&2
  return 1
}

# oe002::protected_changed <before> <after>
# Prints one line per problem and returns 1 when there is any. Every protected
# container must still be present afterwards with an identical Id, StartedAt,
# RestartCount and Status -- so a restart, a stop and a replacement under the
# same name all fail, which is exactly what a name-only comparison missed.
oe002::protected_changed() {
  python3 - "$1" "$2" <<'PY'
import sys

FIELDS = ("id", "started_at", "restart_count", "status")


def parse(text):
    out = {}
    for line in text.splitlines():
        line = line.strip().lstrip("/")
        if not line:
            continue
        parts = line.split("|")
        out[parts[0]] = parts[1:]
    return out


before, after = parse(sys.argv[1]), parse(sys.argv[2])
problems = 0
for name in sorted(before):
    if name not in after:
        print("MISSING protected container %s is no longer running" % name)
        problems += 1
        continue
    for index, field in enumerate(FIELDS):
        old = before[name][index] if index < len(before[name]) else "<missing>"
        new = after[name][index] if index < len(after[name]) else "<missing>"
        if old != new:
            print("CHANGED %s.%s: %s -> %s" % (name, field, old, new))
            problems += 1
for name in sorted(set(after) - set(before)):
    print("NOTE protected container %s appeared during the run" % name)
raise SystemExit(1 if problems else 0)
PY
}

# oe002::fingerprint_diff <before> <after>
# Field-level differences, so a single changed field is visible instead of just
# "something differed".
oe002::fingerprint_diff() {
  python3 - "$1" "$2" <<'PY'
import sys

FIELDS = ("id", "started_at", "restart_count", "status")


def parse(text):
    out = {}
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.lstrip("/").split("|")
        out[parts[0]] = parts[1:]
    return out


before, after = parse(sys.argv[1]), parse(sys.argv[2])
for name in sorted(set(before) - set(after)):
    print("REMOVED container %s" % name)
for name in sorted(set(after) - set(before)):
    print("ADDED container %s" % name)
for name in sorted(set(before) & set(after)):
    b, a = before[name], after[name]
    for index, field in enumerate(FIELDS):
        old = b[index] if index < len(b) else "<missing>"
        new = a[index] if index < len(a) else "<missing>"
        if old != new:
            print("CHANGED %s.%s: %s -> %s" % (name, field, old, new))
PY
}

# oe002::fingerprints_match <before> <after>
# Returns 0 when identical; on any difference prints the field-level diff and
# returns 1.
oe002::fingerprints_match() {
  [ "$1" = "$2" ] && return 0
  oe002::fingerprint_diff "$1" "$2"
  return 1
}

oe002::require_docker() {
  command -v docker >/dev/null 2>&1 || oe002::die 4 "docker CLI not found on PATH"
  docker info >/dev/null 2>&1 || oe002::die 4 "docker daemon not reachable"
}

# Hard pre-flight: refuse to touch anything unless this really is the local
# spike. Fails closed.
oe002::require_spike() {
  oe002::require_docker

  # URLs first, and before anything that could carry a credential: oe002::login
  # POSTs the generated learner password to OE002_LMS_URL, so a look-alike host
  # has to be rejected before the harness ever reaches that point.
  oe002::require_url "OE002_LMS_URL" "$OE002_LMS_URL" "$OE002_ALLOWED_LMS_HOST"
  oe002::require_url "OE002_CMS_URL" "$OE002_CMS_URL" "$OE002_ALLOWED_CMS_HOST"
  oe002::require_url "OE002_MFE_URL" "$OE002_MFE_URL" "$OE002_ALLOWED_MFE_HOST"

  OE002_LMS_CONTAINER="$(oe002::container lms)"
  OE002_CMS_CONTAINER="$(oe002::container cms)"
  [ -n "$OE002_LMS_CONTAINER" ] || oe002::die 5 \
    "no running 'lms' service in compose project '${OE002_COMPOSE_PROJECT}'. Refusing to guess a target."
  [ -n "$OE002_CMS_CONTAINER" ] || oe002::die 5 \
    "no running 'cms' service in compose project '${OE002_COMPOSE_PROJECT}'. Refusing to guess a target."

  local spike_count
  spike_count=$(docker ps --format '{{.Names}}' \
    --filter "label=com.docker.compose.project=${OE002_COMPOSE_PROJECT}" | wc -l | tr -d ' ')
  [ "$spike_count" -ge 2 ] || oe002::die 5 \
    "compose project '${OE002_COMPOSE_PROJECT}' has only ${spike_count} running container(s); expected a full platform."

  # Final gate: ask the running LMS itself which platform it is.
  local name
  name="$(oe002::orm_value lms "
from django.conf import settings
print('OE002_RB_PLATFORM_NAME=%s' % settings.PLATFORM_NAME)
" OE002_RB_PLATFORM_NAME)"
  [ -n "$name" ] || oe002::die 5 "could not read PLATFORM_NAME from ${OE002_LMS_CONTAINER}"
  [ "$name" = "$OE002_EXPECTED_PLATFORM_NAME" ] || oe002::die 5 \
    "target LMS reports PLATFORM_NAME='${name}', expected '${OE002_EXPECTED_PLATFORM_NAME}'. Refusing to continue."

  oe002::log "spike guard: urls canonical (lms=${OE002_ALLOWED_LMS_HOST} cms=${OE002_ALLOWED_CMS_HOST} mfe=${OE002_ALLOWED_MFE_HOST})"
  oe002::log "spike guard: project=${OE002_COMPOSE_PROJECT} containers=${spike_count} lms=${OE002_LMS_CONTAINER} cms=${OE002_CMS_CONTAINER}"
  oe002::log "spike guard: PLATFORM_NAME='${name}' course_id=${OE002_COURSE_ID}"
}

# ---------------------------------------------------------------------------
# Credentials (generated, 0600, outside version control, never printed)
# ---------------------------------------------------------------------------
oe002::ensure_credentials() {
  # Before anything is written: a credentials path inside a worktree would put a
  # secret where the RUNBOOK promises it can never be committed.
  oe002::require_outside_vcs "OE002_CREDENTIALS_FILE" "$OE002_CREDENTIALS_FILE"
  if [ -f "$OE002_CREDENTIALS_FILE" ]; then
    chmod 600 "$OE002_CREDENTIALS_FILE" 2>/dev/null || true
    return 0
  fi
  local dir
  dir="$(dirname "$OE002_CREDENTIALS_FILE")"
  mkdir -p "$dir" || oe002::die 3 "cannot create $dir"
  python3 - "$OE002_CREDENTIALS_FILE" "$OE002_USER_DOMAIN" \
            "$OE002_STAFF_USERNAME" "$OE002_LEARNER_USERNAME" <<'PY' || \
    oe002::die 3 "could not generate $1"
import json, os, secrets, sys, tempfile
path, domain, staff, learner = sys.argv[1:5]
data = {
    "note": "OE-002 local spike test identities. Generated, never logged. Kept outside version control on purpose.",
    "domain": domain,
    "staff":   {"username": staff,   "password": secrets.token_urlsafe(18)},
    "learner": {"username": learner, "password": secrets.token_urlsafe(18)},
}
for key in ("staff", "learner"):
    data[key]["email"] = "%s@%s" % (data[key]["username"], domain)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, "w") as fh:
    json.dump(data, fh, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
  chmod 600 "$OE002_CREDENTIALS_FILE"
}

# oe002::password <staff|learner>   -- prints to stdout for internal use only.
oe002::password() {
  python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]]["password"])' \
    "$OE002_CREDENTIALS_FILE" "$1"
}

# ---------------------------------------------------------------------------
# Open edX management commands
# ---------------------------------------------------------------------------

# oe002::manage <service:lms|cms> <logfile> [manage.py args...]
# Runs ./manage.py <service> <args...> with stdin closed and returns the exit
# code. The service selects BOTH the container and the manage.py variant --
# Open edX's manage.py requires `lms`/`cms` as its first positional argument,
# so passing the command name there instead fails with "invalid choice".
oe002::manage() {
  local service="$1" log="$2"; shift 2
  local container
  case "$service" in
    lms) container="$OE002_LMS_CONTAINER" ;;
    cms) container="$OE002_CMS_CONTAINER" ;;
    *) oe002::die 2 "oe002::manage: unknown service '$service'" ;;
  esac
  [ -n "$container" ] || oe002::die 5 "oe002::manage: no container resolved for '$service' (spike guard not run?)"
  timeout "$OE002_CMD_TIMEOUT" docker exec -w "$OE002_EDXAPP_DIR" "$container" \
    ./manage.py "$service" "$@" </dev/null >"$log" 2>&1
}

# oe002::manage_stdin <service> <logfile> <stdin-text> [manage.py args...]
# Same, but feeds stdin -- force_publish and delete_course prompt via input()
# and die on EOFError without it.
oe002::manage_stdin() {
  local service="$1" log="$2" feed="$3"; shift 3
  local container
  case "$service" in
    lms) container="$OE002_LMS_CONTAINER" ;;
    cms) container="$OE002_CMS_CONTAINER" ;;
    *) oe002::die 2 "oe002::manage_stdin: unknown service '$service'" ;;
  esac
  [ -n "$container" ] || oe002::die 5 "oe002::manage_stdin: no container resolved for '$service'"
  printf '%s\n' "$feed" | timeout "$OE002_CMD_TIMEOUT" \
    docker exec -i -w "$OE002_EDXAPP_DIR" "$container" \
    ./manage.py "$service" "$@" >"$log" 2>&1
}

# oe002::orm_log <service> <logfile> <python-source>
# Runs <python-source> through `manage.py <service> shell -c`, writes the RAW
# combined output to <logfile> and prints only the marker lines (OE002_RB_*), so
# Django start-up noise cannot corrupt a parsed result. The caller chooses the
# log path, which matters when a failure has to be diagnosable from the file the
# caller is already reporting. Returns the exit code of manage.py.
oe002::orm_log() {
  local service="$1" log="$2" py="$3"
  local container
  case "$service" in
    lms) container="$OE002_LMS_CONTAINER" ;;
    cms) container="$OE002_CMS_CONTAINER" ;;
    *) oe002::die 2 "oe002::orm_log: unknown service '$service'" ;;
  esac
  [ -n "$container" ] || oe002::die 5 "oe002::orm_log: no container resolved for '$service'"
  timeout "$OE002_CMD_TIMEOUT" docker exec -w "$OE002_EDXAPP_DIR" "$container" \
    ./manage.py "$service" shell -c "$py" </dev/null >"$log" 2>&1
  local rc=$?
  grep '^OE002_RB_' "$log" 2>/dev/null
  return $rc
}

# oe002::orm <service> <python-source>
# Same, with an auto-generated log path inside OE002_LOG_DIR.
oe002::orm() {
  local service="$1" py="$2"
  case "$service" in
    lms|cms) : ;;
    *) oe002::die 2 "oe002::orm: unknown service '$service'" ;;
  esac
  oe002::orm_log "$service" "${OE002_LOG_DIR}/orm-${service}-$(date +%s%N).log" "$py"
}

# oe002::orm_value <service> <python-source> <marker-name>
# Prints the value after 'MARKER=' from a single-marker query, empty on failure.
oe002::orm_value() {
  local marker="$3"
  local out
  out="$(oe002::orm "$1" "$2")" || return 1
  printf '%s\n' "$out" | grep "^${marker}=" | head -n1 | cut -d= -f2-
}

# oe002::clean <logfile>   -- human-readable excerpt of a raw log
oe002::clean() {
  grep -viE "$OE002_LOG_NOISE" "$1" 2>/dev/null | tail -n 12
}

# oe002::entity_counts
# Prints one KEY=N line per OE-002 test entity, read back through the ORM in a
# single manage.py invocation. Shared by acceptance check C08, by the
# idempotency test and by teardown, so all three count exactly the same way.
# This is a management command, not raw SQL.
oe002::entity_counts() {
  oe002::orm lms "
from django.contrib.auth import get_user_model
from common.djangoapps.student.models import CourseEnrollment
from openedx.core.djangoapps.content.course_overviews.models import CourseOverview
from organizations.models import Organization
U = get_user_model()
cid = '${OE002_COURSE_ID}'
print('OE002_RB_D_ORG=%d' % Organization.objects.filter(short_name__iexact='${OE002_ORG_SHORT}').count())
print('OE002_RB_D_COURSE=%d' % CourseOverview.objects.filter(id=cid).count())
print('OE002_RB_D_STAFF_NAME=%d' % U.objects.filter(username='${OE002_STAFF_USERNAME}').count())
print('OE002_RB_D_STAFF_MAIL=%d' % U.objects.filter(email='${OE002_STAFF_EMAIL}').count())
print('OE002_RB_D_LEARNER_NAME=%d' % U.objects.filter(username='${OE002_LEARNER_USERNAME}').count())
print('OE002_RB_D_LEARNER_MAIL=%d' % U.objects.filter(email='${OE002_LEARNER_EMAIL}').count())
print('OE002_RB_D_ENROLLMENT=%d' % CourseEnrollment.objects.filter(course_id=cid, user__email='${OE002_LEARNER_EMAIL}').count())
print('OE002_RB_D_COURSE_ENROLLMENTS=%d' % CourseEnrollment.objects.filter(course_id=cid).count())
" 2>/dev/null | sed 's/^OE002_RB_D_//'
}

# ---------------------------------------------------------------------------
# Canonical URL validation (review finding F-URL-SUFFIX)
# ---------------------------------------------------------------------------
# oe002::check_url <url> <allowed-host>
# Returns 0 only for a canonical URL whose host matches exactly. On refusal it
# prints one reason line and returns 1, so a rejection is diagnosable. Rejected:
# wrong scheme, any userinfo, host look-alikes and suffixes, non-default port,
# query string, fragment, unparsable input. Fails closed.
oe002::check_url() {
  python3 - "$1" "$2" "$OE002_ALLOWED_SCHEME" <<'PY'
import sys
from urllib.parse import urlsplit

url, allowed_host, allowed_scheme = sys.argv[1], sys.argv[2], sys.argv[3]


def bad(reason):
    print(reason)
    raise SystemExit(1)


try:
    parts = urlsplit(url)
    port = parts.port          # raises on a malformed port
except ValueError as exc:
    bad("unparsable URL: %s" % exc)

if parts.scheme != allowed_scheme:
    bad("scheme is '%s', expected exactly '%s'" % (parts.scheme or "<empty>", allowed_scheme))
if parts.username is not None or parts.password is not None:
    bad("URL carries userinfo, which is never allowed")
host = (parts.hostname or "").rstrip(".").lower()
if not host:
    bad("URL carries no host")
if host != allowed_host.lower().rstrip("."):
    bad("host is '%s', expected exactly '%s' (look-alikes and suffixes are rejected)"
        % (host, allowed_host))
default_port = {"http": 80, "https": 443}.get(allowed_scheme)
if port is not None and port != default_port:
    bad("port %s is not the %s default %s" % (port, allowed_scheme, default_port))
if parts.query:
    bad("URL carries a query string")
if parts.fragment:
    bad("URL carries a fragment")
PY
}

# oe002::require_url <label> <url> <allowed-host>
oe002::require_url() {
  local reason rc
  reason="$(oe002::check_url "$2" "$3")"; rc=$?
  [ $rc -eq 0 ] || oe002::die 5 "${1}='${2}' rejected by the URL guard: ${reason}"
}

# oe002::host_is_allowed <url>
# True only when the URL's host is one of the three canonical spike hosts.
# Applied to EFFECTIVE urls, i.e. after redirects have been followed, so a chain
# that leaves the spike is caught here instead of being trusted to curl's
# cookie-domain rules. This is the check that keeps a credential-carrying request
# from handing a session or a password to a host nobody approved.
oe002::host_is_allowed() {
  local host
  host="$(python3 - "$1" <<'PY'
import sys
from urllib.parse import urlsplit
try:
    print((urlsplit(sys.argv[1]).hostname or "").rstrip(".").lower())
except ValueError:
    print("")
PY
)"
  [ -n "$host" ] || return 1
  case " ${OE002_ALLOWED_LMS_HOST} ${OE002_ALLOWED_CMS_HOST} ${OE002_ALLOWED_MFE_HOST} " in
    *" ${host} "*) return 0 ;;
  esac
  return 1
}

# oe002::require_lms_url <purpose>
# Point-of-use re-validation of the LMS URL, called by every function that is
# about to transmit a secret. require_spike validated these once at start-up; a
# function that actually sends a password or presents a session cookie must not
# trust that nothing mutated the environment in between. Returns 4 on refusal.
oe002::require_lms_url() {
  local reason rc
  reason="$(oe002::check_url "${OE002_LMS_URL}" "$OE002_ALLOWED_LMS_HOST")"; rc=$?
  if [ $rc -ne 0 ]; then
    printf 'refusing to %s: OE002_LMS_URL rejected by the URL guard (%s)\n' "$1" "$reason" >&2
    return 4
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Secret and artefact paths must live outside version control
# ---------------------------------------------------------------------------
# oe002::check_outside_vcs <path>
# Prints the offending .git path and returns 1 when <path> sits inside a git
# worktree. Walks the parent chain instead of calling git, so the harness never
# invokes version control itself.
oe002::check_outside_vcs() {
  python3 - "$1" <<'PY'
import os, sys
target = os.path.abspath(sys.argv[1])
current = target if os.path.isdir(target) else os.path.dirname(target)
if not current:
    current = "/"
while True:
    marker = os.path.join(current, ".git")
    if os.path.exists(marker):
        print(marker)
        raise SystemExit(1)
    parent = os.path.dirname(current)
    if parent == current:
        break
    current = parent
PY
}

# oe002::require_outside_vcs <label> <path>
oe002::require_outside_vcs() {
  local hit
  if hit="$(oe002::check_outside_vcs "$2")"; then
    return 0
  fi
  oe002::die 6 "${1}='${2}' lies inside a version-control worktree (found ${hit}). A secret or artefact path must never be creatable inside the repository."
}

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------
# oe002::http_code <url> [extra curl args...]
oe002::http_code() {
  local url="$1" code
  shift
  # curl already prints 000 when it cannot connect AND exits non-zero, so a
  # `|| printf 000` fallback concatenated into "000000". Take curl's own output
  # and substitute only when it is genuinely empty.
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$OE002_HTTP_TIMEOUT" \
          -L "$@" "$url" 2>/dev/null)"
  printf '%s' "${code:-000}"
}

# oe002::login <cookiejar> <email> <password>
# Session login against the LMS. Distinct non-zero codes so a failure can be
# diagnosed without ever echoing the password:
#   1 no CSRF cookie / pre-flight failed
#   2 login_ajax not HTTP 200
#   3 success != true
#   4 refused BEFORE any request: OE002_LMS_URL is not canonical
#   5 a request left the allowed hosts, or the credential POST was redirected
#
# This is the only place a password is transmitted, so the protections are
# structural rather than advisory: the POST uses --max-redirs 0 and no -L, which
# makes it impossible for curl to replay the body to a redirect target, and the
# effective URL plus the redirect count are then asserted so the property is
# proven on every call instead of being inferred from the flags.
oe002::login() {
  local jar="$1" email="$2" password="$3"
  local csrf body code meta rest eff redirects

  oe002::require_lms_url "transmit a credential" || return 4

  # The CSRF pre-flight carries no secret, but it follows redirects and writes
  # cookies, so where it ends up still has to be an allowed host.
  meta="$(curl -s -c "$jar" -o /dev/null -w '%{http_code} %{url_effective}' \
          --max-time "$OE002_HTTP_TIMEOUT" -L "${OE002_LMS_URL}/login" 2>/dev/null)" || return 1
  eff="${meta#* }"
  if ! oe002::host_is_allowed "$eff"; then
    printf 'refusing to continue: the login pre-flight ended at %s, which is not an allowed host\n' "$eff" >&2
    return 5
  fi
  csrf=$(awk '$6=="csrftoken"{print $7}' "$jar" 2>/dev/null | tail -1)
  [ -n "$csrf" ] || return 1

  body=$(curl -s -b "$jar" -c "$jar" --max-redirs 0 \
           -w '\n%{http_code} %{url_effective} %{num_redirects}' \
           --max-time "$OE002_HTTP_TIMEOUT" \
           -H "X-CSRFToken: $csrf" -H "Referer: ${OE002_LMS_URL}/login" \
           --data-urlencode "email=${email}" \
           --data-urlencode "password=${password}" \
           --data-urlencode "remember=false" \
           "${OE002_LMS_URL}/login_ajax" 2>/dev/null) || return 2
  meta=$(printf '%s' "$body" | tail -n1)
  code="${meta%% *}"
  rest="${meta#* }"
  eff="${rest% *}"
  redirects="${rest##* }"
  [ "$code" = "200" ] || return 2
  if [ "$redirects" != "0" ]; then
    printf 'the credential request followed %s redirect(s); it must follow none\n' "$redirects" >&2
    return 5
  fi
  if ! oe002::host_is_allowed "$eff"; then
    printf 'the credential request ended at %s, which is not an allowed host\n' "$eff" >&2
    return 5
  fi
  printf '%s' "$body" | head -n -1 | grep -q '"success"[[:space:]]*:[[:space:]]*true' || return 3
  return 0
}

# ---------------------------------------------------------------------------
# Learner-view helpers (review finding F-C07-AUTH)
#
# A bare HTTP status is not evidence of a learner view. /dashboard answers 200
# for an anonymous caller too, redirected to apps.local.openedx.io/authn/login.
# So every probe is judged on status AND effective URL, and the session itself is
# proven against an endpoint that answers 401 anonymously.
# ---------------------------------------------------------------------------

# oe002::classify_url <url> -> prints LOGIN_REDIRECT or OK
oe002::classify_url() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlsplit
try:
    segments = [s for s in urlsplit(sys.argv[1]).path.split("/") if s]
except ValueError:
    print("UNPARSABLE"); raise SystemExit
print("LOGIN_REDIRECT" if segments and segments[0] in ("authn", "login", "signin", "register") else "OK")
PY
}

# oe002::probe <jar-or-empty> <url> -> prints "CODE<TAB>EFFECTIVE_URL"
oe002::probe() {
  local jar="$1" url="$2"
  if [ -n "$jar" ]; then
    curl -s -b "$jar" -o /dev/null -w '%{http_code}\t%{url_effective}' \
      --max-time "$OE002_HTTP_TIMEOUT" -L "$url" 2>/dev/null || printf '000\t-'
  else
    curl -s -o /dev/null -w '%{http_code}\t%{url_effective}' \
      --max-time "$OE002_HTTP_TIMEOUT" -L "$url" 2>/dev/null || printf '000\t-'
  fi
}

# oe002::judge_view <label> <code> <effective-url>
# Pure verdict, no I/O: HTTP 200, an allowed host, and no login/authn redirect.
# Sets OE002_PROBE_CODE / OE002_PROBE_URL / OE002_PROBE_CLASS and prints the
# refusal reason. Split out from assert_learner_view so the foreign-host and
# login-redirect cases can be unit-tested with synthetic inputs instead of
# needing a hostile server.
oe002::judge_view() {
  local label="$1" code="$2" eff="$3" class
  class="$(oe002::classify_url "$eff")"
  OE002_PROBE_CODE="$code"
  OE002_PROBE_URL="$eff"
  OE002_PROBE_CLASS="$class"
  if [ "$code" != "200" ]; then
    printf '%s: HTTP %s, expected 200 (effective url %s)' "$label" "$code" "$eff" >&2
    return 1
  fi
  if ! oe002::host_is_allowed "$eff"; then
    OE002_PROBE_CLASS="FOREIGN_HOST"
    printf '%s: HTTP 200 but the request ended at %s, which is not an allowed host -- a session cookie could have followed it there' "$label" "$eff" >&2
    return 1
  fi
  if [ "$class" != "OK" ]; then
    printf '%s: HTTP 200 but the effective url %s is a login/authn redirect -- this is not an authenticated learner view' "$label" "$eff" >&2
    return 1
  fi
  return 0
}

# oe002::assert_learner_view <jar-or-empty> <label> <url>
oe002::assert_learner_view() {
  local jar="$1" label="$2" url="$3" out code eff
  oe002::require_lms_url "present a session cookie" || return 4
  out="$(oe002::probe "$jar" "$url")"
  code="${out%%$'\t'*}"
  eff="${out#*$'\t'}"
  oe002::judge_view "$label" "$code" "$eff"
}

# oe002::assert_session_is_learner <jar> <expected-username>
# Proves the session really belongs to the expected learner. Three conditions,
# all required: the LMS URL must still be canonical at the point the cookie is
# presented, the identity endpoint must answer 401 anonymously (otherwise it
# cannot discriminate anything), and it must name the expected user.
oe002::assert_session_is_learner() {
  local jar="$1" want="$2" body got anon
  oe002::require_lms_url "present a session cookie" || return 4
  body="$(curl -s -b "$jar" --max-redirs 0 --max-time "$OE002_HTTP_TIMEOUT" \
          "${OE002_LMS_URL}${OE002_IDENTITY_PATH}" 2>/dev/null)"
  got="$(printf '%s' "$body" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("username") or "")
except Exception:
    print("")
' 2>/dev/null)"
  anon="$(curl -s -o /dev/null -w '%{http_code}' --max-redirs 0 --max-time "$OE002_HTTP_TIMEOUT" \
          "${OE002_LMS_URL}${OE002_IDENTITY_PATH}" 2>/dev/null || printf '000')"
  OE002_SESSION_USER="$got"
  OE002_SESSION_ANON_CODE="$anon"
  if [ "$anon" != "401" ]; then
    printf 'the identity endpoint %s answers HTTP %s anonymously, so it cannot prove a session is authenticated' \
      "$OE002_IDENTITY_PATH" "$anon" >&2
    return 1
  fi
  if [ "$got" != "$want" ]; then
    printf 'the session identifies as "%s", expected the learner "%s"' "${got:-<empty>}" "$want" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Result recording
# ---------------------------------------------------------------------------
# oe002::record <id> <requirement> <name> <PASS|FAIL|SKIP> <detail> <seconds>
oe002::record() {
  python3 - "$OE002_RESULTS_JSONL" "$@" <<'PY'
import json, sys
path, cid, req, name, status, detail, seconds = sys.argv[1:8]
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps({
        "id": cid, "requirement": req, "name": name,
        "status": status, "detail": detail, "seconds": round(float(seconds), 3),
    }, ensure_ascii=False) + "\n")
PY
  local mark='PASS'
  [ "$4" = "PASS" ] || mark="$4"
  printf '[%s] %s %s -- %s\n' "$mark" "$1" "$3" "$5"
}

# oe002::timer_start / oe002::timer_end -- crude per-check timing
oe002::timer_start() { OE002_T0=$(date +%s.%N); }
oe002::timer_end()   { python3 -c 'import sys,time;print("%.3f"%(time.time()-float(sys.argv[1])))' "$OE002_T0"; }

# ---------------------------------------------------------------------------
# Report assembly
# ---------------------------------------------------------------------------
oe002::write_report() {
  local exit_code="$1"
  python3 - "$OE002_RESULTS_JSONL" "$OE002_REPORT_FILE" "$exit_code" \
            "$OE002_COMPOSE_PROJECT" "$OE002_LMS_URL" "$OE002_CMS_URL" "$OE002_MFE_URL" \
            "$OE002_EXPECTED_PLATFORM_NAME" "$OE002_ORG_SHORT" "$OE002_COURSE_ID" \
            "$OE002_STAFF_USERNAME" "$OE002_LEARNER_USERNAME" "$OE002_ARTIFACT_DIR" <<'PY'
import json, os, socket, sys, time

jsonl, out, exit_code, project, lms, cms, mfe, platform, org, course, staff, learner, artefacts = sys.argv[1:14]

checks = []
if os.path.exists(jsonl):
    with open(jsonl, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                checks.append(json.loads(line))

passed = sum(1 for c in checks if c["status"] == "PASS")
failed = sum(1 for c in checks if c["status"] == "FAIL")
skipped = sum(1 for c in checks if c["status"] == "SKIP")

report = {
    "schema": "oe002-acceptance-report/v1",
    "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "host": socket.gethostname(),
    "exit_code": int(exit_code),
    "target": {
        "compose_project": project,
        "lms_url": lms,
        "cms_url": cms,
        "mfe_url": mfe,
        "expected_platform_name": platform,
        "guard": "refuses any target whose compose project, LMS hostname or PLATFORM_NAME does not match the local spike",
    },
    "openedx_baseline": {
        "worktree": os.environ.get("OE002_WORKTREE", ""),
        "branch": os.environ.get("OE002_BASELINE_BRANCH", ""),
        "head": os.environ.get("OE002_BASELINE_HEAD", ""),
        "note": "supplied by the operator via OE002_BASELINE_* so this harness never invokes git itself",
    },
    "identity": {
        "org_short_name": org,
        "course_id": course,
        "staff_username": staff,
        "learner_username": learner,
        "credentials_file": os.environ.get("OE002_CREDENTIALS_FILE", ""),
        "note": "passwords are generated, stored 0600 outside version control and never printed",
    },
    "checks": checks,
    "summary": {"total": len(checks), "passed": passed, "failed": failed, "skipped": skipped},
    "artifacts": {"dir": artefacts, "logs": os.path.join(artefacts, "logs")},
}
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w", encoding="utf-8") as fh:
    json.dump(report, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
print(out)
PY
}
