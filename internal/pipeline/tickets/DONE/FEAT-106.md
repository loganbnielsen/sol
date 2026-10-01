---
id: FEAT-106
type: feature
severity: high
title: Make the first `sol deploy` guide installation inline instead of requiring a separate bootstrap ritual
source: DEC-057 and docs/DEVELOPER_EXPERIENCE.md §4-5 (2026-09-29)
---

**Depends on:** INFRA-096.

**Related:** `DEC-057` (the contract), `DEC-043` (resolved; named the failure this
removes), `FEAT-107` (the DNS hand-off this flow surfaces), `DEC-016` (target
selection is explicit; no `--env`), `DEC-052` (readiness is observed), `FEAT-090`
(target status), `BUG-094` (preserve state-list failures when resolving an
existing cluster).

## What this is

`DEC-057` §2 requires that a user reaching production for the first time does not
have to learn or invoke a separate bootstrap command. `sol deploy <target>` must
detect an uninitialised installation and guide the user through it in place, then
continue into the deploy.

Today the knowledge lives in operator runbooks and a qualification inventory:
`sol cloud apply` fails when the durable prerequisites are absent, and a user who
does not already know the separate bootstrap root cannot get started (`DEC-043`).

## The experience this must produce

The shape is in `docs/DEVELOPER_EXPERIENCE.md` §5; the properties that matter more
than the wording:

1. **Detection is honest.** `sol deploy` observes whether the installation exists
   and reports what it found — account, region, and the missing prerequisites —
   rather than asserting a state it did not check. An unobservable answer fails
   closed (`DEC-052`).
2. **Automated work and human actions are visually distinct.** The run names the
   one or few external actions (today, DNS delegation) separately from the work
   Sol performs, and does not proceed past a blocker it cannot resolve.
3. **Expensive work happens after cheap, knowable prerequisites.** Validate DNS/TLS
   prerequisites before provisioning when they are knowable, so a user is not made
   to wait through a costly provisioning run for a blocker that could be named
   immediately.
4. **The next run is boring.** After installation, `sol deploy <target>` performs
   no one-time setup and reports the same concise progress as any later deploy.
5. **Runs are resumable.** An interrupted first run re-enters at the stage that
   owns the unmet prerequisite, not from the beginning and not by repeating
   already-installed work (INFRA-096's idempotence).
6. **The stages stay available for diagnosis without becoming required knowledge.**
   A user who wants detail can see the stage a run is in and why it stopped; the
   happy path does not make them address stages explicitly.

## Remediation

- Add the detection and guided path to `sol deploy`, distinct from — but built on
  — the stage INFRA-096 provides. No second implementation of the lifecycle: the
  same stage functions, a different presentation.
- Represent first-run state explicitly (installation absent / partially present /
  present) and drive the prompt from observed facts.
- Make "one action required" a first-class output for the DNS hand-off (FEAT-107),
  including the exact records and a wait/verify step.
- Fail with an actionable message when a prerequisite cannot be satisfied
  automatically, naming the external system and the record or value the user must
  supply.
- Keep `--json`/non-interactive behaviour honest: a CI run must be able to detect
  an uninitialised installation and fail with the same explanation, never hang on
  an interactive prompt, and never silently skip installation.

## Non-goals

- Not a separate `sol init` command as the required path; an explicit
  administrative workflow may exist, but it must not be necessary.
- Not DNS implementation — the hand-off and verification are FEAT-107.
- Not uninstall (FEAT-108).
- Not changing target addressing. The command remains
  `sol deploy <env>/<driver>/<region>`; there is no `--env` (`DEC-016`).
- Not a hosted control plane.

## Acceptance criteria

- On an account with no installation, `sol deploy <target>` detects that, explains
  it, and offers to set up; accepting it reaches a deployed application without the
  user invoking any other command.
- On an account with an installation, `sol deploy <target>` performs no one-time
  setup and no prompt.
- The output distinguishes automated work from external actions, and names the
  exact external action required.
- An interrupted first run resumes at the right stage; a re-run does not repeat
  completed installation work.
- A non-interactive/CI invocation detects an uninitialised installation and fails
  with an actionable explanation rather than prompting or skipping.
- The expensive-provisioning-after-cheap-preflight ordering is observable: a
  knowable DNS/TLS blocker is reported before provisioning begins.

**Demo/example coverage:** the first-run flow is the product's most user-visible
surface, so a runnable example or tutorial section must demonstrate it end to end
(`examples/pluto` and/or `docs/guides/TUTORIAL.md`), and the installation guide
(DOCS-026) must document the same flow.

**TypeScript parity:** No language-parity impact — onboarding is app-language
neutral and no application-facing contract changes.

## Premise checked (2026-10-01)

The premise is that `sol deploy` has no first-run path: the knowledge lives in an
operator runbook, and `sol cloud apply` fails on an absent installation. Checked at
`origin/main` `438267c9`:

```text
$ git show origin/main:cli/bin/cmd_deploy.ml | rg -n 'installation|bootstrap'
(no matches)
```

Positive control: the same search over `cli/bin/cmd_cloud_tf.ml` finds the
installation surface (`installation_observation`, `installation_probes`,
`installation_stage`), so the search does find installation code where it exists.
The deploy command never observed the installation; its only cluster gate was
`destination_of_target`, whose failure is the bare `kube_context` message.
Premise holds.

## Part A landed (2026-10-01): the first run observes the installation and guides it

`sol deploy <target>` now observes the target's durable installation and guides it
in place, as `DEC-057` §2 requires, using the stage `INFRA-096` provides
(`Sol_cli_installation_stage.reconcile`) — no second lifecycle implementation.

**When it runs.** The deploy's own preconditions are unchanged and are checked
first; the installation is observed when the run cannot reach the target's cluster,
which is the first-run shape:

- the target declares no `kube_context`, so `destination_of_target` refuses, or
- the declared cluster is unreachable, so the substrate prerequisite fails.

That bounds the change: an ordinary deploy against a reachable cluster is
untouched and invokes no provider CLI (AC2 — verified by asserting that an
established installation runs no Terraform at all).

**What it decides.** `Sol_cli_installation_onboarding.state_of_verdicts` classifies
the observed verdicts into `Present` / `Absent` / `Partial` / `Indeterminate`: every
prerequisite Established is `Present`; any `Unmet` is decisive (the provider
answered), giving `Absent`, or `Partial` when something else is Established; only
`Unknown` verdicts give `Indeterminate`. `decision` drives the presentation: with
the installation `Present` the run names the environment stage
(`sol cloud apply <target>`) and stops; `Absent`/`Partial` is offered on an
interactive `--apply` run and refused with the command that establishes it
otherwise; `Indeterminate` is reported and never claimed either way.

**What the user sees.** The report separates Sol's automated work from the one
external action (AC3) and prints the resolved configuration it would reconcile.
Accepting runs the durable root, prints the delegation instruction, waits for the
delegation — bounded by the new `sol deploy --await-delegation=SECONDS` (300s by
default, `0` disables) — confirms it from a public resolver rather than from
written configuration, and then re-observes: an interrupted run resumes at whatever
is still unmet, and an established installation repeats nothing (AC4).

**Non-interactive honesty (AC5).** With no terminal, or under `--dry-run` /
`--emit-to`, the run never prompts and never sets anything up: it prints the
observation, the reason it will not act, and `sol cloud bootstrap <target> --apply`.
That is the whole CI path, and the exit code is the deploy's own failure.

**Honest detection, and the correction it forced.** A provider CLI failure that
does not name the resource as missing is now `UNKNOWN`, not `Unmet`:
`Sol_cli_provider_capabilities.installation_observation` consults the provider
tier's `installation_failure_means_absent`. Before this, an `AccessDenied` or a
missing credential was reported as "the provider answered that the prerequisite is
not there" — a false negative `DEC-052` forbids, and on the deploy path one that
would have refused an ordinary CI deploy run with the deploy identity, whose policy
deliberately denies `iam:*` and has no state-bucket read
(`platform/cloud/aws/bootstrap/main.tf`, `data.aws_iam_policy_document.deploy`).

**Where the boundary is, recorded rather than hidden.** An installation Sol cannot
observe is *reported*, not fatal, for the deploy: refusing the run because a deploy
identity cannot read the durable layer would make that supported identity unusable,
which is a security-model change (`docs/deployment/production-bootstrap.md`), and
the deploy's real gates — contract, images, migrations, cluster reachability — are
unaffected. The verdict is still never promoted to healthy and the run names the
command that observes it. This is the one place this ticket's "an unobservable
answer fails closed" is applied to the *verdict* rather than to the whole deploy.

**Absence has to be named, which the removal path already wanted.** Because the
classification requires the provider to say *what* is missing, a probe that fails with
no message at all is `UNKNOWN`, not `Absent` — the behaviour `FEAT-108`'s removal
verification wants, and a silent failure is not evidence of removal. Two test fakes
had encoded the old assumption that any non-zero exit means absence, and now emit the
provider's real vocabulary instead: `test_cloud_bootstrap.sh`'s refusing provider, and
`test_uninstall_cli.sh`'s, whose `head-bucket`, `describe-table` and `get-role`
answered with a bare exit 254. Real AWS names each of these (`(404) ... Not Found`,
`ResourceNotFoundException`, `NoSuchEntity`), so the product behaves as before on the
real path; the fakes were the unrealistic part. Both were found by CI rather than
locally, because this machine has no external NS resolver and the cases without a
stubbed `dig` fell into a different branch here.

## Part B landed (2026-10-01): the run drives the environment stage and reaches it as the deploy identity

`sol deploy <target>` now drives the environment stages when it has no destination
it can reach, and reaches the cluster it provisioned as the target's *deploy*
identity, as **DEC-058** (decided 2026-10-01, Option C) requires. No second
lifecycle implementation: the stage is `Sol_cli_environment_stage`, extracted from
`cmd_cloud_tf`'s apply path so `sol cloud apply` and `sol deploy` call one
implementation, and `sol cloud apply` still prints its own result from the same
typed outcome.

**What triggers it.** The first-run shape: the target names no `kube_context`, or
names one whose context is not in the effective kubeconfig, so the run has nothing
it can reach (`Sol_cli_target_report.context_is_configured`). A kubeconfig Sol
cannot read is not evidence of that and keeps the ordinary path, and a declared
context *is* trusted (`DEC-020`): an unreachable-but-present context keeps part A's
report and names `sol cloud apply`, rather than provisioning on an API-server blip.

**The order is the cheap one first (AC6).** The contract check, the profile
preflight and the rendered plan are built before the environment stage runs, so a
knowable blocker is named before the billable boundary. `test_deploy_environment_stage.sh`
holds this: a `production-single-region` target whose alert delivery is not
established is refused with `preflight found …` and `Nothing was changed.`, and no
`terraform` or `aws` invocation is recorded at all.

**What the run does.** The installation stage runs first (part A, unchanged), and an
established installation prints its observation and continues. The environment
stage then reconciles the target's environment through `sol cloud apply`'s own code
path — cluster root, bootstrap window, platform, verified de-escalation — and
`Sol_cli_environment_stage` returns the cluster it read back. Only then does the run
assemble its own access: for AWS, `Sol_cli_aws_cluster.deploy_access` runs
`aws eks update-kubeconfig --role-arn <deploy_role_arn> --kubeconfig <temp>` with
`KUBECONFIG` scoped to the child processes, so the destination is the cluster the
root's own `deploy_kube_context` output names, the credential is never written into
the user's home, and the run continues into substrate, migration and deployment as
`sol-deploy` (namespace-scoped `sol:deployers` RBAC; `INFRA-025`). Where the
provider declares no deploy identity — GCP today — the run provisions, then stops
and prints the root's kubeconfig command and `kube_context` as the operator's one
remaining action, rather than degrading to the provisioning identity (`DEC-034`).

**What did not change.** Nothing is written to `~/.kube/config` or the target file,
no ambient kubectl context is used, the four identities keep their scopes, and
`DEC-030` stays open: this gives a *deploy run* its own access, not the operator a
persistent one.

**One behaviour correction found while wiring it.** After a successful environment
stage, a later substrate failure no longer runs part A's installation guidance: the
environment was just reconciled, so re-offering it would be advice about the wrong
thing. The guidance remains for the ordinary path, where the destination was
already usable and the cluster went unreachable.

## What remains after part B

- **GCP's first run is the recorded deferral** in `DEC-058`, with its trigger: GCP
  becomes Option A once it has a deploy identity, an access entry and its
  namespace-scoped RBAC. Until then a GCP first run provisions and names the
  operator's kubeconfig steps — which is Option B, deliberately.
- **`DOCS-026`** (the installation and first-deploy guide) was blocked on this
  ticket; it is now unblocked.
- **AC1's "a deployed application"** is demonstrated end to end by the fake-driven
  tests as far as the deploy's own prerequisites, and on a real cluster by the
  existing `example-dockerfile-smoke` / qualification paths. The offline harness
  cannot carry a full Kubernetes API, so "the application came up" remains a real-
  cluster claim, not a shell-fixture one.

## Coverage (part A)

- `examples/pluto/README.md` gains the inline first-run walkthrough beside the
  explicit `sol cloud bootstrap` pair.
- `docs/DEVELOPER_EXPERIENCE.md` §3, §4.2, §5 and §6 state what is implemented
  today, and `docs/guides/deployment.md` §2 replaces "Target (FEAT-106)" with it.
- `docs/reference/cli.md` regenerated: the new flag, and the first-run paragraph in
  `sol deploy`'s own help.

## Checks run (part A)

- `dune build @all`; `internal/ci/check_ocamlformat.sh --all`;
  `internal/ci/check_no_comments.sh`.
- `dune test cli/`, including a new `cli/test/test_deploy_first_run.sh` that drives
  the command against fake `aws` / `terraform` / `kubectl` / `dig`: uninstalled and
  non-interactive, uninstalled and `--dry-run`, partly installed, a denied provider
  (UNKNOWN, never "missing"), installed through an unreachable cluster, and (under a
  pty) an accepted and a declined setup — asserting exit codes, that nothing is
  provisioned without a terminal, and that an established installation runs no
  Terraform; and 7 new cases in `cli/test/test_installation.ml` for the onboarding
  model and the provider absence vocabulary.
- `render-cli-reference.py --check`.

**Language parity (part A):** no application-facing contract changes — no
`sol.toml` field, framework primitive or generated manifest — so `DEC-022` carries
no per-language verdict for this change.

**Ticket state:** stays in `READY_FOR_ENGINEERING`. Part A's criteria hold; AC1's
environment clause and AC6's provisioning ordering do not yet, so the ticket is not
moved to `DONE`.


## Checks run (part B)

- `dune build @all`; `dune build @cli/test/runtest --force`;
  `internal/ci/check_ocamlformat.sh --all`;
  `internal/ci/check_no_comments.sh`; `internal/ci/check_result_syntax.sh`;
  `render-cli-reference.py --check` (no command surface changed).
- New `cli/test/test_deploy_environment_stage.sh`, driving the command against the
  shared `internal/ci/lifecycle_fakes` (extended: `deploy_kube_context` in the AWS
  cluster root's outputs, the deploy role's `update-kubeconfig`, a `dig`, and
  opt-in installation probes) plus a `docker` stub: the preflight-before-provisioning
  ordering above, the environment stage provisioning the cluster and platform roots,
  the run establishing its *own* deploy-identity access
  (`--role-arn …/sol-deploy`, and that role being the last one configured), the run
  then reaching its own prerequisites, and `--dry-run` provisioning nothing.
- `cli/test/test_deploy_first_run.sh`: the two cases whose contract part B changed
  now assert the environment stage is entered and driven (cluster root
  `init`/`plan`/`apply`) rather than a named `sol cloud apply`; the installation
  cases are otherwise unchanged.
- `cli/test/test_cloud_lifecycle.ml`: a new case pins
  `Sol_cli_aws_cluster.deploy_access` — the declared deploy role produces a
  destination carrying this run's own kubeconfig, the provisioning identity is never
  assumed, a target with no `deploy_role_arn` gets no access, and GCP's
  `deploy_access` is `None`.

**Two behaviours the refactor had to keep, found by CI rather than by reading:**

- `sol cloud plan|apply <malformed or unsupported target>` still fails with the
  command's own message (`target must look like <env>/<provider>/<region>.`,
  `unsupported provider "zzz" in target …`). Moving the apply path into the
  environment stage had dropped `provider_of_target_path` from `cloud_init`, so the
  error came from the config layer instead, with a different spelling; the
  command's own target-path check runs first again.
- `--dry-run` and `--emit-to` never enter the environment stage, exactly as they
  never entered the installation you could only set up interactively: they resolve
  the declared destination, and where there is none they name
  `sol cloud apply <target>` and change nothing. Only a run that may change
  something establishes an environment or reaches a cluster.

**Language parity (part B):** no application-facing contract changed — no `sol.toml`
field, framework primitive or generated manifest — so `DEC-022` carries no
per-language verdict for this change.

**Ticket state:** all criteria hold on the provider with a deploy identity. AC1's
remaining clause is GCP's, which `DEC-058` records as an explicit deferral with a
trigger rather than silent drift. Moves to `DONE` with `DEC-058` in the same commit.
