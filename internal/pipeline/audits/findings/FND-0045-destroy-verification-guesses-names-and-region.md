# FND-0045 — Destroy verification checks absence of *guessed* names in a *guessed* region, so a wrong guess reads as "absent"

- **Classification:** `VERIFIED_DEFECT` (fail-open verification)
- **State:** `FIXED_UNQUALIFIED` — the remedy landed 2026-09-24 as `INFRA-069` in HARDEN-004
  step 5 (`#487`): verification is driven by a captured state inventory. **One clause of the
  remedy was implemented narrower than written** — "keep name-based describes only as an extra
  orphan sweep" survives for GCP as the service-networking peering probe alone — and that is the
  coverage residual now recorded as **FND-0055**. See the transition at the end of this file.
- **First identified:** 2026-09-23, by a second reviewer at `main @ f2e1773`; re-verified at
  `origin/main @ f3e9480b`
- **Derived ticket:** `INFRA-069`
- **Evidence class:** `STATIC`

## What is established

`verify_gcp_destroy` / `verify_aws_destroy` (`cli/sol/bin/cmd_cloud_tf.ml:538`, `:433`) prove
absence by describing resources whose identity is reconstructed rather than recorded:

- **Names are derived:** `cluster_name ^ "-postgres"` (`:461`, `:571`), not the IDs the
  state held.
- **Region has a silent default:** `resolved_var "region" … ~default:(Some "us-central1")`
  (`:556-559`).
- **The tfvars reader is a line parser that swallows errors:** `var_file_value`
  (`:194-220`) reads `key = value` lines only. It ignores JSON tfvars, multi-line HCL,
  `TF_VAR_*` and `*.auto.tfvars`, and its `with _ -> None` makes an unreadable var file look
  like an unset variable.
- **"Absent" is matched loosely:** `gcp_absence_message` (`:507-512`) accepts any stderr
  containing `not found`, `not_found` or `does not exist`, which includes a wrong or missing
  **project**.

If region or project resolves wrong, every describe returns a not-found error and
verification reports the target **absent**. The comment above `gcp_absent` explains why
verification must fail closed. Guessing the inputs undercuts that.

(Correction the reviewer made to their own earlier point, kept here: because verification
describes the cluster by name, the Attempt-6 orphan would *not* have leaked silently. It
would have failed loudly, but only because name and region happened to be right.)

## Remedy shape

One observation of state at the start of destroy, turned into a typed inventory
(addresses, IDs/self-links, regions, project). Verify absence of **those** IDs in **those**
regions. Add the cheap post-condition `terraform state list` = empty. Keep name-based
describes only as an extra orphan sweep. Remove `var_file_value` from any decision path.

## Related

FND-0044 (same inventory feeds the reconciliation allowlist); FND-0021 / DEC-040 (absence
must be observed, not inferred); FND-0003.

## Transition (2026-09-24) — remedy landed as `INFRA-069` in step 5; one clause narrower than written

Verified at `origin/main @ 2775d5b1`, pre-live (no provider call was made).

`verify_gcp_destroy` / `verify_aws_destroy` and `var_file_value` are gone from the decision
path. Verification is now driven by the **captured** inventory: `Sol_cli_destroy_verification`
builds each lookup from a resource's own `address`/`kind`/`self-link`/ARN/project/region
(`cli/sol/lib/sol_cli_destroy_verification.ml:47-59`, `:569-571`), takes the project out of the
self-link's own `projects/<p>/` path and the AWS region out of the captured ARN
(`region_of_values`, `cli/sol/lib/sol_cli_cloud_destroy.ml:89-106`), and the GCP absence check
tests the *subject* of a 404 against the project it was made in
(`gcp_absence_message ?project`). The `terraform state list` post-condition became the
post-destroy state read (`post_destroy_state`, `cmd_cloud_tf.ml:744-756`). So "a wrong guess
reads as absent" no longer applies: there is no guess.

**What was implemented narrower.** The remedy's fourth clause — "keep name-based describes only
as an extra orphan sweep" — survives on GCP as a *single* probe, the service-networking peering
on the captured network (`cmd_cloud_tf.ml:672-738`); the cluster, SQL and network describes that
used to run are gone. That is the whole of the coverage change, and it has a consequence this
finding's kept correction note above already predicts from the other direction: the Attempt-6
orphan, which name-based describes would have caught loudly, is now outside the verification
set entirely. Recorded as **FND-0055** (a distinct defect with its own remedy, because the fix is
to *widen the evidence set*, not to un-narrow the guessing). `INFRA-069` remains in
`READY_FOR_ENGINEERING`; whether its sweep clause is discharged by FND-0055's remedy or by its
own follow-up is the HARDEN-004 owner's bookkeeping call.

**What remains unqualified.** The recipes have still never run against a real provider
(Step 5's caveat), and this transition is `STATIC` evidence about the code, not a live destroy.
