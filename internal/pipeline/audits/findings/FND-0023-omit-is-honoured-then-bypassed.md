# FND-0023 — `omit` is honoured by the resolved-config accessors and bypassed by the deploy inventory and the profile preflight

- **Classification:** `VERIFIED_DEFECT`
- **State:** `OPEN`
- **First identified:** 2026-09-21, scoping `INFRA-049` for implementation
- **Last verified:** 2026-09-21 (`main` @ `506d71a9`)
- **Derived ticket:** `INFRA-049` (its decision selects which layer should apply `omit`)
- **Evidence class:** `STATIC` (the two code paths) plus `BEHAVIORAL` for the preflight
  (FND-0012)

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

## Evidence tier of each half

The two halves are not equally strong, and the difference matters before this is used to
frame a decision:

- **Config layer filters `omit` — `STATIC` + pinned by a test.**
  `test_config.ml`'s `test_target_overlay_can_omit_resources_and_services` loads a target
  that sets `omit: true` on `app_db` and `api`, and asserts `Sol_cli_config.resources cfg`
  is `[ "sessions" ]` and `Sol_cli_config.services cfg` is `[]`. That is the accessor
  filtering, observed.
- **Deploy path bypasses it — `STATIC` + `BEHAVIORAL`, but no unit test.**
  The reachability chain is complete and was checked end to end:
  `cmd_deploy.run` builds the inventory with `Sol_cli_manifest.discover_services ()`
  (`sol_cli_manifest.ml` contains no `omit` reference, so the filesystem scan cannot
  filter on it) and narrows it only by `--scope` (`sol_cli_workload_selection.ml` has no
  `omit` reference either); `ctx.resolved_config` flows through
  `Sol_cli_factory.plan_of_services` into `deployment_plan.of_services_result`; `to_spec`
  then calls `sol_yml_language` on each selected unit, and that reads the raw
  `cfg.Sol_cli_config.services` field, not the filtering accessor. FND-0012 observed the
  preflight reporting omitted units live. But no unit test in the tree pins the bypass —
  every plan fixture uses `omit = false` (`test_deployment_plan.ml:798,811,1145`) — so
  this half rests on that chain plus FND-0012's live observation. A regression test
  belongs with the `INFRA-049` fix; it should be added there, not assumed here.

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
revisited in the same change, and any operator target that sets `omit` is currently
getting the config-layer half only.

## What is not established

- Which layer *should* be authoritative — the `INFRA-049` contract decision.
- Whether an intended fix belongs in `sol_yml_language` (read the accessor), in the
  selection (filter the inventory by `omit`), or in both; the language error and the
  "immutable artifact identity" error in FND-0012 have different causes and may need
  different fixes.
- The behaviour of any untracked target that sets `omit`.

## What would make this qualified

A target that omits a unit and one that does not behave distinguishably and explainably
in the profile preflight, with a test pinning it — `INFRA-049`'s acceptance criteria
verbatim.

## Sources

- `cli/sol/lib/sol_cli_config.ml:58,72,233,245,651-654,682-685,849,861,997-998,1105,1120,1286-1287`
- `cli/sol/lib/sol_cli_config.mli:68,81,113-114`
- `cli/sol/lib/sol_cli_deployment_plan.ml:492,678,1095`
- `cli/sol/bin/cmd_deploy.ml:722-732`
- `cli/sol/lib/sol_cli_workload_selection.ml:49-66`
- `cli/sol/lib/sol_cli_manifest.ml` (`discover_services`)
- `internal/pipeline/audits/findings/FND-0012-omit-does-not-exempt-from-profile-preflight.md`
- `internal/pipeline/tickets/READY_FOR_ENGINEERING/INFRA-049.md`
