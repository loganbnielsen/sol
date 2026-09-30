---
id: FND-0078
type: audit-finding
severity: medium
source: GCP application row (sol-qual-gcp-29) — the harness could not tear down its own specimen
---

**Depends on:** None.

**Related:** `internal/qualification/gcp/live-qual.sh` (the destroy phase, `write_app_target`,
`owns_target_file`), `internal/qualification/records/2026-09-30-gcp-application-row-under-enforced-policy.md`.

# The GCP qualification harness cannot reliably destroy its own specimen

Two defects, both hit while tearing down the GCP application row. Together they mean a run can
finish with a live, cost-bearing specimen and no supported way for the harness itself to remove it.

## 1. The destroy phase requires `CLUSTER` but uses `IMPERSONATOR`

The phase's argument check only demands `CLUSTER` for `destroy | verify`:

```
case "${1:-}" in
  cloud | platform | app)
    CLUSTER=...; IMPERSONATOR="$(...)" ; LE_EMAIL=...
    ;;
  destroy | verify | "")
    CLUSTER=...
    ;;
esac
```

but a later credential step reads `IMPERSONATOR` unconditionally, so a destroy invoked the way the
harness documents it fails immediately:

```
internal/qualification/gcp/live-qual.sh: line 340: IMPERSONATOR: unbound variable
```

Supplying the variable satisfies it — the phase then runs — which shows the requirement is real and
simply not declared.

## 2. The app phase's target file is refused by the destroy phase

`write_app_target` writes the *application* target to the shared target path and marks it with the
target it was written for. The destroy phase uses a different target name, so its ownership check
rejects the file, then tries to destroy a target that the file does not declare:

```
REFUSING: examples/pluto/sol/environments.local.yml exists and was not written by this harness; move it aside first.
teardown: sol cloud destroy qual/gcp/us-central1
  (destroy exited non-zero; the verification below decides)
error: target "qual/gcp/us-central1" is not declared in examples/pluto/sol/environments.yml
```

The phase then inventories, reports "teardown NOT verified: resources remain", and exits — leaving
the specimen standing and the target file truncated to zero bytes by its own `cat >`. Recovering
required re-declaring the target by hand and driving `sol cloud destroy` outside the harness.

The same sequencing is not a problem for the cloud phase, which writes its own target and is
followed immediately by phases that do not need to re-declare it.

## Acceptance criteria

- `live-qual.sh destroy` runs after a completed `cloud`/`app` phase without any variable the
  documented invocation does not set, and without manual repair.
- The target the destroy phase needs is either the one the app phase left in place, or the phase
  declares its own — so that a single `cloud → app → destroy` sequence tears down what it created.
- A destroy that cannot resolve its target fails before it truncates any file, and leaves the
  specimen's target declaration intact for the next attempt.
- Coverage in `internal/qualification/gcp/test-live-qual.sh`: a destroy after an app phase resolves
  its target with only the documented variables, and a refused ownership check leaves the target
  file unchanged.

## Fixed

- `destroy` and `verify` now declare the `IMPERSONATOR` they use, so a documented invocation either
  runs or refuses with a message naming the variable instead of failing on an unbound one.
- `owns_target_file` treats an **empty** target file as the harness's own. A phase that truncated
  the file (or a run that left it empty) could otherwise make the next phase refuse it as foreign
  and exit without destroying anything.
- The target mark now records that each phase rewrites the file for the target that phase needs, so
  reusing it is the documented behaviour rather than an accident.

Coverage in `internal/qualification/gcp/test-live-qual.sh`: a destroy without the impersonator is
refused and names it, and a destroy asked to run against an empty harness target file does not
treat it as foreign and goes on to destroy its target.

