---
id: AUDIT-087
type: audit-finding
severity: high
title: The transport's window close and its surface probe were weaker than the ticket that landed them claims
source: targeted adversarial review of INFRA-060 / PR #992 (2026-10-03)
---

**Depends on:** None.

**Related:** `INFRA-060` (the change reviewed), `FND-0021` / `INFRA-061` (the measured
stickiness this mechanism exists to survive), `DEC-039` (the transport's contract), `ADR 0003`
(the de-escalation rule that makes a temporary window necessary at all),
`internal/qualification/transport/README.md`.

## What was reviewed

A targeted adversarial review of the transport-establishment change landed by `INFRA-060`
(`#992`, squash `202c3433`), against three questions: whether the temporary AWS access is
narrowed and removed correctly on every success and failure path; whether the effective-surface
probes actually establish the permissions they claim; and whether any path can leave broader
authority behind. The scope is the establishment mechanism
(`internal/qualification/transport/establish.sh`, `transport.yaml`, the offline test and the
guard) — not a general security audit.

The reviewer was the same agent session, not an independent one: this harness has no subagent
facility, so the result is a review-and-fix by the acting agent rather than an independent pass.
The author of `#992` is a different actor, and the reviewed code was read from `origin/main`, so
these findings are not the author's own account of their change.

## Finding 1 (high) — the removal path could leave cluster-admin behind, and said it had removed it

`delete_entry` swallowed every failure (`aws eks delete-access-entry … || true`), and
`create_narrow_entry` treated "the entry exists" as "the narrow entry is in place" and returned
success:

```console
$ git show origin/main:internal/qualification/transport/establish.sh | sed -n '49,51p;37,41p'
delete_entry() {
  aws eks delete-access-entry --cluster-name "$cluster" --principal-arn "$arn" >/dev/null 2>&1 || true
}
create_narrow_entry() {
  if entry_exists; then
    echo "  access entry with group sol:qualifiers already exists"
    return 0
  fi
```

A failed delete therefore made the *close* path print "already exists" and carry on, and the
probe-failure path printed "refusing to leave a credential broader than its contract: removing
the access entry" and exited 1 without ever checking that the removal happened — the same
"reported complete, still effective" shape as `FND-0021`, one step later in the sequence. The
`INFRA-060` README and ticket both state the mechanism removes the entry rather than leave a
broad credential; nothing established that it did.

Reproduced offline, with a stub whose `delete-access-entry` fails and against the pre-change
script (see *Verification* for how the same test is pointed at `origin/main`):

```console
  [FAIL] the failure says the authority could not be shown to be gone
  [FAIL] the failure says how to remove it
```

The entry and its cluster-admin association both survive that run, and the operator is told
nothing beyond the exit status.

## Finding 2 (medium) — the probe verified three of the contract's claims, and identified the principal by substring

The declared contract is `pods`/`services` `get`/`list`, `pods/portforward` `create`, and
"deliberately absent: every mutating verb, `pods/exec`, `pods/log`, `events`, `secrets`"
(`transport.yaml`). The probe established `get pods`, `get secrets` denied, and
`can-i create pods/portforward`; it tested no other declared absence, and `pods/exec` is the one
that matters most — exec into an application container reaches that container's mounted secrets,
which the secrets control cannot see from outside. The identity assertion was
`grep -q "$role"` over the `auth whoami` JSON: a substring match on the role *name*, with the
groups the principal actually carries fetched and never inspected.

Reproduced against the pre-change script:

```console
  [FAIL] a residual pods/exec grant fails establishment (observed exit 0)
  [FAIL] a system:masters mapping fails establishment (observed exit 0)
```

The first is the material one: a principal granted `pods/exec` passed verification, and the run
would have proceeded on a credential broader than its contract. (The `system:masters` case is
caught in reality by the secrets control, since `system:masters` can read secrets; the offline
stub's secrets model is driven by the association, so only the group assertion catches it there.
The finding is the substring identity check, not that scenario.)

## Finding 3 (low) — the AWS half of the principal's authority was asserted, never verified, and broader than it needs to be

The script overwrote its own inline policy and otherwise assumed the role was what it declared.
An **attached** managed policy (an `AdministratorAccess` added by hand, or left by an earlier
variant) would give the transport principal account-level authority that no Kubernetes-side probe
can observe, and a trust policy naming another account or `*` would let a principal outside this
account become it. The inline policy itself was `["eks:ListClusters","eks:DescribeCluster"]` on
`Resource: "*"`: `eks:ListClusters` is not used by the script at all, and `eks:DescribeCluster`
supports a cluster ARN, so the transport described every cluster in the account to reach one
(AWS documents `ListClusters` as not supporting resource-level permissions, and
`aws eks update-kubeconfig --name` needs `DescribeCluster`).

Reproduced against the pre-change script:

```console
  [FAIL] an attached policy fails establishment (observed exit 0)
  [FAIL] a trust policy naming a wildcard principal fails establishment (observed exit 0)
```

## Checked, and found sound (recorded so it is not re-litigated)

- **Signals.** The EXIT trap runs on `SIGINT`, `SIGTERM` (including `timeout`'s) — measured — so
  an interrupted window is closed by the trap; only `SIGKILL` or a host failure escapes it, which
  no script can cover.
- **A successful exit still implies the window closed.** The success path is gated on the
  effective probe, which requires a denied `get secrets`; a still-associated cluster-admin cannot
  pass it. There is no exit-0-with-a-broad-credential path.
- **The window is as narrow as EKS allows.** EKS access policies are AWS-managed, and
  `AmazonEKSClusterAdminPolicy` is the only one that can write cluster-scoped RBAC; a custom,
  narrower policy is not available.
- **Delete-and-recreate is the right close**, and the probe's retry bound (12 × 15s) covers the
  measured sub-45-second propagation.

## Remediation

- `establish.sh` must not swallow a delete: `remove_entry` requires both a successful
  `delete-access-entry` and a `describe-access-entry` that agrees the entry is gone;
  `recreate_narrow_entry` must refuse to treat a surviving entry as narrowed; the cleanup must
  report a removal only after it is established, and when it cannot be, name the principal, say
  the authority could not be shown to be gone and print the command to remove it by hand. Failure
  paths keep the fail-closed shape: a probe that cannot show the declared surface removes the
  entry.
- The probe must assert the principal's own assumed-role session (`assumed-role/<role>/`), the
  group `sol:qualifiers`, and the absence of `system:masters`; the declared positives (`get pods`,
  `can-i list services`, `can-i create pods/portforward`) and a sample of the declared absences
  (`*/*` as the catch-all, `create pods/exec`, `get pods/log`, `delete pods`) alongside the real
  `get secrets` denial, distinguishing denied from readable from unobservable so an unobservable
  call is never read as absence.
- The AWS side must be checked before any window opens: no attached policy beside the inline one,
  a trust naming this account's root and no wildcard or service principal; and the inline policy
  must be one `eks:DescribeCluster` statement scoped to the cluster's ARN, with
  `eks:ListClusters` gone.
- The offline stub test must cover each of those outcomes, and the guard must pin the inline
  policy structurally (JSON, not text) plus the absence of any `disassociate-access-policy`, with
  mutations proving each rejection. `README.md` and `aws-run-procedure.md` must describe the
  mechanism as it then is.

## Acceptance criteria

- Both tests pass, and the new scenarios fail against the pre-change script (the offline test
  pointed at `git show origin/main:internal/qualification/transport/establish.sh`), so the
  scenarios discriminate rather than merely pass.
- The guard refuses a wildcard resource, a verb other than `eks:DescribeCluster`, a missing
  cluster-ARN definition, and any disassociation, each proven by a mutation.
- `bash internal/ci/run_fast_checks.sh` is green, including the class that discovers the transport
  test.
- No app-author surface changes, so no `examples/` or tutorial demo applies; no language-parity
  impact (DEC-022) — this is qualification-harness tooling.

## Completion (2026-10-03) — the close and the probe now establish what they claim

Filled by the implementation PR that moved this ticket to `DONE`.

- `establish.sh`: `delete_entry` no longer swallows failures; `remove_entry` requires *both* a
  successful delete and a `describe-access-entry` that agrees the entry is gone;
  `recreate_narrow_entry` refuses to treat a surviving entry as narrowed; the cleanup reports a
  removal only after it is established, and `lost_authority` names the principal, says the
  authority could not be shown to be gone and prints the command to remove it — instead of
  claiming a removal that did not happen. The failure paths keep the fail-closed shape: a probe
  that cannot show the declared surface removes the entry.
- The probe asserts the principal's own assumed-role session (`assumed-role/<role>/`), the group
  `sol:qualifiers` and the absence of `system:masters`; the positives are `get pods` and
  `can-i list services` plus `can-i create pods/portforward`; the absences sampled are `*/*`,
  `create pods/exec`, `get pods/log` and `delete pods` beside the real `get secrets` denial.
  Denied, readable and unobservable are distinguished, and an unobservable call is never read as
  absence.
- The AWS side is checked before the window opens: no attached policy beside the inline one, a
  trust naming this account's root and no wildcard or service principal, and one
  `eks:DescribeCluster` statement scoped to the cluster's ARN with `eks:ListClusters` gone.
- The offline test grows from three scenarios to eight and fails **18 expectations** against the
  pre-change script (`bash internal/ci/test_qualification_transport_establish.sh /tmp/oldtransport`
  with `establish.sh` restored from `origin/main`), including
  `a residual pods/exec grant fails establishment (observed exit 0)` and
  `an attached policy fails establishment (observed exit 0)`; against the fixed script every
  expectation holds.
- The guard reads the inline policy as JSON and refuses a wildcard resource, a verb other than
  `eks:DescribeCluster`, a missing cluster-ARN definition, or any `disassociate-access-policy`,
  with three new mutations proving each rejection
  (`internal/ci/test_qualification_transport_check.sh`).
- `README.md`, `aws-run-procedure.md` and `internal/pipeline/audits/QUALIFICATION_STATUS.md`
  describe the mechanism as it now is, including the AWS half and the removal guarantee.
- `bash internal/ci/run_fast_checks.sh` is green, and its class list runs both the guard and the
  offline test (`PASS internal/ci/check_qualification_transport.py`,
  `PASS internal/ci/test_qualification_transport_establish.sh`,
  `PASS internal/ci/test_qualification_transport_check.sh`).

The review's own result was recorded on the reviewed PR (`#992`) as a `SOLDEV-REVIEW: FAIL`
comment with the three violations, since `soldev pipeline review` refuses a merged PR ("no open PR
to review"); the marker's informational role is served by the comment plus this ticket.

**One defect introduced while fixing this, caught before the PR merged.** The first version of the
trust check tested the document with `printf '%s' "$trust" | grep -Eq …` — under `pipefail` that
reports failure *when grep matched*, if the writer is still writing when grep exits on its first
match (`INFRA-101`, filed the same hour from `INFRA-099`'s root cause, with four other sites
listed). Here it would have failed **open**: a trust naming `*` could pass. The check is a `case`
pattern instead, so there is no pipeline at all; no `| grep` remains anywhere in the files this
change touches, and the offline test's `system:masters`, wildcard-trust and extra-principal
scenarios fail if the pattern returns.


## What is still not established (recorded, not fixed)

The probe is a **sample** of the declared surface, not a rule-set comparison: a grant that is
neither `*/*` nor one of the sampled denials — `get configmaps`, say — would pass it. Comparing
the effective rules to the declared ones would need `auth can-i --list` parsing or a binding
enumeration, whose output is version-dependent; the catch-all plus the sampled denials are the
bounded improvement. Similarly, once the access entry is *removed* there is no surface left to
probe, so the removal's evidence is the API's existence report plus the measured propagation —
the effective-surface probe cannot be its backstop. Both belong to the live run's record
(`HARDEN-007`) if the operator wants them closed.
