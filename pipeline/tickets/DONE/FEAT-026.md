---
id: FEAT-026
type: feature
severity: high
source: docs/planning/LIVE_DEV_DEPLOY_ROADMAP.md
branch: FEAT-026/target-deploy-wiring
worktree: ../sun-FEAT-026-target-deploy-wiring
pr: https://github.com/loganbnielsen/sun/pull/98
---

Wire `Sun_cli_config.load_for_target` into `sun deploy`; emit the `env` label; fix every touchpoint the new required target argument breaks.

**Depends on:** FEAT-025.

## Problem

`sun plan <target>` and `sun cloud plan/apply <target>` already resolve
`<env>/<provider>/<region>` via `Sun_cli_config.load_for_target`
(`cmd_plan.ml`, `cmd_cloud_tf.ml:238-292`). `sun deploy` does not — its
`env_target` is built purely from CLI flags
(`Sun_cli_env_target.customer_cloud_defaults` in `cmd_deploy.ml:47`), and
`Sun_cli_command_request.deploy_request` (`sun_cli_command_request.mli`)
has no `target` field at all today. No `env` label is ever emitted:
`sun_cli_manifest_yaml.ml`'s `render_taxonomy_labels` (lines 173-189)
emits `workspace`/`domain`/`service`/`primitive`/`release`, never `env`.
`docs/architecture/observability-design.md`'s Identity table names this
exact gap and names this exact fix.

## Design decision: target argument placement, and its full blast radius

`sun deploy` currently takes the service-path filter as optional `pos 0`
(`cmd_deploy.ml:179`) — the same slot `sun plan` already uses as a
**required** `pos 0` for the target. Resolve the collision by matching
`sun plan`'s precedent: target becomes the required `pos 0` on `sun
deploy`; the existing filter moves to `pos 1` (still optional). This is a
breaking CLI change with no compat shim, consistent with house rules — but
it touches more than the CLI parser:

- **`Sun_cli_command_request.deploy_request`/`make_deploy_request`**
  (`.ml`/`.mli`) needs a `target : string` field and validation, following
  the roadmap's own stated test requirement: "command request tests for
  target file plus CLI override precedence."
- **`env_config` is shared with `sun up`** (`sun_cli_deployment_plan.mli`),
  which has no target concept and stays that way by design (`sun up` stays
  local-only). Adding a required `env` field would force a value at every
  `env_config` construction site, including `sun up`'s and every test
  fixture that builds one. **Decision: make the new field `env : string
  option`** — `Some <resolved env>` from `sun deploy`, `None` from `sun
  up`. Don't force a fake `"local"` sentinel through call sites that have
  no real target.
- **The scaffold-generated CI templates invoke `sun deploy` with no
  positional target today, and there are two separate templates, only one
  of which is a real (non-comment) invocation:**
  - `sun_cli_scaffold_templates.ml`'s `tpl_github_deploy` (~line 405):
    `sun deploy \` `--image-tag "${SHA::7}"` `--registry "$REGISTRY"` — a
    **real, executed CI step**. This is the one that actually breaks.
  - The same file's `sun-ci.yml` template (~lines 144–147, ~251–303) only
    *mentions* `sun deploy --emit-plan-to`/`--emit-to` inside comments
    ("Equivalent Sun command: ..."). These don't execute, but
    `cli/sun/test/test_scaffold.ml` (~lines 99–104, 155–165) asserts the
    literal substrings `"sun deploy --emit-plan-to"`/`"sun deploy
    --emit-to"` appear in the generated file — updating the comments to
    include a target argument breaks these substring assertions too.
- **Documented example invocations with no positional target exist beyond
  what a first pass found** — spot-checked in `README.md` (lines ~393,
  394, 402, 409, 421), `docs/planning/ROADMAP.md` (lines ~138, 599, 600,
  606), `docs/architecture/PRODUCT_ARCHITECTURE.md` (lines ~101, 111 — the
  latter already shows a `--env prod` flag that **does not exist on `sun
  deploy` today**, a pre-existing doc bug independent of this ticket, now
  worth reconciling with whatever shape actually ships), and
  `docs/audits/UX_AUDIT.md` (lines ~17, 146, 173, 200, 226). Also missed by
  this pass, found by later review rounds: `docs/guides/TUTORIAL.md`
  (~478–519), `docs/deployment/self-hosted-substrate-contract.md` (~215,
  237), `docs/architecture/devops-pipeline.md` (~363–364, 394) — and two
  more **shipped, executed** CI templates (copy-into-your-own-repo, not
  just scaffold-generated), the same breakage class as `tpl_github_deploy`:
  `platform/infra/ci/github-actions-deploy.yml:90` and
  `platform/infra/ci/github-actions-gitops.yml:82`, both `sun deploy \`
  with no positional target. Don't treat this list as exhaustive — **run
  `grep -rln "sun deploy" --include=*.md --include=*.ml --include=*.yml
  --include=*.yaml --exclude-dir=project/audits --exclude-dir=project/dogfood
  --exclude-dir=project/tickets/DONE .` as part of this ticket's work**
  (note `--include=*.yml`/`*.yaml` — an earlier pass of this same grep
  used only `*.md`/`*.ml` and missed both `platform/infra/ci/*.yml` files
  above) and update every invocation example that would fail against the
  new required-target signature. The `--exclude-dir`s matter: the
  unfiltered version returns 274 hits, about 47% of which are immutable
  historical records (past audit/dogfood reports, done tickets) — don't
  edit history, only currently-live docs/templates. A hand-maintained line
  list goes stale; the grep doesn't.
- **`sun up` keeps `pos 0` = filter path** (`cmd_up.ml:241`) and stays
  local-only — state this divergence explicitly in both commands'
  `--help` text so it reads as intentional, not inconsistent.

## Non-goal

`sun.yml`'s `services:` declarations and `discover_services`
(`cli/sun/lib/sun_cli_manifest.ml:31`, filesystem-scanning `app/`) remain
two unreconciled sources of "what services exist." This ticket doesn't
unify them — `sun.yml`'s service list stays informational (topology,
`uses` bindings) while filesystem discovery stays authoritative for what
gets built/deployed. Unifying them is bigger than target-resolution wiring
and belongs in its own ticket if it becomes a real problem.

## Remediation

1. Add the target positional to `cmd_deploy.ml`; move `filter_path` to
   `pos 1`.
2. Add `target : string` to `deploy_request` and its `make` validation.
3. Call `Sun_cli_config.load_for_target ~target` before building
   `env_target`; surface a load/parse error the same way `cmd_plan.ml`
   does (print + `exit 1`).
4. Feed the resolved target's `registry` as the default for `--registry`
   when that flag is omitted — explicit `--registry` still wins. (`sun
   deploy` has no `--base-domain` flag today; don't invent one here.)
5. Add `env : string option` to `env_config` (see decision above); thread
   the resolved value from `sun deploy`, `None` from `sun up`. Update
   `render_taxonomy_labels` (`sun_cli_manifest_yaml.ml:173-189`) to emit
   `env` only when `Some`.
6. Update `tpl_github_deploy` to pass a target; update `test_scaffold.ml`'s
   substring assertions accordingly (and the `sun-ci.yml` comment lines,
   for consistency, if they're touched).
7. Run the repo-wide `grep` from the Problem section; fix every real
   invocation example it finds.
8. Add the `--help`/doc note on both `cmd_up.ml` and `cmd_deploy.ml`.
9. Tests: target-resolved deploy with no `--registry` picks up the target
   file's registry; explicit `--registry` overrides it; missing registry
   in both places fails before any docker/kubectl call; generated manifest
   carries `env` when a target resolved one, omits it when not; `pos 1`
   service-path filtering still works; omitting the target argument fails
   with cmdliner's standard missing-required-argument error; a
   `deploy_request` command-request test for target-file-vs-CLI-flag
   precedence (the roadmap's own stated test requirement).

## Acceptance criteria

- `sun deploy dev/aws/us-east-1 --image-tag <sha>` resolves registry from
  `sun/dev/aws/us-east-1.yml` when `--registry` is omitted.
- A deployed service's generated manifest carries a real `env` label
  matching the target's `env` segment; `sun up`-generated manifests carry
  no `env` label (not a fake default).
- `sun deploy dev/aws/us-east-1 app/payments/charge-svc` filters to one
  service.
- A freshly `sun new workspace`-scaffolded repo's generated
  `tpl_github_deploy` CI step still runs successfully against the new
  signature, and `test_scaffold.ml` passes.
- The repo-wide `grep -rn "sun deploy"` sweep from remediation step 7 was
  actually run as part of this PR, not just claimed — show it in the PR
  description.
