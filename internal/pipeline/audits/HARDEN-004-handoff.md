# HARDEN-004 handoff — GCP qualification, destroy-path recovery (2026-09-24)

**Read this first.** It says what merged, what is open, what is next, and what was verified
rather than assumed. `main` at the time of writing: `f3e9480b`.

## Where the work stands

The GCP qualification campaign has not reached cert-manager, and that is deliberate: two live
attempts (5 and 6) exposed that **Sol could not reliably get back to zero**, which matters more
than reaching further into the stack. The recovery path is being repaired before another live
run.

| Merged | What it did |
|---|---|
| #449 | Offline state-machine suite for the qualification harness (`internal/qualification/gcp/test-live-qual.sh`), wired into CI. Found and fixed: teardown with two owners (phase + EXIT trap), absence probes that read any non-zero exit as ABSENT, a quota check whose `\t` pattern never matched a tab, and a quota read that reported "usage is non-zero" when it could not parse the read at all. |
| #450 | `FND-0030` design recorded before implementing it. |
| #451 | Mechanism 2: eligibility is `configuration INTERSECT state`. Plus the policy vocabulary (`failure_policy`, `preparation_outcome`) — **types only, not wired**. |
| #452 | Honesty corrections: the eligibility rule bounds what may be TARGETED, not what Terraform PLANS; plus the unrepresented-resource warning. |

`FND-0030` is **OPEN**. `INFRA-067` (destroy refused by install-time validation) is fixed.
`DEC-043` (durable zone ownership) is decided and implemented; the zone is adopted into
`cli/platform/infra/bootstrap-gcp` and reconciled by the harness.

## Next steps, in order

### Step 1 — plan-and-assert (own PR) — NOT STARTED

`configuration INTERSECT state` bounds targeting, not planning: `-target` includes
dependencies, and a targeted apply reconciles the whole resource, so ForceNew drift plans a
**replacement** — a create on the destroy path.

Implement the preparation as `plan -target=<eligible> -out`, `show -json`, validate, then
`apply` the saved plan. Rules:

- Allow `["no-op"]` anywhere; `["update"]` only on eligible addresses; `["read"]` only where
  `mode = "data"`.
- Refuse everything else: any create, delete, or replace (`["delete","create"]` **or**
  `["create","delete"]`), and any update outside the eligible set.
- For updates on eligible addresses, **report** (do not refuse) attributes changing besides
  the deletion-protection fields, so destroy-path drift reconciliation is visible.
- A refusal is a preparation failure whose reason names the offending addresses and actions.
- Put the validation in the library as a pure function over **parsed** plan JSON, returning
  the offending changes, so it is testable without a cloud.
- Fixtures: pure guard update (pass); dependency create pulled in by `-target` (refuse);
  ForceNew replacement in both orderings (refuse); data-source read (pass); update outside
  eligible (refuse); empty plan (pass).
- Only after it enforces the property: restore the mechanical guarantee in the comments,
  worded as what the *plan check* guarantees.

### Step 2 — wire the policy vocabulary (own PR; subsumes the `prepared:false` item) — NOT STARTED

`prepare_destroy` → `string preparation_outcome`; `gcp_prepare_destroy` → `unit
preparation_outcome`; `prepare_destruction` → the `destruction_preparation` record (two typed
facts, no redundant pair). GCP guard-lowering and plan-check refusals are
`Continue_to_destroy`; AWS `final-snapshot` is `Block_destroy`. Unreadable state becomes
`Preparation_failed/Continue`, distinct from `Nothing_to_prepare` — which replaces the bool and
resolves the `verify_gcp_destroy_preparation ~prepared:false` ambiguity.

**Exit-code contract (decided by the operator):** `0` only if every preparation succeeded or
had nothing to do **and** the destroy succeeded; a distinct nonzero code for "destroy succeeded
but a preparation failed"; the existing failure code for a failed or blocked destroy. Document
the codes in the CLI help.

Tests: the two specified regressions — Block (destroy never invoked, target remains, the
retention guarantee named) and Continue (failure visible, destroy invoked, result reported
separately) — plus the exit code for each case.

### Step 3 — adoption inspection (read-only) — NOT STARTED

IDENTITY (is this resource associated with this exact Sol target?) separately from AUTHORITY
(is that evidence strong enough to assume Terraform ownership and delete it?). Write up
findings and stop; act on nothing. "Current resources do not carry enough provenance" is a
legitimate and useful result — do not lower the standard to make adoption possible.

## Verified vs assumed

**Verified:** the harness suite passes in CI (`24 passed, 0 failed` in the required `test`
job); 29 OCaml tests pass including the eligibility, complement and policy assertions;
`main` builds; cost exposure is zero (GKE and Cloud SQL absent, only the durable zone
remains); the delegation resolves.

**Assumed / not established:** the plan-and-assert guarantee (not implemented — the comments
no longer claim it); the wired policy behaviour (types exist, path still aborts); whether
current resources carry sufficient provenance for adoption (unexamined); whether the
historical "verify: absent" claims in Attempts 5/6 rested on sound checks (both suspect
checks are fixed now, but the old verdicts should not be re-read as strong evidence — the
independent provider inventory is what established those runs were clean).

## Hard stops

Any terraform apply/destroy against a real account; any spend; opening the Attempt-7 gate; CLI
contract changes beyond the exit codes decided above; any mutation during the adoption
inspection.

## Method notes that cost time

- **After `dune fmt`, re-read the file before writing edit anchors.** Formatting invalidated
  hand-written anchors twice and produced a patch that cut through a comment, surfacing as
  `Unbound value`. Better: format first, generate edits against formatted source.
- **The ticket-move guard needs both ids** when a branch names one ticket and the subjects
  name another, each in its own parenthesised group.
- **Use `git grep` for source-of-truth questions**; a working-tree search missed a
  line-continued literal and nearly withdrew a real finding.
- **Never `git add -A` while a qualification target is in the tree** — it swept a target left
  by a debug run into a commit.
- Evidence: Attempt-6 raw logs frozen at `~/sol-attempt6-evidence/` (outside the repo — they
  carry project identifiers); the readable chronology is
  `docs/qualification/2026-09-23-gcp-attempt6.md`.

---

# Handoff, part 2 — the correctness review reorders the plan (2026-09-24)

`main` at the time of writing: `0d062112`. A correctness review of the destroy path was run
against `f2e1773`; each finding below was re-verified against current `main` before being
treated as a premise. **All seven are confirmed in substance, with two corrections**, noted
inline.

## Verification of the review's premises

| | Finding | Verdict |
|---|---|---|
| **A** | The destroy path has constructive applies beyond the preparation. | **Confirmed.** `destroy-reconciliation-apply` (`cmd_cloud_tf.ml:2906`) is `Sol_cli_terraform.apply ~scope:whole_root` with `bootstrap_access_vars ~enabled:true @ destroy_apply_vars` (`:2909-2915`), and `provisioner-bootstrap-access-remove` is whole-root too. A whole-root apply **creates** anything in configuration and absent from state, so in the Attempt-6 shape the step *after* the now-skipped preparation plans to create the cluster. |
| **B** | Destroy decides "substrate exists" from the install-time output contract. | **Confirmed.** `cloud_outputs_of` (`:717`) parses with `gcp_outputs_of_json` (`sol_cli_cloud_lifecycle.ml:211`), whose required fields are `cluster_name`, `project_id`, `region`, `artifact_registry` (+ optional ones). *Correction to the finding's field list: it is those four, not the three named.* So `{}` reads as absent, partial outputs are a parse error that refuses destroy, and complete outputs hit A. |
| **C** | The CLI's absence verification fails open. | **Confirmed in substance.** `verify_gcp_destroy` (`:538`) / `verify_aws_destroy` (`:433`) derive names and region via `var_file_value` (`:194`), a line-based tfvars parser, with a `| None -> default` fallback (`:228`). A wrong region or project yields not-found, which reads as absent. Its parser-limitation details (JSON tfvars, multi-line HCL, `TF_VAR_*`, `*.auto.tfvars`) are inferred from that shape, not traced line by line. #449 fixed this class in the **harness**, not here. |
| **D** | Retention is printed, not observed. | **Confirmed.** `retention_report` is only ever *called* (`:3040`, `:3046`); there is no `describe-db-snapshots` anywhere under `cli/sol/bin/`. Nothing checks that a final snapshot exists and is available, and nothing checks that `none` left zero snapshots and zero retained automated backups. |
| **E** | `exit`-in-helpers is why the wiring is all-or-nothing, and the `on_error` threading already has a hole. | **Confirmed.** `with_cluster_access` (`:1418`) takes `~on_error`, and its **GCP branch is `ignore on_error`** (`:1423`): a failed `get-credentials` after bootstrap-admin was enabled exits without removing the elevated access — on install and on destroy. `require_terraform_success`/`lifecycle_error` exit 1 deep in helpers, so cleanup depends on `at_exit` plus hand-threaded callbacks. `cmd_rollback.ml` already has the target shape. |
| **F** | `gcp_protection_state` identifies resources by *type* in `root_module` only. | **Confirmed in substance.** It reads `values.root_module.resources` and `List.find_opt`s on `type`, mapping that onto a fixed address: child modules are invisible, a second instance of a type is mis-handled, and a benign `null` `deletion_protection` surfaces as an error. *Correction: the message is "unexpected `terraform show -json` shape", not "could not read state" — the latter is the process-failure branch.* |
| **G** | Decode failures ack-and-drop even where a DLQ exists. | **Confirmed in substance.** `kafka_service.ml` defaults `on_decode_error` to a handler that acks (`n e ~raw_bytes:_ ~ack`), on both the normal and retry paths. BUG-028 covered retry-topic records only. The exact `Retry_topics`-vs-source conditionality was not traced. |

## Record correction (A's consequence)

`FND-0030`'s design said "the targeted apply is the only constructive step in the destroy
path". **That is false**, and the finding's design section should be corrected: the
reconciliation apply and the bootstrap-access apply are whole-root and constructive. The
plan-and-assert therefore has to cover **every** destroy-path apply, not only the preparation,
and the reconciliation apply should be scoped to the bootstrap-window resource plus the
eligible guarded resources rather than `whole_root`.

## The order now (same operating rules: own PR each, merge on green, stop at green boundaries)

1. **Offline replay of Attempt 6** (no spend; may be a doc PR). Against a **copy** of
   `~/sol-attempt6-evidence` **state** — never the original, and nothing that can mutate a
   provider — record: `terraform output -json` and which case of B it hits, and `terraform
   plan` with the destroy path's vars (bootstrap admin on + destroy policy vars) together with
   its create/replace set. This tells us whether A would have fired. **If it cannot be done
   without any chance of touching the real project, stop and say so.**
2. **Port destroy to the rollback shape**: `Sol_cli_cloud_destroy.execute ~deps` returning a
   typed outcome, with terraform/gcloud/aws injected, exits only at the command edge, cleanup
   bracketed. Begin with one state observation turned into a **typed inventory** (addresses,
   ids/self-links, regions from state) and derive everything below from it — which fixes F.
   Replace the outputs-based "substrate exists" with the inventory — which fixes B. An offline
   test replays the Attempt-6 state through `execute` with fake deps. Behaviour-preserving
   apart from B and F; say so in the PR.
3. **Plan-and-assert on EVERY destroy-path apply.** The allow/refuse table already in this
   note, plus one explicit allowlist: the bootstrap-access window resource may be created
   (that create is the point of that apply). Scope the reconciliation apply to that resource
   plus the eligible guarded resources instead of `whole_root`. Fixtures: the six already
   listed, **plus** a whole-root-shaped plan with a missing cluster (refused) and a
   bootstrap-window create (allowed).
4. **Wire the policy vocabulary and the decided exit codes** (small once 2 exists).
5. **Verification and retention from the inventory**: verify the ids and regions captured
   *before* destroy, plus `terraform state list` empty as a postcondition; keep the name-based
   describes only as an extra orphan sweep. Retention becomes observed evidence (snapshot `X`
   exists and is available / zero snapshots and retained backups for `none`); a missing
   snapshot under `final-snapshot` is a loud failure. Fixes C and D.
6. **Runtime track (G)**, after 1–5 or in parallel if a session has room: source-topic decode
   failures go to the DLQ where one exists, ack-and-drop only as explicit opt-in; add starter
   alerts for decode drops, DLQ inflow and consumer lag. Check TypeScript parity per DEC-022.

**Adoption inspection is paused until 5 lands.** **Attempt 7 stays closed**, and its negative
criterion — zero target-owned creates — now depends on 1–5, because it rests on every
destroy-path apply being asserted, not just the preparation.
