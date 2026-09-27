# {{Name}}

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
  bash /path/to/sol/platform/local/scripts/prepare-framework-deps.sh
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
