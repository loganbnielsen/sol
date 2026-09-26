---
id: INFRA-080
type: bug
severity: low
title: Three harness verdict refinements Attempt 8 exposed (a class that can never verify absence, a soft-deleted role read as present, and a comment that broke its own printf)
source: GCP Attempt 8 (2026-09-25) — observed in the live run and its bundle
---

**Depends on:** None.

**Related:** `internal/qualification/gcp/live-qual.sh`,
`internal/qualification/gcp/test-live-qual.sh`, `docs/qualification/2026-09-25-gcp-attempt8.md`.

## A. `impersonator-binding` can never verify absence after a successful teardown

The class probes with `gcloud iam service-accounts get-iam-policy <sa>`. For a deleted service
account GCP answers:

```
ERROR: (gcloud.iam.service-accounts.get-iam-policy) PERMISSION_DENIED: Permission
'iam.serviceAccounts.getIamPolicy' denied on resource (or it may not exist).
```

The probe correctly refuses to read that as ABSENT (fail-closed), so **every** successful
teardown ends "teardown NOT verified" for this class — a postcondition that cannot be satisfied
by construction is not a postcondition. The binding is an IAM *policy* on an identity; the
identity's own absence is already covered by `service-account-provisioner`, so either ask a
question that can be answered after deletion, or state that this class is verified by the
identity's absence.

## B. `custom-role` should read GCP's `deleted: true` as absent

GCP soft-deletes custom roles: after Sol's destroy the role is gone from `iam roles list` but
present with `deleted: true` for the undelete window. The probe read it as PRESENT (a true
observation of a state the row does not mean), so a *clean* teardown was reported as residue.
Observed for Attempts 5, 6 and 8 (`sol_sol_qual_gcp_{5,6,8}_cluster_access`, all `deleted: true`).
Non-billable, but the verdict must say what it means: `deleted: true` is the provider's
"deleted", distinct from both PRESENT and UNKNOWN.

## C. `cloud_vars`' comment ends its own `printf`

```sh
  printf '%s\n' \
    "--var=base_domain=$BASE_DOMAIN" \
    # No create_dns_zone here: …
    "--var=provisioner_impersonators=[\"$IMPERSONATOR\"]"
```

The comment consumes the continuation, so the next line is executed as a command:
`--var=provisioner_impersonators=[…]: command not found`, and the var is dropped. **It did not
affect Attempt 8** — the plan transcript shows Sol passing
`-var=provisioner_impersonators=["user:…"]` from the target itself (a `sol_keys` field), which is
why the harness's own copy is redundant. Fix by **deleting the redundant line** (the harness must
not become a second source for a Sol-owned key), and note the same trap is invisible to the
suite because `destroy_vars` carries no comment.

## Acceptance criteria

- The `impersonator-binding` class either asks a question that can answer after deletion or is
  documented as covered by the identity's absence; a clean teardown verifies clean.
- The `custom-role` verdict distinguishes PRESENT / soft-deleted / UNKNOWN, with a regression
  test for each.
- `cloud_vars` emits its complete argument list (a test asserts the cloud invocation carries the
  target-derived variables it relies on — the impersonator arrives from the target, so the
  harness asserts *behaviour*, not the presence of its own duplicate).
- No product code changes.

## Live corroboration (2026-09-26)

The FND-0058 qualification run reproduced all three items exactly as filed, on a clean teardown of a
fresh target (`qual9/gcp/us-central1`): `service-account-provisioner` and `impersonator-binding` read
**UNKNOWN** (GCP answers `PERMISSION_DENIED … (or it may not exist)` for a deleted service account,
and the probe refuses to call that absence — fail-closed by design), `custom-role` read **PRESENT**
with `deleted: true` (GCP's undelete window; non-billable), and `cloud_vars` still printed
`--var=provisioner_impersonators=[…]: command not found` while Sol passed the variable from the target.
So every successful teardown ends "teardown NOT verified" until these are fixed. Record:
`docs/qualification/2026-09-26-gcp-fnd0058-live-qualification.md`.

## What landed (2026-09-26)

The three recorded items are fixed, and a fourth was added: the prompt for this unit named
**three** live-observed defects (a provider-deleted **service account** reading UNKNOWN, the
impersonator **binding** reading UNKNOWN, and the soft-deleted **role** reading PRESENT) while
this ticket's own three are the binding, the role and `cloud_vars` — the *service-account*
class was observed in Attempt 9 but was never filed. It is fixed here too, and recorded as
`FACT` in this ticket's history rather than quietly folded into item A.

### The rule every row now follows

A row is a **postcondition** with an observable that establishes it — never a command and its
exit status. `RESOURCE POSTCONDITION` → `PROVIDER OBSERVABLE` → `HARNESS VERDICT`.

| class | postcondition | observable | verdict rule |
|---|---|---|---|
| `service-account-provisioner` | the target's provisioner identity is no longer **active** | the project's authoritative **list of active service accounts** (`gcloud iam service-accounts list`); the per-account `describe` is kept beside it as raw evidence | email in the list → **PRESENT**; list succeeds and the email is absent → **ABSENT**; the list itself cannot be read → **UNKNOWN**. A `PERMISSION_DENIED` describe is *evidence*, never a verdict |
| `impersonator-binding` | the operator holds no **usable** impersonation authority over that identity | the identity's own active state (a provider-deleted identity cannot be impersonated, and its SA-level policy is deleted with it); when the identity **is** active, the narrowest read — the impersonator's bindings on it | identity absent → **ABSENT**, with the implication named in the detail and the policy read preserved as raw evidence; identity active and a binding is returned → **PRESENT**; identity active, policy read succeeds with nothing for the impersonator → **ABSENT**; identity active, policy read denied/ambiguous → **UNKNOWN** |
| `custom-role` | no **active** custom role of that name | `describe --format='value(name,deleted)'` — GCP's own deletion marker | `deleted: true` → **ABSENT**, detail naming the provider's undelete window and carrying the raw line; marker false/absent → **PRESENT**; not-found vocabulary → **ABSENT**; anything else → **UNKNOWN** |
| `cloud_vars` | the harness passes no argument it cannot parse | its own argument list | no `command not found`; the generated target carries `provisioner_impersonator`; the cloud path passes no second copy |

**The epistemic rule is unchanged and is what the tests protect:** `PERMISSION_DENIED … (or it
may not exist)` is not absence, and nothing in the fix relabels it. Where a class needed the
question changed, the question changed; where an implication carries the postcondition (the
binding above), the implication is stated in the verdict's detail, in the code comment, and
pinned by a test — including the case where the identity is still active.

### `cloud_vars` (item C)

Root cause: a comment line sat **inside** the backslash-continued `printf` argument list, so
the shell ended the command there, ran the next line as a command
(`--var=provisioner_impersonators=[...]: command not found`) and dropped the argument. It was
harmless live only because Sol routes `provisioner_impersonator` from the generated target
(`sol_keys`), so the value arrived anyway — which is exactly why the line is now **gone**
rather than repaired: one source for one setting, and the target is it. The reasoning that used
to sit inside the argument list now sits above the function, where a comment cannot end a
command.

### Evidence

- **Offline suite: 117 assertions, 0 failed** (was 90), including fixtures built from the
  wording GCP actually returned in Attempts 8 and 9 (`PERMISSION_DENIED: Permission
  'iam.serviceAccounts.get' denied on resource (or it may not exist)`, `NOT_FOUND: The role
  named … was not found`, `roles/…\tTrue`).
- **The Attempt-9 shape verifies:** a target whose identity is provider-deleted, whose
  impersonation grant is unusable, whose role is soft-deleted and whose disposable classes are
  absent now ends with a **VERIFIED** teardown, and the bundle keeps the raw describe answer,
  the raw `deleted` marker and the policy read beside the verdicts.
- **Mutations, each made the suite fail:** any probe failure read as ABSENT (fails the
  permission/transport/invalid scenarios); a failed authoritative list read as ABSENT (fails
  "a failed authoritative list is UNKNOWN, never absent"); `deleted: true` read as PRESENT
  (fails the Attempt-9 scenario); an ambiguous policy read read as ABSENT (fails "the binding
  class is UNKNOWN when its read is ambiguous"); the `cloud_vars` comment restored (fails "no
  command-not-found diagnostic"). Positive directions are pinned too: active identity / surviving
  binding / active role each fail verification, and a genuinely not-found role still verifies.
- One live-semantics question was checked read-only (no mutation): the authoritative list exists
  and answers unambiguously, and `--show-deleted` does **not** exist for service accounts in this
  CLI version — so the list's successful-but-absent answer is the strongest available observable
  for "not active", and the deleted marker is available for custom roles, which is why the two
  classes use different observables.

### Not observed live

The **active**-identity path of `impersonator-binding` (identity present, policy readable) has no
live counterpart: every attempt so far deleted the identity. It is pinned offline in both
directions and would be exercised by the first attempt that stops before teardown.

### Scope

`internal/qualification/gcp/{live-qual.sh,test-live-qual.sh}` only. No product code, no
lifecycle behaviour, no Terraform matcher, no provider capability, no FND-0058 change, no
FND-0010 remediation, no live infrastructure, and the preserved Attempt 8 state is untouched.
