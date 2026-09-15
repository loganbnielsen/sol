---
id: FEAT-079
type: feature
severity: medium
source: architecture discussion 2026-09-14 (asked "does -fn have a way to one-off
  execute it?", which surfaced that -fn's Kubernetes semantics are entirely
  implicit/hardcoded)
---

**Depends on:** BUG-031.

**Related:** FEAT-076, FEAT-078 (same "no ambient/default substrate behavior
standing in for an explicit Sol decision" principle, applied here to `-fn`'s
generated `CronJob` instead of `sol-worker`'s retry strategy).

Make `-fn`'s Kubernetes concurrency and retry semantics explicit instead of
implicit Kubernetes defaults baked silently into the generated manifest, and
add manual invocation of the deployed function.

## Premise

BUG-031 fixes a separate, narrower defect: `-fn`'s already-parsed
`cpu`/`memory` config is silently discarded at render time. That is a
wiring bug, not a design question, and is split out so it can land (and be
reviewed) on its own. This ticket covers the two genuinely new pieces of
`-fn`'s contract that don't exist in any form yet — `concurrencyPolicy` and
`backoffLimit` — plus manual invocation. Depends on BUG-031 landing first
because both touch the same `cronjob_doc`/`Render_fn` call site; doing them
concurrently would just create an avoidable merge conflict.

## Problem

`-fn` is currently understood as "a convenient abstraction over Kubernetes
CronJobs," but the underlying `Fn.Make(F).run` binary has zero cron
awareness — it is a general run-once-and-exit executable; cron is just the
only invocation mechanism Sol currently wires up
(`framework/sol-fn/lib/fn.mli`). Two Kubernetes-level decisions that change
application-visible behavior are made silently by the manifest generator
(`cli/sol/lib/sol_cli_manifest_yaml.ml`'s `cronjob_doc`), with no Sol-level
representation at all — not hardcoded-but-wrong like BUG-031, genuinely
absent:

- **`concurrencyPolicy` is unset**, so it silently defaults to Kubernetes'
  `Allow`. For a function whose runtime can exceed its own schedule
  interval, this can produce an unbounded pile-up of concurrent executions
  with no Sol-level decision behind it.
- **Retry policy is unset by Sol** (`restartPolicy: OnFailure`,
  `backoffLimit: 3` are hardcoded in the template), so a handler's `Error _`
  already means "up to 3 Kubernetes-level retries," but that operational
  fact is nowhere in `sol-fn.md`'s documented contract — it can only be
  discovered by reading generated YAML.
- **No manual invocation exists.** There is no `sol fn run` or equivalent;
  the only way to fire an ad-hoc execution today is a hand-written `kubectl
  create job --from=cronjob/...`, which requires the operator to already
  know the k8s name/namespace/context Sol already knows how to resolve.

## Design

**The `CronJob`'s `jobTemplate` is the canonical deployed execution
definition — do not invent a second one.** A `CronJob`'s `jobTemplate.spec`
already carries everything an execution needs (image, env, secrets,
resources, retry policy), and `kubectl create job --from=cronjob/<name>`
already copies exactly that template into a new ad-hoc `Job`. This gives
"scheduled and manual invocation run the same definition" for free, the same
way the FEAT-066/rollback work treats a recorded release as authoritative
rather than reconstructing deployed state from current source — here, the
deployed `CronJob` is authoritative for what a manual invocation should run.
Consequence: this ticket does **not** add a stored Fn-definition
abstraction, a config database, or anything Sol-side that duplicates what
the `CronJob` object already holds.

**Naming principle: don't give a Sol concept a stronger guarantee-name than
the substrate provides underneath it.**

- Expose Kubernetes' `concurrencyPolicy` as `scheduled_concurrency` (not
  bare `concurrency`), because that is exactly and only what it is:
  `sol fn run` is an explicit manual invocation and is **not** constrained
  by it — it can run alongside an in-flight scheduled execution even under
  `scheduled_concurrency = "forbid"`. Do not attempt to enforce mutual
  exclusion across invocation sources in this ticket: a `sol fn run`
  preflight check against existing Jobs is a check, not a lock, and would
  give a false sense of a guarantee Sol does not actually hold (a
  check-then-create is a race, not an invariant). If Sol later wants "at
  most one execution of this function regardless of source," that is a
  distinct, stronger feature (a function-level execution lease) to design
  and name as such — not something to approximate here.
- Do **not** rename `backoffLimit` to `max_attempts`. Kafka's `max_attempts`
  (FEAT-078) has a precisely documented counting contract ("maximum handler
  invocations, including the initial one"); Kubernetes' `backoffLimit` is a
  Job-level retry-count semantic that has not been checked for equivalence
  (pod/container restart interactions in particular). Expose it
  substrate-shaped as `backoff_limit` for now. Renaming to `max_attempts` is
  only correct once the exact mapping between the two models is verified —
  track that as a follow-up, don't do it opportunistically here.

**Scope note, recorded deliberately rather than left implicit:** manual
invocation (part B below) is bundled into this ticket rather than split out
again. The two pieces are coupled on purpose — validating that `sol fn run`
cleanly reuses the deployed `CronJob`'s `jobTemplate` is also the
validation that `scheduled_concurrency`/`backoff_limit` actually land where
they should (both fields ride along in the same template a manual run
copies). This was a judgment call, not the only defensible split — if
implementation reveals the two genuinely don't belong in one PR, split part
B back out into its own ticket rather than force it.

**Config surface (illustrative; exact `sol.toml` key names/shape TBD at
implementation, not decided by this ticket):**

```toml
[service]
schedule = "*/5 * * * *"
cpu = "500m"
memory = "512Mi"
scheduled_concurrency = "forbid"   # allow | forbid | replace
backoff_limit = 3
```

`cpu`/`memory` are BUG-031's concern (already-parsed fields, already
correct by the time this ticket starts). `scheduled_concurrency` and
`backoff_limit` are the new fields this ticket adds.

## Remediation

**A. Manifest semantics**

- Add `scheduled_concurrency` (`allow`/`forbid`/`replace`, default `allow`
  to preserve current behavior unless a value is later chosen as the new
  default) parsed into `Sol_cli_toml.t` and rendered as
  `CronJob.spec.concurrencyPolicy` (Kubernetes' own three-value enum — no
  Sol-invented fourth option).
- Add `backoff_limit` (default `3`, matching today's hardcoded value)
  rendered as `jobTemplate.spec.backoffLimit`.
- Document both in `sol-fn.md`'s contract, including exactly what a
  handler's `Error _` now operationally means end-to-end (handler failure →
  Kubernetes retry up to `backoff_limit` → Job failure), and document that
  `-fn` is formally a run-once execution primitive with cron as one
  invocation mechanism among (currently) two.
- Explicitly out of scope for this ticket (list in the ticket/doc so a
  later reader doesn't treat the omission as accidental):
  `activeDeadlineSeconds`, `startingDeadlineSeconds`,
  `successfulJobsHistoryLimit`/`failedJobsHistoryLimit`, `suspend`.

**B. Manual invocation**

- Add `sol fn run <domain>/<name> [--target ...]`, following the same
  resolve-workspace/domain/name → context/namespace/k8s-name →
  `Sol_cli_kubectl` adapter pattern `cmd_logs.ml` already uses for `-fn`
  addressing (`workload_exists`'s `Fn -> "cronjob"` mapping is the existing
  precedent for treating `-fn` as a `cronjob`-kind workload).
- Implementation: resolve the deployed `CronJob`'s k8s name/namespace/context
  exactly as `sol logs` does, then invoke (via the same kubectl-adapter
  layer, not a raw shell-out) the equivalent of
  `kubectl create job --from=cronjob/<k8s-name> <generated-run-name> -n <ns>`.
  Do not reconstruct the job spec from `sol.toml`/local source — that would
  reintroduce exactly the "rediscover deployed state from current source"
  problem this ticket's Design section rejects; the whole point is that the
  already-deployed `CronJob` is authoritative.
- `sol fn run` is not constrained by `scheduled_concurrency` (see Design's
  naming principle above) — document this explicitly in the command's own
  `--help` text and in `sol-fn.md`, not only in the ticket.

## Non-goals

- No dedicated `-fn` node pool, taints/tolerations, or any other
  compute-isolation mechanism between `-fn` and `-svc`/`-worker` — tracked
  separately as INFRA-015, deliberately not bundled here. This ticket makes
  execution *semantics* explicit; it does not solve isolated execution
  *capacity*.
- No Sol-side function autoscaler or generic trigger abstraction
  (event-triggered `-fn`, HTTP-triggered `-fn`, etc.) — cron and manual
  remain the only two invocation sources this ticket adds.
- No function-level execution lease / cross-invocation-source mutual
  exclusion (see Design above) — `scheduled_concurrency` only governs
  overlap between the CronJob controller's own scheduled Jobs.
- No stored Fn-definition abstraction distinct from the deployed `CronJob`
  object.
- No rename of `backoffLimit` to `max_attempts` or any other renaming that
  implies a stronger/different contract than Kubernetes' own until that
  mapping is separately verified.
- No change to `activeDeadlineSeconds`, `startingDeadlineSeconds`,
  `successfulJobsHistoryLimit`/`failedJobsHistoryLimit`, or `suspend`.
- No re-litigating BUG-031's resource-wiring fix here — that ticket owns
  `cpu`/`memory`.

## Acceptance criteria

- A new `scheduled_concurrency` field renders as
  `CronJob.spec.concurrencyPolicy` with Kubernetes' exact three values;
  omitted, current (`Allow`) behavior is unchanged.
- A new `backoff_limit` field renders as `jobTemplate.spec.backoffLimit`;
  omitted, current (`3`) behavior is unchanged.
- `sol-fn.md` documents: `-fn` as a run-once execution primitive with cron
  as one invocation mechanism; both new fields; and the end-to-end
  operational meaning of a handler's `Error _` given `backoff_limit`.
- `sol fn run <domain>/<name>` creates one ad-hoc `Job` from the deployed
  `CronJob`'s `jobTemplate`, using the same destination-resolution path as
  `sol logs`, and documents (in `--help` and `sol-fn.md`) that it is not
  constrained by `scheduled_concurrency`.
- Demo/example coverage per repo convention: at least one example `-fn`
  demonstrates a non-default `scheduled_concurrency`/`backoff_limit`, and
  `sol fn run` is exercised against it (golden-path smoke or an equivalent
  existing example, not a new demo app if an existing one suffices).
