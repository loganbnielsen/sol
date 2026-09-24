# FND-0056 — The Attempt-7 recovery property is not establishable by current `main`, and the attempt's own pass criteria exclude the only mechanism the repository already names for convergence

- **Classification:** `DESIGN_GAP` (the stated property and the implementation's design are not
  aligned, and closing the gap — or restating the property — is a decision, not a fix)
- **State:** `OPEN`
- **First identified:** 2026-09-24, by pre-live inspection during the authorized Attempt 7
  (HARDEN-004), before any live resource was created or any provider was mutated;
  `origin/main @ 2775d5b1`
- **Derived ticket:** `DEC-044` (the decision the property and its recovery mechanism need)
- **Evidence class:** `STATIC` (code and repository record) with a local `BEHAVIORAL`
  reproduction of the Terraform semantics; **no live provider run** — deliberately
- **Related:** FND-0030 (ownership), FND-0055 (verification coverage), `DEC-040`, ADR 0003
  invariant 6, `INV-DESTROY-1`/`INV-DESTROY-2`,
  `docs/qualification/2026-09-24-gcp-attempt7-prelive-falsification.md`,
  `internal/pipeline/audits/HARDEN-004-handoff.md`

## The property Attempt 7 was to establish

> Given a target where a provider resource exists but Terraform state no longer represents
> that resource, Sol's supported destruction path can converge target-owned disposable
> infrastructure **toward absence** without reconstructing the missing resource, requiring
> undocumented target edits, requiring manual Terraform-state surgery, or requiring
> provider-native deletion as the normal recovery mechanism.

with the postcondition, from the attempt's Phase 7, that the *selected divergent provider
resource* is `ABSENT`.

## What is established (pre-live falsification)

These six statements are the finding. Each is backed below; none required a live call.

1. **A target-owned resource removed from Terraform state is outside `terraform destroy`'s
   ownership set**, unless deletion happens indirectly through provider
   dependency/cascade semantics. `terraform destroy` is an alias for `terraform apply
   -destroy` and destroys *Terraform-managed* infrastructure; `terraform state rm` "causes
   Terraform to 'forget' those items **without first destroying them in the remote system**".
   Reproduced locally at zero cost, plus Sol's own path: `destroy_substrate` is
   `terraform destroy -auto-approve` (`cli/sol/lib/sol_cli_terraform.ml:85-92`, invoked at
   `cli/sol/bin/cmd_cloud_tf.ml:3590-3612`).
2. **Current Sol has no general recovery/adoption mechanism** that restores destructive
   ownership of such a resource. There is no `terraform import` wrapper anywhere in the CLI
   (`rg -n "import" cli/sol/bin/*.ml cli/sol/lib/*.ml` matches only an unrelated comment in
   `sol_cli_manifest_yaml.ml`; positive control: `rg -n "terraform import"` does find the phrase
   where it exists, in `docs/`). The only state mutation on any Sol path is
   `Sol_cli_terraform.state_rm`, used by the *platform* root's INFRA-042 recovery for the
   specific case of a `kubernetes_manifest` whose kind the cluster demonstrably does not serve.
3. **Step 5's provider-verification identity set is derived from the pre-destroy state
   inventory** (`cmd_cloud_tf.ml:898-911`; `Sol_cli_cloud_destroy.identities` over
   `resources state`), so a resource already absent from state before `sol cloud destroy` is
   outside that set. Detailed as its own defect: **FND-0055**.
4. **Therefore current `main` cannot establish the general Attempt-7 property as written** —
   and, for a resource with no cascade path, cannot reach the attempt's postcondition by any
   means the attempt authorizes.
5. **A provider cascade can satisfy `ABSENT` for selected fixtures**, but that is
   resource-specific provider behaviour, not the recovery contract: Sol neither targets the
   divergent resource for destruction nor observes its identity afterwards. A qualification
   built on such a fixture would demonstrate a special case and report it as a general one.
6. **A leaf orphan can remain `PRESENT` while falling outside Step-5 verification**, so the
   current verification contract is insufficient for state-divergence recovery (FND-0055).

## The contradiction this exposes in the attempt's own criteria

The pass criteria forbid "importing the provider resource / re-adopting it into state" (and
Phase 6's success conditions repeat: "Success must NOT require: importing the provider
resource; re-adding it to Terraform state"). But the repository's *own recorded design* for
this exact problem says convergence requires precisely that: FND-0030 §Design point 3 —
*"a resource present in the provider and absent from state is neither created nor destroyed by
Terraform. **Converging it requires adopting it and then destroying it** … That is a new
capability"*. And the executable contract already allows a recovery path: `INV-DESTROY-2`
requires that a destroy not "require manual emptying/state removal **outside the documented
recovery**" — wording that presumes a documented recovery exists.

So Attempt 7's criteria and the repository's recovery design cannot both hold. One of them has
to change, and that is a decision:

- either the property is restated as *"converge everything state owns, do not reconstruct the
  divergent resource, and report the divergent resource as unrecoverable residue"* — in which
  case Attempt 7 is runnable today (and would FAIL the current postcondition, by design,
  loudly); or
- the "no adoption" clause is dropped and a Sol-driven, asserted **adoption-then-destroy**
  recovery becomes part of the supported path — in which case the property is achievable and
  the qualification tests that mechanism.

Attempt 7 remains **unexecuted**: it was stopped before live creation, because buying a live
run to demonstrate a limitation already established from the repository's code, its own design
note, and Terraform's documented semantics would spend a GKE cluster and a Cloud SQL instance
to learn nothing. Nothing was created, nothing was mutated, and the qualification account is
unchanged (see the attempt record).

## What is NOT established

- **No live provider observation of any kind.** The four eyes-on facts are: the code paths
  above, FND-0030's recorded design, Terraform's own CLI documentation, and a local
  reproduction of the semantics.
- **Which provider resources actually cascade** is not established. The subnetwork/network
  and node-pool cases were *reasoned about*, not tested; a cascade is a provider behaviour that
  would need its own live observation before it could be relied on. It is explicitly not a
  qualification of the general property.
- **Whether a `plan`-derived declared set is complete** for every kind (design alternative B2
  in `DEC-044`) — the mechanism is sound on the evidence, but its coverage per resource kind was
  not audited.

## Remedy shape

Not a mechanical fix, and deliberately not made here. `DEC-044` carries the alternatives for
both halves (recovery ownership; verification coverage), the recommendation, and the acceptance
criteria of the implementation it would authorize. FND-0030 stays `OPEN` and owns the
ownership half; this finding owns the statement that the *qualification as written* cannot pass,
and FND-0055 owns the verification defect.
