---
id: FEAT-090
type: feature
severity: medium
title: Extend the target-status surface with cloud health, drift and last operation
source: Sol Unified Operational Interface design review, 2026-09-18
---

**Depends on:** None.

**Premise verified 2026-10-01** (base `d75f2aca`), still actionable:

```text
$ rg -n 'drift' cli/ | wc -l
0
$ rg -c 'Cloud:' cli/bin/cmd_target.ml
(no match)
```


**Related:** DEC-032, INFRA-027, OBS-044, ADR 0003.

**Reconciled with `DEC-057` (2026-09-29):** the experience contract puts this field
on the day-two surface (`docs/DEVELOPER_EXPERIENCE.md` §7 and §11) — "last
operation" is one of the facts a user should be able to read without a provider
console, and readiness is observed rather than inferred. That confirms the field is
on the product path; it does not change this ticket's design constraints (ADR 0003's
no-new-store rule still stands).

## What this is

`sol target show --check` already reports a target's identity, Kubernetes
reachability, and platform readiness. It does not report what the review's
example output shows:

```text
Target: prod/aws/us-east-1
Platform: Ready
Cloud: Healthy               <- missing
Drift: None                  <- missing
Last operation: cloud apply  <- missing
```

Add those capabilities to the existing surface. The constraint that matters more
than the command name: **exactly one surface answers "what is the state of this
target"**. A second one is already in sight — the review proposes
`sol cloud status`, which would sit beside `sol target show` and re-derive the
same facts from the same sources. Whether `sol cloud status` becomes a thin alias
or is not added at all is an ergonomic implementation choice; a competing
target-state model is not.

Each new field has a real authority, and most of this ticket is naming it
honestly rather than computing something new:

- **Cloud health** — the provider's own view of the resources Sol manages, not a
  Sol-side record.
- **Drift** — the relationship between Terraform's recorded state and observed
  reality. A refresh/plan read only; never a mutation.
- **Last operation** — what Sol last did to this target, when, and with what
  outcome. There is no target-scoped record of this today, and ADR 0003 settles
  what may be added: the phase is *not* infrastructure truth, is recomputed each
  run, and "no phase-pointer file or second infrastructure state database is
  introduced". So this field must be derived from an existing authority — local
  run history (`.sol/runs/`), deployment events (`sol deployments`), or
  Terraform — or reported as unavailable. It must not persist a new
  target-scoped store.

The lifecycle *phase* itself is out of scope: ADR 0003 defines it, and
`Sol_cli_cloud_lifecycle` already carries `phase`, `phase_policy`,
`policy_of_phase`, `transition_allowed`, `ready_policy_applies` and
`policy_vars`. This ticket renders the phase; it does not define or re-derive it.
Note the ADR's rule when rendering it: readiness is *observed*, never inferred
from the phase — so the two must be reported as the distinct things they are
rather than reconciled into one word.

## Evidence (2026-09-18, `main` at 790dc3e8)

`sol target show --check` emits identity, reachability, and readiness only:

```text
cli/sol/bin/cmd_target.ml:67   let kubernetes_status ~check … -> Not_configured | Configured | Reachable | Unreachable
cli/sol/bin/cmd_target.ml:90   let platform_status ~check … -> readiness_summary (optional)
cli/sol/bin/cmd_target.ml:118  let show target verbose json check =
```

No drift read exists anywhere:

```text
$ rg -n 'drift' cli/ | wc -l
0
```

and there is no persisted cloud apply/destroy record, so "last operation" has no
authority to read from yet. `--check` is opt-in by design because the summary is
what an operator reads while diagnosing an unreachable cluster
(`cli/sol/bin/cmd_target.ml:1-6`), so no new probe may make the default
invocation block.

Two shape notes: `sol target show` requires a full `env/provider/region` path
(DEC-016 — no current target, no default), so the review's `--target prod`
shorthand is not valid today and is not part of this ticket. And `--json` already
exists, so any new field must appear there too.

## Non-goals

- Not a new target-state model, and not a second command that reports target
  state.
- Not drift *remediation*; reporting only. Applying is `sol cloud apply`.
- Not the lifecycle phase itself — ADR 0003 defines it.
- Not a new durable store for "last operation"; ADR 0003 rejects a phase pointer
  and a second infrastructure state database, and this field is no exception.
- Not infrastructure dashboards (INFRA-027).
- Not making any new read part of the default invocation; the offline summary
  stays offline.
- Not the `--target prod` shorthand (DEC-016 owns target addressing).

## Acceptance criteria

- `sol target show` reports cloud health, drift, and last operation alongside the
  existing identity/reachability/readiness fields, and `--json` carries the same
  fields.
- Each field names its authority in the code, and none is answered from a Sol
  record where the provider or Terraform state is authoritative.
- The offline invocation still returns without touching the network; the new
  reads sit behind the existing opt-in.
- Exactly one command family reports target state after this change. If
  `sol cloud status` is added, it delegates to the same projection and a test
  asserts the two agree.
- An unreachable or absent cloud reports as such, never as "healthy" by default.
- If last operation has no authority available, it reports as unavailable — not
  as "none" — so the absence of a record is not mistaken for a recorded absence.
- No new store, pointer file, or state database is introduced.

**Demo/example coverage:** `sol target show` is user-facing, so `examples/pluto`
(or `TUTORIAL.md`, whichever the run demonstrates against) must show the new
output, and `docs/deployment/production-bootstrap.md` must be updated if it
quotes the old shape.

**TypeScript parity:** No language-parity impact — target inspection is
language-neutral and no application-facing contract changes.

## Checkpoint (2026-10-01) — authority per field, and where the work starts

Branch `FEAT-090/target-status`. Nothing is implemented yet; `Sol_cli_target_report`
still has no cloud/drift/operation field. Everything below was verified by reading
the code named, so the next session starts at "write it", not at "find it".

**The projection.** `cli/bin/cmd_target.ml:80` computes each status in the bin
(`kubernetes_status`, `platform_status`) and hands it to
`Sol_cli_target_report.rows` / `to_json` (`cli/lib/cloud/sol_cli_target_report.ml`).
The new fields belong there too: one projection, one command family (this ticket's
"exactly one surface" constraint), `--json` included for free.

**`Cloud:` — authority is the provider's own answer, and it already exists.**
`Sol_cli_provider_capabilities.installation_probes provider configuration` gives the
`Inspect`/`Unavailable`/`Unverifiable` probe set, and
`Sol_cli_installation.observe ~run:(Sol_cli_provider_capabilities.installation_observation
~provider)` runs them and returns `(prerequisite, verdict) list` with the
`Established | Unmet | Unknown` vocabulary — the same observation `sol cloud
bootstrap` and the deploy's installation stage use (`cli/bin/cmd_deploy.ml:144`,
`observe_installation`). So the row is a projection of an existing observation, not
a new probe family: all established → `Healthy`; anything `Unmet`/`Unknown` →
`Unmet — <prerequisite>: <reason>` (never `Healthy` by default, and `Unknown` is
never promoted). Move that helper out of `cmd_deploy` into
`Sol_cli_installation` (or `Sol_cli_provider_capabilities`) so both callers share
it, rather than copying it into `cmd_target`.

**`Drift:` — a read-only refresh, and it needs one new Terraform wrapper.**
`Sol_cli_terraform.plan` (`cli/lib/cloud/sol_cli_terraform.ml:87`) already returns
`Sol_cli_process.output`, which carries `exit_code` (`cli/lib/base/sol_cli_process.mli`).
Add `plan_refresh_only` beside it, appending `-refresh-only -detailed-exitcode`, and
read the code: `0` → `None` (no drift), `2` → drift detected, `1`/spawn failure →
`Unknown — <reason>`, never "no drift". It must not mutate: `-refresh-only` writes
state refresh results only, and the ticket's non-goal list forbids remediation.
Wiring is the same prepare/init path `Sol_cli_environment_stage.plan` uses
(`prepare ~strict:false` → `Sol_cli_cloud_wiring.init`), so the drift read belongs in
`Sol_cli_environment_stage` as a `drift` entry point and `cmd_target` calls it — the
bin must not assemble Terraform workdirs itself.

**`Last operation:` — the honest answer today is `unavailable`, with its reason.**
The ticket's own evidence stands: no target-scoped record of the last operation
exists, and `ADR 0003` forbids adding one (no phase pointer, no second state
database). The AC already anticipates this: "If last operation has no authority
available, it reports as unavailable — not as 'none'". Local run history is the
only existing candidate and is **not** target-scoped: `Sol_cli_run_log` writes
`<XDG_DATA_HOME>/sol/runs/<prefix>-<timestamp>.log` with no target in the record, so
deriving a target's last operation from it would be inference, not observation.
Report `unavailable — Sol keeps no target-scoped operation record (ADR 0003)`. If a
later ticket makes the run record target-scoped, this row reads it and the
`unavailable` reason disappears; that is the trigger to revisit, recorded here so it
is not discovered twice.

**What sits behind `--check`, and what does not.** The AC requires the offline
invocation to stay offline, so all three rows are opt-in and mirror `Platform:`:
without `--check` the row is omitted/`not checked`; the default summary stays what
an operator reads while diagnosing an unreachable cluster. `Cloud:` and `Drift:`
both touch the network (provider APIs; Terraform refresh), `Last operation:` does
not.

**Remaining work, in order** (none of it design-blocked):

1. `Sol_cli_environment_stage.drift` + `Sol_cli_terraform.plan_refresh_only`, with a
   unit case for the three exit-code verdicts.
2. Share the installation-observation helper with `cmd_deploy`.
3. `Sol_cli_target_report`: `Cloud:` / `Drift:` / `Last operation:` rows and JSON
   fields, with `?cloud ?drift ?last_operation` mirroring `?platform`.
4. `cli/bin/cmd_target.ml`: compute all three under `--check`.
5. Tests: a fake-driven case for each verdict (established/unmet/unknown; drift
   none/detected/unknown; last operation unavailable), plus the JSON shape.
6. Docs and the demo the AC names: `examples/pluto`/`TUTORIAL.md` output, and
   `docs/deployment/production-bootstrap.md` if it quotes the old shape.

**Not blocked on an operator decision.** Where the ticket leaves a choice ("whether
`sol cloud status` becomes a thin alias or is not added at all"), the answer here is
**not added at all**: nothing else in this stream needs a second entry point, and
adding then keeping two surfaces agreeing is more machinery than the problem is
worth today.

## Completion (2026-10-01)

Implemented on `FEAT-090/target-status`, rebased onto `main` at `9b0e272a`. The
checkpoint above is the design record; this section says what landed and where the two
places it changed differ from it.

**What landed.** `sol target show` reports the three day-two facts, each from its own
authority:

- **`last operation`** — always present, reported as `unavailable — Sol keeps no
  target-scoped operation record (ADR 0003)`. `Sol_cli_target_report.last_operation_unavailable`
  is the one definition, and the projection defaults to it so no caller can omit the row.
- **`cloud`** (behind `--check`) — `Sol_cli_installation.health_summary` projects the
  existing installation observation: every prerequisite `Established` → `Healthy`,
  otherwise `Unmet — <prerequisite>: <reason>`, or `Unknown — …` when any prerequisite
  could not be looked at. The observation is the provider's, never a Sol-side record.
- **`drift`** (behind `--check`) — `Sol_cli_environment_stage.drift` runs a read-only
  `terraform plan -refresh-only -detailed-exitcode` in the cluster root's workdir and
  classifies the exit code: `0` → `None`, `2` → `Detected`, anything else (including a
  spawn failure) → `Unknown — <reason>`, never "no drift". It is not routed through
  `Sol_cli_supervised`, so it records no operation and cannot make the state guard
  refuse a later constructive run.

`Sol_cli_provider_capabilities.observe_installation` is now the one installation
observation helper, shared by `cmd_target` and `cmd_deploy` (the copy in `cmd_deploy` is
gone). `Sol_cli_terraform.init` gained `?echo` (default `true`) so the drift read can
initialize its workdir quietly: a status command must not print a `$ terraform` line
over its own `--json` output, and `cli/test/test_target_status.sh` holds that.

**Two differences from the checkpoint, with reasons.**

1. **`Unknown` stays distinct from `Unmet` instead of being collapsed into it.** The
   checkpoint proposed `Unmet — …` for both. Collapsing them would report a probe Sol
   could not run as one the provider answered absent — the exact confusion `DEC-052` and
   `DEC-040` exist to prevent. `health_summary` takes the weaker headline when any
   unresolved prerequisite is `Unknown`, and lists each with its own verdict and reason.
2. **`last operation` is reported by the offline invocation, not only under `--check`.**
   The AC gates the *new reads* behind `--check`; this row performs no read, and its
   message is precisely what tells a reader Sol keeps no such record — hiding it behind
   `--check` would imply it is a probe. `cloud` and `drift` stay opt-in, so the offline
   summary still touches no network (asserted in the shell test).

**No new store.** Nothing is persisted: drift reuses the existing Terraform workdir and a
refresh-only plan, `cloud` reuses the installation observation, and the last-operation
row is a constant. `sol cloud status` was not added, so one command family reports target
state.

**Revisit trigger for `last operation`:** if a later ticket makes run history or the
deployment-event stream target-scoped, this row reads it and the `unavailable` reason
disappears. The constant and its single call site (the `last_operation` default in
`Sol_cli_target_report`) are the whole surface to change.

**Demo/example coverage.** `docs/guides/TUTORIAL.md` §*Inspecting a target* shows the new
output and explains each row; `docs/architecture/observability-design.md` and
`docs/DEVELOPER_EXPERIENCE.md` §7 record FEAT-090 as shipped.
`docs/deployment/production-bootstrap.md` does not quote the old shape, so it is
unchanged.

**Validation.** `dune build`; `dune test cli/` (including the existing `sol target show
--check` rules and `test_cloud_bootstrap.sh`); new unit cases in `test_installation.ml`
(the health summary), `test_environment_stage.ml` (the drift exit codes) and
`test_target_report.ml` (rows, JSON, offline omission); a new fake-driven end-to-end
`cli/test/test_target_status.sh` covering cloud healthy/unmet/unknown, drift
none/detected/unknown, the offline rows and no-read guarantee, and that `--json` stays
parseable JSON. `internal/ci/check_ocamlformat.sh --all`, `check_no_comments.sh`,
`check_result_syntax.sh`, `check_cli_reference.py`, `check_test_reachability.py`,
`check_provider_dispatch.sh`, `check_library_output.sh` and
`check_examples_self_contained.sh` all pass.

**TypeScript parity:** No language-parity impact — target inspection is language-neutral
and no application-facing contract changes.
