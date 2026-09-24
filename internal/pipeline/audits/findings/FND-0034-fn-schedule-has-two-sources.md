# FND-0034 — A `-fn`'s schedule has two sources; the one that schedules defaults to hourly, and the other only names the Pushgateway job

- **Classification:** `DESIGN_GAP`
- **State:** `OPEN`
- **First identified:** 2026-09-23, correctness audit
- **Last verified:** 2026-09-23 (`origin/main @ f3e9480b`)
- **Derived ticket:** `BUG-048` (subsumes EXP-022)
- **Evidence class:** `STATIC`

## What is established

1. **The CronJob schedule comes from `sol.toml`.** `extract_schedule`
   (`cli/sol/lib/sol_cli_manifest_yaml.ml:29-36`) re-reads the service's `sol.toml`
   independently of the plan's already-loaded `toml`
   (`sol_cli_deployment_plan.ml:~930`) and maps **both** "no `schedule` key" and
   "`sol.toml` failed to load" to `"0 * * * *"`. Plan loading parses the same file
   first, so the error arm is effectively unreachable. The absent-key default is
   live. Together with FND-0033, `schedul = "0 3 * * *"` deploys an **hourly** job.
2. **The code declares a schedule too.** The generated library is
   `let trigger = Fn.Cron "0 * * * *"` (`sol_cli_scaffold_templates.ml:1156`). The
   runtime never schedules from it. `Fn.Make.run` uses it only as the **default
   Pushgateway `job` name** (`sol-fn/lib/fn.ml:30-36`). The two values can disagree
   with nothing noticing, and `TUTORIAL.md:520` still says Sol "reads the schedule
   literal from source".
3. **The job name is a cron string.** Two functions with the same schedule (hourly is
   the default) would push to the same Pushgateway group `job="0 * * * *"`. A push
   replaces its group, so each function's run would overwrite the other's
   `sol_fn_invocations_total`.
4. **No push happens on the golden path anyway** (EXP-022, still live). The generated
   `bin/main.ml` (`sol_cli_scaffold_templates.ml:1175-1190`) calls `F.run ~env ~ot:obs ()`
   without `~pushgateway_url`, and nothing in `sol-fn` reads `PUSHGATEWAY_URL`,
   although `default_cluster_env` injects it. The invocation counter and duration
   histogram are recorded in-process and discarded at exit. A scheduled function that
   fails every run is visible only in CronJob/Pod status and logs, never in the
   metrics the spec documents.

## Impact

Medium. A scheduled function's defining property can silently take a default, and its
documented metrics are silently absent. Item 3 becomes live the moment EXP-022 is fixed
naively.

## Decision needed

Pick one authority for the schedule. Recommended: `sol.toml`, **required** for `-fn`
(no default). Then change `Fn.trigger` to `Cron | Lambda` without a string, or make the
CLI read it from the code, but not both. Make the Pushgateway job the workload's
identity (`<domain>/<name>`), never the schedule. Promote EXP-022.

## Related

EXP-022 (BACKLOG); FND-0033; REFAC-012/REFAC-036 (moved schedule parsing to `sol.toml`).
