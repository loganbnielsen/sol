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

---

# Step 1 — the offline replay cannot be constructed safely (2026-09-24)

**Outcome: deliberately not run.** The instruction carries its own rule: if reproducing the
historical plan requires credentials or connectivity to the real project, do not run it, and
record that the retrospective plan cannot safely be reproduced offline. That is what the
inspection found.

## What the inspection found

- The frozen evidence is **logs only** — 21 files at `~/sol-attempt6-evidence/`, no state
  snapshot. There is nothing local to replay against.
- The only local `terraform.tfstate` files are backend **initialization records**, and both
  point at the real project:

  | root | backend | bucket | prefix |
  |---|---|---|---|
  | `cli/platform/infra/gcp` | `gcs` | `sol-qualification-tfstate` | `sol/qual/gcp/us-central1/cloud.tfstate` |
  | `cli/platform/infra/bootstrap-gcp` | `gcs` | `sol-qualification-tfstate` | `bootstrap/gcp` |

- So any `terraform plan` would (a) read state from the real bucket and (b) refresh against the
  real Google project. **A plan is a network operation on `sol-qualification`.** Calling that
  an offline replay would be a fiction, and it would put the surviving qualification account in
  the path of a command whose purpose is retrospective.

**Therefore the Attempt-6 destroy-path plan set was not reproduced.** Recorded, not worked
around.

## What still stands — source-level evidence, not inference

- `destroy-reconciliation-apply` is `Sol_cli_terraform.apply ~scope:whole_root` with
  `bootstrap_access_vars ~enabled:true @ destroy_apply_vars` (`cmd_cloud_tf.ml:2906-2915`).
- `provisioner-bootstrap-access-remove` is whole-root (`:2334-2349`), and the install-side
  enable is whole-root (`:2304`).
- A whole-root apply constructs configured-but-absent resources by definition.

So the preparation is **not** the only constructive step on the destroy path: the Attempt-6
shape has constructive applies **before and after** the preparation that mechanism 2 now skips.
This is what the correctness review's finding A rests on, and the replay being unrunnable does
not weaken it — it is evidence about the code, not about a plan output.

## Forward lesson, cheap and worth taking

The teardown evidence bundle should capture `terraform show -json` (or `terraform state pull`)
**before** any destroy runs. It is a local read, it costs nothing, it is not a mutation, and it
would have made this step executable offline. Harness improvement candidate; not done here.

---

# Step 2 — destroy runs through a typed execution core with a state inventory (2026-09-24)

**Outcome: landed.** `Sol_cli_cloud_destroy.execute ~deps` (own library module,
`cli/sol/lib/sol_cli_cloud_destroy.ml`) is now the destroy sequence. It returns a typed
`outcome` and never calls `exit`; `cmd_cloud_tf.ml`'s `cloud_destroy` resolves the request
and owns the one process exit. Terraform/gcloud/aws operations are injected through `deps`;
`Sol_cli_rollback.execute` is the precedent. Behaviour is unchanged except for B, F and the
control-flow correction that makes cleanup reliable.

## Fix B / FND-0044 point 2 — existence from state, not from install outputs

One `terraform show -json` observation is classified into a typed inventory
(`State_empty | State_represented of resource list | State_unreadable`), and
`substrate_presence` is three-valued (`Present | Absent | Unknown`). Substrate existence, the
destruction phase, which resources may be prepared, the reconciliation apply and the platform
teardown are all derived from it. The install-time output contract no longer decides anything:
a target with no outputs, partial outputs or complete outputs destroys the same way. An
unreadable state is UNKNOWN and is never read as absence.

## Fix F / FND-0048 — the real addresses, root and child modules

`inventory_of_show_json` walks `root_module` and every `child_modules` entry, retaining
Terraform's own `address`. Guarded resources are matched by address
(`google_sql_database_instance.postgres`, `google_container_cluster.main`), never by a type
mapped back onto a fixed address; a second instance of a type is a different address, not a
mis-attributed first one. `deletion_protection` is `bool option`, so a benign null is `None`;
a missing `values` is the empty state rather than a read failure. The inventory also captures
the provider id/self-link, project/account and region/location, so Step 5 can verify from it.

## Fix E structurally — cleanup is bracketed, not hand-threaded

`with_elevated_access` enables the bootstrap access, runs the one operation that uses it, and
removes the access **unconditionally** — including when enabling itself failed. The removal's
result is carried as `cleanup` evidence in the outcome, never swallowed, and a cleanup failure
on the otherwise-successful path is fatal rather than replaced by an unrelated success. The
hand-threaded `on_error` every failing branch had to remember is gone from the destroy path.

## Evidence

- `cli/sol/test/test_cloud_destroy.ml` — 20 offline cases with fake deps: the eight the step
  named (empty state; half-built/partial-outputs; a partial-outputs parse failure cannot refuse;
  child-module address preserved; same type, distinct instances; state-read failure classified
  UNKNOWN and not absence; elevated-access failure still removes; cleanup failure preserved as
  evidence) plus identity, region-from-zone and null-guard cases. No terraform, gcloud, aws or
  network.
- `internal/ci/test_cloud_lifecycle_offline.sh` — the fixture now models what
  `terraform show -json` actually emits (every resource carries its real `address`), and the
  "absent target" fixture empties the state as well as the outputs. The RDS-absent fixture
  keeps an EKS representation, so "substrate exists, no RDS" stays distinct from "wholly
  absent". Full offline harness green.
- `internal/ci/check_ocamlformat.sh --all` green; CI's unit-test command
  (`dune test framework/… cli/sol/test/`) green.

## Deliberately not done (later steps)

Step 4 (wire the policy vocabulary
and the decided exit codes), Step 5 (verification/retention from the inventory), adoption
inspection, FND-0010, the parked `cluster_issuer` change and runtime finding G. (Step 3
landed — see below.) REFAC-091's install half is also still open, so that ticket stays in
`READY_FOR_ENGINEERING`.

**Demo/example: not applicable** — internal lifecycle refactor with no change to what an
application author writes. **No language-parity impact** (DEC-022): no application-facing
contract changed.

# Step 3 — every destroy-path apply is plan-asserted (2026-09-24)

**Outcome: landed.** Destroy no longer performs an unasserted constructive Terraform
operation. Each apply reachable from the destroy path is planned to a saved plan, classified
from Terraform's own resource changes (addresses and actions), refused when any change is
outside that phase's allowlist, and applied *as the saved plan* only then.

## The applies reachable from destroy, and what each may do

| phase | scope | why it exists | permitted in destruction | refused |
| --- | --- | --- | --- | --- |
| `rds-destroy-prepare` | `-target=aws_db_instance.postgres` | lower RDS deletion protection and set the final-snapshot policy | `update` of `aws_db_instance.postgres` | any create/replace/delete, anything else |
| `gcp-destroy-prepare` | `-target=` the guarded addresses the inventory represents | lower Cloud SQL / GKE deletion protection | `update` of those addresses | any create/replace, anything else |
| `destroy-reconciliation-apply` | bootstrap mechanism + guarded addresses the inventory represents | hold the Destroy policy in force and open the bootstrap window | create/update the bootstrap mechanism; `update` a represented guarded address | create/replace of anything else — including a missing cluster the `-target` pulls in |
| `provisioner-bootstrap-access-remove` | bootstrap mechanism only | close the elevation | create/update/delete the bootstrap mechanism | anything else |

`terraform destroy` (platform + substrate) is not an apply and is non-constructive by
construction — a destroy plan removes what state holds and creates nothing — so it is not
asserted here.

## Mechanism

- `Sol_cli_terraform_plan`: one reusable mechanism. `changes_of_plan_json` reads
  `resource_changes` (real `address`/`type`/`mode`/`actions`); `violations` classifies against a
  phase `policy`; `guarded_apply` refuses before applying. `no-op` anywhere and a data-source
  `read` are always permitted; an unrecognised action, a document with no `resource_changes`, a
  plan-command failure, and an unreadable plan are all REFUSE.
- `Sol_cli_terraform.plan_saved` / `show_json_plan` / `apply_saved`: the apply receives the
  saved plan file, so what ran is what was asserted — not a re-plan that could differ.
- `Sol_cli_cloud_destroy`: the phase allowlists (`guard_preparation_policy`,
  `bootstrap_enable_policy`, `reconciliation_policy`, `bootstrap_removal_policy`), stated in
  addresses and actions.

## Scope narrowing

- Reconciliation moved off `whole_root` to bootstrap + the guarded addresses the Step-2
  inventory represents. GCP targets the stable root address
  `kubernetes_cluster_role_binding.provisioner_bootstrap_admin`; **AWS targets `module.eks`**,
  because its bootstrap access is an access-policy association *inside* the `eks` module whose
  internal address is module-version-dependent. A guessed `-target` there would fail closed but
  strand the target, and it cannot be validated offline against the real module — so the module
  is the smallest stable scope, the rule names the resource type, and the plan assertion is the
  enforcement. Configured-but-unrepresented resources are not targeted at all.
- Removal moved off `whole_root` to the bootstrap mechanism alone (the Destroy policy vars are
  unnecessary once the guarded resources are out of scope; the config vars stay).

## "Cleanup" is a name, not a safety property

The removal apply is asserted like any other. If its plan is refused the apply does not run,
`with_elevated_access` records `Cleanup_failed`, and the outcome says the elevated access may
remain (`Elevated_access_not_removed` on the otherwise-successful path). Cleanup stays
structurally attempted; it just may not execute an unsafe apply.

## Evidence

- 17 new offline unit tests (`test_terraform_plan.ml`): action classification; malformed
  documents; empty/read-only plans; the phase allowlists (missing-cluster CREATE refused,
  unrepresented guarded CREATE refused, unexpected CREATE refused, unexpected REPLACE refused,
  bootstrap CREATE allowed, represented guarded UPDATE allowed, removal with an unexpected
  CREATE refused, out-of-scope DELETE refused, Attempt-6 inventory prunes the scope,
  unrecognised action refused); and `guarded_apply` — refusal / malformed / plan-failure each
  never invoke the apply, permitted applies once.
- 2 new execution-level tests in `test_cloud_destroy.ml`: a refused reconciliation never applies
  and still attempts removal; a refused removal is not reported as successful cleanup.
- The offline harness models the saved-plan flow (plan with `-out`, `show -json <plan>`,
  `apply <plan>`), and gained an end-to-end refusal scenario: a reconciliation plan that would
  reconstruct the missing cluster is refused, the substrate destroy never runs, and the
  bootstrap window is still closed.
- `dune build`, CI's unit-test command, `check_ocamlformat.sh --all` and the full offline
  harness all green.

## Deliberately not done (Step 4+)

Step 5's provider verification/retention observation, adoption/import, FND-0010, the parked
`cluster_issuer` change and runtime finding G remain untouched. (Step 4 landed — see below.)
REFAC-091's install half is still open, so that ticket stays in `READY_FOR_ENGINEERING`.

**Demo/example: not applicable** — internal lifecycle refactor. **No language-parity impact**
(DEC-022): no application-facing contract changed.

# Step 4 — the failure policy is wired, with decided exit codes (2026-09-24)

**Outcome: landed.** Step 3 answers "may this Terraform operation execute safely?"; Step 4
answers "if a preparation cannot safely execute or fails, what does destruction do next?".
The two stay independent: `eligibility` (does the preparation apply to a represented
resource?) → `outcome` (did it succeed, fail, or get refused?) → `consequence` (may
destruction continue?).

The governing invariant: **destruction remains available from a half-built target unless
proceeding would violate an explicit destruction-time safety guarantee the target declared.**
Neither extreme is reachable — "every preparation failure blocks" is gone, and "preparation
failure can never block" was never true.

## The exit-code contract (decided by the operator, 2026-09-24)

| code | meaning |
| --- | --- |
| `0` | clean: every applicable preparation succeeded or had nothing to do, destruction reached absence, verification confirmed it, and no cleanup failure remains |
| `3` | degraded success: absence was reached and verified, but one or more `Continue_to_destroy` preparations failed or were refused |
| `1` | failure or block: destruction did not reach its postcondition, including a `Block_destroy` guarantee preventing destruction |
| `2` | *not used here* — reserved for this CLI's refusal / cannot-proceed-as-requested semantics |

Documented in `sol cloud destroy`'s `EXIT STATUS` man section and pinned in
`test_cloud_destroy.ml` (`exit_clean` / `exit_degraded` / `exit_failure`).

## What is wired

- `Sol_cli_cloud_lifecycle`'s existing vocabulary (from #451: types only, not wired) is now
  the destroy path's: `deps.prepare` returns
  `preparation Sol_cli_cloud_lifecycle.preparation_outcome`, and the core decides the
  consequence with `destruction_blocked` / `preparation_failure`.
- Edge typed outcomes: `prepare_destroy_result` → `string preparation_outcome` (the AWS
  snapshot identity, or nothing, or a failure); `gcp_prepare_destroy_result` → `unit
  preparation_outcome`; `prepare_destruction_result` → `preparation preparation_outcome`.
  Verification is part of the preparation (an unconfirmed snapshot identity is not a
  preparation), and the old `~prepared:false` ambiguity is gone — the "nothing was prepared"
  case is `Nothing_to_prepare`, and the verify function is only reached once a preparation
  applied.
- Policies: AWS `Retain_final_snapshot` → `Block_destroy` (the canonical DEC-033 case, and the
  reason names the target's own retention guarantee); AWS `Retain_nothing` → best-effort;
  GCP guard lowering → `Continue_to_destroy`; GCP's "cannot retain anything on GCP yet"
  refusal → `Block_destroy` (a retention guarantee, not a guard-lowering failure).
- Unreadable state → `Preparation_failed {policy = Continue_to_destroy}`, deliberately
  **distinct** from `Nothing_to_prepare`. UNKNOWN is never absence and never silently a
  best-effort failure: the preparation runs, the substrate stays `Substrate_unknown`, and the
  failure is reported.
- Plan refusal is an outcome, not permission to weaken Step 3. Nothing in the assertions
  changed: the refused apply still never runs, and Step 4 only decides what follows.
- The outcome distinguishes the histories:
  `Destroy_succeeded { preparation; degradations; substrate; cleanup }` (empty `degradations`
  = clean, non-empty = degraded), `Destroy_blocked { guarantee; cleanup }`, and
  `Destroy_failed { failure; degradations; cleanup }`. A degraded preparation survives a later
  destroy failure; a cleanup failure is evidence alongside the primary failure, never a
  replacement for it.

## The reconciliation boundary, inspected (§4)

The combined bootstrap-access enable/reconciliation was examined for whether its typed
dependency can honestly represent the two responsibilities' different consequences. It can:
the apply's two halves share the fate of one plan, and a failure means *the authority was not
obtained*, so the operation the window exists to authorise (the platform teardown) cannot run.
That is now `Protected_skipped`, a degradation: the platform teardown is skipped and reported,
the substrate destroy — which needs no cluster authority — proceeds, and removal is still
attempted. No provider conditional, phase-name inspection, or string matching was added.

Keeping "we chose not to perform an unsafe preparation" separate from "we lack the authority
required" is what `Protected_skipped` vs `Protected_failed` encodes: the first degrades the
destroy, the second fails it.

## §8 — the removal allowlist's CREATE, tightened

Step 3 allowed `Create | Update | Delete` on the bootstrap mechanism during removal. Nothing
requires the create: GCP expresses the closed window as
`count = var.provisioner_bootstrap_admin ? 1 : 0` (so `false` plans a delete, or nothing), and
AWS's `access_entries` map drops the `bootstrap` policy association when the variable is false
(so the association is removed). A create there would be the apply *adding* the elevation it
was asked to close. The policy is now `Update | Delete`, with a regression
(`test_terraform_plan.ml`: "removal may not create the elevation it is closing"). The AWS
`module.eks` compromise from Step 3 is preserved unchanged — no module-internal address was
guessed.

## Evidence (all offline)

- `test_cloud_destroy.ml` grew a `failure policy` group: `Continue_to_destroy` failure destroys
  and stays visible (exit 3); `Block_destroy` failure blocks, names the guarantee, and never
  invokes the substrate destroy (exit 1); a clean preparation and destroy stay clean (exit 0);
  a degradation is preserved when the destroy then fails; UNKNOWN is not absence and not
  silent; a refused plan becomes a continue failure with the unsafe apply still unexecuted.
  Existing coverage now pins the reconciliation split: a skipped teardown is a degradation with
  removal attempted, a *failed* protected operation is a failure, and a skipped teardown plus a
  cleanup failure keep all three facts separate.
- The harness's end-to-end refusal scenario now carries Step 4's semantics: the refused
  reconciliation never applies (the stub exits 99 if it does), the substrate destroy runs, the
  window is still closed, the degradation is reported, and the run exits 3.
- `dune build`, CI's unit-test command, `check_ocamlformat.sh --all` and the full offline
  harness all green (29 destroy tests, 18 plan tests).

## Deliberately not done (Step 5+)

Step 5's provider absence verification from the inventory, observed retention, adoption/import,
runtime finding G, FND-0010 and the parked `cluster_issuer` work remain untouched.

**Demo/example: not applicable** — internal lifecycle refactor. **No language-parity impact**
(DEC-022): no application-facing contract changed.
