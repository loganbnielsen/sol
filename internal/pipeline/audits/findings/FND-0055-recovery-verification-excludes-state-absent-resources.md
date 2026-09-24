# FND-0055 — Destroy verification's evidence set is the *state* inventory, so a target-declared resource that state does not represent is invisible to it and its survival can be reported as "postcondition established"

- **Classification:** `VERIFIED_DEFECT` (fail-open verification; the coverage half of the
  recovery contract)
- **State:** `OPEN`
- **First identified:** 2026-09-24, while preparing GCP Attempt 7 (HARDEN-004) — before any
  live resource was created; verified against `origin/main @ 2775d5b1`
- **Derived ticket:** `DEC-044` → the implementation that decision authorizes
- **Evidence class:** `STATIC` for the Sol claim; `BEHAVIORAL` for the Terraform semantics it
  depends on (reproduced locally, no cloud — see "Reproduction")
- **Related:** FND-0030 (the same divergence, seen from the ownership side), FND-0045 (the
  finding whose remedy narrowed this coverage), FND-0044, `DEC-040` (absence must be observed),
  ADR 0003 invariant 6, ADR 0004, `INV-DESTROY-1`/`INV-DESTROY-2` in
  `docs/qualification/gcp-production-single-region-v1-matrix.tsv`

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
coverage), FND-0046, `DEC-040`, `DEC-033`, ADR 0003 invariant 6, ADR 0004, `docs/qualification/
2026-09-24-gcp-attempt7-prelive-falsification.md`.
