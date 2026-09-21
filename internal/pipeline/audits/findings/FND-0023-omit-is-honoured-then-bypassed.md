# FND-0023 — `omit` is honoured by the resolved-config accessors and bypassed by the deploy inventory and the profile preflight

- **Classification:** `VERIFIED_DEFECT`
- **State:** `OPEN`
- **First identified:** 2026-09-21, scoping `INFRA-049` for implementation
- **Last verified:** 2026-09-21 (`main` @ `506d71a9`)
- **Derived ticket:** `INFRA-049` (its decision selects which layer should apply `omit`)
- **Evidence class:** `STATIC` (the code paths) + `BEHAVIORAL` (the preflight — FND-0012's
  live observation, reproduced under control on 2026-09-21)

## Correction to the first reading

The first pass at this said "`omit` is inert" — parsed and never read. That was wrong,
and the way it was wrong is worth recording: the search excluded
`cli/sol/lib/sol_cli_config.ml` (the file that both declares and consumes the field), so
it found the parse sites and missed the consumers. `omit` **is** read. The defect is not
that it does nothing; it is that the code does two different things with it.

## What is established

**`omit` is parsed and consumed inside the config layer.** `Sol_cli_config`:

- declares `omit : bool` on both `service` and `resource` (`sol_cli_config.mli:68,81`);
- merges it as `b.omit || a.omit` (`sol_cli_config.ml:849,861`) — omit wins over an
  overlay that does not set it;
- filters it in `active_resources`/`active_services`
  (`sol_cli_config.ml:997-998`), exported as the resolved-config accessors
  `resources`/`services` (`sol_cli_config.ml:1286-1287`, `sol_cli_config.mli:113-114`);
- those accessors are genuinely used: `validate_services (active_services cfg)`
  (`:1120`), the resource-declaration check (`:1105`), and
  `service_uses_resource_type` (`sol_cli_deployment_plan.ml:492`).

**The deploy path does not consult that accessor to decide what to deploy.** In
`cmd_deploy.run`:

- the inventory is `Sol_cli_manifest.discover_services ()` (`cmd_deploy.ml:723`) — a
  filesystem scan of every workload with a Dockerfile, with no target config involved;
- it is narrowed only by `--scope` (`Sol_cli_workload_selection.resolve`, which filters
  on selection, not on `omit` — `sol_cli_workload_selection.ml:49-66`);
- that selection becomes the plan's `services`, and the profile preflight reads it
  directly: `profile_claim ~services:resolved_services`
  (`sol_cli_deployment_plan.ml:1095`) and `sol_yml_language` reads the **raw** record
  field `cfg.Sol_cli_config.services`, not the filtering accessor
  (`sol_cli_deployment_plan.ml:678`).

So an omitted unit is still in the deploy selection and still reaches the preflight, which
is exactly FND-0012's behavioural observation — but now with the mechanism: the config
layer filters, and the deploy/preflight layer bypasses the filter. `omit` is not
unimplemented; it is applied in one place and ignored in the place its users would notice.

## Reproduction (2026-09-21, `main` @ `506d71a9`)

Throwaway copy of `examples/pluto`; `qual/aws/us-east-1.yml` carries the run8 target's
omissions (`order_svc`, `fulfillment_worker`: `omit: true`).

**The omitted units are in the plan, by name.** With the profile check out of the way
(the target's `profile:` line removed — nothing else changed, and the languages are the
real `typescript`), a dry run prints the plan's service list:

```text
$ sol deploy qual/aws/us-east-1 --dry-run --image-ref <svc>=<repo>@sha256:<digest> …  # one per service
[worker] comms/notify_worker
[svc]    demo_ts/order_svc             <-- omit: true
[worker] demo_ts/fulfillment_worker    <-- omit: true
[svc]    payments/charge_svc
[svc]    checkout/checkout_svc
```

**…and the profile preflight reads that list.** With the profile declared, as the real
target does, and the same omissions:

```text
$ sol deploy qual/aws/us-east-1 --dry-run --image-tag probe
error: this target selects profile production-single-region/v1, and preflight found 2
unmet guarantee(s). Nothing was changed.
  - qualified version set is not established [application]: service "order_svc" declares
    language typescript, which production-single-region/v1 does not qualify; ...
```

**Narrowing the selection removes them; `omit` does not.** Same target, `--scope`:

```text
$ sol deploy qual/aws/us-east-1 --dry-run --scope checkout/checkout_svc \
    --image-ref checkout_svc=<repo>@sha256:<digest>
...
[dry-run] ok (0.0s)                      # exit 0, no language finding
```

So: the omitted units are present in `plan.services` (named above), the preflight reports
them, `--scope` removes them and `omit: true` does not. That is also the evidence for the
"smaller fix does not work" note below — pointing `sol_yml_language` alone at the accessor
would leave the unit in `plan.services`, where it would fail the same predicate as "does
not declare a language".

The run8 target example's own comment states the intent that this behaviour defeats:
the TypeScript pair is "omitted here rather than left to fail the run at step 1". The
author expected `omit` to exempt the preflight; it does not.

### Reproducing the by-name observation

Verbatim, so the finding does not rest on trust in this summary. A throwaway copy of
`examples/pluto`, and a target that carries the run8 omissions — note the only difference
from the real target is the absent `profile:`, which leaves the selection untouched and
only stops the preflight from gating before the plan is printed:

```sh
scratch="$(mktemp -d)"
cp -r examples/pluto "$scratch/pluto" && cd "$scratch/pluto"
mkdir -p sol/qual/aws
cat > sol/qual/aws/us-east-1.yml <<'YAML'
target:
  cluster_name: sol-qual-omit-test
  kube_context: sol-qual-omit-test
  base_domain: smoke-test.invalid
  cluster_issuer: letsencrypt-staging
  letsencrypt_email: smoke-test@example.invalid
  registry: 111122223333.dkr.ecr.us-east-1.amazonaws.com
  state_bucket: sol-qual-omit-test-state
  state_lock_table: sol-qual-omit-test-lock
  provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
  cluster_access_role_arn: arn:aws:iam::111122223333:role/sol-cluster-access
  deploy_role_arn: arn:aws:iam::111122223333:role/sol-deploy
  operator_role_arn: arn:aws:iam::111122223333:role/sol-operator
  cluster_endpoint_cidr: 203.0.113.0/24
  alert_receiver_type: webhook
  alert_receiver_url: https://example.invalid/hook
  alert_owner: test
  alert_runbook_url: https://example.invalid/runbook
  node_failure_headroom_nodes: 1
  destroy_retention: none
services:
  order_svc:
    omit: true
  fulfillment_worker:
    omit: true
YAML
dg="$(printf 'a%.0s' {1..64})"; reg=111122223333.dkr.ecr.us-east-1.amazonaws.com
sol deploy qual/aws/us-east-1 --dry-run \
  --image-ref "checkout_svc=$reg/checkout_svc@sha256:$dg" \
  --image-ref "charge_svc=$reg/charge_svc@sha256:$dg" \
  --image-ref "notify_worker=$reg/notify_worker@sha256:$dg" \
  --image-ref "order_svc=$reg/order_svc@sha256:$dg" \
  --image-ref "fulfillment_worker=$reg/fulfillment_worker@sha256:$dg"
# → the plan prints [svc] demo_ts/order_svc and [worker] demo_ts/fulfillment_worker
#   even though both are omitted
```

Adding the real target's `profile: production-single-region` back and replacing the
`--image-ref` list with `--image-tag probe` produces the failing preflight quoted above.
The account id `111122223333` is a documented placeholder; no registry or cluster is
contacted (`--dry-run`).

## Consequence for `INFRA-049`

This changes what the decision is deciding. It is not "should we implement this key or
remove it" — it is already implemented in the config layer. The choice is which layer is
authoritative:

- make the deploy selection and the preflight derive from the omit-filtered resolved
  config (so `omit` means "not in this target's set"), or
- declare `omit` to mean only what the config accessors already do, and make the deploy
  path stop implying more (and stop feeding `profile_claim` a list the config layer would
  have filtered).

Either way the current split — filter here, bypass there — is the defect.

### If option A is chosen: what does an explicit `--scope` naming an omitted unit do?

The DEC cannot stop at "derive the selection from the omit-filtered config", because that
leaves a real fork, and the two readings have different regression matrices:

- **`omit` is a *default*; `--scope` is explicit intent** (strawman; my recommendation).
  `omit` removes the unit from the no-`--scope` set; naming it in `--scope` includes it
  again, and the run *reports* that it selected an omitted unit. Rationale: `--scope` is
  already the operator's explicit statement of what this invocation deploys (DEC-036),
  and in the run8 target `omit` reads as "do not make the default run deal with this",
  not "this unit may never be deployed". It keeps an escape hatch and avoids a `--scope`
  that silently selects nothing.
- **`omit` is authoritative.** `--scope` cannot resurrect an omitted unit; naming it is
  refused or diagnosed. Simpler rule, but a scope that names a unit and deploys nothing is
  a surprising outcome, and it removes the only way to qualify a unit the workspace still
  contains.

Regression matrix, per reading: the first needs "no scope → omitted unit absent",
"scope names an omitted unit → present and reported", "scope names only omitted units →
not silently empty"; the second needs "scope names an omitted unit → refused/diagnosed".

## Evidence tier of each half

The two halves are not equally strong, and the difference matters before this is used to
frame a decision:

- **Config layer filters `omit` — `STATIC` + pinned by a test.**
  `test_config.ml`'s `test_target_overlay_can_omit_resources_and_services` loads a target
  that sets `omit: true` on `app_db` and `api`, and asserts `Sol_cli_config.resources cfg`
  is `[ "sessions" ]` and `Sol_cli_config.services cfg` is `[]`. That is the accessor
  filtering, observed.
- **Deploy path bypasses it — `BEHAVIORAL`, reproduced under control; still no unit
  test.** The reproduction above shows the failure follows the selection (`--scope`
  removes the unit and the preflight passes; `omit: true` does not). The reachability
  chain is also complete and was checked end to end:
  `cmd_deploy.run` builds the inventory with `Sol_cli_manifest.discover_services ()`
  (`sol_cli_manifest.ml` contains no `omit` reference, so the filesystem scan cannot
  filter on it) and narrows it only by `--scope` (`sol_cli_workload_selection.ml` has no
  `omit` reference either); `ctx.resolved_config` flows through
  `Sol_cli_factory.plan_of_services` into `deployment_plan.of_services_result`; `to_spec`
  then calls `sol_yml_language` on each selected unit, and that reads the raw
  `cfg.Sol_cli_config.services` field, not the filtering accessor. What is missing is a
  *regression* test — every plan fixture still uses `omit = false`
  (`test_deployment_plan.ml:798,811,1145`) — and that belongs with the `INFRA-049` fix,
  not assumed here.

## Who is affected

The repository tracks *example* targets for four environments
(`examples/pluto/sol/{dev,prod,pilot,customer_cloud}/aws/us-east-1.yml`), and of **all
tracked files** only two set `omit`, in six places:

| File | Units |
|---|---|
| `examples/pluto/sol/dev/aws/us-east-1.yml` | 4 |
| `docs/qualification/run8-aws-target.example.yml` | 2 |

That is a statement about **tracked** files, not a guarantee about real targets. Real
targets are created outside the repository — `internal/ci/check_no_account_artifacts.sh`
forbids tracking `sol/(qual|qual2)/`, but it does *not* forbid `sol/prod/…` — so a real
target that sets `omit` is invisible here. Absence of a hit is not evidence of absence
(the FND-0021 lesson). Whichever way `INFRA-049` resolves, the two tracked files must be
revisited in the same change. The migration **cannot be complete**, though: an untracked
target that sets `omit` will change behaviour silently on upgrade, and this repository has
no channel to warn its owner. The DEC should record that as a known, un-warnable
population rather than implying the two tracked files cover it.

## What is not established

- Which layer *should* be authoritative — the `INFRA-049` contract decision.
- **Which change actually fixes it — and the smaller one does not.** The language error
  is produced by `Sol_cli_profile_preflight.ml`'s `Qualified_versions`, which iterates
  `plan.services` and each `service_spec.language` (`:88-128`). That list is the deploy
  selection, and each `language` came from `sol_yml_language`. So the load-bearing bypass
  is the **selection** including an omitted unit. Pointing `sol_yml_language` at the
  filtering accessor *alone* would not fix the preflight: the omitted unit would then read
  as `language = None` and fail the same predicate as "does not declare a language". The
  unit has to leave `plan.services`. Recorded here so the decision is not settled with the
  smaller change.
- The behaviour of any untracked target that sets `omit`.

## What would make this qualified

A target that omits a unit and one that does not behave distinguishably and explainably
in the profile preflight, with a test pinning it — `INFRA-049`'s acceptance criteria
verbatim.

## Sources

- `cli/sol/lib/sol_cli_config.ml:58,72,233,245,651-654,682-685,849,861,997-998,1105,1120,1286-1287`
- `cli/sol/lib/sol_cli_config.mli:68,81,113-114`
- `cli/sol/lib/sol_cli_deployment_plan.ml:492,678,1095`
- `cli/sol/lib/sol_cli_profile_preflight.ml:88-128` (the `Qualified_versions` predicate)
- `cli/sol/bin/cmd_deploy.ml:722-732`
- `cli/sol/lib/sol_cli_workload_selection.ml:49-66`
- `cli/sol/lib/sol_cli_manifest.ml` (`discover_services`)
- `internal/pipeline/audits/findings/FND-0012-omit-does-not-exempt-from-profile-preflight.md`
- `internal/pipeline/tickets/READY_FOR_ENGINEERING/INFRA-049.md`
