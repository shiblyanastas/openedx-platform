# OE-002 — local Open edX acceptance path

A reproducible operator script that proves the MIALO integration prerequisites
against the **isolated local Open edX spike** and nothing else.

Lane: `qwen/openedx-oe-002` · baseline `9e67d1429d5ab49a36fb9881a26457efeee0bb89`
(`release/verawood.1`, branch `mialo/verawood-spike`) · supervisor `codex-1`.

---

## 1. What it proves

| OE-002 item | Check | How it is proved |
|---|---|---|
| 1 LMS, Studio, login, MFE reachable | `C01` | HTTP 200 on `local.openedx.io/`, `studio.local.openedx.io/`, `/login`, `apps.local.openedx.io/catalog/` |
| 2 test organisation + test course, idempotent | `C02` | `cms add_organization`, `cms create_course split`; accepts both `Created …` and `Course already exists` |
| 3 course can be published | `C03` | `cms force_publish --commit`; accepts `Success! Published` and `already in published state` |
| 4 own test learner, idempotent | `C04` | `cms create_test_users --ignore_user_already_exists` |
| 5 learner can be enrolled | `C05` | `lms enroll_user_in_course` (documented idempotent, swallows `CourseEnrollmentExistsError`) |
| 6 enrollment provable by an **independent** read-back | `C06` | primary: learner session login + `GET /api/enrollment/v1/enrollment`. secondary: ORM query via `manage.py lms shell -c`. No raw SQL. |
| 7 course reachable from the learner's view | `C07` | C07 logs in as the learner **itself**, proves the session identity through `/api/user/v1/me` (which answers 401 anonymously), and rejects any probe whose *effective* URL is a login/authn redirect |
| 8 re-running creates no duplicates | `C08` | ORM counts for org / course / both users / enrollment must each be exactly 1 |
| 9 errors → non-zero exit + readable diagnosis | `C09` + `test_error_paths.sh` | an invalid course key must be rejected; hostile scenarios assert non-zero **and** a matching diagnosis |
| 10 spike only, never MIALO / cloud / production | `C10` | canonical URL validation, compose-label container resolution, `PLATFORM_NAME` read-back, plus a before/after **fingerprint** (`Id`, `StartedAt`, `RestartCount`, `Status`) of every non-spike container |

`C02` also creates the course **author**, because `create_course` takes the
author as a positional argument and no other requirement covers it.

---

## 2. Prerequisites

* The spike is up: eleven containers under the compose project
  `mialo_openedx_spike_local` (`docker ps` shows `…-lms-1`, `…-cms-1`, …).
* `docker`, `curl`, `python3`, `bash` ≥ 4 on the host. No other host dependency;
  nothing is installed and no package manager is invoked.
* `/etc/hosts` resolves `local.openedx.io`, `studio.local.openedx.io` and
  `apps.local.openedx.io` (Tutor's bootstrap already did this).
* The user running it may `docker exec` into the spike containers.

Not needed: `tutor` itself. See §7 — `tutor local exec` hangs on this host, so
the harness talks to the containers directly.

---

## 3. Start

From the lane worktree:

```bash
export OE002_WORKTREE=/home/shiblyanastas/openedx-spike/wt-qwen-oe002
export OE002_BASELINE_BRANCH=qwen/openedx-oe-002
export OE002_BASELINE_HEAD=9e67d1429d5ab49a36fb9881a26457efeee0bb89

mialo/oe002/run_all.sh          # acceptance + error paths + review findings + idempotency
```

Single stages:

```bash
mialo/oe002/acceptance.sh              # the ten checks
mialo/oe002/acceptance.sh --only C06   # one check (diagnostics, fast)
mialo/oe002/acceptance.sh --list
mialo/oe002/test_error_paths.sh
mialo/oe002/test_review_findings.sh
mialo/oe002/test_idempotency.sh
```

The three `OE002_*` exports only feed the report; the harness never invokes
`git` itself. Measured on this host: a full `acceptance.sh` run takes ~46 s, the
error paths ~32 s, the idempotency stage ~130 s (it tears down and then runs
acceptance twice), so `run_all.sh` completes in about 3.5 minutes.

---

## 4. Repeat

Every stage is safe to re-run. The test identities are **fixed**, so a second
run reuses instead of duplicating:

```
org      MIALOOE  ("MIALO Open edX OE-002 Test Organization")
course   course-v1:MIALOOE+OE002+2026_T1  ("OE-002 Acceptance Course")
author   mialo_oe002_staff   @example.com
learner  mialo_oe002_learner @example.com
```

`test_idempotency.sh` is the stage that actually *proves* this: it tears the
entities down, asserts the slate is clean, runs acceptance twice and asserts the
entity counts are byte-identical afterwards — and that run A really took the
create path while run B really took the reuse path.

To exercise a different identity without touching the defaults, override the
environment for one invocation, e.g.
`OE002_COURSE_RUN=2026_T2 mialo/oe002/acceptance.sh`.

---

## 5. Teardown (Rückbau)

Dry run first — it only prints what it would remove:

```bash
mialo/oe002/teardown.sh
```

Then act:

```bash
mialo/oe002/teardown.sh --apply
mialo/oe002/teardown.sh --apply --purge-credentials   # also drop the passwords
```

Removal order: enrollments → course (`cms delete_course --remove-assets`, the
official command) → organisation → users. Afterwards every count must be `0`;
the script asserts that rather than assuming it.

The containers are never touched. Teardown removes only the four OE-002
entities and, on request, the credential file.

---

## 6. Artefacts

Everything generated stays **outside** the repository, so a commit can only ever
contain the harness itself:

```
/home/shiblyanastas/openedx-spike/
├── .oe002-credentials.json            0600, generated, never printed, never committed
├── oe002-artifacts/                   acceptance.sh
│   ├── oe002-report.json              machine-readable result summary
│   ├── oe002-results.jsonl            one JSON object per check
│   ├── c06-enrollment-api.json        raw learner enrollment API response
│   └── logs/                          full unfiltered output of every command
├── oe002-artifacts-errortests/        test_error_paths.sh
├── oe002-artifacts-findings/          test_review_findings.sh (+ review-findings-report.json)
├── oe002-artifacts-idempotency/       test_idempotency.sh (+ idempotency-report.json)
└── oe002-artifacts-batch/             run_all.sh (+ batch-summary.json, container fingerprints)
```

`oe002-report.json` schema `oe002-acceptance-report/v1` carries: target and
guard description, Open edX baseline, test identity, one entry per check
(`id`, `requirement`, `name`, `status`, `detail`, `seconds`), a summary and the
artefact locations.

Passwords are generated with `secrets.token_urlsafe(18)` on first use, stored
`0600` outside version control, and never written to a log, a report or stdout.

---

## 7. Known environment deviations

Found by running, not assumed. Each one changed the implementation.

1. **`tutor local exec` hangs.** It forwards to `docker compose exec`, which
   blocks indefinitely on this host (Docker Compose v5.5.1) even for `echo`,
   with and without `-T`. Verified twice, 9 min and 2 min with no output.
   `docker exec` into the same container returns immediately. The harness
   therefore resolves containers by compose **label**
   (`com.docker.compose.project` + `com.docker.compose.service`) and calls
   `docker exec` directly. The commands themselves are still the official Open
   edX management commands.
2. **`manage.py` needs the variant as its first argument.** `./manage.py
   create_course …` fails with `invalid choice: 'create_course' (choose from
   lms, cms)`. The service selects both the container *and* the variant.
3. **`force_publish --commit` prompts.** It calls `input()` through
   `query_yes_no(…, default="no")`, so closed stdin dies on `EOFError`. The
   harness feeds `y`. `delete_course` prompts twice and gets `y\ny`.
4. **No `manage_user` command exists at this commit.** User creation uses
   `create_test_users --ignore_user_already_exists`, whose "username exists and
   email matches → continue" semantics are exactly the idempotency we need.
5. **No official command deletes an organisation or a user.** `teardown.sh`
   therefore uses `manage.py lms shell -c` — still a management command, never a
   direct SQL write. Three findings from actually running it shaped the code:
   * `organizations.api.remove_organization` only **deactivates** the row (its
     data layer calls `_inactivate_organization`), so a hard delete has to
     follow; otherwise the count never reaches zero and the next acceptance run
     silently reuses a dead organisation.
   * Deleting the organisation raises `ProtectedError`: `CatalogCourse.org`
     references it with `on_delete=PROTECT`, and that row appears as a side
     effect of creating the course.
   * Deleting a user raises MySQL `IntegrityError 1451`: simple-history tables
     such as `student_courseaccessrolehistory` reference `auth_user` through a
     foreign key that does not cascade. Measured on this spike — 32 referencing
     rows had to be removed before the author and 39 before the learner.

   Both are handled by sweeping every model that points at the instance before
   deleting it, instead of hard-coding the two tables found so far. Teardown
   order is enrollments → course → organisation → users, because the course must
   go before the organisation that `CatalogCourse` links them through.
   `retire_user` was rejected: it anonymises instead of removing, needs the
   retirement pipeline configured, and leaves rows behind.
6. **`create_course` bypasses the organisation check.** It calls
   `create_new_course_in_store` directly, not `create_new_course`, so it neither
   requires nor creates an `Organization` row. Organisation and course are
   therefore two separate steps here.
7. **The MFE answers HTTP 200 for any path.** `apps.local.openedx.io/<anything>`
   serves the SPA shell with 200 — measured for a deliberately bogus path. Two
   consequences: the MFE probe in `C01` proves reachability only, not that the
   catalog route resolved; and the MFE cannot be used to prove that a non-200 is
   detected, so `E10` uses Studio for that, which returns a real 404.
8. **`/dashboard` answers 200 anonymously**, redirected to
   `apps.local.openedx.io/authn/login?next=%2Fdashboard`. Measured both ways:
   authenticated → `200 …/learner-dashboard/`, anonymous → `200 …/authn/login`.
   Status alone therefore cannot distinguish a learner view from a login page,
   which is what `C07` now checks via the effective URL and the identity
   endpoint (`/api/user/v1/me`: 200 with the username, 401 anonymously).

---

## 8. Safety guarantees

`oe002::require_spike` fails closed before any write, on all of:

* `OE002_LMS_URL`, `OE002_CMS_URL` or `OE002_MFE_URL` not being **canonical and
  exact** — the scheme must be `http`, the host must equal
  `local.openedx.io` / `studio.local.openedx.io` / `apps.local.openedx.io`
  exactly, and userinfo, a non-default port, a query string and a fragment are
  each rejected on their own. This runs *first*, before anything that carries a
  credential, because `oe002::login` POSTs the generated learner password to
  `OE002_LMS_URL`;
* no running `lms`/`cms` service in compose project `mialo_openedx_spike_local`;
* fewer than two running containers in that project;
* the running LMS reporting a `PLATFORM_NAME` other than
  `MIALO Open edX Spike`.

**Credential transmission.** Validating the base variables is not sufficient on
its own: what matters is the *effective* target of any request that carries a
secret. So every credential-carrying call is protected three ways (added on
codex-1's instruction in #7400):

* `oe002::login` re-validates `OE002_LMS_URL` **at the point of use**
  (`oe002::require_lms_url`) and refuses with rc 4 *before any request is made* —
  measured at 0.016 s against an attacker-suffix host, which is the evidence that
  nothing went out on the wire (`RF-URL-28`, `RF-URL-29`). `require_spike`
  checking the same variable once at start-up is deliberately not trusted: a
  function that transmits a password validates again.
* The password POST and the identity calls use `--max-redirs 0` and no `-L`, so
  curl cannot replay a body or a cookie to a redirect target at all. The effective
  URL and the redirect count are then asserted on every call, so the property is
  proven per request rather than inferred from the flags.
* Requests that legitimately follow redirects (the learner-view probes) are
  judged by `oe002::judge_view` on the **effective** URL: a 200 that ends on a
  host outside the allowed set is rejected as `FOREIGN_HOST`, and a 200 that ends
  on `/authn/…`, `/login`, `/signin` or `/register` is rejected as
  `LOGIN_REDIRECT` (`RF-URL-18…27`). `judge_view` is pure, so both cases are
  pinned without standing up a hostile server.

`RF-URL-30` is the positive control: a canonical URL and a real learner still
produce rc 0, so the hardening did not break the happy path.

Separately, `oe002::require_outside_vcs` refuses (exit 6) to create the
credentials file or any artefact directory when the path lies inside a version
control worktree. It walks the parent chain looking for a `.git` entry rather
than invoking git, so the harness never calls version control itself. Without
this an `OE002_CREDENTIALS_FILE` override could have placed a secret inside the
repository while this document promised it could never be committed.

The harness contains no `docker stop`, `docker restart`, `docker rm` or compose
mutation of any kind — and that is asserted statically, not just claimed
(`RF-ISO-22` greps every script for a mutating docker verb, `RF-ISO-23` proves
that grep can actually fire, `RF-ISO-24` pins the verbs used to
`ps`/`exec`/`inspect`/`info`). Isolation is then judged in two tiers:

* **Asserted** — the *protected* containers, by default the explicit list
  `OE002_PROTECTED_CONTAINERS` (`mialo-launch-postgres`,
  `mialo-slide-preview-db`, `mialo-stage-b-check-db-1`). Each must still be
  running afterwards with an identical **fingerprint**: `Id`, `StartedAt`,
  `RestartCount` and `Status`. A stop, a restart and a replacement under the same
  name each fail; comparing names alone would have stayed green across all three
  while still claiming "MIALO untouched". An **empty** protected set is itself a
  failure (`NONE-MATCHED`), because with nothing to compare the claim would pass
  vacuously. `RF-ISO-10…20` pin every one of these.
* **Recorded, not asserted** — every other non-spike container, diffed field by
  field and printed.

**Why the asserted tier is an explicit list and not a `mialo*` pattern** — this is
a judgement call and is flagged for review. Two concrete false alarms were
observed while developing this harness on a host that runs several agent lanes:

* `p0fresh-0c5a091cb22e` / `p0upgrade-0c5a091cb22e` started and finished on their
  own mid-batch;
* `mialo-unified-codex-app1-1` was redeployed by its own lane during a run — `Id`
  `10f55da1…` → `9a82bd7e…`, `StartedAt` `21:17:07Z` → `21:21:19Z`.

Neither was caused by this harness, and a pattern match reported both as an
isolation violation, which would have made the suite unusable as a gate. The list
therefore names exactly the long-lived services OE-002 is responsible for not
disturbing. Nothing is hidden by the narrowing: the full non-spike diff is still
printed and written to `foreign-fingerprint-{before,after}.txt`, and
`OE002_PROTECTED_CONTAINERS=""` with `OE002_PROTECTED_PATTERN=mialo` restores the
wide assertion (`RF-ISO-21` proves that widening works). A change to a container
on the list still fails the batch — that is the case the requirement is about.

There is no path from this harness to a cloud or production endpoint: the target
is resolved exclusively from the local compose project label and validated
against exact local hostnames.

---

## 9. Files

```
mialo/oe002/
├── RUNBOOK.md                this document
├── lib.sh                    shared config, spike guard, URL/path guards, command/ORM/HTTP helpers, report writer
├── acceptance.sh             the ten checks (C01…C10)
├── test_idempotency.sh       teardown → create path → reuse path → identical counts
├── test_error_paths.sh       hostile scenarios (E01…E11)
├── test_review_findings.sh   regression suite for the codex-1 cold-review findings (RF-*)
├── teardown.sh               removal of the four OE-002 entities (dry run by default)
└── run_all.sh                the whole batch + container isolation proof
```

`test_review_findings.sh` is the finding-to-test matrix for review round #7389:
`RF-URL-*` pins canonical URL validation, `RF-C07-*` pins the authenticated
learner view, `RF-ISO-*` pins container-identity comparison, `RF-SEC-*` pins the
secret/artefact path guard. Each finding also keeps a permanent **red-evidence**
assertion (`RF-URL-00`, `RF-C07-00`) that re-demonstrates the original defect was
real, so the suite cannot quietly degrade into testing nothing.
