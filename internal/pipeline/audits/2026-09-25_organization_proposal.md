# Repository organization proposal

**Status:** accepted (2026-09-25). Reviewed in two external rounds on #515 (see
§ *Review log*). DEC-046 and DEC-047 record the decisions and the answers to the
open questions.
**Decisions:** DEC-046 (repository layout), DEC-047 (deployment config layering).
**Origin:** operator review notes on `cli/platform/infra` and the `cli/` split,
worked through with an agent session and checked against the tree at `origin/main`
`1aad2623`.

This document is the authoritative scope for the tickets it lists. Each ticket
carries its dependencies and acceptance criteria, and points here for the reasoning.

## Why

The repo has grown by accretion, and several directories now answer "where does
this go?" with two or three places at once. The things that make it look messy
share one cause: **the files don't sit on the axis they actually vary along.**

- `cli/platform/infra/base` is two things. Its resources are Helm and Kubernetes
  only — cluster-agnostic — but it declares `backend "s3" {}`, which makes it the
  AWS entry point too. `base-gcp` exists only to wrap it with a GCS backend.
- `infra/bootstrap` is AWS-only with no suffix; `infra/bootstrap-gcp` has one.
- `infra/argocd` and `infra/ci` are delivery templates, not Terraform roots.
- Local dev reads Grafana dashboards and the Alloy config from
  `cli/platform/infra/base/` (`cli/sol/lib/sol_cli_dev_observability.ml:69,260`),
  so shared assets live under a cloud-only path.
- `cli/platform/local/scripts/` mixes what `sol local` runs (`ensure-*.sh`) with
  maintainer tooling (`run_tests.sh`, `perf.sh`, `install-hooks.sh`, …).
- Audits, dogfood runs and qualification records each live in two or three places
  (`docs/audits` + `internal/pipeline/audits`; `docs/qualification` +
  `internal/qualification` + `internal/pipeline/qualification`).
- `contract/` is user-facing reference kept outside `docs/`.
- `framework/` has a slot for OCaml but not TypeScript, which DEC-022 treats as
  first-class.
- Platform Helm values are 18 JSON files. You can't see how local and cloud
  differ without opening three files per component.
- A project's deployment config has two layers (`sol.yml` → target file), so
  per-environment policy has to be copied into every region's file.

## Rules

The layout follows from six rules. They aren't fully independent: rule 5 is
largely a consequence of rule 1. They're working heuristics, not an axiom set.
When a new file has no obvious home, apply the rules rather than the tree.

1. **The top level is split by audience.** What users install (`cli`, `platform`,
   `framework`), what they read (`docs`, `examples`), and what only maintainers
   touch (`internal`). **`docs/` is for people using Sol; `internal/` is for people
   building Sol.**
2. **Code and assets are separate.** `cli/` holds the binary and what the binary
   itself needs: OCaml, its SQL migrations and its test scripts. It holds no
   platform assets. `platform/` holds only what the CLI drives: Helm values,
   Terraform, templates and scripts, and no OCaml.
3. **Platform assets are split shared / local / cloud.** Anything both environments
   use lives in `shared/`, so neither side owns it. Platform config varies by
   **profile** (`local`, `durable`). Project config varies by **environment and
   target**.
4. **Cloud providers mirror each other by role.** Every provider has the same set
   of Terraform roots with the same names, and CI checks it. The resources inside
   a root don't have to match, because AWS IAM and GCP service accounts aren't
   one-to-one.

   **The directory is the marker, and each provider's roots are all or nothing.**
   The set of roles (`bootstrap`, `cluster`, `platform`) is fixed in one place.
   The check has three parts:

   - A registered provider with **no** directory under `platform/cloud/` exists
     only on paper. That is allowed.
   - Every registered provider **that has a directory under `platform/cloud/`**
     has every role. A half-built provider fails.
   - Every directory under `platform/cloud/` (other than `modules/` and
     `delivery/`) is a registered provider.

   The permissive part is existing policy, not a new exemption.
   `internal/ci/check_destroy_completeness.sh:40-42` already skips a provider with
   no root ("A provider with no root yet has nothing of its own to deploy"). The
   role-completeness part is new. Whether a provider is *usable* stays the
   capability layer's job (`Sol_cli_provider_capabilities.capabilities_of`), not
   the layout check's.

   That handles a third provider without renegotiating anything. The
   Azure-on-paper test (`2026-09-25_cloud_lifecycle_end_state.md` § S11) added an
   `Azure` constructor to `Sol_cli_provider.t`, and to `all`, with no Terraform
   roots, and built the tree to measure the change surface. Under this rule that
   stays legal: registering a provider leaves it on paper. Creating
   `platform/cloud/azure/` is what makes the check demand all three roles.

   **One provider list for every guard.** Today there are two derivations.
   `Sol_cli_provider.all` is used by `Sol_cli_profile_preflight`, the readiness
   invocation printer and `test_cloud_lifecycle.ml`.
   `check_destroy_completeness.sh:33` instead scrapes the string literals out of
   `let to_string` with `sed`. They can disagree. The proposal standardizes on
   `Sol_cli_provider.all`, which needs two things:

   - **`all` can't silently omit a constructor.** `to_string` has that property
     because an exhaustive match won't compile without a new arm, and `all` doesn't
     have it today. REFAC-100 makes `all` exhaustive by construction, so adding a
     constructor without placing it in `all` fails the build.
   - **Shell guards read the list from a declared function, not a text scrape.** A
     small printer executable, following the existing
     `cli/sol/test/print_readiness_invocations.ml` →
     `internal/ci/check_readiness_invocations.sh` pattern, prints
     `List.map Sol_cli_provider.to_string Sol_cli_provider.all`. Both
     `check_destroy_completeness.sh` and the rule-4 guard read it, and the `sed`
     scrape is deleted.

5. **Each kind of artifact has one home.** Every application language has a slot in
   `framework/`, audits live in one place, and qualification records live in one
   place. Implementer specs stay next to the code they describe.
6. **Code folders follow the dependency graph.** A domain that the graph separates
   cleanly becomes its own dune library. Because the libraries are
   `(wrapped false)`, no module is renamed, but a module can only use another
   domain if its `dune` lists that domain, so the boundary is enforced at build
   time. Modules caught in a cycle stay in the top-level library until the cycle
   is broken.

## Target layout

```
sol/
  README.md  AGENTS.md  CONTRIBUTING.md  CHANGELOG.md  LICENSE  TRADEMARK.md
  *.opam  dune-project  dune-workspace   ← must stay at root (opam/dune)

  framework/
    README.md
    ocaml/                     sol-svc, sol-worker, sol-fn, sol-jobs, … (+ each package's spec .md)
    typescript/README.md       pointer to the @sol-fab/kafka and @sol-fab/obs repositories

  cli/                         the `sol` binary — OCaml only
    bin/  lib/<domain>/  test/  migrations/

  platform/                    what the CLI provisions — no OCaml
    README.md
    shared/
      components.json          Helm values for every component, keyed by profile
      observability/           dashboards/, alloy/ — used by local AND cloud
    local/
      scripts/                 ensure-*.sh, setup-local.sh (what `sol local` runs)
      config/                  prometheus.yml, tempo.yaml, …
    cloud/
      modules/platform/        the shared platform Terraform module — no backend
      aws/{bootstrap,cluster,platform}/
      gcp/{bootstrap,cluster,platform}/
      <provider>/…             same roles for every provider in the registry (rule 4)
      delivery/                argocd/, ci/ (GitOps and CI templates)

  examples/                    runnable references (pluto), self-contained

  docs/                        users only
    ROADMAP.md                 public direction (DEC-046 Q1)
    guides/  reference/  deployment/  architecture/  hosted/  legal/  assets/

  internal/                    maintainers only
    ci/  tooling/  fixtures/
    specs/                     cross-language framework conventions (DEC-022)
    planning/                  WORK_SUMMARY, OPAM_FOUNDATION_TRACKER, LIVE_DEV_DEPLOY_ROADMAP
    contributing-map.md
    pipeline/{tickets,audits,dogfood}/
    qualification/{aws,gcp,records}/
```

## Moves

| Today | Target | Ticket |
|---|---|---|
| `cli/platform/` | `platform/` | REFAC-099 |
| `cli/sol/{bin,lib,test,control_plane_migrations}` | `cli/{bin,lib,test,migrations}` | REFAC-099 |
| `infra/base` (definition + S3 backend) | `cloud/modules/platform` + `cloud/aws/platform` | REFAC-100 |
| `infra/base-gcp` | `cloud/gcp/platform` | REFAC-100 |
| `infra/aws`, `infra/gcp` | `cloud/{aws,gcp}/cluster` | REFAC-100 |
| `infra/bootstrap`, `infra/bootstrap-gcp` | `cloud/{aws,gcp}/bootstrap` | REFAC-100 |
| `infra/argocd`, `infra/ci` | `cloud/delivery/` | REFAC-100 |
| `infra/base/{dashboards,alloy}` | `shared/observability/` | REFAC-101 |
| `components/<c>/values-{common,local,durable}.json` | `shared/components.json` | REFAC-102 |
| `local/scripts/{run_tests,perf,install-hooks,prepare-framework-deps,prove-workspace-independence,check-schemas}.sh` | `internal/tooling/` | REFAC-103 |
| `local/k8s/`, `local/schemas/`, `local/config/grafana-dashboards/sol-demo-overview.json` | `internal/fixtures/`, or delete | REFAC-103 |
| 157 flat files in `cli/sol/lib/` | per-domain dune libraries where the graph allows (rule 6) | REFAC-104 |
| `contract/{runtime,substrate}.md` | `docs/reference/` | DOCS-023 |
| `docs/{audits,dogfood}` | `internal/pipeline/{audits,dogfood}` | DOCS-023 |
| `docs/qualification/`, `internal/pipeline/qualification/`, `internal/qualification/` | `internal/qualification/` | DOCS-023 |
| cross-language framework conventions (spread across DEC-022 and package specs) | `internal/specs/framework-conventions.md` | DOCS-023 |
| — | `framework/typescript/README.md` | DOCS-024 |
| pluto targets pointing at `internal/qualification/aws/smoke-test.tfvars` | self-contained example | REFAC-105 |
| `sol/<env>/<provider>/<region>.yml` | `sol/environments.yml` (sol.yml → env → target) | DEC-047, FEAT-100 |

The `infra/*` and `components/*` paths above are relative to `cli/platform/` today
and to `platform/` after REFAC-099.

## Platform component values: one file, keyed by profile

The CLI (`Sol_cli_platform_component.merged_values_yaml`) and Terraform
(`jsondecode(file(...))` in `infra/base/main.tf`) already share these values under
ADR 0001: `common`, deep-merged with the profile's overlay. The mechanism is fine.
The file count isn't: 18 files, and tempo's three are all `{}`.

```json
{
  "loki": {
    "common":  { "gateway": { "enabled": false }, "loki": { "auth_enabled": false } },
    "local":   { "loki": { "storage": { "type": "filesystem" }, "useTestSchema": true } },
    "durable": { "loki": { "storage": { "type": "s3" }, "schemaConfig": { "...": "..." } } }
  },
  "redpanda": { "common": { "...": "..." } }
}
```

**Key it by profile, never by env, provider or region.** Loki shouldn't be
configured differently in `prod/aws/us-east-1` and `prod/gcp/europe-west1`. If it
were, that difference would be a bug under "dev mirrors prod". A single file puts
every local-vs-durable difference on one screen, so a PR that adds drift shows up
as one diff.

**It stays JSON.** An earlier draft proposed YAML. That would have added a
dependency: the CLI has no YAML library (`cli/sol/lib/dune` lists `unix yojson
cmdliner otoml sol_process ptime`), and `sol.yml` is read by a hand-written subset
parser. It would also have left two independent YAML implementations (Terraform's
`yamldecode` and a new OCaml one) that must agree exactly on what reaches Helm.
Today `jsondecode` and `yojson` agree exactly, and the benefit comes from the
single file, not the format.

## Deployment config: three layers (DEC-047)

**Keep the address.** `prod/aws/us-east-1` identifies a deployment, and DEC-031's
target positional is built on it.

**Change the layering.** The loader has two layers. `sol.yml` is the base, and
the leaf `sol/<env>/<provider>/<region>.yml` sits on top of it
(`merge base overlay`, `cli/sol/lib/sol_cli_config.ml`). Nothing exists at the env
level, so each leaf mixes two kinds of setting:

| Setting | What it varies by |
|---|---|
| `cluster_name`, `kube_context`, `registry` | target |
| `profile`, `scale`, `size`, alert routing, `base_domain`, `letsencrypt_email`, `node_failure_headroom_nodes` | environment |

Every pluto environment has one region today, so this costs nothing yet. It already
shows, though: `prod` and `pilot` repeat `base_domain`, `letsencrypt_email` and
`node_failure_headroom_nodes`. The first second region copies prod's scale, profile,
alerting and domain into another file, and after that the regions can drift apart
with nothing to catch it.

Proposed: `sol.yml` says what the app is, the environment sets policy, and the target
says where it runs. Environments and targets go in one file, and every key can be
overridden at a lower layer:

```yaml
# sol/environments.yml
prod:
  profile: production-single-region
  base_domain: pluto.example.com
  letsencrypt_email: ops@pluto.example.com
  alerts:
    receiver: webhook
    url: https://alerts.example.com/sol/webhook
    owner: pluto-oncall
    runbook: https://runbooks.example.com/sol
  node_failure_headroom_nodes: 1
  services:
    charge_svc:
      scale:
        min: 1
        max: 2
  targets:
    aws/us-east-1:
      cluster_name: pluto-prod
      kube_context: pluto-prod
      registry: 123456789012.dkr.ecr.us-east-1.amazonaws.com
    aws/eu-west-1:
      cluster_name: pluto-prod-eu

dev:
  cluster_issuer: letsencrypt-staging
  resources:
    app_db:
      omit: true
    events:
      omit: true
  targets:
    aws/us-east-1:
      cluster_name: sol-dev
```

The sample is in block style on purpose. The current parser has no code path
for flow maps (`{ … }`), and nothing here should imply a parser feature nobody
has budgeted. FEAT-100 decides whether to extend the hand-written parser or take
a real YAML library, and costs whichever it chooses.

- `sol deploy prod/aws/us-east-1` doesn't change. It resolves `sol.yml` → `prod` →
  `aws/us-east-1`.
- A region that needs something different overrides it at target level, so no
  expressive power is lost.
- **Why one file:** it's small now, and every environment's policy fits on one
  screen. Split it when a real user needs that.
- **Trade-off:** for a large organization with many targets owned by different
  teams, one file becomes a merge-conflict hotspot, and a bad edit can reach
  every target at once. Both argue for a file per target. Sol is pre-alpha with
  no such users, so this optimizes for clarity now.

**How overrides merge has to be pinned down per key.** "Every key can be
overridden at a lower layer" is ambiguous for nested maps. If the environment
sets `scale.min` and the target sets `scale.max`, do both survive (deep merge),
or does the target's `scale` replace the environment's? That ambiguity is exactly
where environments drift silently. DEC-047 records a table giving, for each key,
**deep-merge** or **replace**. The default matches today's per-type merge
functions (`merge_target`, `merge_resource`, `merge_service` in
`Sol_cli_config`), so nothing changes by accident.

This changes what app authors write, so unlike the repo moves it is a
product-surface decision. It needs a demo update (pluto, tutorial) and a TypeScript
parity note.

## Open questions for reviewers

**Resolved 2026-09-25.** The answers are in DEC-046 (1–3) and DEC-047 (4):
`docs/planning/` is split, with ROADMAP staying public and the rest moving to
`internal/planning/`; `docs/architecture/` stays except `contributing-map.md`;
rule 6's mechanism is as proposed; the file is `sol/environments.yml`. The
questions are kept below as they were asked.

1. **Where do `docs/planning/` (ROADMAP, WORK_SUMMARY) go?** Under rule 1 they're
   maintainer material and belong in `internal/`. A public roadmap is a reason to
   keep them in `docs/`. The proposal leaves them in place until this is decided.
   The answer covers all four files there, including `OPAM_FOUNDATION_TRACKER.md`
   and `LIVE_DEV_DEPLOY_ROADMAP.md`, which also name `cli/platform` paths.
2. **Should `docs/architecture/` (ADRs, `contributing-map.md`) move too?** ADRs
   explain the design to people building Sol, which argues for `internal/`. They
   also explain it to evaluators, which argues for `docs/`.
3. **Is the rule-6 mechanism right for `cli/lib`?** Proposed: one dune library
   per domain the graph separates cleanly, with the remainder in the top-level
   library. The alternative, plain folders under `(include_subdirs unqualified)`,
   makes navigation easier but enforces nothing. The two can't be mixed in one
   subtree: under `include_subdirs unqualified`, dune treats every subdirectory as
   part of the enclosing library. So choosing libraries means
   `(include_subdirs no)` with a `dune` per domain directory. REFAC-104 delivers
   the graph and the decision for each domain.
4. **Name of the environments file:** `sol/environments.yml`, or an `environments:`
   key in a second top-level file such as `sol.deploy.yml`?

## Sequencing

Path moves are ordered so each path changes once:

Arrows point from a dependency to the tickets that wait on it:

```
DEC-046 ─┬─> REFAC-099 ─┬─> REFAC-100 ──> REFAC-101
         │  (two moves) ├─> REFAC-102
         │              ├─> REFAC-103
         │              └─> REFAC-104
         ├─> DOCS-023
         └─> DOCS-024

DEC-047 ───┐
           ├─> FEAT-100
REFAC-105 ─┘
```

DEC-047 and REFAC-105 are independent; only FEAT-100 needs both. REFAC-099 lands
as two commits or PRs, `cli/platform` → `platform/` first and `cli/sol` → `cli/`
second, so the two repo-wide diffs aren't tangled together.

Each move ticket updates hardcoded paths in `cli/`, `internal/ci/`,
`.github/workflows/`, `AGENTS.md`, `CONTRIBUTING.md` and `docs/` in the same
change. `rg -n --hidden -g '!.git' '<old path>'` must return nothing outside
`internal/pipeline/` and dated historical records before the ticket closes.

**The one way a move can fail silently** is a workflow `paths:` filter that no
longer matches, so the workflow stops triggering instead of failing. Today there
is exactly one: `.github/workflows/workspace-independence.yml:26`. Every other
workflow reference is in a `run:` step and fails visibly. REFAC-099 adds a check
that every path in a `paths:` filter exists.

## Evidence

Commands run on 2026-09-25. Items up to the review log were run against `origin/main`
`1aad2623`; line numbers from review round 1 are against `50449a1a`, and
round 2's (`check_destroy_completeness.sh:33,40-42`) against `dae9540d`. **Line
numbers are only meaningful with their base commit**, since both trees moved during
review.

- `sed -n 20p cli/platform/infra/base/main.tf` → `backend "s3" {}`.
- `head -18 cli/platform/infra/base-gcp/variables.tf`: this root exists because
  "the S3 backend `base` declares cannot be the GCS one a GCP target needs".
- `rg -n 'cli/platform/infra/base/(dashboards|alloy)' cli/sol/lib` →
  `sol_cli_dev_observability.ml:69` and `:260`. Local dev reads cloud-path assets.
- `rg -n --hidden -g '!.git' 'local/k8s|deploy-local\.sh|demo-app\.yaml|svc-template\.yaml'`,
  excluding `internal/pipeline/`: the only match is
  `cli/platform/local/k8s/deploy-local.sh:27`, the directory referencing itself.
  That match is the positive control showing the search can see the directory.
  Nothing outside it uses it.
- `examples/pluto/sol/{dev,customer_cloud}/aws/us-east-1.yml` set
  `terraform_var_file: ../../../../../internal/qualification/aws/smoke-test.tfvars`,
  and `docs/guides/TUTORIAL.md:441` tells users to deploy `customer_cloud/aws/us-east-1`.
- `ls cli/platform/components/*/`: 6 components × 3 JSON files. Tempo's three
  are each `{}`.
- `rg -n --hidden -g '!.git' check_platform_root_wrapper` matches only a comment in
  `cli/platform/infra/base-gcp/variables.tf:13`. The CI check it describes doesn't
  exist, so nothing currently keeps the GCP root's variables in step with `base`.
  REFAC-100 adds it.
- `sed -n 3,4p cli/sol/lib/dune` → `(wrapped false)` and
  `(libraries unix yojson cmdliner otoml sol_process ptime)`, with no YAML library.
  `rg -n 'unsupported sol.yml syntax' cli/sol/lib/sol_cli_config.ml` → six
  rejection branches (lines 493–738 at `50449a1a`; 492–735 at `0b3441a8`) in the
  hand-written parser.
- `find . -name dune -not -path './_build/*'` lists 42 `dune` files (the positive
  control that the search sees them). Piping that list to `xargs rg -l include_subdirs`
  finds nothing, so no `dune` file uses `include_subdirs` today.

## Review log

**Round 1 (2026-09-25), from an external reviewer.** Accepted:

- **YAML for component values dropped**; kept as one JSON file keyed by profile
  (REFAC-102).
- **Rule 4 made registry-driven**, with an explicit story for paper providers
  (Azure).
- **DEC-047 merge semantics** to be pinned down per key; the environments sample
  rewritten in block style.
- **REFAC-099 split into two moves**, with the workflow `paths:` check and the full
  list of loud CI consumers.
- **REFAC-104 reframed** as a dependency graph plus a library/folder decision per
  domain, and the `include_subdirs` mechanism corrected.
- **The ownership argument for a single environments file dropped.**
- **Diagram and layout fixes:** order diagram fixed; `docs/assets/` and the
  `docs/planning/` files added to the layout; the stale ticket-type list in
  `AGENTS.md` added to DEC-046's scope.

**Round 2 (2026-09-25), same reviewer.** Accepted:

- **Rule 4 rewritten as "the directory is the marker".** A registered provider
  without a directory stays on paper, and a provider with a directory must have
  every role. This replaces a strict check that would have failed the S11
  worktree, and a claim that `production_qualified` exempted paper providers,
  which the check never read.
- **One provider list:** `Sol_cli_provider.all`, made exhaustive by construction
  and printed for shell guards. It replaces `check_destroy_completeness.sh`'s
  `sed` scrape of `to_string`.
- **Rule 2 reworded:** `cli/` holds the binary's SQL migrations and test scripts
  too. "Only OCaml" could never be true
  (`find cli/sol -type f ! -name '*.ml' ! -name '*.mli' ! -name dune`).
- **REFAC-099's consumer list corrected:** `classify-changes.sh` removed, and
  `internal/ci/provider_dispatch_allowlist.txt` (path-keyed data) named.
- **Glob semantics defined** for the workflow `paths:` check.
- **The three provider modules named separately:** `Sol_cli_provider`,
  `Sol_cli_provider_capabilities`, `Sol_cli_provider_registry`.

Withdrawn after checking: the reviewer's line numbers for the parser rejections.
Both sets were correct for their own base commit (`0b3441a8` vs `50449a1a`), so
the evidence now states its base.

**Correction found during implementation (REFAC-100, 2026-09-25).** The *Evidence* entry above saying the check `base-gcp`'s comment cites "doesn't exist, so nothing currently keeps the GCP root's variables in step with `base`" is **wrong**. Only the script *name* in the comment was stale: the check lives in `cli/test/check_production_infra.sh`, as `docs/qualification/gcp-bootstrap-inventory.md:670` records. The search looked for the file name without a positive control, the failure mode `AGENTS.md` § *Verifying claims* warns about, and both review rounds repeated it. REFAC-100 generalizes that existing check to every provider's platform root instead of adding a new one.

Withdrawn after checking (round 1): a separate "path guard" ticket before the move. The
reviewer suspected `classify-changes.sh` and `perf_baseline.json` would stop
matching after the move. Neither depends on `cli/` paths: the classifier matches
`docs/*` and ticket paths only, and the baseline is keyed by suite name.
