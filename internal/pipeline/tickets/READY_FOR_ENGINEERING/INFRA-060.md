---
id: INFRA-060
type: feature
severity: medium
title: Establish a qualification-only transport capability for private application services
source: audit finding FND-0020 — DEC-039
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0020-qualification-transport-gap.md`
**Contract:** DEC-039

**Premise (verified 2026-10-03):** criteria 1–3 were already satisfied on `main` — the
capability landed in #405 (manifest, `establish.sh`, README, guard and mutation test all
present; `python3 internal/ci/check_qualification_transport.py` and its mutation test pass
in the worktree). Criterion 3's guard is now
`internal/ci/check_qualification_transport.py` with
`internal/ci/test_qualification_transport_check.sh`, a structural rewrite of the `.sh` the
criterion names. What was still missing was criterion 4 (the run procedure did not mention
transport or the identity split at all) and the establishment mechanism: the live attempt
could not show the capability grants only transport, because closing its temporary window
by disassociating the policy did not take effect (`FND-0021` / `INFRA-061`).

## Goal

Give live qualification a way to drive a transaction against an application's
private `ClusterIP` service, **without** adding any verb to the production
identities and without the capability becoming part of ordinary customer
infrastructure.

## Acceptance criteria

1. A qualification-only group (`sol:qualifiers`) and IAM principal exist, granting
   **only**: `pods`/`services` `get`/`list` (addressing) and `pods/portforward`
   `create` (transport). No mutating verb, no `pods/exec`, no `pods/log`, no
   `events`, no `secrets`.
2. It is established by `internal/qualification/transport/`, which no
   production Terraform root references and `sol cloud apply` never applies. No
   target field names the qualifier principal.
3. `internal/ci/check_qualification_transport.sh` asserts both directions — the
   production roots never reference the qualifier group, and the manifest carries
   no verb beyond the permitted set — with a mutation case for each, so the guard
   is demonstrably falsifiable.
4. The qualification procedure documents that the record must name the transport
   identity separately from the identities whose contracts are under test.
5. Live: a transaction reaches an application service through this capability, and
   the production identities' permissions are unchanged afterwards (the operator's
   effective surface still excludes `pods/portforward`).

## Out of scope

Any change to provisioner, publisher, deploy or operator; any ingress exposure of
application services to production.

## Completion — part A (2026-10-03)

Criterion 5 is live and stays open, so this ticket remains `READY_FOR_ENGINEERING`; the
branch declares itself part A of it.

**The establishment mechanism now verifies the surface it declares.** `establish.sh` closes
its temporary cluster-admin window by **deleting the access entry and recreating it
narrow** — never by `eks disassociate-access-policy`, the path measured not to propagate
(`FND-0021`) — and then verifies the **effective** surface with real calls, as the principal
`kubectl auth whoami` names: `get pods` succeeds, `get secrets` is `Forbidden`,
`pods/portforward` is permitted, retried within a bound. When it cannot show that surface it
removes the access entry rather than leave a credential broader than its contract. The
previously accepted fourth positional (`context`) was dead — the script never used it — and
is now the namespace the post-establishment probe reads.

**The sequence is pinned offline.** `internal/ci/test_qualification_transport_establish.sh`
drives it against stub `aws`/`kubectl` binaries and asserts three outcomes: a narrow surface
is accepted; a surface broader than declared fails with the entry removed; a manifest that
did not take effect fails with the window closed. It also asserts that no run reaches
`disassociate-access-policy`. Falsifiability was checked by mutation: reverting the close to
a disassociation fails *the window is never closed by a disassociation*; short-circuiting
the probe to succeed fails *a residual broad grant fails establishment*; and restoring the
entry on a failed verification fails *the access entry is removed rather than left broad*.
`internal/tooling/scripts/verify.sh static` discovers it, so CI runs it with the other
guards.

**Criterion 4 is satisfied.** The AWS run procedure now carries § *Qualification transport
into private application services*, stating how B3 obtains connectivity, the establishment
and verification sequence, and that the record names the identity that established and drove
transport separately from the identities under qualification (DEC-039 §4); step 7 points at
it. The transport README documents the same, including why the window is closed by deletion
rather than disassociation.

**Adjacent documentation corrected.** The matrix's B3 evidence column now requires the
application's own evidence that it processed a message rather than broker progress such as
consumer offset/lag (DEC-039 §5; the check FND-0020 left open). `FND-0020` and `FND-0021`
move `OPEN` → `FIXED_UNQUALIFIED` with dated state lines, and `QUALIFICATION_STATUS.md`
records the resolution. FND-0021's provider behaviour — propagation delay with a bound, or a
persistent divergence — is still unmeasured and needs a live cluster; until then the API's
report for that operation is treated as untrusted, which is the fail-closed direction. That
state update extends `INFRA-061`'s (DONE) record rather than reopening it, and it is flagged
here so the qualification lead can adjust it.

**Acceptance criteria:** 1–3 already satisfied and unchanged (criterion 3 by the structural
guard plus its mutation test); 4 satisfied; 5 not attempted — it is live, and the harness
being ready for it is what this part delivers.

**Demo / example coverage:** none applies — internal qualification harness mechanics, not a
change to what an app author does.

**Language parity (DEC-022):** no impact — harness and qualification mechanics, not a
framework convention or an application-facing capability.

**Remaining limitation:** neither the establishment nor the verification has run against a
real EKS cluster. The offline test fixes the logic, not the provider behaviour; criterion 5
and FND-0021's bound are live steps, and their exercise belongs to `HARDEN-007`.
