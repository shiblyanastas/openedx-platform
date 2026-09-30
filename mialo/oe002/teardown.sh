#!/usr/bin/env bash
# OE-002 teardown -- remove every entity the acceptance path created.
#
# Dry run by default. Nothing is touched until --apply is given.
#
# Usage:
#   teardown.sh                show what would be removed
#   teardown.sh --apply        remove it
#   teardown.sh --apply --purge-credentials   also delete the generated passwords
#
# Exit: 0 removed (or nothing to remove), 1 a step failed, 2 bad usage,
#       3-5 environment/spike-guard failure.
#
# DEVIATIONS, declared on purpose. Open edX ships an official management command
# for deleting a course (`cms delete_course`) but none for deleting an
# organisation or a user, so those steps go through `manage.py lms shell -c`.
# That is still a management command, never a direct SQL write. Four findings
# from actually running this shaped the implementation:
#
#   * `organizations.api.remove_organization` only DEACTIVATES the row (its data
#     layer calls `_inactivate_organization`), so a hard delete has to follow it --
#     otherwise the count never reaches zero and the next acceptance run silently
#     reuses a dead organisation.
#   * Deleting the organisation raises ProtectedError: `CatalogCourse.org`
#     references it with on_delete=PROTECT, and that row appears as a side effect
#     of creating the course.
#   * Deleting a user raises MySQL IntegrityError 1451: simple-history tables such
#     as `student_courseaccessrolehistory` reference `auth_user` through a foreign
#     key that does not cascade.
#     Both are handled by sweeping every model that points at the instance before
#     deleting it, instead of hard-coding the two tables found so far.
#   * `retire_user` was rejected: it anonymises instead of removing, needs the
#     retirement pipeline configured, and leaves rows behind. Teardown here means
#     "the entity is gone", which retirement does not deliver.
#
# Order is enrollments -> course -> organisation -> users: the course must go
# before the organisation that CatalogCourse links them through.

set -uo pipefail

OE002_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mialo/oe002/lib.sh
. "${OE002_HERE}/lib.sh"

APPLY=0
PURGE_CREDS=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    --apply) APPLY=1; shift ;;
    --purge-credentials) PURGE_CREDS=1; shift ;;
    *) oe002::die 2 "unknown argument '$1' (try --help)" ;;
  esac
done
if [ "$PURGE_CREDS" = "1" ] && [ "$APPLY" != "1" ]; then
  oe002::die 2 "--purge-credentials requires --apply"
fi

oe002::prepare_artifacts
oe002::require_spike
oe002::ensure_credentials

oe002::step "entity counts BEFORE"
oe002::entity_counts | tee "${OE002_ARTIFACT_DIR}/teardown-counts-before.txt"

if [ "$APPLY" != "1" ]; then
  oe002::step "dry run -- nothing was changed"
  oe002::log "would remove, in this order:"
  oe002::log "  1. every CourseEnrollment row on ${OE002_COURSE_ID}"
  oe002::log "  2. the course via 'manage.py cms delete_course ${OE002_COURSE_ID} --remove-assets'"
  oe002::log "  3. the organisation ${OE002_ORG_SHORT} (deactivate, sweep protected references, delete)"
  oe002::log "  4. the users ${OE002_STAFF_USERNAME} and ${OE002_LEARNER_USERNAME} (sweep references, delete)"
  oe002::log "re-run with --apply to actually remove them."
  exit 0
fi

FAILED=0

# ---------------------------------------------------------------------------
# Step 1: enrollments on the course
# ---------------------------------------------------------------------------
oe002::step "step 1/4: removing enrollments"
log="${OE002_LOG_DIR}/teardown-enrollments.log"
oe002::orm_log lms "$log" "
from common.djangoapps.student.models import CourseEnrollment
n, _ = CourseEnrollment.objects.filter(course_id='${OE002_COURSE_ID}').delete()
print('OE002_RB_T_ENROLLMENTS_DELETED=%d' % n)
"
rc=$?
if [ $rc -ne 0 ]; then
  FAILED=1
  printf 'OE-002 DIAGNOSIS teardown step 1: enrollment removal exited %s; raw output in %s\n' "$rc" "$log" >&2
  oe002::clean "$log" >&2
fi

# ---------------------------------------------------------------------------
# Step 2: the course, through the official management command
# ---------------------------------------------------------------------------
oe002::step "step 2/4: deleting the course (official cms delete_course)"
log="${OE002_LOG_DIR}/teardown-delete-course.log"
# delete_course asks twice, both with default="no"; feed both confirmations.
oe002::manage_stdin cms "$log" "y
y" delete_course "$OE002_COURSE_ID" --remove-assets
rc=$?
if grep -q "^Deleted course" "$log"; then
  oe002::log "course deleted: $(grep -oE '^Deleted course .*' "$log" | head -n1)"
elif grep -q "Course not found" "$log"; then
  oe002::log "course was already absent -- nothing to delete (exit ${rc})"
else
  FAILED=1
  printf 'OE-002 DIAGNOSIS teardown step 2: delete_course exited %s without a recognisable confirmation\n' "$rc" >&2
  oe002::clean "$log" >&2
fi

# ---------------------------------------------------------------------------
# Steps 3 + 4: organisation and users, each preceded by a reference sweep
# ---------------------------------------------------------------------------
oe002::step "step 3-4/4: removing organisation and users"
log="${OE002_LOG_DIR}/teardown-orm.log"
oe002::orm_log lms "$log" "
from django.apps import apps
from django.contrib.auth import get_user_model
from organizations import api as organizations_api
from organizations.models import Organization
U = get_user_model()


def fk_fields_pointing_at(target):
    # Every (model, field-name) whose foreign key targets the given model.
    # No backticks anywhere in this block: it is embedded in a double-quoted
    # shell string, where a backtick would become a command substitution.
    found = []
    for model in apps.get_models():
        if model is target:
            continue
        try:
            fields = model._meta.get_fields()
        except Exception:
            continue
        for field in fields:
            if getattr(field, 'related_model', None) is not target:
                continue
            if getattr(field, 'many_to_one', False) or getattr(field, 'one_to_one', False):
                found.append((model, field.name))
    return found


def sweep(target, instance, label):
    # Delete everything that points at the instance, then the instance itself.
    #
    # Several Open edX tables reference auth_user and Organization through keys
    # that neither cascade nor allow deletion, so a plain .delete() raises. The
    # reference list is resolved once and then re-walked, because removing one
    # row can expose the next blocker.
    references = fk_fields_pointing_at(target)
    removed = 0
    for round_no in range(3):
        blocked_this_round = 0
        for model, name in references:
            try:
                deleted, _ = model._default_manager.filter(**{name: instance}).delete()
            except Exception as exc:
                blocked_this_round += 1
                print('OE002_RB_T_FKBLOCK=%s round=%d %s.%s:%s'
                      % (label, round_no, model.__name__, name, type(exc).__name__))
                continue
            removed += deleted
        if blocked_this_round == 0:
            break
    try:
        deleted, _ = target.objects.filter(pk=instance.pk).delete()
        print('OE002_RB_T_%s=%s deleted=%d swept=%d' % (label, instance.pk, deleted, removed))
    except Exception as exc:
        print('OE002_RB_T_%s=%s deleted=0 swept=%d error=%s'
              % (label, instance.pk, removed, type(exc).__name__))


org = Organization.objects.filter(short_name__iexact='${OE002_ORG_SHORT}').first()
if org is None:
    print('OE002_RB_T_ORG=absent')
else:
    # The documented API call first -- it deactivates -- then the hard delete.
    try:
        organizations_api.remove_organization(org.id)
        print('OE002_RB_T_ORG_DEACTIVATED=id=%s' % org.id)
    except Exception as exc:
        print('OE002_RB_T_ORG_DEACTIVATE_FAILED=%s' % type(exc).__name__)
    sweep(Organization, org, 'ORG')

for username in ('${OE002_STAFF_USERNAME}', '${OE002_LEARNER_USERNAME}'):
    user = U.objects.filter(username=username).first()
    if user is None:
        print('OE002_RB_T_USER_%s=absent' % username)
        continue
    sweep(U, user, 'USER_%s' % username)
"
rc=$?
if [ $rc -ne 0 ]; then
  FAILED=1
  printf 'OE-002 DIAGNOSIS teardown step 3-4: the ORM cleanup exited %s; raw output in %s\n' "$rc" "$log" >&2
  oe002::clean "$log" >&2
fi

# ---------------------------------------------------------------------------
if [ "$PURGE_CREDS" = "1" ] && [ -f "$OE002_CREDENTIALS_FILE" ]; then
  rm -f "$OE002_CREDENTIALS_FILE"
  oe002::log "credentials purged: ${OE002_CREDENTIALS_FILE}"
fi

oe002::step "entity counts AFTER"
oe002::entity_counts | tee "${OE002_ARTIFACT_DIR}/teardown-counts-after.txt"

# Every OE-002 entity must now be gone. Asserted, not assumed.
leftover="$(oe002::entity_counts | grep -vE '^[A-Z_]+=0$' || true)"
if [ -n "$leftover" ]; then
  FAILED=1
  printf 'OE-002 DIAGNOSIS teardown: entities survived the teardown:\n%s\n' "$leftover" >&2
fi

oe002::step "teardown summary"
if [ "$FAILED" = "0" ]; then
  oe002::log "teardown complete: no OE-002 entity remains"
  exit 0
fi
oe002::log "teardown finished with failures -- see the diagnoses above" >&2
exit 1
