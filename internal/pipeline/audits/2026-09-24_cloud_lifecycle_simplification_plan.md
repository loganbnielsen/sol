# Sol cloud lifecycle: simplification and provider boundary — execution plan

**Status:** authoritative execution plan. Each stage is a ticket (see § Ticket map); tickets carry
the dependencies and point back here for scope, so this file is the single source of truth.
**Supersedes:** the earlier 12-PR draft of this plan (never committed).
**Inputs:** the Attempt-6 due-diligence investigation, the HARDEN complexity/assumption audit,
the cloud architecture boundary audit, and two rounds of engineer review (folded in below).

This is a sequence of **stages with explicit dependencies**, not a fixed list of PRs. Each stage
may land as one PR or several; the engineer chooses PR boundaries consistent with the repo's
ticket and CI rules (§ Repo process). A stage is done when its **acceptance evidence** is merged
on `main`, not when code exists on a branch.

Do not perform a large rewrite. Preserve behaviour unless a stage explicitly removes behaviour
whose requirement has been withdrawn.

---

## Decisions this plan treats as made

Treat these as decided unless implementation evidence contradicts them (then stop — § Stop
conditions).

1. **Terraform owns Terraform-managed infrastructure**: resource graph, state, provider CRUD,
   ordering, locking, ordinary reconciliation, import/adoption, and provider-native identity of
   the resources it manages. Sol may *inspect* state and plan to enforce Sol-level policy. Sol
   does not reconstruct Terraform's ownership model. (Premise to be confirmed in Stage 2 before
   anything is deleted.)
2. **Provider-native identity is not part of generic Sol.** No ARN, GCP self-link, Azure
   resource ID, "account-as-project", per-kind lookup recipes, or provider not-found parsing in
   generic types or modules. Where a Sol guarantee needs provider evidence, the boundary returns
   a Sol-level verdict:

   ```ocaml
   type verdict = Present | Absent | Unknown of string
   ```

   and the identity/query mechanics stay provider-private.
3. **Small capabilities, not one Cloud interface.** Candidate set: Terraform roots / backend /
   variables; credential readiness; opaque cluster access; temporary authority window;
   destruction guards and retention; non-Terraform residue; readiness data. Capabilities may be
   optional or answer `Unsupported reason`. Do not force AWS/GCP/Azure symmetry.
4. **Terraform stays visible.** Generic Sol legitimately knows resource address, plan action,
   saved plan and state presence, because it enforces Sol invariants over them (e.g. destroy
   never constructs). `Sol_cli_terraform_plan` is the model boundary: generic policy over
   Terraform evidence, no provider semantics.
5. **Independent provider inventory belongs to qualification**, not to product runtime.
6. **Generalized adoption (DEC-044 A1) is withdrawn** unless new evidence independently
   establishes the requirement.

### Target dependency direction

```text
CLI
 │
 ▼
Sol lifecycle core ───────────► generic Terraform engine (state / plan / execution / supervision)
 │
 ▼
capabilities_of : provider -> capabilities      (the one provider dispatch)
 ├── AWS capabilities
 ├── GCP capabilities
 └── (future) Azure capabilities
```

Provider implementations depend on Sol-level types (`verdict`, `retention_support`,
`failure_policy`, plan `matcher`). Generic lifecycle code does not depend on provider-native
types. Several small capability records/modules are preferred over one large one.

---

## Stage dependency graph

```text
S1 Evidence hygiene + db_password + provider-match guard
 │
 ▼
S2 Terraform-authority due diligence + abandonment guard ──► S5a delete Terraform-managed sweep rows
 │
 ▼
S3 Correct historical records
 │
 ▼
S4 Supervision + durable completion evidence (one design unit)
 │
 ▼
S5b Delete the unjustified runtime model (B2, per-kind verification, identities, A1, exit 3)
 │
 ▼
S6 Table-shaped capabilities + registry
 │
 ▼
S7 Generic apply sequence (execute ~deps)
 │
 ▼
S8 Opaque cluster access
 │
 ▼
S9 Retention + residue capabilities
 │
 ▼
S10 Provider-owned target configuration
 │
 ▼
S11 Azure-on-paper fitness test; guards at zero
```

### Ticket map

| Stage | Ticket | Initial directory | Depends on |
|---|---|---|---|
| S1.a evidence hygiene | INFRA-075 | READY_FOR_ENGINEERING | — |
| S1.b `db_password` | SEC-010 | READY_FOR_ENGINEERING | — |
| S1.c provider-match guard | REFAC-092 | READY_FOR_ENGINEERING | SEC-010 |
| S2 authority due diligence | DEC-045 | READY_FOR_ENGINEERING | — |
| S3 record corrections | DOCS-022 | BACKLOG | DEC-045 |
| S4 supervision + completion evidence | INFRA-076 | READY_FOR_ENGINEERING | INFRA-075 |
| S5a Terraform-managed sweep rows | REFAC-093 | BACKLOG | DEC-045 |
| S5b delete ownership/verification model | REFAC-094 | BACKLOG | DEC-045, DOCS-022, INFRA-076 |
| S6 table capabilities + registry | REFAC-095 | BACKLOG | REFAC-092, REFAC-094 |
| S7 generic apply sequence | REFAC-091 (existing, narrowed to its install half) | READY_FOR_ENGINEERING | REFAC-095 |
| S8 opaque cluster access | REFAC-096 | BACKLOG | REFAC-091 |
| S9 retention + residue capabilities | REFAC-097 | BACKLOG | REFAC-096 |
| S10 provider-owned target configuration | REFAC-098 | BACKLOG | REFAC-097 |
| S11 fitness test, guards at zero | HARDEN-005 | BACKLOG | REFAC-093, REFAC-098 |

Everything downstream of DEC-045 starts in `BACKLOG`, because S2 may legitimately stop the
deletion program; promote those tickets once DEC-045 records its decision. REFAC-091 stays in
`READY_FOR_ENGINEERING` (where it already is), and `/work` holds it until REFAC-095 is `DONE`.

Hard ordering constraints (the rest is preference):

- Nothing is deleted before **S2** records the authority decision.
- **B2 / declared-universe deletion (S5b) must not merge before S4 is canonical on `main`.**
- **S5a** (Terraform-managed sweep rows) depends only on S2 and may land any time after it.
- S7 precedes S8 so the 575-line `cloud_init` is restructured once, not twice.
- S10 is last because it changes the target-file parsing surface.

---

## S1 — Evidence hygiene, the live `db_password` defect, and the provider-match guard

Do this first. Every later stage depends on comparable before/after evidence and on the guard.

### S1.a Evidence contamination (first commit of the program)

Observed: `~/.local/share/sol/runs/` held exactly 21 `cloud-destroy-20260925T005743Z-*` runs,
all started within the same minute; with `keep = 20` shared across every command prefix, that
burst pruned every earlier run, including the Attempt 6 and 7 run directories.

- Identify the writer (`rg` for `Sol_cli_run_log.create` callers reachable from tests and
  scripts that leave `SOL_HOME` unset; `internal/ci/test_cloud_lifecycle_offline.sh` already
  exports it, so the writer is probably elsewhere).
- Isolate test `SOL_HOME` hermetically.
- Add an executable guard: a test run must fail if it would write under the real user Sol home.

### S1.b `db_password` — fix at the correct layers, not by enumerating providers

Defect: `Sol_cli_db_credential.provider_creates_postgres` is `Aws -> true | _ -> false`, and the
check keys on AWS's `create_rds`. GCP creates Cloud SQL from `var.db_password`
(`cli/platform/infra/gcp/main.tf:202`), so on GCP Sol's refusal of `--var=db_password` (the value
would reach the logged argv) never runs.

Do **not** change it to `Aws | Gcp -> true`. Split the two concerns it conflated:

| Concern | Owner | Mechanism |
|---|---|---|
| A required input is missing | **Terraform** | AWS declares `db_password` with `default = ""` (the reason Sol's `Missing` check exists); GCP declares it with no default, so Terraform already refuses. Make AWS fail at plan time too: remove the empty default or add a validation tied to `create_rds`. Sol's `Missing` check then becomes Terraform's. |
| A secret appears in logged argv | **Sol process/logging safety** | Refuse `--var db_password` (and any other declared secret variable) on every provider. `Sol_cli_process` already has a `redact` mechanism; use or extend it rather than adding a provider concept. |

Acceptance evidence:

- AWS: `--var db_password=…` refused; a missing password fails at `terraform plan`, before any
  apply.
- GCP: `--var db_password=…` refused (the regression that is broken today).
- A root that declares no such variable is unaffected.
- No provider match remains in this logic, so "a new provider inherits `_ -> false`" is
  impossible by construction, not by test.

### S1.c Architectural guard (executable, allowlist that shrinks)

Add a CI check under `internal/ci/` (same style as the existing guards):

- **Provider matches outside approved locations**: count `Sol_cli_provider.Aws|Gcp` matches (and
  `Aws_outputs|Gcp_outputs`) outside provider/registry modules. Commit the current baseline as an
  allowlist. Report-only is acceptable at first; the allowlist must only shrink.
- **Wildcard provider matches: forbidden immediately for new code.** After S1.b, two survivors
  remain; allowlist them explicitly, each with a one-line reason:
  - `sol_cli_config.ml:1432` — production DB deletion protection set for AWS only; GCP relies on
    its root default (`sql_deletion_protection` defaults to `true`). Not a live defect; unchecked
    for a new provider.
  - `sol_cli_cloud_lifecycle.ml:52` — backend-config fallback error.
  - **Correction (2026-09-25, REFAC-092/DOCS-022):** the line above is wrong. That `| _` belongs
    to the enclosing `match target.state_bucket`, not to the provider match. The two real
    survivors are both in `sol_cli_config.ml`: `:1432` (production DB deletion protection) and
    `:1452` (the production profile's node shape, applied for AWS only).

Record every other hazard found while auditing wildcards; do not refactor them in S1.

---

## S2 — Terraform destruction-authority due diligence

A research/decision stage. It gates every deletion in S5.

### The narrowed question

> For resources Terraform is **actually configured to delete** — not `ABANDON`, `skip_destroy`,
> `skip_delete`, or equivalent — does a normally completed successful `terraform destroy` plus
> empty state establish Terraform's side of the destroy postcondition?

Check with primary sources (Terraform core and provider source/docs at the versions Sol pins):

- provider Delete success/failure contract, including "already gone" handling;
- asynchronous deletion (does the provider wait for the operation to finish before returning?);
- state persistence during destroy; failed remote persistence; `errored.tfstate`;
- interrupted operations (already researched: graceful stop vs abrupt death);
- whether Terraform can return a successful destroy with empty state while the same managed,
  billable resource remains;
- AWS/GCP exceptions specific to the kinds Sol's roots declare.

Keep these classes separate; they are not falsifications of the premise:

| Class | Handled by |
|---|---|
| Terraform-managed, configured to delete | Terraform (the premise under test) |
| Intentionally relinquished (`deletion_policy = "ABANDON"`, `skip_destroy`, `skip_delete`, …) | residue capability (S9) |
| Retained snapshots | retention capability (S9) |
| Kubernetes/controller-created (LoadBalancer, PV disks) | prevention + residue (S9) |
| Manually removed from state; externally created; corrupted | out of contract — fail closed where detectable |

### Abandonment inventory and guard

- Inventory every intentional-relinquish attribute in the roots. Today:
  `rg -n 'deletion_policy|skip_destroy|skip_delete|ABANDON' cli/platform/infra` finds exactly one,
  `google_service_networking_connection.sql` (`infra/gcp/main.tf:235`).
- Each one must have declared residue handling (the peering is released by deleting the network;
  that is observed behaviour, and the residue check covers it).
- Add a CI guard: introducing a new relinquish attribute without a corresponding residue entry
  fails the build.

### Output

A recorded decision: either **the authority premise holds** (for configured-to-delete resources),
or a documented counterexample and a stop (§ Stop conditions).

---

## S3 — Correct the historical records

Depends on S2. Correct records **before** deleting implementation. Preserve history: add dated
correction/supersession notes; never silently rewrite a previous conclusion.

Revisit at minimum: the Attempt 5 and Attempt 6 records, FND-0030, FND-0055, FND-0056, DEC-044,
INV-DESTROY-1, INV-DESTROY-4.

Record explicitly:

- Both observed provider/state divergences were **operator-created**. Attempt 5: the operator
  ran `terraform state rm` on the zone. Attempt 6: the operator force-unlocked a lock held by a
  live apply, then SIGTERM'd Terraform **and its provider plugin**
  (Attempt 6 agent transcript `cc1eb286…`, lines 613–615; frozen logs in
  `~/sol-attempt6-evidence/`).
- The Attempt 6 claim "killing the harness orphaned its `terraform apply`, which then produced
  the divergence" is falsified: the orphan ran normally; the divergence came from the later
  direct kill. The "force-unlock after confirming no Terraform process remained" wording is
  also false for Attempt 6.
- The supported, Sol-caused divergence route is the separate process-supervision defect:
  Sol dies → Terraform's stdout pipe breaks → Terraform dies by SIGPIPE → in-flight create
  unrecorded, lock left. **Status: reproduced locally, fix pending (S4).** Do not describe it as
  fixed in S3.
- Independent provider inventory is a qualification responsibility (INV-DESTROY-1's
  "provider-verified" means qualification verification).
- DEC-040 decides **authorization** de-escalation; it was cited as "absence must be observed"
  for resources, a generalization it never made. Note the mis-citation where it propagated.
- A1 is withdrawn.
- Restate FND-0030 around the behaviour that remains required: destroy never constructs; a
  half-built target is always destructible; divergence Sol cannot vouch for fails closed and is
  named.

---

## S4 — Terraform supervision and durable completion evidence (one design unit)

Depends on S3. Treat supervision and completion evidence as **one design**, even if it lands in
a couple of commits: the completion artifact must be written by something whose lifetime is not
Sol's.

### Failure being removed (reproduced)

Sol runs Terraform in its own process group, reads stdout/stderr through pipes, and buffers the
phase log in memory until exit. If Sol dies (SIGKILL, OOM, crash, SIGHUP, or Ctrl-C, since Sol
keeps the default SIGINT disposition), Terraform is killed by SIGPIPE at its next output line:
reproduced with `terraform_data`, rc −13 after 5.1 s, lock left held, in-flight resource missing
from state.

### Required properties

1. **Output survives Sol.** Terraform stdout/stderr go to durable files in the run directory,
   never to a pipe only Sol reads. Sol tails them for display.
2. **A supervisor that outlives Sol** launches Terraform in its own session/process group and
   writes a completion artifact: `{pid, host, started_at}` at launch; the exit status (code or
   terminating signal) at exit.
3. **Signal boundary.** On user/Sol interrupt: send **one** SIGINT to Terraform's pid only, never
   to provider plugins, never by process name; then wait. A second interrupt is an explicit,
   labelled data-loss choice. No SIGKILL or timeouts as lifecycle control. Never force-unlock.
4. **Operational visibility.** After this stage, *Sol exiting does not mean Terraform exited*.
   `sol cloud` output must say so when it happens (Terraform still running, pid, and that it
   holds the lock), and the next invocation must report it (see states below).

### Operation state: three values, not two

| State | Condition | Next Sol invocation |
|---|---|---|
| **Running** | no exit status recorded, and the supervisor or Terraform is alive on this host (pid + start-time check) | report "an operation is still running (pid, host, started), holding the lock; wait". Never unlock. |
| **Resolved** | exit status recorded — **including a graceful non-zero exit after Ctrl-C** — and no `errored.tfstate` | proceed normally |
| **Unresolved** | no exit status and nothing alive (supervisor killed, reboot, OOM); or Terraform terminated by signal; or `errored.tfstate` present | refuse an ordinary constructive retry; name the reason; operator reconciliation required |

Rules:

- A graceful interrupt is **Resolved**. Marking it suspicious would recreate the conservatism
  this program removes.
- The backend lock stays authoritative. Do not invent a second lock; a leftover lock is
  translated into a clear message, not removed.
- `errored.tfstate`: detect it, fail loudly with its path, preserve it, never auto-`state push`.
- Prevent blind retry only for **Unresolved** — never by rediscovering every provider resource.
- A lock held by another host cannot be liveness-checked: report it as such (Running-elsewhere
  or Unknown), never as abandoned.

### Test infrastructure decision (make this first)

The SIGPIPE reproduction used `terraform_data`, which is built into Terraform and has **no plugin
process**, so it can prove "Sol death does not SIGPIPE Terraform" but not "provider children are
not signalled" — the property that actually broke in Attempt 6. Choose one, hermetically:

- a tiny local test provider with a slow Create, built in-repo; or
- a vendored/cached `null`/`time` provider so CI needs no network.

### Acceptance evidence (offline)

- Reproduce the SIGPIPE failure against the pre-fix code path, then show it no longer occurs.
- Sol killed mid-apply: Terraform keeps running, output keeps being written, exit status is
  recorded, lock released normally, state complete.
- One Ctrl-C reaches Terraform only; Terraform performs its graceful stop; the provider plugin
  process receives no signal from Sol.
- Running / Resolved / Unresolved each classified correctly, including graceful non-zero exit →
  Resolved.
- `errored.tfstate` → loud failure, file preserved.
- Unrelated Terraform processes on the host are untouched.

### Qualification harness: same discipline

`internal/qualification/*` must adopt the same process-identity rules: act only on the recorded
process group/pid it launched, SIGINT Terraform only, no `pkill -f`, no force-unlock. The
Attempt 6 divergence came from exactly those practices.

---

## S5 — Delete the unjustified runtime model

### S5a (depends on S2 only) — Terraform-managed sweep rows

Remove sweep rows for kinds Terraform manages and destroys: EIP, NAT gateway, ECR prefix
(`aws_orphan_sweep` in `cli/sol/bin/cmd_cloud_tf.ml`). Keep controller-created and
intentionally relinquished residue (LoadBalancer, PV disks, the peering).

### S5b (depends on S2 and S4 canonical on `main`) — ownership/verification model

Delete product-runtime machinery whose purpose is independently modelling Terraform-managed
ownership. Do not move it into provider modules; if its requirement is withdrawn, delete it.

- per-kind provider verification of Terraform-managed kinds (the 18 recipes in
  `Sol_cli_destroy_verification`);
- provider identity capture used only by that verification (`identity`; the `arn`, `project`,
  `provider_id`, `region` fields of `Sol_cli_cloud_destroy.resource`);
- ARN parsing, GCP self-link/project extraction, AWS error-code parsing, GCP 404-subject rule —
  where used only by that verification;
- B2 declared universe: `declared_set`, `declared_query_of`, `gcp_declared_recipe`,
  `aws_declared_recipe`, per-address obligations, the read-only destroy-time plan that feeds them;
- any A1/import scaffolding;
- **exit code 3** → exit 0 plus a warning line (only `test_cloud_lifecycle_offline.sh` reads 3);
- slim the generic inventory to: Terraform address, deletion-protection state, and
  retention-relevant identifiers where a surviving retention check needs them.

Keep independent provider inventory in qualification. Keep SEC-008's rule (the plan JSON never
reaches the run log).

---

## Surviving destroy semantics (must hold throughout S5–S9)

These are **preserved**, and each keeps executable evidence:

- **Destroy never constructs.** Every constructive destroy-path Terraform operation stays
  saved-plan asserted. Simplify the four per-phase policies to one rule: *no CREATE or REPLACE
  during destroy except the identified temporary bootstrap-authority operation*; the removal
  phase additionally forbids CREATE, as today. Do not weaken this.
- **Half-built targets stay destructible.** Keep configuration ∩ represented-state eligibility,
  so preparation never creates a resource in order to delete it (e.g. an apply that failed
  before the cluster existed).
- **Block vs Continue**, where it is real policy: a failed non-essential preparation may allow
  destroy; an unsatisfiable promised retention guarantee blocks it.
- **Bracketed elevation.**
- **Post-destroy state empty** check.
- **Retention**: independent observation for promises Terraform destruction cannot establish.
- **Non-Terraform residue**: demonstrated controller-created or deliberately relinquished
  resources only; prefer prevention before parent destruction (delete LoadBalancer Services and
  PVCs before the cluster).

---

## S6 — Table-shaped capabilities and the registry

Extract from actual call sites; do not start from a module signature. Begin with capabilities
that are already data:

- Terraform roots (cloud, platform) and backend arguments;
- Terraform variables per target;
- readiness data (`platform_storage`, `readiness_invocations` — already this shape);
- bootstrap/authority-window matchers and scope (`bootstrap_matchers`, `bootstrap_scope`,
  `reconciliation_scope`);
- guarded addresses (`gcp_guarded_resources`, `aws_db_instance.postgres`).

Concentrate provider selection in `capabilities_of`. Shrink the S1.c allowlist accordingly.
A future provider must fail explicitly at registration/capability construction, never inherit
another provider's behaviour.

## S7 — Generic apply sequence

Give apply the same shape destroy already has (`execute ~deps`; REFAC-091's install half):
generic sequencing, provider inputs supplied as explicit dependencies, no provider selection
inside the sequence. Behaviour-preserving; not a lifecycle redesign.

## S8 — Opaque cluster access

Replace `cloud_outputs = Aws_outputs | Gcp_outputs` (17 dispatch sites) with the smallest
abstraction apply and destroy need: a cluster name/handle, a kube environment, platform
variables. Provider output records and parsing stay provider-private. No universal output record
of optional fields.

## S9 — Retention and residue capabilities

- **Retention:** Sol owns `destroy_retention`. The provider answers
  `Supported { vars; observe : unit -> verdict } | Unsupported reason`; `Unsupported` maps to
  `Block_destroy` as today (GCP's "cannot retain"). No universal snapshot model.
- **Residue:** provider-private observation of things Terraform does not own and Sol has a
  demonstrated reason to verify, returning `verdict`s. Generic code receives no ARN, self-link,
  resource ID or query recipe.

## S10 — Provider-owned target configuration

Move provider-native configuration (`provisioner_role_arn`, `cluster_access_role_arn`,
`deploy_role_arn`, `operator_role_arn`, `state_lock_table`, `provisioner_impersonator`) out of
the flat generic `Sol_cli_config.target` into a provider-owned field, without creating a
universal provider-identity record. Last, because it changes target-file parsing.

## S11 — Fitness test and guards at zero

Repeat the Azure-on-paper test (do not implement Azure). Baseline from the boundary audit:
about 5 registration touches and about 45 edits to existing lifecycle code, across the CLI
orchestrator, two generic library modules, two generic types, and one silent wildcard. Target:

```text
+ Azure Terraform roots
+ Azure capabilities
+ one registration arm
+ Azure credentials
+ qualification
```

with no generic identity widening and no scattered lifecycle edits. The S1.c guard's provider-
match allowlist and wildcard allowlist are at zero (or each residual entry is justified in one
line).

---

## Qualification boundary

Qualification may know far more than product runtime — provider identities, inventories,
cost-bearing objects, per-kind lookup recipes — and that is intentional. Qualification asks
whether reality independently confirms Sol's claim. Runtime Sol does not embed its own
qualification harness. Qualification also captures a `terraform state pull` before any teardown,
so later analysis never depends on state that was destroyed.

---

## Stop conditions

Stop and ask for a decision if:

- the Terraform authority premise is materially falsified **for configured-to-delete
  resources** (intentional relinquishment is not a falsification — see S2);
- a supported Sol lifecycle still produces state/provider divergence after S4;
- generic Sol genuinely needs provider-native identity for a surviving product invariant;
- a provider difference cannot be expressed without changing Sol's domain semantics;
- a deletion would weaken a demonstrated retention or safety guarantee;
- the capability boundary would require false AWS/GCP symmetry.

Routine implementation friction is not a stop condition.

---

## Repo process (applies to every stage)

- **Tickets.** One ticket per PR in `internal/pipeline/tickets/READY_FOR_ENGINEERING/`, or a
  declared batch branch naming every ticket id; the Ticket-move guard enforces the move to
  `DONE/`. Verify each ticket's premise before starting (declare a `premise:` probe where it
  reduces to an existence check).
- **Merges are serial.** Branch protection is strict: one CI cycle per merge; update from
  `main`, wait for green, re-post the `SOLDEV-REVIEW: PASS <sha>` marker, merge. Check the marker
  actually landed on batch branches.
- **Worktrees.** No mutating work in the canonical checkout; `git -C <worktree>` on every
  mutating command; `git worktree add … origin/main`.
- **Formatting.** `internal/ci/check_ocamlformat.sh --staged` before every push.
- **Completion notes.** Demo/example: not applicable (cloud lifecycle internals) — say so.
  Language parity (DEC-022): no application-facing impact — say so.
- **Docs.** Update `internal/planning/WORK_SUMMARY.md` per stage; update findings/decisions whenever
  their status changes.

### Per-stage discipline

For each stage state: the invariant preserved or simplified; the old responsibility; the new
owner; the executable evidence added or retained; the tests run. Prefer deletion over abstraction
when a behaviour has no product requirement. Prefer moving provider knowledge behind an existing
seam over creating new layers. Do not preserve code because effort went into it; do not delete
code because it is complex. The criterion is responsibility.

---

## End-state report

- **Before:** the models generic Sol owned and where provider knowledge crossed boundaries.
- **After:** what Sol, Terraform, and each provider own.
- **Deleted model:** the ownership/identity machinery that no longer exists.
- **Provider change surface:** the S11 Azure test against the baseline (about 45 edits).
- **Complexity:** line/module reductions (secondary).
- **Evidence** that the simplification did not weaken: destroy-never-constructs; half-built
  destruction; retention; privilege cleanup; abnormal-operation safety (Running / Resolved /
  Unresolved); qualification independence.

Success criterion: *Sol owns Sol semantics. Terraform owns Terraform semantics. Provider
implementations own provider semantics. Each boundary exposes only what the next layer needs.*
