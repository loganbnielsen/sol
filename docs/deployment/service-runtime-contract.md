# Service Runtime Contract

[`self-hosted-substrate-contract.md`](self-hosted-substrate-contract.md)
documents what must exist *around* your containers (cluster, registry, Kafka,
secrets). This document covers the other direction: what the code *inside* a
`*_svc`/`*_worker`/`*_fn` directory must actually do — and, for every item,
whether Sol's tooling actually checks it or merely assumes it.

Read both together. They're the complete picture of what Sol requires.

## The core fact to hold onto

Sol is a **naming-convention-driven container orchestrator** with one narrow,
runtime-checked health contract bolted on for `-svc`. Everything else — does
the code inside actually work, does it read the right environment variable
names, does it use Kafka correctly — is entirely developer-trusted. A
violation of any of it surfaces only as an *operational* failure (crash loop,
a probe that never turns green, silently missing metrics), never as a build
or deploy rejection. There is no compiler, schema, or admission check that
verifies a `*_svc` directory actually behaves like a service before Sol
deploys it.

Concretely: replace a generated service's `bin/main.ml` with
`print_endline "hello world"`. `dune build` succeeds. `docker build` succeeds.
`sol deploy`/`kubectl apply` succeeds. The pod then exits immediately, never
binds a port, and every downstream check (readiness probe, `sol status`,
CI's health-poll loop) reports it unhealthy — the *only* place this gets
caught, and only after it's already running.

## Discovery contract — purely structural, content never inspected

`Sol_cli_manifest.discover_services` requires exactly:

- A directory at `app/<domain>/<name>_svc/`, `_worker/`, or `_fn/` — the
  suffix determines the primitive, which determines what Kubernetes object
  wraps it (Deployment+Service for `-svc`, Deployment for `-worker`, CronJob
  for `-fn`, using the `schedule:` field from `sol.toml`).
- A `Dockerfile` present directly in that directory.

That's the entire predicate. Discovery never opens the Dockerfile or any
source file — a directory with the right name and an empty Dockerfile
satisfies it exactly as well as a real, working service does.

## Runtime health contract (`-svc` only) — checked, but only after deploy

The generated Deployment (`sol_cli_manifest_yaml.ml`) declares:

```yaml
ports:
  - containerPort: 8080
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 10
readinessProbe:
  httpGet:
    path: /healthz
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 10
```

| Requirement | Actually checked? | When / how |
|---|---|---|
| Bind an HTTP server on port 8080 | Yes | Kubernetes readiness/liveness probes, post-deploy. `sol status` and CI's golden-path health-poll loop (`curl -sf http://localhost:8080/health`) also depend on this, also post-deploy. |
| Serve `GET /healthz` returning 2xx once ready | Yes | Same probes as above. |
| Serve `GET /metrics` in Prometheus text format | **No hard check anywhere.** | Prometheus scrapes it; a wrong format or missing endpoint produces silently empty/garbage metrics, not an error anyone sees. |
| Handle `SIGTERM` by draining in-flight requests | **No check.** | `sol-svc`'s `Service.run` installs a self-pipe SIGTERM handler with a `drain_timeout_s` (default 30s) before force-cancelling. Ignore SIGTERM entirely and nothing fails — you just get harsher connection drops during rolling deploys, since Kubernetes SIGKILLs after `terminationGracePeriodSeconds` regardless. |

Two details worth being precise about, since they're easy to get subtly
wrong:

- **The port is a hardcoded convention, not an injected one.** `Service.run`
  reads `Sys.getenv_opt "PORT"` and falls back to a default of `8080` if
  unset. The generated Deployment never actually sets a `PORT` environment
  variable — it just declares `containerPort: 8080` and trusts the
  application's own default to match. The `$PORT` override exists as an
  escape hatch (useful if you're not using `sol-svc`'s generated scaffold),
  but nothing in the generated manifest exercises it; the two sides agree by
  convention, not by wiring.
- **The termination grace period is not explicitly set.** The generated
  Deployment has no `terminationGracePeriodSeconds`, so it uses Kubernetes'
  own default of 30 seconds — which happens to equal `Service.run`'s
  `drain_timeout_s` default. If you ever raise `drain_timeout_s` above 30s
  without also raising `terminationGracePeriodSeconds` in a `sol.toml`
  override (if one exists) or generated manifest, Kubernetes will SIGKILL the
  pod before your own drain logic finishes — a real, currently-unguarded
  footgun for anyone customizing this value.

## Config and secret injection — the wiring is real, the naming is trusted

There are two distinct Secret objects per namespace, and only one of them is
actually mounted by any generated workload:

- Both a standard `Deployment` (`deployment_doc`) and an Argo Rollout
  (`rollout_doc`) get `envFrom: secretRef: name: <k8s-name>-secrets` — a
  **per-service** Secret (`sol_cli_manifest_yaml.ml`'s `secret_doc`), e.g.
  `charge-svc-secrets`. Verified by rendering both directly: `rollout_doc`'s
  `envFrom` block is identical to `deployment_doc`'s, same per-service
  `%s-env`/`%s-secrets` names, same indentation — there is no difference at
  all between the two rollout strategies here.
- A separate, fixed-name Secret, `sol-secrets`
  (`Sol_cli_manifest.runtime_secret_name`), currently has **no workload Pod
  consumer at all** in any generated manifest. Its only actual consumer today
  is FRIC-012's in-cluster migration Job, which mounts it directly via
  `envFrom`. A comment in `sol_cli_secret.ml` describes patching it as being
  "for Argo Rollout workloads," but that doesn't match what `rollout_doc`
  currently generates — the comment appears to describe an intent that isn't
  (or isn't yet) wired up in the manifest-rendering code.

`sol secret set` (`sol_cli_secret.ml`) still writes to **both** objects on
every call: it patches the shared `sol-secrets` Secret, then patches every
per-service `<name>-secrets` Secret it finds in the namespace
(`patch_workload_secrets`), then triggers a rollout restart. Given the above,
only the per-service patch currently has any effect on a running workload —
the `sol-secrets` write updates an object nothing reads except the migration
Job.

This is real, mechanical wiring in both directions — but what's **not**
checked in either case is that your application code actually reads the
environment variable by the name Sol/you expect (`POSTGRES_URL`,
`KAFKA_BROKERS`, `SCHEMA_REGISTRY_URL`, etc.). Typo the name in your own code
and nothing fails until the connection you expected to work doesn't, at
runtime.

## Migration file convention — filenames only, SQL content unchecked

`sol migrate --dry-run` (`cmd_migrate.ml`'s `print_pending_sql`) previews
`db/migrations/*.sql` with a raw lexicographic filename sort, skipping
`*.down.sql`. The path that actually determines applied order is different
and more specific: `sol migrate apply` delegates to the external `pg-eio`
package's `Migration` module, which parses each filename as
`<integer version>_<name>.sql` and sorts numerically on the parsed integer —
not on the filename string. These two orderings only coincide because
migration filenames are conventionally zero-padded (`0001_...`, `0002_...`);
a non-padded scheme could make the dry-run preview and the real applied order
disagree. Either way, the SQL content itself is never validated by Sol or
`pg-eio` — only by whatever the database driver accepts or rejects when it
actually runs.

## What genuinely *is* compiler-enforced — and the real scope of that

Some things really are type-checked, but only because a developer chose to
construct a specific library's types — Sol's tooling never verifies that
choice was made at all:

- `Kafka_security.t` is a required field on every `kafka-eio` producer,
  consumer, and service config type. If you build one of those configs, the
  compiler forces you to state a security posture. Nothing stops a container
  from talking to Kafka a completely different way (a raw client, a different
  library) that never constructs this type at all — Sol's orchestration layer
  has no visibility into that choice either way.
- `sol-svc`'s `Route` DSL enforces that auth is declared per route, at the
  point you write `Route.get`/`Route.post` calls using it. This is real,
  useful, and entirely internal to code that opts into the DSL. A `*_svc`
  directory that never touches `sol-svc` at all is invisible to this
  enforcement, and indistinguishable to Sol's discovery/deploy tooling from
  one that uses it correctly.

## Synchronous service calls

Cross-domain events are the default integration path. A synchronous
service-to-service request is an explicit opt-in:

```toml
[service]
calls = ["checkout/checkout_svc"]
```

That declaration makes Sol inject `CHECKOUT_SVC_URL` into the caller and opens
the generated NetworkPolicy only for that caller/target pair. Application code
should use `Peer` for the URL/header plumbing and ordinary
`cohttp-eio` for the request:

```ocaml
Sol_obs.with_span obs ?parent:req.trace_ctx "call_checkout" (fun span ->
  let trace_ctx = Sol_obs.current_trace_context span in
  match Peer.url "checkout_svc", Peer.headers ~env ~trace_ctx () with
  | Ok base_uri, Ok headers ->
    let uri = Uri.with_path base_uri "/quote" in
    let headers = Http.Header.of_list headers in
    Cohttp_eio.Client.call client ~sw ~headers `GET uri
  | Error err, _ | _, Error err -> ...)
```

**Dev-substrate caveat:** the generated policy is correct per the Kubernetes
spec, but the local dev substrate's policy engine (kube-router on k3d/k3s
v1.27) does not enforce cross-namespace `namespaceSelector` rules, so a declared
call is refused locally even though it is wired correctly. Customer-cloud
clusters are unaffected. See BUG-022 for the reproduction; the golden-path smoke
asserts the wiring (injected URL plus the applied policy pair) rather than live
enforcement.

`Peer.headers` sets `x-api-key` from `SOL_API_KEY_FILE`/`SOL_API_KEY` and
serializes the supplied `trace_ctx` as a W3C `traceparent`. The callee's
`Sol_svc` extracts that header into `Request.trace_ctx`.

Routes that use `` `Api_key`` auth expect the caller to send `x-api-key`.
`sol-svc` reads the expected value from `SOL_API_KEY_FILE` first, then
`SOL_API_KEY`. Sol emits `SOL_API_KEY` in the generated Secret with an empty
placeholder value, so operators can provide one shared internal key through
the normal Secret or ExternalSecret path.

## Summary

| Layer | Enforced by | When |
|---|---|---|
| Directory naming + Dockerfile presence | `discover_services` (string/filesystem check) | Before deploy — determines *what gets generated*, not whether it's correct |
| Port bound, `/healthz` responds | Kubernetes probes, `sol status`, CI health-poll | After deploy, repeatedly |
| `/metrics` format | Nothing | Never — silent failure only |
| SIGTERM drain | Nothing | Never — degrades gracefully into a harder kill, no error |
| Env var names read correctly | Nothing | Never — surfaces as a runtime connection failure |
| Migration SQL correctness | The database itself | At apply time, via whatever error the driver returns |
| Kafka security config shape | OCaml compiler | Only if code constructs `kafka-eio`'s types directly |
| Per-route auth declaration | OCaml compiler | Only if code uses `sol-svc`'s `Route` DSL |
| Service call NetworkPolicy | `sol.toml` `calls` declaration | Only for explicitly declared caller/target pairs |

If you're building anything on top of Sol that generates code or containers
on a user's behalf (a UI, a codegen tool), this table is the actual safety
net you're relying on — and everywhere it says "nothing," that's a real gap,
not an oversight to route around.
