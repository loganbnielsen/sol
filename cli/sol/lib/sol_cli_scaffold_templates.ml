(* ── Shared templates ─────────────────────────────────────────────────────── *)

let tpl_ocamlformat =
  {tpl|profile = default
version = 0.29.0
|tpl}
;;

let tpl_dune_project =
  {tpl|(lang dune 3.0)
|tpl}
;;

(* DEC-025: the workspace's own dependency declaration. This is what makes the
   workspace the owner of its framework dependency -- `sol new` writes it, the
   developer's opam switch satisfies it, and the Docker build reproduces it. The
   generated Dockerfile deliberately carries no framework repository list.

   The framework version is intentionally unconstrained here: in development the
   switch provides the framework (see
   cli/platform/local/scripts/prepare-framework-deps.sh), while a pinned or
   released setup constrains it in this file. Choosing the channel is a workspace
   decision, not one the CLI makes. *)
let ws_opam =
  {tpl|# Workspace dependency declaration (DEC-025).
#
# The Sol framework packages this workspace consumes. `dune build` resolves them
# from the current opam switch, and the generated Dockerfile reproduces them with
# `opam install . --deps-only` -- so the Dockerfile carries no repository list of
# its own. The workspace owns this choice; Docker only reconstructs it.
opam-version: "2.0"
synopsis: "{{Name}} -- a Sol workspace"
# TODO(you): fill these in before publishing this workspace anywhere. They are
# left as TODOs rather than guessed, the same way the rest of this scaffold
# leaves your project's identity to you.
maintainer: "TODO(your-email@example.com)"
depends: [
  "ocaml" {>= "5.4.0"}
  "dune" {>= "3.0"}
  "sol-svc"
  "sol-worker"
  "sol-fn"
  "sol-jobs"
  "sol-obs"
  "kafka-eio-service"
]

# DEVELOPMENT CHANNEL: track the framework's main branch. Its exact revision is
# whatever main was when you last updated. For a released or reproducible setup,
# constrain the versions in `depends` above and delete this block. Replacing
# `#main` with a tag or commit is strictly more reproducible and needs no other
# change -- see DEC-025's development/release channel policy.
pin-depends: [
  [ "sol-runtime.dev"       "git+https://github.com/loganbnielsen/sol.git#main" ]
  [ "sol-env.dev"           "git+https://github.com/loganbnielsen/sol.git#main" ]
  [ "sol-obs.dev"           "git+https://github.com/loganbnielsen/sol.git#main" ]
  [ "kafka-eio-service.dev" "git+https://github.com/loganbnielsen/sol.git#main" ]
  [ "sol-svc.dev"           "git+https://github.com/loganbnielsen/sol.git#main" ]
  [ "sol-worker.dev"        "git+https://github.com/loganbnielsen/sol.git#main" ]
  [ "sol-fn.dev"            "git+https://github.com/loganbnielsen/sol.git#main" ]
  [ "sol-jobs.dev"          "git+https://github.com/loganbnielsen/sol.git#main" ]

  # The framework's own dependencies that are not yet in the public
  # opam-repository. opam does NOT apply a dependency's pin-depends transitively,
  # so a workspace tracking an unreleased framework channel has to name them
  # itself -- that is part of what choosing this channel costs. Once RELEASE-005
  # publishes these packages, delete this block; the workspace then no longer
  # needs to know anything about them.
  #
  # Pinned by immutable commit SHA rather than a branch: unlike the channel
  # choice above, these carry no "track development" intent.
  [ "obs-loki-eio.0.1.0"  "git+https://github.com/loganbnielsen/obs-loki-eio.git#20ff330a8f03aedf71c600f113e2bf0f8a14f205" ]
  [ "obs-tempo-eio.0.1.0" "git+https://github.com/loganbnielsen/obs-tempo-eio.git#31fd441cbae2a3fc5435539248524f00a6c6fd3d" ]
  [ "pg-eio.0.1.0"        "git+https://github.com/loganbnielsen/pg-eio.git#3ef3a20f6d9a81ce2d8e3a439e5f5f8862fba3bb" ]
  [ "lambda-eio.0.1.0"    "git+https://github.com/loganbnielsen/lambda-eio.git#c07c367b0f8919ae6efb9c3af2cd39d9061b1fdd" ]

  # These are published, but the published releases LAG what the framework needs
  # (concretely: obs-loki-eio requires obs-eio >= 0.1.1, which is not in
  # opam-repository). opam can only see the versions the registry offers, so a
  # consumer of an unreleased framework channel has to point at the same sources
  # the framework itself does. Commit-pinned, since this is not a "track
  # development" choice. All of it disappears when RELEASE-005 publishes the
  # framework and its dependencies.
  [ "https-eio.0.1.1"           "git+https://github.com/loganbnielsen/https-eio.git#e548f47cd8cc607e4781638fa3f4aec996b60d60" ]
  [ "kafka-eio.0.3.0"           "git+https://github.com/loganbnielsen/kafka-eio.git#784bf37c32e141406cf6a1837150d38d2cb2919e" ]
  [ "obs-eio.0.1.2"             "git+https://github.com/loganbnielsen/obs-eio.git#b425c55eba8b1bc65378d7fc7d6c77a573001fb4" ]
  [ "obs-prometheus-eio.0.1.0"  "git+https://github.com/loganbnielsen/obs-prometheus-eio.git#5f443342fd20a36551336f27f7dbb93ab90e73bb" ]
]
|tpl}
;;

(* DEC-024: the workspace manifest. Its presence is what makes this directory a
   Sol workspace -- `sol` resolves the root by walking up to the nearest
   sol.yml, so it must exist even when the workspace needs no settings. *)
let tpl_sol_yml =
  {tpl|# Sol workspace manifest.
#
# A directory containing this file is a Sol workspace. `sol` finds the
# workspace root by walking up from the current directory to the nearest
# sol.yml, so commands work from anywhere inside the workspace.
#
# Workspace-level configuration (project, resources, services) belongs here.
# The file is valid with no settings at all -- its presence is what
# establishes the boundary.
|tpl}
;;

let tpl_readme =
  {tpl|# {{Name}}

A Sol workspace with two services: `charge_svc` (HTTP) and `notify_worker` (Kafka consumer).

## Prerequisites

System packages required before building:

```bash
sudo apt-get install -y librdkafka-dev libpq-dev libpq5
```

The Sol framework is an ordinary opam dependency, declared in `{{basename}}.opam`
alongside the rest of this workspace's dependencies. Nothing is vendored into
this directory, and the workspace has no knowledge of where Sol's source lives.

- **Released framework:** `opam install . --deps-only` resolves the version you
  declare in `{{basename}}.opam`.
- **Development framework (tracking Sol `main`):** install the framework from a
  Sol checkout, which makes your switch satisfy the declared dependency:

  ```bash
  bash /path/to/sol/cli/platform/local/scripts/prepare-framework-deps.sh
  ```

  That is Sol's own bootstrap — the same one the Sol repository's CI runs — so
  there is one definition of the development switch rather than a list of pins
  copied into every workspace.

## Build

```bash
eval $(opam env)
dune build
```

## Run locally

```bash
sol local infra up   # provision local k3d cluster + Kafka + supporting infra (~5 min first run)
sol local run        # run all workspace services locally (dune exec, dev env vars)
```

## Deploy to cluster

```bash
sol up          # build images and deploy to cluster
sol local status   # show running pods and endpoints
sol migrate     # apply database migrations
sol rollback    # roll back all services to previous image
```

## Project layout

```
sol.yml                   ← workspace manifest (identifies this as a Sol workspace)
events/payments/          ← Charged event contract (payments team owns)
app/payments/charge_svc/  ← HTTP service (publishes Charged on POST /charges)
app/comms/notify_worker/  ← Kafka consumer (subscribes to Charged)
lib/                      ← shared storage module (used by svc and worker)
db/migrations/            ← SQL migration files
  *.sql                   ← forward migrations
  *.down.sql              ← rollback migrations (used by `sol migrate rollback`)
test/                     ← schema backward-compatibility CI gate
  test_schemas.ml
  dune
.dockerignore             ← excludes _build/ and .git/ from Docker build context
{{basename}}.opam              ← declares the Sol framework dependency (DEC-025)
```

This workspace's directory, OCaml module names, and SQL identifiers use the
OCaml-safe form `{{name}}` (lowercased, `-` → `_`). Kubernetes namespaces and
object names use the hyphenated form (`_` → `-`), e.g. `{{name}}-payments`; the
mapping is applied automatically.
|tpl}
;;

let tpl_sol_toml =
  {tpl|# Sol service configuration — all fields are optional.

[infra.scale]
# replicas = 1
# cpu      = "250m"
# memory   = "256Mi"

[infra.env]
# secrets = []
# config  = {}

[infra.rollout]
# strategy = "canary"       # or "blue-green"
# steps    = [10, 40, 100]  # canary only
|tpl}
;;

(* -fn sol.toml: [service] carries the cron schedule so sol deploy reads it
   without scanning OCaml source for "schedule = ..." string literals. *)
let tpl_fn_sol_toml =
  {tpl|# Sol service configuration — all fields are optional.

[service]
schedule = "0 * * * *"   # cron schedule (required)
# scheduled_concurrency = "forbid"  # allow (default) | forbid | replace -- overlap
                                     # between scheduled runs only; a manual
                                     # `sol fn run` is never constrained by this.
# backoff_limit = 3                 # Kubernetes Job retries before giving up (default: 3)

[infra.scale]
# cpu    = "100m"
# memory = "128Mi"

[infra.env]
# secrets = []
# config  = {}
|tpl}
;;

(* Event-directory sol.toml: [service] carries the topic name so sol deploy
   discovers topics without scanning OCaml source. *)
let tpl_event_sol_toml =
  {tpl|# Sol event metadata.

[service]
topics = ["{{team}}-{{name}}s"]
|tpl}
;;

(* Three-job pipeline: build-and-test, build-images, deploy — see the
   generated workflow's own header comment for the full contract. *)
let tpl_github_ci =
  {tpl|# Sol CI - build, test, and deploy on every push to main.
#
# Required GitHub secrets (Settings -> Secrets and variables -> Actions):
#   REGISTRY           container registry prefix, e.g.:
#                        AWS ECR:   123456789.dkr.ecr.us-east-1.amazonaws.com
#                        GCP AR:    us-central1-docker.pkg.dev/my-project/{{name}}
#                        Docker Hub: docker.io/myorg
#   REGISTRY_USER      registry username (or "AWS" for ECR)
#   REGISTRY_PASSWORD  registry password / access token
#
# Required GitHub repo variable (Settings -> Secrets and variables -> Actions ->
# Variables -- not a secret, this is just a path):
#   SOL_TARGET         deployment target, <env>/<provider>/<region>, e.g.
#                      prod/aws/us-east-1. Requires a matching
#                      sol/<env>/<provider>/<region>.yml file committed in
#                      this repo -- this workspace ships a placeholder at
#                      sol/prod/aws/us-east-1.yml; rename it to match your
#                      real target if it isn't prod/aws/us-east-1.
#
# Optional (GitOps push step):
#   GITOPS_TOKEN       GitHub token with repo-write access to commit manifests/.
#                      ${{ secrets.GITHUB_TOKEN }} works when pushing to the same repo.
#
# No KUBECONFIG or cluster credentials are needed for the build-and-test or
# build-images jobs. The deploy job emits manifests for GitOps instead of
# applying them directly to a cluster.
#
# ── Sol CI contract ──────────────────────────────────────────────────────────
#
# PHASE 1 — Build (user-owned, Sol-stable):
#   Compile and test OCaml code using: eval $(opam env) && dune build && dune runtest
#   Build and push Docker images using your registry's docker login + docker build/push.
#   Sol does not own this step today; a future `sol build` command will replace it.
#
# PHASE 2 — Deploy (Sol-owned, typed contract):
#   sol deploy <target> --emit-plan-to plan.json --dry-run   # capture typed deployment intent
#   sol deploy <target> --emit-to manifests/ --image-tag $SHA  # render K8s YAML (GitOps)
#
# Never duplicate the plan/render/execute logic from sol deploy in CI.
# All deployment decisions (image tags, namespaces, service discovery, secrets)
# belong in the CLI pipeline. CI only provides inputs (--registry, --image-tag).
# ─────────────────────────────────────────────────────────────────────────────

name: Sol CI

on:
  push:
    branches: [main]
  pull_request:

env:
  REGISTRY:   ${{ secrets.REGISTRY }}
  IMAGE_TAG:  ${{ github.sha }}
  SOL_TARGET: ${{ vars.SOL_TARGET }}

# ── Job 1: compile + unit tests ──────────────────────────────────────────── #
jobs:
  build-and-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up OCaml
        uses: ocaml/setup-ocaml@v3
        with:
          ocaml-compiler: "5.4.1"
          opam-depext: false

      - name: Install system deps
        run: sudo apt-get install -y librdkafka-dev libpq-dev

      - name: Install opam deps
        run: opam install . --deps-only --with-test -y

      - name: Build
        run: eval $(opam env) && dune build

      - name: Test
        run: eval $(opam env) && dune runtest

# ── Job 2: build and push service images ────────────────────────────────── #
  build-images:
    needs: build-and-test
    if: github.event_name != 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up OCaml
        uses: ocaml/setup-ocaml@v3
        with:
          ocaml-compiler: "5.4.1"
          opam-depext: false

      - name: Install system deps
        run: sudo apt-get install -y librdkafka-dev libpq-dev

      - name: Install opam deps
        run: opam install . --deps-only -y

      - name: Build service binaries
        run: eval $(opam env) && dune build

      # Registry login — uncomment the block that matches your registry:

      # AWS ECR:
      # - uses: aws-actions/configure-aws-credentials@v4
      #   with:
      #     aws-access-key-id:     ${{ secrets.AWS_ACCESS_KEY_ID }}
      #     aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      #     aws-region:            ${{ secrets.AWS_REGION }}
      # - run: |
      #     aws ecr get-login-password | \
      #       docker login --username AWS --password-stdin ${{ secrets.REGISTRY }}

      # GCP Artifact Registry:
      # - uses: google-github-actions/auth@v2
      #   with: { credentials_json: '${{ secrets.GCP_SA_KEY }}' }
      # - run: gcloud auth configure-docker ${{ secrets.REGISTRY }}

      # Generic (Docker Hub, GHCR, etc.):
      - name: Log in to registry
        run: |
          echo "${{ secrets.REGISTRY_PASSWORD }}" | \
            docker login "$REGISTRY" -u "${{ secrets.REGISTRY_USER }}" --password-stdin

      - name: Build and push images
        run: |
          SHORT_SHA=${IMAGE_TAG::7}
          # TODO(sol-build): This step will be replaced by `sol build --registry $REGISTRY`
          # once Sol publishes a stable build command. Until then, build images explicitly.
          # sol up discovers services from app/<domain>/<name>/Dockerfile.
          # Build and push each image explicitly here:
          find app -name Dockerfile | while read dockerfile; do
            dir=$(dirname "$dockerfile")
            svc=$(basename "$dir" | tr '_' '-')
            image="${REGISTRY}/{{name}}/${svc}:${SHORT_SHA}"
            # --provenance=false --sbom=false: without these, BuildKit attaches
            # a provenance/SBOM attestation sub-manifest to the image index,
            # which EKS's containerd fails to pull with a bare "not found" on
            # the tag even though the image is really in the registry --
            # confirmed live (DOGFOOD-011). Local k3d tolerates it either way.
            docker build --provenance=false --sbom=false -t "$image" -f "$dockerfile" .
            docker push "$image"
          done

# ── Job 3: emit deployment plan + GitOps manifests ──────────────────────── #
# This job runs only on pushes to main (not on pull requests).
# `sol deploy <target> --emit-plan-to plan.json` records the full deployment intent
# (images, namespaces, config) without applying anything — useful for auditing.
# `sol deploy <target> --emit-to manifests/` renders Kubernetes YAML to manifests/.
# An Argo CD Application watching that directory reconciles the change
# automatically; no KUBECONFIG or cluster credentials are required in CI.
  deploy:
    needs: build-images
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          token: ${{ secrets.GITOPS_TOKEN || secrets.GITHUB_TOKEN }}
          fetch-depth: 0

      - name: Set up OCaml
        uses: ocaml/setup-ocaml@v3
        with:
          ocaml-compiler: "5.4.1"
          opam-depext: false

      - name: Install system deps
        run: sudo apt-get install -y librdkafka-dev libpq-dev

      - name: Install opam deps
        run: opam install . --deps-only -y

      - name: Build sol binary
        run: eval $(opam env) && dune build cli/sol/bin/main.exe
        # TODO: replace with a pre-built binary download once Sol publishes releases.

      - name: Export deployment plan
        run: |
          eval $(opam env)
          # Equivalent Sol command: sol deploy <target> --emit-plan-to plan.json --dry-run
          _build/default/cli/sol/bin/main.exe deploy "$SOL_TARGET" \
            --registry  "$REGISTRY" \
            --image-tag "${IMAGE_TAG::7}" \
            --emit-plan-to plan.json \
            --dry-run
        # plan.json captures the full intent for this deploy (images, namespaces, config).

      - name: Upload deployment plan
        uses: actions/upload-artifact@v4
        with:
          name: deployment-plan-${{ github.sha }}
          path: plan.json

      - name: Emit GitOps manifests
        run: |
          eval $(opam env)
          # Equivalent Sol command: sol deploy <target> --emit-to manifests/
          _build/default/cli/sol/bin/main.exe deploy "$SOL_TARGET" \
            --registry  "$REGISTRY" \
            --image-tag "${IMAGE_TAG::7}" \
            --emit-to   manifests/
        # Writes rendered Kubernetes YAML to manifests/.
        # Argo CD (or Flux) watches this directory and reconciles automatically.

      - name: Commit and push manifests
        run: |
          git config user.email "ci@sol.dev"
          git config user.name  "Sol CI"
          git add manifests/
          git diff --cached --quiet && echo "no manifest changes" && exit 0
          git commit -m "deploy: ${IMAGE_TAG::7}"
          git push
|tpl}
;;

let tpl_github_deploy =
  {tpl|# CI/CD — deploy to your Sol cluster on every push to main.
#
# Required secrets (set in GitHub repo Settings → Secrets):
#   KUBECONFIG_B64   base64-encoded kubeconfig: $(cat ~/.kube/config | base64)
#   REGISTRY         container registry prefix, e.g.:
#                      AWS ECR:  123456789.dkr.ecr.us-east-1.amazonaws.com
#                      GCP AR:   us-central1-docker.pkg.dev/my-project/{{name}}
#                      Docker Hub: docker.io/myorg
#
# Required repo variable (Settings → Secrets and variables → Actions → Variables —
# not a secret, this is just a path):
#   SOL_TARGET       deployment target, <env>/<provider>/<region>, e.g. prod/aws/us-east-1.
#                    Requires a matching sol/<env>/<provider>/<region>.yml file
#                    committed in this repo -- this workspace ships a placeholder
#                    at sol/prod/aws/us-east-1.yml; rename it to match your real
#                    target if it isn't prod/aws/us-east-1.
#
# For ECR add AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION and
# uncomment the ECR login step below.
#
# See cli/platform/infra/ci/ in the Sol repo for the full GitOps (Argo CD) variant.

name: Deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: ocaml/setup-ocaml@v3
        with:
          ocaml-compiler: "5.4.1"
          opam-depext: false

      - name: Install system deps
        run: sudo apt-get install -y librdkafka-dev libpq-dev

      - name: Build
        run: |
          opam install . --deps-only -y
          eval $(opam env) && dune build

      # ── Registry login ───────────────────────────────────────────────── #
      # Uncomment the block that matches your registry:

      # AWS ECR:
      # - uses: aws-actions/configure-aws-credentials@v4
      #   with:
      #     aws-access-key-id:     ${{ secrets.AWS_ACCESS_KEY_ID }}
      #     aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      #     aws-region:            ${{ secrets.AWS_REGION }}
      # - run: |
      #     aws ecr get-login-password | \
      #       docker login --username AWS --password-stdin ${{ secrets.REGISTRY }}

      # GCP Artifact Registry:
      # - uses: google-github-actions/auth@v2
      #   with: { credentials_json: '${{ secrets.GCP_SA_KEY }}' }
      # - run: gcloud auth configure-docker ${{ secrets.REGISTRY }}

      # Docker Hub:
      # - uses: docker/login-action@v3
      #   with:
      #     username: ${{ secrets.DOCKERHUB_USERNAME }}
      #     password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Build and push images
        env:
          REGISTRY: ${{ secrets.REGISTRY }}
          SHA:      ${{ github.sha }}
        run: |
          SHORT_SHA=${SHA::7}
          find app -name Dockerfile | while read dockerfile; do
            dir=$(dirname "$dockerfile")
            svc=$(basename "$dir" | tr '_' '-')
            image="${REGISTRY}/{{name}}/${svc}:${SHORT_SHA}"
            # --provenance=false --sbom=false: without these, BuildKit attaches
            # a provenance/SBOM attestation sub-manifest to the image index,
            # which EKS's containerd fails to pull with a bare "not found" on
            # the tag even though the image is really in the registry --
            # confirmed live (DOGFOOD-011). Local k3d tolerates it either way.
            docker build --provenance=false --sbom=false -t "$image" -f "$dockerfile" .
            docker push "$image"
          done

      - name: Deploy
        env:
          REGISTRY:   ${{ secrets.REGISTRY }}
          SHA:        ${{ github.sha }}
          SOL_TARGET: ${{ vars.SOL_TARGET }}
        run: |
          mkdir -p ~/.kube
          echo "${{ secrets.KUBECONFIG_B64 }}" | base64 -d > ~/.kube/config
          eval $(opam env)
          sol deploy "$SOL_TARGET" \
            --image-tag "${SHA::7}" \
            --registry  "$REGISTRY"

      - name: Status
        run: eval $(opam env) && sol status --target "$SOL_TARGET"
|tpl}
;;

let tpl_dockerfile =
  {tpl|# Stage 1: compile inside ubuntu-24.04 so the binary links against glibc 2.39.
# Dependencies are NOT listed in this file. The image reproduces the environment
# the workspace declares in {{basename}}.opam -- `opam install . --deps-only` -- so the
# workspace owns its dependency choices (including which framework channel it
# tracks) and the build merely reconstructs them. Framework packages carry their
# own pin-depends for anything not yet in the public opam-repository (DEC-025), so
# no Sol repository needs to appear in a generated Dockerfile.
FROM ocaml/opam:ubuntu-24.04-ocaml-5.4 AS build
RUN sudo apt-get update && sudo apt-get install -y \
    librdkafka-dev libpq-dev libssl-dev libgmp-dev pkg-config && \
    sudo rm -rf /var/lib/apt/lists/*
# `opam repository set-url` first: the ocaml/opam base image's default remote is a
# local git+file:// checkout frozen at whatever opam-repository snapshot existed
# when the image was built, which can predate a version a dependency requires
# (observed: https-eio needing tls-eio >= 2.1.0, unsatisfiable against the frozen
# snapshot even after `opam update`). Pointing at the real opam.ocaml.org resolves
# it. CI does not hit this -- ocaml/setup-ocaml initializes a fresh index.
RUN opam repository set-url default https://opam.ocaml.org && opam update
# Only the dependency declaration is copied before installing, so the dependency
# layer is cached independently of workspace source changes.
COPY --chown=opam:opam {{basename}}.opam /workspace/
WORKDIR /workspace
RUN opam install -y --no-self-upgrade --deps-only .
COPY --chown=opam:opam . /workspace
WORKDIR /workspace
RUN opam exec -- dune build {{repo_dir}}/bin/main.exe

# Stage 2: minimal runtime image
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y librdkafka1 libpq5 ca-certificates && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /workspace/_build/default/{{repo_dir}}/bin/main.exe /usr/local/bin/{{binary}}
# Run as nobody (uid 65534) — matches securityContext in generated k8s manifests
USER 65534
CMD ["/usr/local/bin/{{binary}}"]
|tpl}
;;

let tpl_dockerignore =
  {tpl|_build/
.git/
*.docker-ctx/
|tpl}
;;

(* sol deploy deliberately refuses to run against a target with no
   sol/<env>/<provider>/<region>.yml file, even an empty one -- otherwise a
   typo'd target would silently inherit sol.yml's shared defaults and
   deploy anyway. This placeholder exists so a freshly scaffolded workspace
   has a real first target instead of failing before its first deploy;
   rename/move it (and update SOL_TARGET below) to your actual target. *)
let tpl_deploy_target =
  {tpl|# Placeholder target for `sol deploy prod/aws/us-east-1`.
# Rename this file's path (sol/<env>/<provider>/<region>.yml) to your real
# deployment target, and set the SOL_TARGET repository variable in GitHub
# (used by .github/workflows/deploy.yml) to match.
#
# target:
#   registry: <your-registry-url>
|tpl}
;;

(* ── Workspace scaffold templates ─────────────────────────────────────────── *)

(* events/payments/charged.ml — satisfies Kafka_service.MESSAGE *)
let ws_charged_ml =
  {tpl|type t = {
  id             : string;
  amount_cents   : int;
  customer_id    : string;
  currency       : string;
  correlation_id : string;
}

let topic_name = Kafka_service.topic_name_exn "{{name}}-payments-charges"

let schema = {|{
  "type": "object",
  "properties": {
    "id":             { "type": "string"  },
    "amount_cents":   { "type": "integer" },
    "customer_id":    { "type": "string"  },
    "currency":       { "type": "string"  },
    "correlation_id": { "type": "string"  }
  },
  "required": ["id", "amount_cents", "customer_id", "currency", "correlation_id"]
}|}

let encode t = `Assoc [
  ("id",             `String t.id);
  ("amount_cents",   `Int    t.amount_cents);
  ("customer_id",    `String t.customer_id);
  ("currency",       `String t.currency);
  ("correlation_id", `String t.correlation_id);
]

let required_string fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _              -> Error (name ^ " must be a string")
  | None                -> Error (name ^ " is required")

let required_int fields name =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Ok value
  | Some _            -> Error (name ^ " must be an integer")
  | None              -> Error (name ^ " is required")

let ( let* ) = Result.bind

let decode = function
  | `Assoc fields ->
    let* id = required_string fields "id" in
    let* amount_cents = required_int fields "amount_cents" in
    let* customer_id = required_string fields "customer_id" in
    let* currency = required_string fields "currency" in
    let* correlation_id = required_string fields "correlation_id" in
    Ok { id; amount_cents; customer_id; currency; correlation_id }
  | _ -> Error "expected object"
|tpl}
;;

(* events/payments/dune *)
let ws_events_dune =
  {tpl|(library
 (name {{name}}_payments_events)
 (wrapped false)
 (modules Charged)
 (libraries kafka-eio-service yojson))
|tpl}
;;

(* lib/notification.ml — shared storage module *)
let ws_notification_ml =
  {tpl|(* Notification storage — generated by sol new workspace.
   Run `sol migrate` to create the table in the cluster. *)

let insert_q =
  Caqti_request.Infix.(Caqti_type.(t4 string string int string) ->. Caqti_type.unit)
    "INSERT INTO {{name}}_notifications \
     (charge_id, customer_id, amount_cents, currency) \
     VALUES (?, ?, ?, ?)"

let list_q =
  Caqti_request.Infix.(Caqti_type.unit ->* Caqti_type.(t4 string string int string))
    "SELECT charge_id, customer_id, amount_cents, currency \
     FROM {{name}}_notifications \
     ORDER BY created_at DESC LIMIT 20"

let insert pool ~charge_id ~customer_id ~amount_cents ~currency =
  Pg_db.exec pool insert_q (charge_id, customer_id, amount_cents, currency)

let list_recent pool =
  Pg_db.collect pool list_q ()
|tpl}
;;

(* lib/dune — shared storage library *)
let ws_storage_dune =
  {tpl|(library
 (name {{name}}_storage)
 (wrapped false)
 (modules Notification)
 (libraries pg-eio caqti))
|tpl}
;;

(* app/payments/charge_svc/lib/handler.ml *)
let ws_svc_handler_ml =
  {tpl|(* POST /charges  — publish Charged to Kafka
   GET  /health      — liveness probe
   GET  /notifications — list notifications written by notify_worker *)

(* FRIC-026: seed the RNG once. Without this the charge id is a fixed
   sequence per process start, so ids repeat across restarts. *)
let () = Random.self_init ()

let routes pool ~publish_charged ~obs = [
  Route.get "/health" ~auth:`Public (fun _req ->
    Response.ok "ok"
  );
  Route.post "/charges" ~auth:`Public (fun req ->
    let required_string json name =
      match Yojson.Basic.Util.member name json with
      | `String value -> Ok value
      | `Null         -> Error (name ^ " is required")
      | _             -> Error (name ^ " must be a string")
    in
    let required_int json name =
      match Yojson.Basic.Util.member name json with
      | `Int value -> Ok value
      | `Null      -> Error (name ^ " is required")
      | _          -> Error (name ^ " must be an integer")
    in
    let decode_charge json =
      Result.bind (required_string json "customer_id") @@ fun customer_id ->
      Result.bind (required_int json "amount_cents") @@ fun amount_cents ->
      Result.map
        (fun currency -> customer_id, amount_cents, currency)
        (required_string json "currency")
    in
    let parsed =
      try Ok (Yojson.Basic.from_string req.body)
      with Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)
    in
    match Result.bind parsed decode_charge with
    | Error msg ->
      Response.bad_request msg
    | Ok (customer_id, amount_cents, currency) ->
      Sol_obs.with_span obs ?parent:req.trace_ctx "charges" (fun sp ->
        let charge_id = Printf.sprintf "ch_%06d" (Random.int 999999) in
        let event : Charged.t = {
          id             = charge_id;
          customer_id;
          amount_cents;
          currency;
          correlation_id = Option.value (Request.header req "x-correlation-id")
                             ~default:charge_id;
        } in
        Sol_obs.log sp Sol_obs.Info
          ~fields:[("charge_id", charge_id); ("customer_id", customer_id)]
          "charge accepted";
        match publish_charged event with
        | Ok () ->
          Response.json ~status:202
            (Printf.sprintf {|{"id":"%s","accepted":true}|} charge_id)
        | Error msg ->
          Response.internal_error ("publish failed: " ^ msg))
  );
  Route.get "/notifications" ~auth:`Public (fun _req ->
    match Notification.list_recent pool with
    | Error _  -> Response.json ~status:500 {|{"error":"db unavailable"}|}
    | Ok rows  ->
      let row_json (charge_id, customer_id, amount_cents, currency) =
        `Assoc [
          ("charge_id",    `String charge_id);
          ("customer_id",  `String customer_id);
          ("amount_cents", `Int amount_cents);
          ("currency",     `String currency);
        ]
      in
      Response.json (Yojson.Basic.to_string (`List (List.map row_json rows)))
  );
]
|tpl}
;;

(* app/payments/charge_svc/lib/dune *)
let ws_svc_lib_dune =
  {tpl|(library
 (name {{name}}_payments_charge_svc)
 (wrapped false)
 (modules Handler)
 (libraries {{name}}_storage {{name}}_payments_events sol-svc sol-obs yojson))
|tpl}
;;

(* app/payments/charge_svc/bin/main.ml *)
let ws_svc_bin_ml =
  {tpl|let fatal msg =
  prerr_endline ("error: " ^ msg);
  exit 1

let require_kafka label = function
  | Ok value -> value
  | Error e  -> fatal (label ^ ": " ^ Kafka_service.error_to_string e)

let require_db_pool ~sw ~stdenv =
  match Pg_db.of_env ~sw ~stdenv () with
  | Ok pool -> pool
  | Error e -> fatal ("db pool: " ^ Pg_error.to_string e)

let () =
  let kafka_config = Kafka_service.config_of_env () |> require_kafka "kafka config" in
  Eio_main.run @@ fun env ->
  let obs =
    Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
      ~service:"{{name}}-charge-svc" ~context:[("team", "payments")] ()
  in
  Eio.Switch.run @@ fun sw ->
  let pool = require_db_pool ~sw ~stdenv:(env :> Caqti_eio.stdenv) in
  let kafka = Kafka_service.create kafka_config ~sw |> require_kafka "kafka create" in
  let charged_topic =
    Kafka_service.register kafka ~net:env#net ~clock:env#clock (module Charged)
    |> require_kafka "kafka register"
  in
  let publish_charged event =
    match Eio.Promise.await (Kafka_service.publish kafka charged_topic event) with
    | Ok () -> Ok ()
    | Error e -> Error (Kafka.Error.to_string e)
  in
  Service.run (Handler.routes pool ~publish_charged ~obs) ~env
    ~ot:obs ()
  |> Result.map_error Service.run_error_to_string
  |> function Ok () -> () | Error e -> fatal e
|tpl}
;;

(* app/payments/charge_svc/bin/dune *)
let ws_svc_bin_dune =
  {tpl|(executable
 (name main)
 (libraries
  {{name}}_payments_charge_svc
  sol-svc kafka-eio-service sol-obs
  pg-eio caqti-eio caqti-eio.unix caqti-driver-postgresql
  eio_main))
|tpl}
;;

(* app/comms/notify_worker/lib/notify_worker.ml — satisfies
   Worker.RETRYABLE_WORKER (it can return Worker.Retry on a DB failure, so
   it isn't Ack-only). Run via Worker.Make_with_retry with an explicit
   ~retry_strategy. *)
let ws_worker_ml =
  {tpl|(* Inject pool and observability handle via functor so there's no mutable state.
   Worker.Make_with_retry requires module Message, group_id, and handle inside
   the functor. *)
module Make (Config : sig
  val pool : Pg_db.pool
  val obs  : Sol_obs.t
end) = struct

  module Message = Charged

  let group_id = "{{name}}-comms-notify-worker"

  let handle (msg : Message.t) ~trace_ctx:_ : Worker.outcome =
    Sol_obs.log_info Config.obs
      ~fields:[("charge_id", msg.id); ("customer_id", msg.customer_id);
               ("amount_cents", string_of_int msg.amount_cents)]
      "charge event received";
    match Notification.insert Config.pool
            ~charge_id:msg.id ~customer_id:msg.customer_id
            ~amount_cents:msg.amount_cents ~currency:msg.currency with
    | Ok ()   -> Worker.Ack
    | Error e ->
      Sol_obs.log_error Config.obs
        ~fields:[("error", Pg_error.to_string e)]
        "db insert failed";
      Worker.Retry (Pg_error.to_string e)

end
|tpl}
;;

(* app/comms/notify_worker/lib/dune *)
let ws_worker_lib_dune =
  {tpl|(library
 (name {{name}}_comms_notify)
 (wrapped false)
 (modules Notify_worker)
 (libraries
  {{name}}_storage {{name}}_payments_events
  sol-worker kafka-eio-service sol-obs pg-eio))
|tpl}
;;

(* app/comms/notify_worker/bin/main.ml *)
let ws_worker_bin_ml =
  {tpl|let fatal msg =
  prerr_endline ("error: " ^ msg);
  exit 1

let require_db_pool ~sw ~stdenv =
  match Pg_db.of_env ~sw ~stdenv () with
  | Ok pool -> pool
  | Error e -> fatal ("db pool: " ^ Pg_error.to_string e)

let require_kafka label = function
  | Ok value -> value
  | Error e  -> fatal (label ^ ": " ^ Kafka_service.error_to_string e)

let () =
  let kafka_config = Kafka_service.config_of_env () |> require_kafka "kafka config" in
  Eio_main.run @@ fun env ->
  let obs =
    Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
      ~service:"{{name}}-notify-worker" ~context:[("team", "comms")] ()
  in
  Eio.Switch.run @@ fun sw ->
  let pool = require_db_pool ~sw ~stdenv:(env :> Caqti_eio.stdenv) in
  let module W = Notify_worker.Make(struct
    let pool = pool
    let obs  = obs
  end) in
  let module WR = Worker.Make_with_retry(W) in
  WR.run ~env ~config:kafka_config
    ~retry_strategy:(Worker.In_memory Kafka.Consumer.default_retry)
    ~ot:obs ()
  |> Result.map_error Worker.run_error_to_string
  |> function Ok () -> () | Error msg -> fatal msg
|tpl}
;;

(* app/comms/notify_worker/bin/dune *)
let ws_worker_bin_dune =
  {tpl|(executable
 (name main)
 (libraries
  {{name}}_comms_notify sol-worker kafka-eio-service sol-obs
  pg-eio caqti-eio caqti-eio.unix caqti-driver-postgresql
  eio_main))
|tpl}
;;

(* db/migrations/0001_notifications.sql *)
let ws_migration_sql =
  {tpl|CREATE TABLE IF NOT EXISTS {{name}}_notifications (
  id           BIGSERIAL    PRIMARY KEY,
  charge_id    TEXT         NOT NULL,
  customer_id  TEXT         NOT NULL,
  amount_cents INTEGER      NOT NULL,
  currency     TEXT         NOT NULL DEFAULT 'usd',
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
|tpl}
;;

(* db/migrations/0001_notifications.down.sql *)
let ws_migration_down_sql =
  {tpl|DROP TABLE IF EXISTS {{name}}_notifications;
|tpl}
;;

(* test/test_schemas.ml — schema compatibility CI gate *)
let ws_test_schemas_ml =
  {tpl|(* Schema backward-compatibility check — generated by sol new workspace.
   Run against a live schema registry: SCHEMA_REGISTRY_URL=http://... dune test
   If SCHEMA_REGISTRY_URL is not set the test is skipped (safe for unit CI). *)
let () =
  match Sys.getenv_opt "SCHEMA_REGISTRY_URL" with
  | None ->
    Printf.printf "SCHEMA_REGISTRY_URL not set — skipping schema compat check\n%!"
  | Some registry_url ->
    Eio_main.run (fun env ->
      match Kafka_service.Schema.check_all
              ~net:env#net
              ~clock:env#clock
              ~registry_url
              [ (module Charged) ]
      with
      | Ok () ->
        Printf.printf "schema compatibility: ok\n%!"
      | Error e ->
        Printf.eprintf "schema compatibility FAILED: %s\n%!" (Kafka_service.error_to_string e);
        exit 1
    )
|tpl}
;;

(* test/dune *)
let ws_test_dune =
  {tpl|(executable
 (name test_schemas)
 (libraries kafka-eio-service eio_main {{name}}_payments_events))
|tpl}
;;

(* ── Generic primitive templates ──────────────────────────────────────────── *)

(* Generic svc: lib/handler.ml *)
let svc_handler_ml =
  {tpl|let routes = [
  Route.get "/health" ~auth:`Public (fun _req ->
    Response.ok "ok"
  );
]
|tpl}
;;

(* Generic svc: lib/dune *)
let svc_lib_dune =
  {tpl|(library
 (name {{lib}})
 (wrapped false)
 (modules Handler)
 (libraries sol-svc))
|tpl}
;;

(* Generic svc: bin/main.ml *)
let svc_bin_ml =
  {tpl|let fatal msg =
  prerr_endline ("error: " ^ msg);
  exit 1

let () = Eio_main.run @@ fun env ->
  let obs =
    Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
      ~service:"{{name}}-svc" ()
  in
  Service.run Handler.routes ~env ~ot:obs ()
  |> Result.map_error Service.run_error_to_string
  |> function Ok () -> () | Error e -> fatal e
|tpl}
;;

(* Generic svc: bin/dune *)
let svc_bin_dune =
  {tpl|(executable
 (name main)
 (libraries {{lib}} sol-svc sol-obs eio_main))
|tpl}
;;

(* Generic worker: lib/<name>_worker.ml — satisfies Worker.WORKER; replace the
   stub Message with your event module. *)
let worker_lib_ml =
  {tpl|(* Replace Message with your event module, e.g.:
     module Message = My_team_events.My_event *)
module Message = struct
  type t = { id : string }
  let topic_name = Kafka_service.topic_name_exn "{{domain}}-{{name}}-events"
  let schema = {|{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}|}
  let encode t = `Assoc [("id", `String t.id)]
  let required_string fields name =
    match List.assoc_opt name fields with
    | Some (`String value) -> Ok value
    | Some _              -> Error (name ^ " must be a string")
    | None                -> Error (name ^ " is required")
  let ( let* ) = Result.bind
  let decode = function
    | `Assoc fields ->
      let* id = required_string fields "id" in
      Ok { id }
    | _ -> Error "expected object"
end

let group_id = "{{domain}}-{{name}}-worker"

let handle (msg : Message.t) ~trace_ctx:_ =
  Printf.printf "[{{name}}-worker] received id=%s\n%!" msg.id;
  (* Add side effects here, then return Worker.Ack. The worker acknowledges
     (commits the offset) for you, only after this returns Worker.Ack — there is
     no ack to call.
     This is an Ack-only worker: it has no retry capability, so a failed side
     effect here has nowhere to go but a raised exception. If you need retry
     or dead-letter handling, change Message.t's module to implement
     Worker.RETRYABLE_WORKER (handle returning Worker.outcome, i.e.
     Worker.Ack | Worker.Retry _ | Worker.Dead_letter _) and run it with
     Worker.Make_with_retry, which requires an explicit ~retry_strategy. *)
  Worker.Ack
|tpl}
;;

(* Generic worker: lib/dune *)
let worker_lib_dune =
  {tpl|(library
 (name {{lib}})
 (wrapped false)
 (modules {{Mod}})
 (libraries sol-worker kafka-eio-service yojson))
|tpl}
;;

(* Generic worker: bin/main.ml *)
let worker_bin_ml =
  {tpl|let fatal msg =
  prerr_endline ("error: " ^ msg);
  exit 1

let require_kafka label = function
  | Ok value -> value
  | Error e  -> fatal (label ^ ": " ^ Kafka_service.error_to_string e)

let () = Eio_main.run @@ fun env ->
  let config = Kafka_service.config_of_env () |> require_kafka "kafka config" in
  let obs =
    Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
      ~service:"{{name}}-worker" ()
  in
  let module W = Worker.Make({{Mod}}) in
  W.run ~env ~config ~ot:obs ()
  |> Result.map_error Worker.run_error_to_string
  |> function Ok () -> () | Error msg -> fatal msg
|tpl}
;;

(* Generic worker: bin/dune *)
let worker_bin_dune =
  {tpl|(executable
 (name main)
 (libraries {{lib}} sol-worker kafka-eio-service sol-obs eio_main))
|tpl}
;;

(* Generic fn: lib/<name>_fn.ml — satisfies Fn.FN *)
let fn_lib_ml =
  {tpl|(* The schedule lives in this workload's sol.toml ([service] schedule). *)
let trigger = Fn.Cron

let run () =
  Printf.printf "[{{name}}-fn] running\n%!";
  Ok ()
|tpl}
;;

(* Generic fn: lib/dune *)
let fn_lib_dune =
  {tpl|(library
 (name {{lib}})
 (wrapped false)
 (libraries sol-fn)
 (modules {{Mod}}))
|tpl}
;;

(* Generic fn: bin/main.ml *)
let fn_bin_ml =
  {tpl|let fatal msg =
  prerr_endline ("error: " ^ msg);
  exit 1

let () = Eio_main.run @@ fun env ->
  let obs =
    Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
      ~service:"{{name}}-fn" ()
  in
  let module F = Fn.Make({{Mod}}) in
  match F.run ~env ~ot:obs () with
  | Ok () -> ()
  | Error `Signalled -> exit 130
  | Error e -> fatal (Fn.run_error_to_string e)
|tpl}
;;

(* Generic fn: bin/dune *)
let fn_bin_dune =
  {tpl|(executable
 (name main)
 (libraries {{lib}} sol-fn sol-obs eio_main))
|tpl}
;;

(* Generic event: <name>.ml — satisfies Kafka_service.MESSAGE *)
let event_ml =
  {tpl|type t = {
  id      : string;
  payload : string;
}

let topic_name = Kafka_service.topic_name_exn "{{team}}-{{name}}s"

let schema = {|{
  "type": "object",
  "properties": {
    "id":      { "type": "string" },
    "payload": { "type": "string" }
  },
  "required": ["id", "payload"]
}|}

let encode t = `Assoc [
  ("id",      `String t.id);
  ("payload", `String t.payload);
]

let required_string fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _              -> Error (name ^ " must be a string")
  | None                -> Error (name ^ " is required")

let ( let* ) = Result.bind

let decode = function
  | `Assoc fields ->
    let* id = required_string fields "id" in
    let* payload = required_string fields "payload" in
    Ok { id; payload }
  | _ -> Error "expected object"
|tpl}
;;
