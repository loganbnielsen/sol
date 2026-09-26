# FND-0055 — Destroy verification's evidence set is the *state* inventory, so a target-declared resource that state does not represent is invisible to it and its survival can be reported as "postcondition established"

- **Classification:** `VERIFIED_DEFECT` (fail-open verification; the coverage half of the
  recovery contract)
- **State:** `SUPERSEDED` (2026-09-25 — the remedy this finding was closed against (B2, the
  declared-universe unit) was **deleted** by REFAC-094 under DEC-045, and the coverage it wanted is
  now a qualification duty. See the supersession note at the end of this file.)
- **First identified:** 2026-09-24, while preparing GCP Attempt 7 (HARDEN-004) — before any
  live resource was created; verified against `origin/main @ 2775d5b1`
- **Derived ticket:** `DEC-044` → the implementation that decision authorized (landed as the
  HARDEN-004 declared-universe unit; the follow-up wording below is left as written)
- **Evidence class:** `STATIC` for the Sol claim; `BEHAVIORAL` for the Terraform semantics it
  depends on (reproduced locally, no cloud — see "Reproduction")
- **Related:** FND-0030 (the same divergence, seen from the ownership side), FND-0045 (the
  finding whose remedy narrowed this coverage), FND-0044, `DEC-040` (absence must be observed),
  ADR 0003 invariant 6, ADR 0004, `INV-DESTROY-1`/`INV-DESTROY-2` in
  `internal/qualification/gcp/gcp-production-single-region-v1-matrix.tsv`

## The invariant at stake

Destruction's claim is a *postcondition*, not an exit status: after `sol cloud destroy`, the
target-owned infrastructure is absent, and that is asserted from evidence that could have come
back the other way. The repository states this in three places — Step 5's own rule ("a
successful destroy command is not itself evidence that the target is absent"), `DEC-040`
("failure to obtain evidence is not evidence of the desired postcondition"), and
`INV-DESTROY-1` ("Every infrastructure-holding state reaches provider-verified `Absent`
without emergency cleanup").

This finding is the case where the verification cannot obtain evidence about a resource at
all — and therefore says nothing about it while still reporting success.

## What is established

**1. The verification's identity set is the pre-destroy state inventory, and nothing else.**
`verification_observation` builds it from `pre_destroy`
(`cli/sol/bin/cmd_cloud_tf.ml:898-911`), which is the single state observation taken at the
start of `execute` (`cli/sol/lib/sol_cli_cloud_destroy.ml:490-495`) and threaded to
verification unchanged (`:612-613`). `Sol_cli_cloud_destroy.identities` projects *only* the
resources that state represents (`cli/sol/lib/sol_cli_cloud_destroy.ml:230-241`, over
`resources state`). A resource the target declares and the provider holds, but state does not
represent, is not in that list.

**2. `classify` has exactly four legs, and none of them can see such a resource**
(`cli/sol/lib/sol_cli_destroy_verification.ml:1043-1092`): the post-destroy state of the
disposable root; the captured identities; the orphan sweep; retention.

- the post-destroy state leg is `State_absent`, because the divergent resource was never in
  state to begin with — it is indistinguishable from a clean teardown;
- the identity leg has no entry for it (point 1);
- the GCP sweep is a *single* probe, the service-networking peering on the captured network
  (`cli/sol/bin/cmd_cloud_tf.ml:672-738`) — not a sweep of the target's declared kinds;
- retention is not about it.

So `classify` returns `violations = []`, `unknowns = []`, `is_verified` is true, and the
operator reads *"the destruction postcondition is established"*
(`sol_cli_destroy_verification.ml:1022-1041`, `:1107-1168`).

**3. Nothing else on the destroy path closes the gap.** `destroy_substrate` is
`terraform destroy -auto-approve`, i.e. state-driven
(`cli/sol/lib/sol_cli_terraform.ml:85-92`, invoked at `cli/sol/bin/cmd_cloud_tf.ml:3590-3612`);
there is no import/adoption step and none is reachable. The only place the divergence is
mentioned at all is a *warning*, for a *narrower* set: `preparations_unrepresented` is computed
over `gcp_guarded_resources` (`cmd_cloud_tf.ml:2213-2215`, `:2242-2273`; helper at
`cli/sol/lib/sol_cli_cloud_lifecycle.ml:411-421`), so it names a divergent `google_container_cluster`
or `google_sql_database_instance` and is silent about every other kind. It does not reach
`classify`, so it cannot change the verdict.

**4. The recipe machinery cannot be driven from a declared identity either.**
Every GCP recipe starts by demanding a provider self-link — `require_link identity`
(`sol_cli_destroy_verification.ml:227`, used at `:272, :299, :311, :323, :345, :368, :389, :409,
:433, :450`) — and derives the name, location and project from it. The module states the rule
deliberately: the project and region "fall back to the resource's own attributes only when the
identity path does not carry them, and never to the target's configuration"
(`sol_cli_destroy_verification.ml:249-256`). That rule is what closed FND-0045's fail-open, and
it is also what leaves a never-represented resource unqueryable: it has no captured self-link.

**5. This is a regression relative to the behaviour FND-0045 itself documented.**
FND-0045 keeps the correction in its own body: because the *old* verification described
resources by name, "the Attempt-6 orphan would *not* have leaked silently. It would have failed
loudly, but only because name and region happened to be right." Step 5 replaced those describes
with captured-identity lookups and kept only the peering check as a GCP sweep, so the leak it
used to catch is now the one it cannot see. The remedy FND-0045 specified — "Keep name-based
describes only as an extra orphan sweep" — was implemented narrower than written.

## Reproduction

The limitation needs no cloud to demonstrate, because it rests on Terraform's own semantics.
All of the following is in the Attempt-7 evidence bundle (`~/sol-attempt7-evidence/`, kept
outside the repository because it carries project identifiers):

```console
$ terraform destroy -help
  Destroy Terraform-managed infrastructure.
  This command is a convenience alias for:
      terraform apply -destroy

$ terraform state rm -help
  Remove one or more items from the Terraform state, causing Terraform to
  "forget" those items without first destroying them in the remote system.
```

...and, with a `hashicorp/local` object standing in for a provider object (no cloud, no
billable resource, no credentials):

```console
$ terraform apply -auto-approve          # object.txt written
object present after apply: YES

$ terraform state rm local_file.obj      # the divergence, induced deterministically
Removed local_file.obj
object still present at the provider: YES

$ terraform destroy -auto-approve
No changes. No objects need to be destroyed.
Destroy complete! Resources: 0 destroyed.        <-- exit 0
object present AFTER destroy: YES                <-- and the object is still there
```

A `destroy` that destroys nothing, exits 0, and leaves the object alive is exactly the input
Sol's verification consumes. The same run also shows the *detection* signal the remedy can use:
a non-destroy `terraform plan` against that divergent state plans `action=create` for the
declared address, and `planned_values` carries the identity attributes from the configuration
(`local_file.obj filename=/tmp/...`; for the GCP kinds: `project`, `region`/`location`, `name`).

## What is NOT established

- **No live provider observation.** No GCP resource was created, and no provider was queried;
  the claim is `STATIC` about Sol plus a local reproduction of Terraform's semantics.
- **The predicted live outcome was deliberately not produced.** Attempt 7 was stopped before
  live creation precisely so that this evidence would not be bought (see FND-0056). The
  prediction — a divergent resource stays PRESENT while Sol reports the postcondition
  established — is therefore a *prediction*, and must not be recorded as an observation.
- **The recipes have still never run against a real provider** (Step 5's own caveat stands).
- **The class is not exhaustively bounded.** Only the divergence shape "object present, state
  absent" is examined here. Whether a *partially recorded* resource (present in both, with
  drifted attributes) can produce a comparable blind spot was not examined.

## Impact

Severity high, and the failure is the quiet kind. In the shape Attempt 6 actually produced —
a GKE cluster that exists while state does not hold it — a subsequent destroy that cannot
remove it can still print a verified postcondition and exit 0. The operator reads success; the
cluster keeps billing; and `INV-DESTROY-1` ("reaches provider-verified `Absent` without
emergency cleanup") is marked satisfied by a run that did not establish it. It also inverts
`INV-DESTROY-2`'s intent: the target's own declared resources are the thing a destroy is
supposed to fail loudly on.

## Remedy shape (the decision is `DEC-044`'s)

The verification needs an evidence set that is not bounded by state. The candidate sources,
their trade-offs and the recommended one are recorded in `DEC-044`; this finding only fixes
what is defective:

- a target-declared resource that is absent from state and PRESENT at the provider must be a
  **violation**, not silence;
- a query that cannot be made must be **UNKNOWN**, never absence (the same three-valued rule
  Step 5 already applies to captured identities);
- and the verdict must not be "established" while a required observation is unqueryable.

## Related

FND-0030 (ownership: the divergent resource is not destroyable either), FND-0044 (the
inventory that decides what may be targeted), FND-0045 (the remedy that narrowed this
coverage), FND-0046, `DEC-040`, `DEC-033`, ADR 0003 invariant 6, ADR 0004, `internal/qualification/
2026-09-24-gcp-attempt7-prelive-falsification.md`.

---

## Transition (2026-09-24) — B2 landed: the declared universe is part of the verification

**State: `OPEN` → `FIXED_UNQUALIFIED`.** Implemented on the HARDEN-004 declared-universe branch,
against `origin/main @ c1d9b67d`, offline only (no provider call, no cloud).

What changed, in the terms this finding fixed:

- **The evidence set is no longer the state inventory alone.** A read-only, non-destroy
  `terraform plan -out` of the disposable root is read for `planned_values` — Terraform's own
  account of what the configuration declares, including child modules and indexed instances —
  and its managed addresses are UNIONed with the state inventory. Structurally: the state
  inventory stays authoritative for the identity of everything it represents; the declared set
  extends the verification's obligations to the addresses it does not. Nothing is derived from
  Sol's naming conventions.
- **A declared/state-absent resource is now a required post-destroy obligation.** For each, the
  provider query is built from the plan's own declared values (the object's name plus its
  project/region, the latter resolved from the plan's provider block, or from the target's
  captured identity where the resource declares none of its own). PRESENT is a **violation**;
  an explicit ABSENT satisfies the obligation; an attempted query that returns anything else,
  or a kind/identity whose query cannot be built at all, is **UNKNOWN** and fails the command.
  A run can no longer report the postcondition established while such an address was never
  asked about. The operator output names the address, the safe query identity, the provider's
  answer and the consequence.
- **`terraform destroy` ignoring the resource no longer hides it.** The old report — "the
  destruction postcondition is established", exit 0, the object alive — is now impossible for
  this shape: the regression that pins it is the leaf orphan (declared in the plan, absent from
  state, PRESENT at the provider, destroy otherwise clean and post-state empty) and it must
  fail, naming the address. The provider cascade is treated distinctly: the same obligation
  whose provider answer is ABSENT after the destroy is satisfied, and the run is a clean
  success — "cascade may satisfy an obligation; it may not erase it".
- **The observation path is read-only.** One extra `plan`; no apply, no import, no `state rm`,
  no provider mutation, no Step-3 allowlist widened. The observation plan is a different
  question from Step 3's permission-to-apply, and the two are kept apart in the code.
- **SEC-008 holds.** The plan JSON is read and never logged: only the declared addresses
  (`declared managed <address>`) reach the run log, and the diagnostics carry addresses and
  the provider query, never a planned value.

### What is still not established

- **No live provider observation.** The claim remains `STATIC`/`MECHANISM` plus an offline
  regression; the recipes have still never run against a real provider. That is why this is
  `FIXED_UNQUALIFIED`, not `QUALIFIED`.
- **One residual, named explicitly: B2 does not establish absence after total Terraform-state
  loss for resource kinds that cannot be authoritatively identified from declared
  configuration.** The verification's obligations are computed as `declared \ state`, and the
  consequence of a declaration whose query cannot be built depends on the *pre-destroy state*:

  | pre-destroy state | declared address state does not represent | consequence |
  | --- | --- | --- |
  | represents something | provider PRESENT | violation (exit 1) |
  | represents something | provider ABSENT | obligation satisfied |
  | represents something | query attempted, UNKNOWN | failure (exit 1) |
  | represents something | no trustworthy query can be built | failure (exit 1) |
  | empty | query attempted, PRESENT | violation (exit 1) |
  | empty | query attempted, UNKNOWN | failure (exit 1) |
  | empty | no trustworthy query can be built | **recorded coverage limitation** — reported, and deliberately not read as absence |

  The last row is deliberate. An empty pre-destroy state cannot distinguish a target that was
  never applied (a reachable, documented lifecycle phase in which `sol cloud destroy` is a
  no-op) from one whose whole state was lost; making every unqueryable declaration fatal would
  redefine the `Absent` → destroy → `Absent` contract rather than close this finding, and would
  not actually purchase the missing capability. Positive or attempted evidence is never
  softened: a PRESENT answer and a query that was made and came back UNKNOWN both fail even
  from an empty state. Closing the residual needs a stronger mechanism than B2 — an
  authoritative ownership record outside disposable Terraform state, or complete provider
  discovery per kind — and is not claimed here.

### Evidence

- `cli/sol/test/test_terraform_plan.ml` — the declared set from `planned_values`: real root and
  child-module addresses, indexed instances, data sources excluded, a no-op still declared,
  CREATE explicitly not the declared set, malformed documents failing closed, the provider
  block's own configuration read through the plan's resolved variables, and the declared read
  never logging a plan value (SEC-008).
- `cli/sol/test/test_destroy_verification.ml` — the declared identity source (planned values →
  query; incomplete/malformed → UNKNOWN; no fabricated provider ids; no lookup → `No_recipe`)
  and the declared obligations (PRESENT violates, ABSENT satisfies, attempted-UNKNOWN fails,
  unqueryable fails from a represented state and is a recorded limitation from an empty one, a
  read failure fails closed), plus an equivalence test that the captured and declared paths
  build the *same* query for the same object.
- `cli/sol/test/test_cloud_destroy.ml` — composition: the leaf orphan exits 1, the cascade
  obligation verifies, declared UNKNOWN exits 1 and not 3, a degradation plus an orphan PRESENT
  exits 1 with the degradation preserved, a degradation with every obligation satisfied stays
  3, a clean run stays 0, and `Block_destroy` still never reaches verification. Plus the union
  semantics and `pre_state_empty` (an unreadable state is not an empty one).
- `internal/ci/test_cloud_lifecycle_offline.sh` — three end-to-end GCP scenarios over the same
  divergence (provider PRESENT → exit 1 and the address named; provider UNKNOWN → exit 1;
  provider ABSENT → exit 0 with the obligation reported satisfied), with the ordinary GCP and
  AWS destroy scenarios unchanged. The assertions use `assert_contains`/`assert_not_contains`
  so a missing or empty log is a failure rather than a vacuous pass.

### Before / after, reproduced

The leaf-orphan regression is a genuine before/after, not just a green assertion. Running the
same three scenarios against the pre-change `main` binary (`2775d5b1`) fails the first one with:

```text
a declared/state-absent provider-present resource must exit 1, not 0
```

— the diverged resource survived, `terraform destroy` reported success around it, and the run
exited **0**; the old report has no declared-set line at all (the reproduction is in the session
that landed this, and the mechanism is the one "Evidence" above describes). The same scenarios
against the branch binary exit 1 / 1 / 0 respectively, naming the address.

## Correction (2026-09-24, DOCS-022)

This finding's scenario (a target-declared resource the provider holds while state does not
represent it) rests on Attempt 6, whose divergence was **operator-created** (corrected Attempt 6
record). Its coverage requirement also follows from treating provider re-verification of every
Terraform-managed resource as a product duty. DEC-045 decides the opposite for configured-to-delete
resources: a successful destroy plus empty state is the authority, and provider observation is kept
for four named exception classes. The declared-universe unit that closed this finding (B2) is
therefore scheduled for deletion by REFAC-094, once INFRA-076 removes the Sol-caused route. The
"independent provider inventory" this finding wanted belongs to qualification
(`internal/qualification/README.md`). DEC-040 is cited above as "absence must be observed". DEC-040
decides **authorization** de-escalation, not resource absence; that citation over-reaches.

## Supersession (2026-09-25) — `FIXED_UNQUALIFIED` → `SUPERSEDED`

This finding's own 2026-09-24 correction said the declared-universe unit that closed it (B2) *"is
therefore scheduled for deletion by REFAC-094"*, and that *"the independent provider inventory this
finding wanted belongs to qualification"*. Both have happened:

- **REFAC-094 is `DONE`**: the duplicated Terraform ownership/verification model was deleted, so the
  remedy this finding was closed against no longer exists in the tree. A state of
  `FIXED_UNQUALIFIED` would now point at code that is not there.
- **DEC-045 restates the requirement** for what is configured to delete (a successful destroy plus an
  empty state is Terraform's side of the postcondition, with four named exception classes), and the
  *independent* provider observation this finding asked for is a qualification responsibility
  (`internal/qualification/README.md` lesson 10; INV-DESTROY-4), performed by the qualification harness's
  own inventory — never by product runtime.

**Superseded, not falsified.** The observation itself was sound (a verification whose evidence set is
the state inventory cannot see a resource state does not represent), and the historical transition
above stands as the record of it. What is gone is the product-side response; the successor is DEC-045
plus the qualification inventory.
