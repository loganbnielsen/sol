# GCP Attempt 7 — pre-live falsification, no live resource created (2026-09-24)

**Outcome:** the attempt was authorized, opened, and then **stopped before Phase 2**. No provider
resource was created, no Terraform state was mutated, and no provider object was deleted. The
attempt's positive postcondition was found to be *unreachable as written* on current `main`, from
evidence obtainable without spending anything — which is what the brief's own stop condition asked
for. Nothing here is a qualification of the recovery contract; it is a falsification of one, plus
the two findings and the decision that follow from it.

**Cost exposure at close: zero** — and this time not because a teardown worked, but because
nothing was ever created. The qualification project was re-inventoried independently before the
session ended (below).

## Run identity

| | |
|---|---|
| Attempt | HARDEN-004 Attempt 7 |
| Target | `qual/gcp/us-central1` (never written — Phase 2 was not entered) |
| Project / region | `sol-qualification` / `us-central1` (the harness defaults) |
| Revision | `main @ 2775d5b1` (worktree `docs/attempt7-prelive-falsification`, created from `origin/main`) |
| CLI binary | `_build/default/cli/sol/bin/main.exe`, `sol --version` = `edbba1c9` — the last commit that touched `cli/`, **not** `2775d5b1` (a finding/docs-only commit). Recorded so a later reader does not read the mismatch as a build error |
| Tool versions | Terraform v1.9.8; Google Cloud SDK 585.0.0 |
| Timestamps | container `date -u` at baseline `2026-09-24T22:08:35Z`; at record capture `2026-09-24T22:19:08Z`. Quoted as observed; durations deliberately not computed |
| Evidence bundle | `~/sol-attempt7-evidence/` — outside the repository, because it carries project identifiers (the same rule Attempt 6's raw logs followed) |

## What was authorized, and what was actually used

The brief authorized narrowly-scoped live operations for a controlled qualification. Only the
read-only halves were exercised: **Phase 0** (independent provider/project/account inventory) and
**Phase 1** (offline preflight). Every mutating authorization — creating the fixture, inducing the
divergence, running the recovery path — was left unused, deliberately.

## Phase 0 — baseline, established independently before any mutation

Every line below was read from the provider, not from the handoff's earlier "zero exposure"
statement.

| Observation | Verdict |
|---|---|
| Authenticated identity | the account configured for the qualification project (verified equal to `gcloud config get core/account`); holds `roles/owner` on the project |
| Project | `sol-qualification`, lifecycle `ACTIVE` |
| Billing | enabled |
| GKE clusters (all locations) | **ABSENT** |
| Cloud SQL instances | **ABSENT** |
| Compute instances / instance groups / disks | **ABSENT** |
| Regional and global addresses, forwarding rules | **ABSENT** |
| Routers, NATs, networks other than `default` | **ABSENT** |
| Service-networking peerings | **ABSENT** |
| Artifact Registry repositories | **ABSENT** |
| Service accounts other than the project's Compute default | **ABSENT** |
| Quota usage (`CPUS`, `IN_USE_ADDRESSES`, `SSD_TOTAL_GB`, `DISKS_TOTAL_GB`, `INSTANCES`) | all `0`, against ample limits |
| Disposable Terraform state | `sol/qual/gcp/us-central1/{cloud,platform}.tfstate` and `sol/prod/gcp/us-central1/{cloud,platform}.tfstate` all **represent 0 resources** |
| Durable prerequisites (DEC-042/DEC-043) | DNS zone `qual-gcp-sol-fab-dev` **PRESENT** (4 NS delegated, resolving over DoH) and GCS bucket `sol-qualification-tfstate` **PRESENT**; the durable root's own state represents exactly those two objects |
| Unknowns | none that could have hidden a billable resource |

The account was therefore clean, and Attempt 7 would not have been piled on residue. **One
unexpected object is recorded rather than explained away:** an empty `sol/prod/gcp/us-central1/`
state pair exists alongside the `qual/` one. It holds no resources and costs nothing; it is noted
here because a future reader comparing state prefixes will find it.

## Phase 1 — preflight

| Check | Result |
|---|---|
| Current `origin/main` synced; canonical checkout clean | yes (`2775d5b1`, `git status --porcelain` empty; the attempt ran from a worktree per REFAC-090) |
| Credentials and qualification target confirmed | yes — project, region and account as above |
| Billing/project/account identity confirmed | yes |
| Quota sufficient for the narrowly required fixture | yes, by a wide margin |
| Durable prerequisites healthy | yes (zone delegated, bucket present, durable state owns both) |
| Teardown/recovery command available from the exact target to be used | **not reached** — `sol cloud destroy` exists and is wired, but the attempt never needed it; this check is discharged by the falsification instead |
| Evidence directory outside disposable Terraform working directories | yes: `~/sol-attempt7-evidence/` |
| No parked/unmerged code required | yes — the parked `cluster_issuer` change was not needed and was not touched |

**Offline gates were not the binding constraint.** They are the *next* step's preflight, and the
attempt stopped one gate earlier, at the falsification. Recorded rather than skipped silently.

## The falsification

The brief's stop condition: *"if current-main evidence materially contradicts the qualification
design below, stop before creating live resources and report the contradiction."* It was met.

The property to be qualified was: a target where a provider resource exists while Terraform state
does not represent it, and the target still declares it, can be converged to absence by the
supported destruction path **without** reconstructing the missing resource, editing the target,
repairing Terraform state, or using provider-native deletion as the normal recovery mechanism —
with the divergent resource itself `ABSENT` afterwards.

Three facts, all establishable pre-live and all reproduced in the evidence bundle:

1. **A resource removed from state is outside `terraform destroy`'s ownership set.**
   `terraform destroy` documents itself as an alias for `terraform apply -destroy`, i.e. it acts on
   Terraform-*managed* infrastructure; `terraform state rm` documents that it makes Terraform
   "forget" an item "**without first destroying them in the remote system**". Reproduced locally
   with a `hashicorp/local` object standing in for a provider object — no cloud, no credentials,
   no billable resource:

   ```console
   $ terraform state rm local_file.obj
   Removed local_file.obj
   object still present at the provider: YES

   $ terraform destroy -auto-approve
   No changes. No objects need to be destroyed.
   Destroy complete! Resources: 0 destroyed.     <-- exit 0
   object present AFTER destroy: YES             <-- and it is still there
   ```

2. **Sol has no mechanism that restores destructive ownership.** `destroy_substrate` is a plain
   state-driven `terraform destroy`; there is no `terraform import` wrapper anywhere in the CLI
   (`rg -n "import" cli/sol/bin/*.ml cli/sol/lib/*.ml` matches one unrelated comment; positive
   control: the same search *does* find `terraform import` where it exists, in `docs/`).

3. **The verification cannot see it.** Step 5's provider evidence is built from the *captured*
   pre-destroy state inventory, so a resource that was never represented contributes to no leg of
   the verdict and its survival can be reported as "the destruction postcondition is established".

Consequently the required postcondition is reachable only if the **provider** cascades the
divergent object's removal behind a represented parent. That is provider behaviour; Sol neither
targets the object nor observes its identity afterwards. Recording it as a pass would have
promoted a resource-specific special case to a general contract, so it was **rejected as a
fixture** — together with the leaf-orphan and exact-Attempt-6-shape fixtures, which were each
predicted (correctly, on the evidence above) to produce a failure already established
structurally. Buying a GKE cluster and a Cloud SQL instance to observe a known answer is the
spending this stop avoided.

And the attempt's own criteria could not be satisfied even with the mechanism: they forbid
"importing the provider resource / re-adding it to Terraform state", while the repository's own
recorded design for this exact problem says convergence *requires* it — FND-0030 §Design point 3:
"Converging it requires adopting it and then destroying it … a new capability". That is a
contradiction between the qualification's criteria and the product's recovery design, and it is
not this session's to resolve.

## What this establishes, and what it does not

**Established (`STATIC` for the Sol claims; `BEHAVIORAL` for Terraform's semantics, reproduced
locally):** the four facts above, and therefore that current `main` cannot establish the
attempt's general property as written.

**Not established — and not to be read into this record:**

- **No live provider observation of any kind.** No resource was created, none was queried about
  the divergence, no destroy was run. The predicted live outcome is a *prediction*.
- **Which provider resources cascade** when a parent is deleted. Reasoned about, not tested, and
  explicitly not relied on.
- **Whether the recipes behave as documented against a real provider.** They still have never
  run live (Step 5's own caveat).
- **Whether a plan-derived declared set covers every kind** — the mechanism is sound on the
  evidence, its per-kind coverage was not audited.

**Observed / inferred / unknown, kept apart as the brief required:** observed = the Phase-0
inventory, the CLI's own help text, and the local reproduction; inferred = the fixture outcomes
that were predicted rather than run; unknown = everything a live call would have answered.

## Cost safety at close

Re-inventoried independently after the decision to stop, from the provider rather than from any
exit status: GKE, Cloud SQL, instances, addresses, disks, forwarding rules, routers, peerings,
registries and non-default service accounts all **`ABSENT`**; quota usage all `0`; durable
prerequisites **PRESENT** and healthy with the delegation resolving. Nothing was created, so
nothing had to be cleaned up, and **no emergency cleanup was required or performed**.

## Findings and follow-up

- **FND-0055** (new) — recovery verification coverage: the postcondition's evidence set is the
  state inventory, so a target-declared/provider-present/state-absent resource is invisible to it.
- **FND-0056** (new) — the qualification-design gap: the property is not establishable by current
  `main`, and the attempt's criteria exclude the only mechanism the repository names for
  convergence.
- **FND-0030** (updated, remains `OPEN`) — mechanisms 1–2 landed in HARDEN-004 steps 2–4; its
  acceptance criterion is unmet because mechanism 3 (adoption) does not exist.
- **FND-0045** (updated) — `FIXED_UNQUALIFIED`: its remedy landed in step 5, with its
  "keep name-based describes as an orphan sweep" clause implemented narrower than written, which
  is where FND-0055's hole comes from.
- **DEC-044** (new, `BACKLOG`, `Decision Required`) — the ownership + coverage decision, with
  options, a recommendation, and the acceptance criteria of the implementation it would authorize.

**Next unit, recommended:** compute the declared address set from a read-only, non-destroy
`terraform plan -json` of the disposable root, union it with the state inventory, and require a
provider observation for every declared address state does not represent — PRESENT is a violation,
unqueryable is UNKNOWN, and UNKNOWN fails. That removes the fail-open, is offline-testable, and
makes any future live attempt fail for the *real* reason and name the resource. Adoption
(`terraform import` behind the existing saved-plan assertion, then the ordinary destroy) is the
second unit and is **not** authorized until `DEC-044` is decided.

**Attempt 7 remains unexecuted as a qualification.** A live attempt needs a fresh, explicit
authorization and a fresh Phase-0 baseline, because the property it would qualify will have been
restated to name the recovery mechanism.
