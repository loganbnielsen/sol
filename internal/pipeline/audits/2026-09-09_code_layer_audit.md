# 2026-09-09 Code Layer Audit

Vision used for this pass: Sol should become the "Vercel of backends": a CLI
and framework that share one factory contract, take a workspace from source to
running backend services, and make telemetry/release inspection the default
operating surface.

## Validation Run

- PASS: `dune build @all`
- PASS: `dune runtest`
- BLOCKED: `npm test --workspaces --if-present` did not execute the TS tests in
  this WSL environment. Node resolved through Windows `CMD.EXE`, emitted UNC
  path warnings for the workspace package directories, and reported 0 tests.

## Ranked Findings

1. `split` `cli/sol/bin/cmd_up.ml`: `run` owns local env mutation, Docker
   context prep, build/push, manifest apply, rollout wait, port-forward setup,
   deploy-state writes, and migration hints in one command body. Extract the
   reusable factory stages already implied by the docs: build context, image
   build/push, plan execution, rollout wait, post-deploy observation.

2. `move` `cli/sol/bin/cmd_deploy.ml`: deploy policy and post-deploy telemetry
   still live in the command handler: explicit target-file validation,
   GitOps-secret safety, consumer-group removal guard, state writes, service URL
   lookup, and release-event push. Put deploy orchestration behind a
   `plan -> execution_result` boundary so CLI, CI, and hosted can call the same
   path.

3. `leak` `cli/sol/lib/sol_cli_manifest.ml`: service discovery is still a
   filesystem/Kubernetes-manifest concern and validates only
   `app/<domain>/<name>_{svc,worker,fn}/Dockerfile`. The deployment plan should
   receive a neutral workspace model that can also carry preflight expectations:
   ports, health path, metrics path, secret keys, topics, migrations, and volume
   claims.

4. `gap` `cli/sol/lib/sol_cli_deployment_plan.ml` and
   `cli/sol/lib/sol_cli_toml.ml`: no workload-level volume model exists. The
   platform has durable component storage toggles, but an app service/worker/fn
   cannot declare a mounted persistent volume through `sol.toml`, the plan, or
   rendering. Add the smallest typed `[infra.volumes]` shape before users need
   GitOps overlays for common stateful workers.

5. `gap` `docs/deployment/service-runtime-contract.md`: the doc correctly
   calls out the fundamental factory gap: Sol mostly catches bad runtime
   behavior after deploy. Add a `sol check` or pre-deploy check phase that
   verifies generated services expose `/healthz`, `/metrics` when expected,
   required env keys, and scaffold/runtime primitive conformance before real
   deploy.

6. `stale-contract` `docs/deployment/self-hosted-substrate-contract.md`: this
   doc describes `DATABASE_URL`, `kafka_secret_name`, `postgres_secret_name`,
   `tls_secret_name`, and `loki_url`/`pushgateway_url` `sol.toml` fields that
   do not match the current implementation. The actual code uses fixed
   platform env keys plus per-service Secrets. Fix the doc or implement the
   fields, but do not leave the product contract ambiguous.

7. `leak` `framework/sol-svc`, `framework/sol-worker`, `framework/sol-fn`:
   signal-handler/self-pipe logic is duplicated across primitives. This is not
   urgent, but it is a real runtime helper with three copies. Move it to
   `sol-env` or leave a deliberate local duplicate comment and stop expanding
   it.

8. `yagni` `packages/sol-obs` and `packages/sol-kafka`: the TS package layer is
   useful as a vocabulary bridge, but avoid growing it into a second framework.
   Keep it as policy helpers over Fastify/kafkajs/prom-client until at least two
   real TS services prove which lifecycle pieces must be centralized.

## Product Assessment

The strongest architectural choice is already present: deployment plans are
typed, serializable, and mode-aware. That is the right spine for local,
customer-cloud, GitOps, and hosted. The next work should make every command use
that spine more completely.

The weakest product contract is runtime proof. Today Sol can build and deploy a
container-shaped directory that is not actually a Sol service. For a "Vercel of
backends" product, this is the difference between a framework and a factory:
factories reject bad parts before assembly.

Telemetry is one of the repo's best-developed surfaces. OCaml primitives emit
standard metrics, labels are stable, release events feed the timeline, and TS
helpers mirror label vocabulary. The gap is enforcement for custom containers
and generated/non-OCaml services: Sol assumes scrapeability more than it proves
it.

Persistent platform storage exists for infrastructure components. Persistent
application volumes do not. Model them narrowly before adding more deployment
flexibility:

```toml
[infra.volumes.data]
mount_path = "/data"
size = "10Gi"
access_mode = "ReadWriteOnce"
```

That is enough to render PVC + volumeMount for one common stateful-service case.
Leave StorageClass, snapshots, expansion, shared RWX, and backup policy for a
later escape hatch.

Internal APIs should not start as HTTP endpoints. The lazy first boundary is an
OCaml module/API around:

```text
workspace scan -> deployment plan -> execution request -> execution result -> release record
```

Once that shape is stable, expose it through CLI JSON and hosted HTTP. Starting
with a hosted REST API now would freeze accidental CLI details.

## Simplest Recommended Architecture

```text
CLI args
  -> command request
  -> workspace model
  -> deployment plan
  -> executor(local | direct | gitops | hosted)
  -> execution result
  -> release/telemetry record
```

Framework runtime path stays:

```text
app code -> sol-svc/sol-worker/sol-fn -> sol-obs -> provider adapters
```

Keep the public app API boring. Push deployment/hosting complexity behind the
plan and executor boundary.

## Ponytail Audit

- `shrink` `cmd_up.ml`: extract build/apply/wait result phases; replacement is
  fewer command-local branches, not a new framework.
- `delete` hosted mock/database residue until hosted executor work resumes;
  replacement is docs plus the plan JSON boundary.
- `stdlib/native` no major wins found beyond existing process helper cleanup;
  most hand-written parsing is either TOML-backed or intentionally tiny.
- `yagni` TS framework ambitions; keep `@sol/obs` and `@sol/kafka` as policy
  helpers until real usage forces more.

net: -300 to -600 lines possible mostly by moving command-stage duplication and
deleting stale hosted spike code when not actively used; -0 deps obvious.
