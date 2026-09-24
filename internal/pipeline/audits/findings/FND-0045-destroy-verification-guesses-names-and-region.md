# FND-0045 — Destroy verification checks absence of *guessed* names in a *guessed* region, so a wrong guess reads as "absent"

- **Classification:** `VERIFIED_DEFECT` (fail-open verification)
- **State:** `OPEN`
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
