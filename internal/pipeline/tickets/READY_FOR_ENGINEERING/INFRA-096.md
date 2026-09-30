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
