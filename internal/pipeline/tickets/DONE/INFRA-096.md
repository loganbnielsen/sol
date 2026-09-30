---
id: INFRA-096
type: feature
severity: high
title: Give the durable Sol installation one idempotent, verifiable lifecycle stage
source: DEC-057 and docs/DEVELOPER_EXPERIENCE.md §3-4 (2026-09-29)
---

**Depends on:** None.

**Related:** `DEC-057` (the contract this implements), `DEC-043` (resolved by it;
the stage model and lifetime table), `DEC-042` (the delegated zone's durable
ownership), `DEC-052` (capabilities are observed, not asserted), `INFRA-083` (a
capability may need to say "none"), `SEC-005` (admission control for the
deploy-identity namespace boundary), `DEC-030` (the deploy identity model),
`ADR 0002`/`ADR 0003` (Sol owns the cloud-target lifecycle; phases determine
authority), `platform/cloud/aws/bootstrap/`, `platform/cloud/gcp/bootstrap/`.

## What this is

`DEC-057` decides that Sol has a **durable installation** distinct from any
environment: Terraform state and locking, the provisioning/cluster-access/deploy/
operator identities, and the delegated DNS zone when Sol owns one. It outlives
every environment and is removed only by an explicit uninstall.

The durable pieces largely exist as provider roots —
`platform/cloud/aws/bootstrap/` and `platform/cloud/gcp/bootstrap/`, including
GCP's mirror built for HARDEN-004. What does not exist is a **product path that
owns and drives them**: today they are applied by an operator or a qualification
harness that already knows the incantation, and `sol cloud` has no stage that
ensures, reconciles and verifies them as a unit.

`DEC-043` recorded the failure this avoids: `sol cloud apply` presents itself as
"credentials + target in, usable cloud out", but it cannot bootstrap a cloud from
zero, and an operator who does not already know the separate bootstrap root cannot
get started. `DEC-043` also recorded the minimum bar for the durable root: it is
an IaC owner and must be **reconciled, not merely presence-checked**, with a
destructive plan stopping the run.

## Remediation

- **Name the stage and give it one owner.** A `bootstrap` stage that ensures the
  installation's durable prerequisites, with a provider-symmetric implementation
  behind it. It must be idempotent and independently verifiable: re-running it on
  an already-installed account is a no-op that observes and reports, and a partial
  or failed run is safely re-runnable.
- **Reconcile the durable root, do not just check presence.** The one structurally
  required presence check is the state backend (a root cannot create the backend
  that stores its own state); everything the durable root declares is planned and
  reconciled. A plan containing a replace or destroy of a durable resource stops
  and asks a human (`DEC-043`'s rule, carried forward).
- **Verify, don't assume.** Each durable prerequisite gets an observable verdict,
  using `DEC-052`'s vocabulary: state backend reachable and locked, identities
  resolvable, the delegated zone present with its nameservers readable. An
  unobservable answer is `UNKNOWN` and fails closed — never promoted to healthy.
- **Make the boundary provable.** A test must fail if an environment destroy
  removes a durable prerequisite. `DEC-043`'s acceptance criterion is now this
  ticket's: a target `destroy` cannot take the installation with it.
- **Do not invent authority.** `DEC-043` § *Design constraints* 2 stands: the
  resolved installation configuration may derive plumbing (bucket names, registry
  names) but must never derive an authority grant or an accountability
  declaration, and the resolved configuration must be inspectable.
- **Keep the operator path honest.** If an explicit administrative workflow
  (`sol init`-style) is added, it is for operators who want it; the ordinary path
  is the inline one in FEAT-106.

## Non-goals

- Not the inline onboarding UX — that is FEAT-106; this ticket provides the stage
  it calls.
- Not new providers. `DEC-051`'s driver admission rule decides when a cloud earns
  a driver; this ticket makes the existing AWS/GCP drivers symmetric.
- Not uninstall — that is FEAT-108.
- Not a second state model. The stage reconciles the existing durable roots.
- Not a change to `DEC-016`/`DEC-031`/`DEC-032` addressing.

## Acceptance criteria

- One stage ensures the installation's durable prerequisites, idempotently, and
  is independently verifiable on a re-run.
- Each prerequisite reports an `Established` / `Unmet` / `UNKNOWN` verdict from an
  observation, never from configuration; `UNKNOWN` fails closed.
- A durable-root plan containing a replacement or destruction stops the run.
- A test fails if environment destroy removes a durable prerequisite.
- The stage is provider-symmetric: the GCP path is not an AWS shape copied over,
  and the AWS path is not privileged.
- The resolved installation configuration is inspectable, and no authority grant
  or accountability declaration is ever derived.
- The premise that the durable roots exist but have no product owner is verified
  in the completion notes, with the command and its output.

**Demo/example coverage:** the installation path is app-author-visible through the
first deploy, so `docs/DEVELOPER_EXPERIENCE.md` §3–4 and the planned installation
guide (DOCS-026) must show the stage's user-visible output, and `examples/pluto`
(or the tutorial) must show a second deploy against an existing installation.

**TypeScript parity:** No language-parity impact — the installation is
language-neutral and no application-facing contract changes.

## Pickup record (2026-09-30)

**Premise verified, with a positive control.** The claim is that the durable roots exist
but no product path owns them. Run at `origin/main` `e19695ec`:

```text
$ rg -n 'cloud/(aws|gcp)/bootstrap' cli/ platform/ internal/ docs/
docs/reference/substrate.md:364
docs/deployment/production-bootstrap.md:17
internal/qualification/aws/aws-run-procedure.md:81
internal/qualification/aws/live-row.sh:25
internal/qualification/aws/run8-aws-target.example.yml:41
internal/qualification/records/2026-09-29-aws-durable-zone-adoption.md:42
internal/ci/check_cluster_access_identity.py:25
internal/ci/check_durable_dns_zone.py:30,42
internal/ci/check_production_infra.py:262,287
internal/ci/test_cluster_access_identity.sh:6
internal/ci/test_durable_dns_zone_check.py:30,32,77,86,93
internal/ci/test_production_infra_check.py:20,21
internal/ci/test_provider_roots.sh:37
        (no cli/ hit)

$ rg -n 'cloud/(aws|gcp)/(cluster|platform)' cli/ | wc -l
13
```

Every reference to a durable root is a document, the qualification harness or one of its
dated records, or a CI guard. Nothing in `cli/` names one — and the control shows the same
search does find the provider roots that *do* have a product owner. Premise holds.

**Machinery this ticket must not rebuild.** `cli/lib/cloud/sol_cli_aws_absence.ml:346` and
`sol_cli_gcp_absence.ml:276` already define `durable_observations`, so destroy-time absence
verification already models the state backend as durable and outside the target's
disposable set; AC4's boundary test anchors there. `Sol_cli_cloud_lifecycle` already
carries a phase machine (`Absent | Cloud_bootstrap | Platform_installing | Ready | …`) and
the `readiness = Established | Unmet of string` vocabulary, which the installation verdicts
extend with `UNKNOWN` (DEC-052) rather than replacing with a second one.

**Measured scope.** The durable root is real Terraform — the state bucket with versioning,
SSE and public-access block, the lock table, five IAM policy documents, and the optional
durable DNS zone — and the surrounding cloud surface is large (`sol_cli_cloud_lifecycle`
804 lines, `sol_cli_cloud_wiring` 947, `cmd_cloud_tf` 744, plus the GCP mirror). This is a
multi-session ticket, so it is recorded here as three landings rather than attempted as
one.

## Implementation split (recorded at pickup; the ticket stays READY until all three land)

- **A — observation and verdicts.** An installation-prerequisite model carrying the
  DEC-052 vocabulary (`Established` / `Unmet` / `UNKNOWN`, with `UNKNOWN` failing closed),
  one prerequisite set and one probe per provider so symmetry is by construction rather
  than an AWS shape copied over, and the inspectable resolved installation configuration —
  whose *type* has no field for an authority grant or an accountability declaration, so
  AC6 holds structurally instead of by review. The per-provider sets and probe argv live
  behind `Sol_cli_provider_capabilities` (`installation_prerequisites` /
  `installation_probes`): REFAC-092's provider-dispatch guard refuses
  `Sol_cli_provider.Aws`/`Gcp` in a generic module, so the model module names no provider
  and the provider-specific argv sits in the provider tier the guard requires.
- **B — the stage.** `bootstrap` driving the durable root: reconcile rather than
  presence-check, with the state backend as the one structural exception because a root
  cannot create the backend that stores its own state; idempotent on re-run; safely
  re-runnable after a partial run; and stopping when a plan would replace or destroy a
  durable resource (DEC-043's rule, carried into AC3).
- **C — the boundary and the user-visible path.** The test that fails if an environment
  `destroy` removes a durable prerequisite, plus the `docs/DEVELOPER_EXPERIENCE.md` §3–4
  output and the second-deploy example the coverage note requires.

`sol uninstall` is FEAT-108 and inline onboarding is FEAT-106; this ticket provides the
stage they call. No `sol init`-style command is added, because DEC-057 §2 makes the inline
path the ordinary one and the ticket's own non-goals keep the administrative workflow
optional.

## Part A completion notes (2026-09-30)

Part A is landed as the observation half: a resolver, the per-provider data behind a
capability, and a command that reports. Nothing here creates or changes anything.

**What a user sees.** `sol cloud bootstrap <TARGET>` resolves the target's declaration,
prints the resolved installation configuration, observes each prerequisite at the provider,
and fails closed (exit 1) on anything not `Established`:

```text
$ PATH=<fake aws that answers yes> sol cloud bootstrap qual/aws/us-east-1
Installation (CloudBootstrap) -- the durable prerequisites that outlive every environment:

  resolved configuration
  state bucket             sol-qual-tfstate
  state prefix             bootstrap/aws
  region                   us-east-1
  lock table               sol-qual-tflock
  provisioning identity    arn:aws:iam::111122223333:role/sol-provisioner
  ...
  terraform state backend      Established
  terraform state lock         Established
  provisioning identity        Established
  cluster-access identity      Established
  deploy identity              Established
  operator identity            Established
  delegated DNS zone           Established
```

`cli/test/test_cloud_bootstrap.sh` pins that output end to end against a fake provider,
including the three failure directions: a refusing provider is `Unmet` carrying the
provider's own message, a provider CLI that cannot be spawned is `UNKNOWN`, and a target
whose declaration is incomplete is refused before anything is observed.

**Corrections the wiring forced, each with its evidence.** The first slice was written from
the AWS root outward; driving real argv exposed three things it asserted that the durable
roots do not contain, and one that would have reported health it had not observed:

- **The publisher identity is not an observable prerequisite.** `platform/cloud/aws/bootstrap`
  emits a publisher *policy document* (`outputs.tf`, `publisher_policy_json`), but the
  identity it authorises is the operator's CI identity: no target field names it and "Sol's
  own execution never resolves it" (`docs/deployment/production-bootstrap.md` §2). A
  prerequisite whose verdict could therefore never come from an observation was removed
  rather than kept as a permanent `Unmet`; DEC-043's identity class is the four
  identities Sol does resolve.
- **GCP has no durable installation identities to observe.** `platform/cloud/gcp/bootstrap/main.tf`
  (42 lines) declares the state bucket and the optional Cloud DNS zone and nothing else; the
  provisioning/cluster-access/deploy service accounts are created by the *cluster* root
  (`platform/cloud/gcp/cluster/main.tf:244`), so they are target-disposable, not installation
  members. GCP's set is therefore `State_backend` and `Delegated_zone` — the provider sets
  differ for a verified reason rather than by an AWS shape copied over. Whether GCP should
  own durable identities of its own is a durable-root question, not an observation one, and
  is not asserted here.
- **A query-shaped probe cannot take its answer from the exit code.**
  `aws route53 list-hosted-zones-by-name` **succeeds with an empty list** when no zone
  matches, so "the command ran" reported `Established` for an installation with no delegated
  zone — a false healthy, the exact failure DEC-052 exists to stop. Probes now carry how
  their command answers: exit code (`head-bucket`, `describe-table`, `get-role`,
  `gcloud … describe`) or the output naming the resource (Route53's list, `--format=value(name)`).
- **The GCP zone is named by Terraform, not by the domain.** The durable root creates
  `replace(var.base_domain, ".", "-")` (`platform/cloud/gcp/bootstrap/main.tf`), and the
  qualification harness describes it the same way (`internal/qualification/gcp/live-qual.sh`,
  `ZONE_NAME`), so the probe asks for `qual-gcp-example-test`, not `qual-gcp.example.test`.

**What is resolved, and from where.** `Sol_cli_installation.of_target` derives the state
prefix (`bootstrap/<provider>`) and the delegated zone's domain from the target's
`base_domain`, and takes everything else from the target's declaration —
`state_bucket`, `region`, and the provider block's `state_lock_table` /
`provisioner_role_arn` / `cluster_access_role_arn` / `deploy_role_arn` /
`operator_role_arn` / `project_id`. The AWS probes ask IAM for the role **name** derived
from the declared ARN, so a declaration of authority is not passed back as plumbing. The
resolved configuration still has no field for an authority grant, so AC6 remains structural.

**Known limitation, recorded rather than hidden.** Zone ownership is not yet declared
anywhere: the resolver reads the delegated zone from the target's `base_domain`, so a
target whose DNS is external (a user-supplied zone, DEC-057 §4) reports the zone `Unmet`
even though nothing is wrong. That is the safe direction (the installation is not reported
established without the observation), and DEC-057 §4's create/adopt/ownership declaration
is FEAT-107's; when it lands, `of_target` is where the distinction is resolved.

**Still open in this ticket.** Part B (the stage: reconcile, not presence-check, with a
destructive plan stopping the run) and part C (the destroy-boundary test and the
`docs/DEVELOPER_EXPERIENCE.md` §3–4 / second-deploy example coverage). The ticket stays in
`READY_FOR_ENGINEERING`; the demo/example obligation is discharged with part C.


## Part B completion notes (2026-09-30)

`sol cloud bootstrap <TARGET> --apply` reconciles the durable root; without the flag the
command still only reports.

- **The durable root has an owner of its own.** `cloud_role` gains `Bootstrap`, so
  `platform/cloud/<provider>/bootstrap` is materialized into a work directory of its own
  (`aws-bootstrap-…` / `gcp-bootstrap-…`) with the installation's backend, beside the
  cluster and platform roots rather than reusing either.
- **Reconciled, not presence-checked.** The run initializes the durable root and plans it;
  a plan at the declared state applies nothing, so a second run is a no-op that reports,
  and a partial run is safely re-runnable. The state backend is the one presence check —
  it is reported first, and Terraform's own `init` decides, so a backend that can create
  itself is not blocked and one that cannot fails closed before anything is applied.
- **A destructive plan stops the run (AC3).** `Sol_cli_terraform_plan` gains an
  `Every_change` matcher, and the stage's policy allows create/update/read on it while
  refusing replace and delete: everything the durable root declares outlives every
  environment, so recreation or deletion is never an automatic action. The refusal names
  the address, and the plan is not applied.
- **A run never creates, and never drops, a durable DNS zone.** `manage_dns_zone` follows
  whether the root's *own state* already owns the zone, read from `terraform state list`:
  the stage reconciles ownership that exists and takes none that does not. Creating a zone
  needs the create/adopt declaration FEAT-107 owns, and passing `manage_dns_zone=true`
  against a live zone Terraform does not own would create a second one with different
  nameservers — the silent breakage DEC-043 records.

`cli/test/test_cloud_bootstrap.sh` drives all of it against fake `aws` and `terraform`:
reconcile applies the plan, a no-change plan re-runs as a no-op, and a plan whose actions
are `delete,create` is refused with the address named and no `apply` executed.

**Still open in this landing:** part C, below.

## Part C completion notes (2026-09-30)

**The boundary is provable (AC4).** `internal/ci/test_cloud_lifecycle_offline.sh` now fails, for
both providers, if a target `destroy` reaches the installation. The checks are anchored on the
`durable_observations` the ticket named (`sol_cli_aws_absence.ml`, `sol_cli_gcp_absence.ml`):

- no terraform invocation from a destroy has a `-chdir=` under the durable root, so the
  destroy never plans, applies or destroys the installation's own root;
- no invocation addresses the installation's own state
  (`bootstrap/aws/default.tfstate`, `prefix=bootstrap/gcp`);
- the state backend is reported as `external: Terraform state bucket` and never as
  `present after destroy:`, so the destructive path asserts the prerequisite *survives*
  rather than assuming it, and its presence is never counted as the target's residue.

The AWS case already asserted this for the delegated hosted zone; both providers now assert
the state backend as well. Positive control: the `-chdir` pattern was checked against a real
durable-root invocation line (`-chdir=…/terraform/aws-bootstrap-8d3a40f75e5c68de/platform/cloud/aws/bootstrap`),
so the check fires on the shape it forbids rather than matching nothing.

**The user-visible path (AC for the coverage note).** `docs/DEVELOPER_EXPERIENCE.md` §4.3 now
carries the stage's real output — the resolved configuration, the verdict table, and what
`Unmet`/`UNKNOWN` mean — and states that `--apply` reconciles with a replace/destroy stop and
is a no-op when the root is already at its declared state. `examples/pluto/README.md` gains
"Once per account: the installation": the target declaration the installation is resolved
from, the observe-and-reconcile pair, and a second environment (`sol deploy pilot/aws/us-east-1`)
deploying against the installation that already exists, with no installation work.

**Language parity:** no application-facing contract changes — the installation is
language-neutral (no `sol.toml` field, no framework primitive, no changed manifest), so
DEC-022 carries no per-language verdict for this ticket.

**Recorded limitations, unchanged from the earlier notes.** GCP's durable root declares no
identities, so its observed set is the state backend and the delegated zone; whether GCP
should own durable identities is a durable-root question, not an observation one. Zone
ownership is not declared anywhere yet, so a target whose DNS is external reports the
delegated zone `Unmet` — the safe direction — until FEAT-107's create/adopt declaration
lands, at which point `Sol_cli_installation.of_target` and the stage's `manage_dns_zone`
decision are where it plugs in.
