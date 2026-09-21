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

## Who is affected

Only two tracked configurations set `omit`, in six places (no customer or production
target is tracked):

| File | Units |
|---|---|
| `examples/pluto/sol/dev/aws/us-east-1.yml` | 4 |
| `docs/qualification/run8-aws-target.example.yml` | 2 |

Whichever way `INFRA-049` resolves, those two files must be revisited in the same change,
and any operator target that sets `omit` (untracked, and so invisible here) is currently
getting the config-layer half only.

## What is not established

- Which layer *should* be authoritative — the `INFRA-049` contract decision.
- Whether an intended fix belongs in `sol_yml_language` (read the accessor), in the
  selection (filter the inventory by `omit`), or in both; the language error and the
  "immutable artifact identity" error in FND-0012 have different causes and may need
  different fixes.
- The behaviour of any untracked `sol/qual/…` target that sets `omit`.

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
