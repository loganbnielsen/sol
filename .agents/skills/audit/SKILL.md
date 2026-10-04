---
name: audit
description: Run a technical production-readiness audit of the Sol codebase. Checks security, runtime correctness, data integrity, and infrastructure synthesis against the principles in internal/pipeline/audits/AUDIT.md. Files each finding it makes as a ticket in internal/pipeline/tickets/READY_FOR_ENGINEERING/.
---

# /audit — Production Readiness Audit

Works through every section of `internal/pipeline/audits/AUDIT.md` by reading the actual source files and verifying each invariant holds. Files each finding it makes as a ticket in `internal/pipeline/tickets/READY_FOR_ENGINEERING/`.

The audit must evaluate both operational readiness and mission alignment: autonomous domain teams, typed event contracts, generated infrastructure, explicit security, framework-owned lifecycles, and AI-agent-friendly conventions.

## Ticket directory structure

```
internal/pipeline/tickets/
  BACKLOG/                  ← captured but not yet ready to act on
  READY_FOR_ENGINEERING/    ← actionable; this is where new findings land
                               (also covers "worktree/PR open" — GitHub's own
                               open-PR/review/CI state tracks that, no local
                               directory duplicates it; see REFAC-077)
  DONE/                     ← merged
```

## Steps

### 1. Read the template
Read `internal/pipeline/audits/AUDIT.md` in full before starting. This is the checklist you will work through.

### 2. Determine today's date
Use the current date for the output filename in `YYYY-MM-DD` format.

### 3. Check previous findings


Check all `internal/pipeline/tickets/` subdirectories for existing AUDIT-* ticket files. A finding already tracked anywhere in `internal/pipeline/tickets/` should not be re-materialised. If a finding exists in `DONE/`, mark it resolved in the report — but verify the fix is still actually live in `main` before trusting that (see EXP-032: a `DONE` ticket's merge can be reverted after the fact and never refixed, leaving the ticket falsely marked resolved). Run `soldev pipeline check-reverts` and treat anything it flags as still-open, not resolved.

### 4. Work through each section

For each checklist item in `internal/pipeline/audits/AUDIT.md`, read the relevant source files and determine whether the invariant passes or fails. Do not rely on memory or assumptions — read the code.

**Section 1 — Local Developer Loop (`cli/bin/`, `cli/lib/base/sol_cli_scaffold.ml`):**
- Read `cmd_new.ml` to verify generated workspaces compile cleanly and library names are workspace-namespaced
- Check `cmd_up.ml` and `cmd_deploy.ml` for failure-path behaviour and rollback

**Section 2 — Infrastructure Synthesis (`cli/lib/workspace/sol_cli_manifest.ml`):**
- Read `sol_cli_manifest.ml` in full
- Check `deployment_doc` and `cronjob_doc` for `runAsNonRoot`, `runAsUser`, `seccompProfile`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation`
- Check `service_doc` for `type: ClusterIP` (not `NodePort`)
- Check `secret_doc` exists and `default_cluster_secrets` contains no plaintext passwords
- Check `network_policy_doc` is included in `render`
- Verify all `Sys.command` calls use `Filename.quote`

**Section 3 — Core Runtime (`~/Code/kafka-eio/kafka-eio-core/lib/kafka_stubs.c`, `~/Code/kafka-eio/kafka-eio-consumer/lib/kafka_consumer.ml` — extracted to the standalone `kafka-eio` opam package, no longer in this repo; `framework/ocaml/sol-worker/lib/worker.ml`, `cli/bin/cmd_new.ml`):**
- Read `kafka_stubs.c` — for every blocking librdkafka call, verify `caml_release_runtime_system()` before and `caml_acquire_runtime_system()` after
- Check `pause_partition` and `resume_partition` for `CAMLparam`/`CAMLreturn`
- Read `kafka_consumer.ml` — verify `acked` ref and warning in both `consume` and `consume_partitioned`
- Read `cmd_new.ml` — verify `ack ()` placement in worker templates
- Read `kafka_service.ml` — verify `produce_await` result is checked before `ack ()`

**Section 4 — Observability (`framework/ocaml/kafka-eio-service/lib/kafka_service.ml`, `framework/ocaml/sol-svc/lib/`):**
- Read `parse_base_url` — verify `https://` is handled
- Read `default_on_decode_error` — check for structured log line, Prometheus counter, dead-letter option

**Sections 8–9 — Mission alignment and framework boundary:**
- Read `README.md`, `docs/ROADMAP.md`, and `docs/guides/TUTORIAL.md` for the stated architecture and user promise
- Read `cmd_new.ml` scaffold templates and the reference workspaces under `internal/fixtures/venus/` / `examples/pluto/`
- Verify event contracts are owned under `events/<team>/` and consumers import contracts, not producer service internals
- Verify generated names and labels preserve workspace/domain/service ownership
- Verify `Sol.Service.Make`, `Sol.Worker.Make`, and `Sol.Fn.Make` own lifecycle concerns in generated apps
- Verify package specs and user-facing docs do not claim commands or guarantees that are unavailable

### 5. File the findings

An audit keeps no report of its own. The ticket tree is the record of every previous pass, so
read it before filing; the report-shaped content below becomes the ticket body:

- the observation and the exact command or line that shows it
- the mechanism, and what the product actually does
- what it would take to fix, and what would make a fix fail (the acceptance criteria)
- the next free `<FAMILY>-NNN`, continuing from the highest id across `internal/pipeline/tickets/`

### 6. Materialise tickets

For each finding:

1. Search all `internal/pipeline/tickets/` subdirectories for `<id>.md`. If found anywhere, skip.
2. If not found, create `internal/pipeline/tickets/READY_FOR_ENGINEERING/<id>.md`:

```markdown
---
id: <AUDIT-NNN>
type: audit-finding
severity: <critical|high|medium|low>
source: the pass that found this, by date
---

<one-line title>

**Description:** <from finding>

**Impact:** <from finding>

**Remediation:** <from finding>
```

Do not set `branch:` or `worktree:` — those are written by `/start` when work begins.
