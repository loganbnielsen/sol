---
id: AUDIT-075
type: audit-finding
severity: medium
source: production-readiness review 2026-09-16 (adversarial Sol-over-Kubernetes review)
---

Deployment-event `actor` field is an arbitrary, unverifiable environment variable

## Program disposition

Deferred beyond maturity A. The first profile requires named cloud/cluster/deploy
identities through AUDIT-072, but organization-grade deployment attribution is a
multi-team guarantee. Promote this ticket for maturity B or when deployment
records are used as an audit control; until then the field must remain documented
as best-effort provenance.

**Depends on:** None.

**Description:** `sol_cli_deployment_attempt.ml:32` sets
`~actor:(Sys.getenv_opt "SOL_ACTOR")` — an arbitrary optional environment
variable, not derived from any verifiable identity (kubeconfig context,
CI OIDC token claim, git committer). `WORK_SUMMARY.md` markets FEAT-070's
deployment-event record as giving provenance ("who/what deployed it"),
but as implemented, anyone can set `$SOL_ACTOR` to any string — including
another person's name — or leave it unset, and the record is silently
incomplete either way.

**Impact:** For a solo operator (maturity A) this is low-stakes. Once a
team shares CI runners or cluster credentials (maturity B), "who deployed
this and can I trust that" becomes a real incident-response and
accountability question, and today's field cannot actually answer it —
worse, it looks like an audit control without being one, which is more
dangerous than having no such field at all (it invites false confidence).

**Remediation:**

1. Prefer a verifiable source when one is available, in priority order:
   a CI-provided identity claim already present in the environment (e.g.
   `GITHUB_ACTOR`/`GITLAB_USER_LOGIN`/an OIDC `sub` claim, whichever the
   invoking CI already exports), then `git config user.email` from the
   workspace repo, then the existing `$SOL_ACTOR` override, then `None`.
2. Keep `$SOL_ACTOR` as an explicit override for cases with no other
   signal, but record which source produced the value (not just the
   value) so `sol deployments` can display it honestly — e.g. distinguish
   "ci:github-actions" / "git:local" / "override:env" / "unknown" —
   rather than presenting every source as equally authoritative.
3. Document plainly (in `docs/architecture/devops-pipeline.md` or
   wherever `sol deployments` is documented) that this field is
   best-effort provenance, not a security control, until a real identity
   system exists.

**Acceptance criteria:**

- A deploy run from a CI environment with a recognizable identity claim
  records that identity automatically, with no `SOL_ACTOR` needed.
- A deploy run with only `SOL_ACTOR` set records it, tagged as an
  override rather than presented identically to a verified source.
- `sol deployments`/`sol_cli_deployment.ml`'s display distinguishes the
  provenance source.

**Demo/example coverage:** Not applicable — CLI/CI-environment behavior,
no app-facing config surface.

**TypeScript-parity note (DEC-022):** No language-parity impact — this is
CLI/deploy-orchestration bookkeeping, independent of the deployed
workload's language.
