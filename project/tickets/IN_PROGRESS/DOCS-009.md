---
id: DOCS-009
type: feature
severity: medium
source: chat discussion 2026-09-07 — questioning whether "compiler-checked correctness" claims about Sol's orchestration were actually accurate
---

**Depends on:** None.

Write the missing half of Sol's contract documentation: what a `*_svc`/`*_worker`/`*_fn` container must actually implement, and — critically — which parts of that Sol's tooling actually checks versus merely assumes.

**Description:** `docs/deployment/self-hosted-substrate-contract.md` already documents the "what must exist around your containers" direction (cluster, registry, Kafka brokers, secrets, DNS) precisely and well. There is no equivalent document for the inverse direction: what the code *inside* a container must do to be a valid Sol service, and which of those requirements are mechanically checked versus purely trusted.

A concrete conversation surfaced how easy it is to overstate what Sol actually verifies. Traced through the real mechanics: `discover_services` is a pure filesystem/naming check (directory suffix + Dockerfile presence) that never reads the code inside; `dune build`/`docker build`/`kubectl apply` all succeed regardless of whether a service does anything real; the only thing ever checked is a narrow, *post-deploy* runtime health contract for `-svc` (does `/healthz` respond, is `$PORT` bound) via Kubernetes probes and `sol status`/CI's own health-poll loop — and even that only fires after a broken service has already been deployed. Everything else (correct env var names, correct Kafka usage, correct business logic) is entirely developer-trusted, with any violation surfacing only as an operational failure (crash loop, failed probe, silent bad behavior), never a build or deploy rejection.

**Impact:** Without this written down explicitly, it's easy (as this conversation demonstrated) to informally overstate what Sol guarantees — e.g. describing "compiler-checked route/auth correctness" as a property of Sol's orchestration layer, when it's actually a property that only holds if a developer chooses to use Sol's framework libraries correctly, which nothing externally verifies. This matters most for anyone designing tooling *on top of* Sol (e.g. a future UI or code generator) who needs to know precisely where the real safety net ends.

**Remediation:** Write `docs/deployment/service-runtime-contract.md` (or similar, matching the existing substrate-contract doc's naming/style), enumerating:
1. The discovery contract (directory naming + Dockerfile presence) and that it is purely structural — content of the container is never inspected.
2. The runtime health contract for `-svc` (`$PORT`, `GET /healthz`, `GET /metrics` in Prometheus format, SIGTERM drain) — and explicitly, for each item, *when* and *how* it's actually checked (post-deploy probes / CI health-poll), not just that it's expected.
3. The config/secret-injection contract (`envFrom` → fixed `sol-secrets` Secret name) and that Sol never verifies the application actually reads the expected env var names.
4. The migration file-naming convention (`db/migrations/*.sql`, `.down.sql` pairing) and that SQL content itself is never validated beyond what the database driver accepts.
5. What genuinely *is* compiler-enforced, and the scope of that enforcement: library-level type contracts (`Kafka_security.t`, `Route`'s auth declarations) that only apply if a developer chooses to construct those specific library types — not anything Sol's tooling verifies externally.
6. A clear closing statement of the actual model: Sol is a naming-convention-driven container orchestrator with one narrow, runtime-checked health contract for `-svc`; everything else is developer-trusted and only surfaces as an operational failure, not a build/deploy-time rejection.

**Acceptance criteria:**
- Every claim in the new doc is verified against the actual current code (`sol_cli_manifest.ml`'s `discover_services`, the generated Deployment/probe YAML, `cmd_migrate.ml`, etc.), not asserted from memory of past conversation.
- The doc is honest about the gap between "what's checked" and "what's merely conventional" for every item — no item should imply stronger enforcement than actually exists.
- Cross-linked from `docs/deployment/self-hosted-substrate-contract.md` (and vice versa), since together they form the complete "what Sol assumes" picture.
