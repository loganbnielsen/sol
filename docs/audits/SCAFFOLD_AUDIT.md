# Sun Framework: Scaffold Quality Audit

This is a reusable audit template. When performing an audit, create fresh scaffolded workspaces/services/events/functions/workers, verify every generated artifact, and record findings using the format at the bottom. Do not record findings in this file.

**What this audits:** Whether `sun new ...` produces code that compiles immediately, teaches Sun's intended architecture, preserves production defaults, and gives humans and AI agents a predictable working surface.

**Scaffold standard:** Generated code is product code. A bad pattern in a template becomes the default pattern in every startup built on Sun.

---

## 1. Workspace Scaffold

The default workspace should be a complete, multi-domain Sun application that demonstrates the intended model.

**Command:** `sun new workspace <name>`

**Source locations:** `cli/sun/bin/cmd_new.ml` · `cli/sun/lib/sun_cli_scaffold.ml`

### Checklist

* [ ] **Compiles immediately:** Fresh workspace builds with zero errors and zero warnings.
* [ ] **Domain model is clear:** Generated paths use `events/<team>/` and `app/<team>/<name>-<primitive>/` consistently.
* [ ] **Default example crosses domains correctly:** Producer and consumer domains communicate through an event contract, not service internals.
* [ ] **Library names are workspace-namespaced:** Generated dune libraries avoid collisions in monorepos and multi-workspace checkouts.
* [ ] **No obsolete instructions:** Generated README and comments do not reference repo-local scripts, missing commands, or stale workflows.
* [ ] **Generated files are minimal:** The scaffold contains enough to run and understand the app without large unused modules or confusing placeholder files.

---

## 2. Service Scaffold (`-svc`)

HTTP services should expose explicit routes, explicit auth, observability, and framework-owned lifecycle.

**Command:** `sun new svc <domain>/<name>`

### Checklist

* [ ] **Uses `Sun.Service.Make`:** Generated entrypoint delegates lifecycle, metrics, health, and graceful shutdown to the framework.
* [ ] **Auth is explicit on every route:** No route relies on path naming conventions or hidden defaults for auth.
* [ ] **Handlers return typed responses:** Generated handlers use Sun request/response types and avoid naked exceptions for normal control flow.
* [ ] **Metrics and tracing are wired by the framework:** The template does not require manual instrumentation for baseline telemetry.
* [ ] **Naming follows conventions:** File paths, module names, Kubernetes names, and service labels derive predictably from workspace/domain/service.
* [ ] **Business logic is local:** The handler module is the obvious edit point and does not manipulate infrastructure directly.

---

## 3. Worker Scaffold (`-worker`)

Workers are the cross-domain event processing primitive. Their defaults must preserve at-least-once semantics and clear event ownership.

**Command:** `sun new worker <domain>/<name>`

### Checklist

* [ ] **Uses `Sun.Worker.Make`:** Generated entrypoint delegates Kafka lifecycle, schema registration, metrics, shutdown, and retry behavior to the framework.
* [ ] **Consumes event contracts, not services:** Template imports message contracts from `events/<publishing-team>/`, never from a producer service implementation.
* [ ] **Acks after side effects:** Generated handler calls `ack()` only after all business side effects succeed.
* [ ] **Failure path does not ack:** Handler errors return `Error` or equivalent without committing the offset.
* [ ] **Consumer group is stable and owned:** `group_id` includes workspace/domain/worker identity and does not depend on mutable deployment metadata.
* [ ] **Trace context is accepted:** Handler shape includes trace context when the framework supports it.

---

## 4. Function Scaffold (`-fn`)

Scheduled functions should be small, explicit units of business work with framework-managed invocation telemetry.

**Command:** `sun new fn <domain>/<name>`

### Checklist

* [ ] **Uses `Sun.Fn.Make`:** Generated entrypoint delegates invocation lifecycle and metrics push behavior to the framework.
* [ ] **Schedule is explicit:** Cron schedule is visible in the function module or generated config according to the current framework contract.
* [ ] **Run result is explicit:** `run` returns a result value; normal failures are not represented by exceptions.
* [ ] **No long-running service assumptions:** Template exits after one invocation and does not depend on HTTP or worker lifecycles.
* [ ] **Generated CronJob config is synthesized:** The user does not hand-write Kubernetes CronJob YAML.

---

## 5. Event Scaffold

Events are Sun's cross-domain contract. The scaffold must make ownership and compatibility obvious.

**Command:** `sun new event <domain>/<name>`

### Checklist

* [ ] **Event lives under publishing domain:** File path is `events/<domain>/<name>.ml`.
* [ ] **Satisfies message contract:** Generated module compiles against the Kafka service `MESSAGE` module type.
* [ ] **Topic naming is stable:** Topic name includes workspace and publishing domain identity.
* [ ] **Schema is explicit and readable:** Generated schema is visible, valid, and tied to the event type.
* [ ] **Compatibility path is documented:** Generated docs or tests show how to catch breaking changes before deploy.
* [ ] **No service implementation dependency:** Event modules do not import app service modules.

---

## 6. Storage and Migration Scaffold

Storage scaffolding should be explicit, result-based, and workspace-isolated.

### Checklist

* [ ] **Migrations are numbered and idempotent where possible:** Generated SQL follows the documented naming convention and can be applied safely once.
* [ ] **Migration tracking is workspace-isolated:** Generated commands or docs use a workspace-prefixed migrations table when needed.
* [ ] **Storage APIs return results:** Generated storage helpers do not expose naked database exceptions at public boundaries.
* [ ] **Database ownership is understandable:** Shared storage modules are documented enough that cross-domain coupling is visible.
* [ ] **Schema and code agree:** Generated SQL columns match storage helper fields and service/worker payloads.

---

## 7. Deployment Metadata Scaffold

`sun.toml`, Dockerfiles, and generated deployment inputs should preserve Sun defaults while allowing visible overrides.

### Checklist

* [ ] **`sun.toml` is minimal and meaningful:** Defaults are not duplicated unnecessarily, and overrides are high-level rather than raw Kubernetes.
* [ ] **Security defaults are production-aware:** Templates do not hard-code production plaintext secrets, root containers, or insecure Kafka settings.
* [ ] **Dockerfiles are portable:** Generated Dockerfiles match the current container portability policy and do not assume incompatible host/container binaries.
* [ ] **No hand-written manifests:** Scaffolded workspaces do not include per-service Kubernetes YAML as source files.
* [ ] **Override points are visible:** Scale, env, resource, and security override mechanisms are discoverable without reading framework internals.

---

## 8. AI-Agent Working Surface

The scaffold should be easy for an AI agent to modify correctly because names, modules, and contracts are predictable.

### Checklist

* [ ] **Edit points are obvious:** Handler, worker, function, event, migration, and storage files are easy to locate by path and module name.
* [ ] **Templates include local context:** Generated code names dependencies and contracts clearly enough that an agent does not need to infer hidden wiring.
* [ ] **Types catch common drift:** Changing an event or storage shape creates compile-time pressure in affected handlers/workers.
* [ ] **No surprising metaprogramming:** Templates avoid dynamic module loading, hidden code generation, or stringly typed wiring where typed APIs are available.
* [ ] **Verification path is documented:** Generated README tells an agent how to build, run, test, deploy, inspect logs, and roll back with Sun commands.

---

## Executable Runbook

Run this from a clean temporary directory so generated files are easy to inspect.

```bash
sun new workspace scaffold_audit
cd scaffold_audit
eval $(opam env) && dune build

sun new svc payments/refund
sun new worker logistics/fulfillment
sun new fn billing/invoice
sun new event billing/payment_confirmed
eval $(opam env) && dune build
```

**Invariants:**
* [ ] Both builds produce zero warnings and zero errors.
* [ ] New artifacts appear under the expected domain paths.
* [ ] No Kubernetes manifest is added as a source file.
* [ ] Generated docs and code identify the intended edit points.
* [ ] Service, worker, function, event, storage, and migration naming follows Sun conventions.

---

## Findings Log

Record every gap found during this audit run below. Use one entry per finding.

```
### [SCAFFOLD-NNN] — Scaffold / Template Name
* **Category:** Compile | Domain Ownership | Runtime Semantics | Security | Docs | AI-Agent Surface
* **Severity:** Critical | High | Medium | Low
* **Location:** `path/to/template-or-generated-file.ml` (Lines X-Y)
* **Description:** What the scaffold generates and why it violates Sun's conventions or product promise.
* **Impact:** What bad pattern a startup or AI agent would inherit from the template.
* **Remediation:** The concrete template, generated doc, or CLI change required.
```
