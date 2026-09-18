<p align="center">
  <img src="./docs/assets/sol-logo.png" alt="Sol" width="300">
</p>

# Sol

Sol is an open-source software factory for backend systems. Write domain logic in **OCaml or TypeScript** — both are first-class application languages on one language-neutral platform. Sol scaffolds, builds, packages, observes, and deploys either, against a single contract: the same schema-registry conventions, trace propagation, metric vocabulary, retry/DLQ semantics, and deploy lifecycle, in every language. OCaml is the deepest-supported path and where Sol's architecture is proven; TypeScript is the broadest on-ramp for backend developers. (Sol's own CLI and platform are written in OCaml, and are language-neutral in what they do.) Its conventions are regular enough that AI coding agents produce correct output without touching Kubernetes internals, and OCaml's type system (no null, errors as values, exhaustive pattern matching, Eio's structured concurrency) catches entire classes of bugs before they ship.

---

## What it looks like

```ocaml
(* app/payments/charge_svc/lib/handler.ml — routes, trimmed *)
let routes pool = [
  Route.get "/health" ~auth:`Public (fun _req -> Response.ok "ok");
  Route.post "/charges" ~auth:`Public (fun req -> (* validate req.body, then: *)
    match Notification.insert pool ~charge_id ~customer_id ~amount_cents ~currency with
    | Ok ()   -> Response.json ~status:202 (Printf.sprintf {|{"id":"%s","accepted":true}|} charge_id)
    | Error e -> Response.internal_error ("db insert failed: " ^ Pg_error.to_string e));
]
```

```ocaml
(* bin/main.ml — the entrypoint, trimmed: env/observability/db-pool setup omitted *)
let () = Eio_main.run @@ fun env ->
  (* ... build `obs` (observability handle) and `pool` (DB pool) here ... *)
  Service.run (Handler.routes pool) ~env ~ot:obs ()
  |> Result.map_error Service.run_error_to_string
  |> function Ok () -> () | Error e -> failwith e
```

Sol owns the server lifecycle, graceful shutdown, structured logging, metrics, tracing, packaging, and deployment. You write routes, handlers, and domain logic.

---

## Quickstart

**Prerequisites:** k3d, Helm, Docker, kubectl, and `librdkafka-dev`/`libpq-dev`/`libpq5`.

```bash
# Install (Linux x86_64) — replace vX.Y.Z with the latest release:
# https://github.com/loganbnielsen/sol/releases
curl -L https://github.com/loganbnielsen/sol/releases/latest/download/sol-vX.Y.Z-linux-x86_64.tar.gz | tar xz
export PATH="$PWD/sol-vX.Y.Z-linux-x86_64/bin:$PATH"

sol local infra up        # local cluster: Redpanda, PostgreSQL, Loki, Prometheus, Grafana
sol new workspace pluto
cd pluto
sol up                  # build + deploy
sol local status

curl localhost:8080/health
# ok
```

That's a real HTTP service, backed by a Kafka worker and PostgreSQL, with logs and metrics already flowing. Continue with the **[Tutorial](docs/guides/TUTORIAL.md)** for the full walkthrough — publishing events, database migrations, Grafana dashboards, production deploys, and rollbacks.

### Building from source (contributors)

The tarball above is the supported install. Building `sol` from a checkout needs
a little more, and none of it is covered by `dune build` alone:

- **OCaml 5.4.1 or newer.** `dune-project` requires `ocaml >= 5.4.0`. Refresh the
  opam index first (`opam update`) — a stale index does not know about 5.4.1 — then
  `opam switch create 5.4.1` and `opam install dune` (a fresh switch has no dune).
- **System packages:** `librdkafka-dev libpq-dev libpq5 build-essential pkg-config`.
- **Eleven external `*-eio` packages.** `sol.opam` depends on `kafka-eio`,
  `obs-eio`, `obs-loki-eio`, `obs-prometheus-eio`, `obs-tempo-eio`, `pg-eio`,
  `aws-eio`, `s3-eio`, `dynamodb-eio`, `lambda-eio`, and `https-eio`. Several are
  not on opam yet, so pin them from source first, e.g.
  `opam pin add kafka-eio https://github.com/loganbnielsen/kafka-eio.git`
  (repeat per package), then `opam install --deps-only --with-test .`.
- **Build:** `dune build cli/sol/bin/main.exe`; the binary lands at
  `_build/default/cli/sol/bin/main.exe`.

**[`docs/dogfood/DOGFOOD.md`](docs/dogfood/DOGFOOD.md)** has the full
local-substrate walkthrough, including the exact dependency commands.

---

## What Sol handles

- **Kafka** — topic provisioning, schema registration, Confluent wire format, producer/consumer lifecycle
- **HTTP** — REST routing, middleware, request/response types
- **Storage** — PostgreSQL via caqti, typed table functor, migrations
- **Observability** — structured logs to Loki, metrics to Prometheus, Grafana dashboards, wired automatically
- **Deployment** — Kubernetes manifests, Terraform for cloud infrastructure, Argo CD for GitOps, CI workflow references

You write domain logic. Sol handles the factory work: scaffold, build, package, deploy, observe, inspect, roll back.

---

## Application model

A Sol workspace organizes services by domain team, with typed events as the only contract between them. `sol new workspace` scaffolds an `-svc` and a `-worker`; `sol new fn`/`sol new worker`/`sol new svc` add more as a workspace grows:

```
myapp/
  events/payments/charged.ml     ← event contract, owned by the publishing team
  app/
    payments/charge_svc/         ← REST API service   (-svc)
    comms/notify_worker/         ← Kafka consumer      (-worker)
    billing/invoice_fn/          ← scheduled function  (-fn)
  db/migrations/
  dune-project
```

`-svc` is a REST API service, `-worker` is a Kafka consumer, `-fn` is a scheduled function — the three primitives every domain team builds with. Teams don't share code across domains; they publish and subscribe to typed Kafka events, enforced at the wire level by Sol's schema registry integration.

See [Product Architecture](docs/architecture/PRODUCT_ARCHITECTURE.md) for the full factory model and design principles.

### TypeScript

TypeScript is a first-class application language: the same application model
and operational conventions, implemented idiomatically on the Node ecosystem
(`kafkajs`, `pg`, Fastify, `prom-client`) with Sol supplying only the
semantics and integration glue those libraries do not. Today that layer is two
published npm packages:

- [`@sol-fab/kafka`](https://github.com/loganbnielsen/sol-kafka) — Kafka policy
  layer over `kafkajs`: schema-registry ordering/fatality, explicit topic
  provisioning, the Confluent wire format, decode/retry/crash routing, retry/DLQ
  record conventions, and trace propagation.
- [`@sol-fab/obs`](https://github.com/loganbnielsen/sol-obs) — metric names,
  label vocabularies, Loki push shape, and W3C `traceparent` propagation, so TS
  and OCaml workloads land in the same Grafana panels and Tempo traces.

Both are Apache-2.0 and published with build provenance, each in its own public
repository with its own CI — the same extraction pattern used for the OCaml
`*-eio` packages. They are consumed from npm; this repo no longer carries
`packages/`. Releases are tokenless (npm trusted publishing / OIDC).

The runnable showcase is
[`examples/pluto/app/demo_ts`](examples/pluto/app/demo_ts/README.md): a
TypeScript `-svc` and `-worker` deployed by the same Sol CLI and Kubernetes
machinery, exercising a live cross-service, trace-linked Kafka run. It installs
`@sol-fab/*` from npm and is deliberately its own npm project root — it also
serves as the conformance fixture proving a Sol workspace needs no enclosing
JavaScript workspace to consume them (DEC-024).

TypeScript is the adoption on-ramp, and it is being built out to a complete
golden path (`sol new --language typescript` → `sol local up` → `sol deploy`),
not just packages.

---

## Deployment

Sol targets Kubernetes. Run locally against a k3d cluster with `sol up`, or ship to your own AWS/GCP infrastructure with `sol deploy` (direct or GitOps) — the same application model compiles to Kubernetes manifests and Terraform either way. `sol cloud plan/apply` provisions the underlying cluster, registry, and database in your own cloud account; Sol never owns your infrastructure.

See the [Tutorial](docs/guides/TUTORIAL.md), [Factory Pipeline](docs/architecture/devops-pipeline.md), and [deployment escape hatches](docs/deployment/escape-hatches.md) (per-service `sol.toml` overrides) for details.

---

## Status

Sol is under active development and not yet production-stable. HTTP services, Kafka workers, scheduled functions, PostgreSQL, observability, local development, and Kubernetes deployment are implemented and dogfooded end-to-end. Cloud infrastructure provisioning and the AWS integration layer are further along than most other pieces but still experimental.

See [ROADMAP.md](docs/planning/ROADMAP.md) for the current implementation status, layer by layer, and what's planned next.

---

## Repository layout

Sol is a platform, a language-neutral application contract, and first-party
framework implementations of that contract. The first level of the repository
mirrors those concepts:

```text
sol/
├── cli/         # the `sol` CLI and the platform implementation it drives
├── contract/    # the language-neutral application contract (runtime + substrate)
├── framework/   # first-party implementations: OCaml here, TypeScript in sibling repos
├── examples/    # runnable applications that teach the product (start with pluto)
├── docs/        # architecture, deployment, guides, hosting, legal, planning
└── internal/    # maintainer machinery: ci, qualification, pipeline, tooling, fixtures
```

- **Use or manage Sol** → [`cli/`](cli/) and [`contract/`](contract/).
- **Build an application** → [`framework/`](framework/) and [`examples/pluto/`](examples/pluto/).
- **Work on Sol itself** → [`internal/`](internal/) and [`docs/architecture/contributing-map.md`](docs/architecture/contributing-map.md).

## Docs

- [Tutorial](docs/guides/TUTORIAL.md) — full walkthrough, start to finish
- [Contract](contract/README.md) — the language-neutral application contract
- [TypeScript packages](https://github.com/loganbnielsen/sol-kafka) — the published `@sol-fab/kafka` and [`@sol-fab/obs`](https://github.com/loganbnielsen/sol-obs) packages, plus the [`demo_ts`](examples/pluto/app/demo_ts/README.md) showcase
- [Product Architecture](docs/architecture/PRODUCT_ARCHITECTURE.md) — factory model, design principles, ownership lanes
- [Factory Pipeline](docs/architecture/devops-pipeline.md) — what each `sol` command does
- [Deployment escape hatches](docs/deployment/escape-hatches.md) — `sol.toml` reference
- [Roadmap](docs/planning/ROADMAP.md) — current status and what's next
- [Contributor map](docs/architecture/contributing-map.md) — where to make common changes
- Build-from-source, running tests, and the full repo layout: [`.claude/CLAUDE.md`](.claude/CLAUDE.md)

## License

Apache-2.0 — see [LICENSE](LICENSE). The "Sol" name and logo are covered by
[TRADEMARK.md](TRADEMARK.md), not by that licence. Outside contributions are not
being accepted yet — see [CONTRIBUTING.md](CONTRIBUTING.md).

