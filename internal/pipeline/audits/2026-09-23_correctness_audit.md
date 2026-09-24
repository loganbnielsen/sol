# Correctness audit — fail-loud and modeling — 2026-09-23

**Revision inspected:** `origin/main @ f3e9480b` (cited files are unchanged from
`f2e17738`; the one intervening commit touches only `cmd_cloud_tf.ml` /
`sol_cli_cloud_lifecycle.ml`). Out-of-repo pinned packages read from the opam
switch sources: `kafka-eio 0.3.0`, `pg-eio`.

**Scope.** The 2026-09-21 fail-open audit covered the CLI's *verdict surfaces*
(status, de-escalation, release record, pruning, `logs`/`fn` existence). This pass
covers what it did not:

- the **framework runtime** — `kafka-eio-service`, `sol-worker`, `sol-svc`
  (lifecycle + auth), `sol-fn`, `sol-jobs`, `sol-runtime`, `sol-obs`;
- the CLI's **mutating** paths that read before they write — `sol secret`,
  migrations, consumer-group drift, config loading (`sol.toml`), ECR repository
  derivation;
- **modeling**: where one fact has two sources, where an identity is narrower than
  the thing it identifies, and where a documented guarantee is not what the code
  enforces.

Nits, naming and style are deliberately out of scope.

**Second contribution — cloud destroy lifecycle.** A second reviewer (another agent)
reviewed `cmd_cloud_tf.ml`, `sol_cli_cloud_lifecycle.ml`, the ADRs and FND-0030 at
`main @ f2e1773`, plus the worker's failure semantics. Every claim was re-verified here
against `origin/main @ f3e9480b` (#452 merged, and it did not change them) before filing
FND-0044 to FND-0049. One claim was corrected: the starter alerts *do* include consumer lag.

**Definitions.** *Fail-open* as in the 2026-09-21 report: a failure, an
unreadable/indeterminate state, or an absent result presented as success, healthy,
complete, safe, or as a definite negative. *Modeling defect*: the type or data
model admits a state the system then mishandles silently — a narrower identity, a
duplicated source of truth, or a guarantee the representation cannot carry.

**Method.** Read each code path end to end. Swept the CLI for collapse shapes, with
a positive control for each sweep (the multi-line `with | _ ->` pattern was first
confirmed to match the known `PORT` parse in `sol-svc/lib/service.ml:244`). Where a
claim would frame a decision, ran it: throwaway executables linked against
`sol_cli` / `sol_svc` in an isolated worktree, plus a fake `kubectl` on `PATH`. The
probe sources are recorded in each finding; none was committed.

## Findings

| Finding | Classification | Severity | Evidence | Ticket |
|---|---|---|---|---|
| FND-0031 — `sol secret set/delete/list` read an unreadable Secret as absent: `set` rewrites it without its existing data and reports success, `delete` reports a deletion it never made | `VERIFIED_DEFECT` | high | `MECHANISM` (fake kubectl) | BUG-040 |
| FND-0032 — a migration is identified by version alone: a second `NNN_` file after `NNN` is applied is never run, and the deploy gate reports "Migrations: OK" | `VERIFIED_DEFECT` | high | `MECHANISM` (Sol gate), `STATIC` (pg-eio runner) | BUG-041; FEAT-094 (backlog) |
| FND-0033 — `sol.toml` silently ignores unknown keys and tables, so a typo drops the setting | `DESIGN_GAP` (decided — see finding) | medium | `MECHANISM` (probe) | BUG-042 |
| FND-0034 — a `-fn`'s schedule has two sources; the one that schedules defaults to hourly when absent, and the other only names the Pushgateway job | `DESIGN_GAP` | medium | `STATIC` | BUG-048 |
| FND-0035 — a dead Retry_topics relay is reported only when the source consumer exits, which a healthy consumer never does; health stays green | `VERIFIED_DEFECT` | medium | `STATIC` | BUG-043 |
| FND-0036 — `sol-jobs`: the claim ignores `kind`, so two `Make` instances cross-claim and fail each other's jobs; every DB error is invisible without `?ot`; leases are neither renewed nor fenced | `VERIFIED_DEFECT` (a, c), `DESIGN_GAP` (b) | medium | `STATIC` | BUG-044, BUG-050 |
| FND-0037 — `Unverified_dev_only` JWT mode has no runtime guard, and the `sol-svc` spec still says verification is unimplemented and uses the unverified mode in its payments example | `DESIGN_GAP` + `DOCUMENTATION_GAP` | high | `STATIC` | DOCS-021, SEC-006 |
| FND-0038 — the consumer-group-removal guard reads unreadable deploy state as "no previous groups", and its stated rationale contradicts `offset_reset = Earliest` | `VERIFIED_DEFECT` | medium | `STATIC` | BUG-045 |
| FND-0039 — the production profile ships Kafka in plaintext without authentication; the "plaintext only in dev" architecture claim is not realised by any Sol path | `DESIGN_GAP` | high | `STATIC` | SEC-007; FEAT-093 (backlog) |
| FND-0040 — the schema-compatibility guarantee is best-effort at every layer (FULL set after registering, warn-only; any 404 = "no prior schema"; the CI gate exits 0 without a registry) | `DESIGN_GAP` | medium | `STATIC` | BUG-049 |
| FND-0041 — `sol-svc` lifecycle: an external `stop` never reaches the server (full drain timeout, then "drain timeout reached"); a malformed `PORT` is silently ignored; SIGTERM stops accepting before endpoints drain | `VERIFIED_DEFECT` (a, b), `QUALIFICATION_GAP` (c) | medium | `BEHAVIORAL` (a, b), `STATIC` (c) | BUG-046, INFRA-073 |
| FND-0042 — the process-global signal handler is modeled as per-run: last install wins, and the handler outlives the pipe it writes to | `VERIFIED_DEFECT` | low | `STATIC` | BUG-047 |
| FND-0043 — ECR repository existence is derived from which workloads have a Dockerfile in the invoking checkout, and applied with `-auto-approve` + `force_delete` | `DESIGN_GAP` | medium | `STATIC` | INFRA-074 |
| FND-0044 — the destroy path still runs two whole-root constructive applies after the targeted preparation (contradicting FND-0030's design), and decides "substrate exists" with the install-time outputs contract (2 of 3 half-built cases fail) | `VERIFIED_DEFECT` | high | `STATIC` | INFRA-068 |
| FND-0045 — destroy verification describes guessed names in a guessed region (default `us-central1`), via a line-based tfvars parser that swallows errors; any "not found" counts as absent | `VERIFIED_DEFECT` | high | `STATIC` | INFRA-069 |
| FND-0046 — the retention report is printed from the policy, never observed from the provider | `VERIFIED_DEFECT` | medium | `STATIC` | INFRA-072 |
| FND-0047 — on GCP, `with_cluster_access` ignores `on_error`, so a credential failure exits with bootstrap access still elevated (install and destroy) | `VERIFIED_DEFECT` | high | `STATIC` | INFRA-070, REFAC-091 |
| FND-0048 — `gcp_protection_state` matches guarded resources by type in `root_module`, not by address; an empty state is reported as "could not read state" | `VERIFIED_DEFECT` | medium | `STATIC` | INFRA-071 |
| FND-0049 — decode drops, DLQ inflow and `relay_failed` have metrics but no starter alerts; the source-topic ack-and-drop default is contested | `DESIGN_GAP` | medium | `STATIC` | OBS-047; DEC-044 (backlog) |

## What the findings share

Three shapes recur, and each has a precedent fix already in the tree.

1. **"Could not ask" collapsed into "the answer is no"** — FND-0031, FND-0036(c),
   FND-0038, and the `Error _ -> []` arms FND-0043 depends on. This is the same
   shape FND-0024/FND-0025 fixed by making the read tri-state. In
   `Sol_cli_secret` it is worse than a misleading message: the collapsed read feeds
   a **write**, so the fail-open is destructive rather than diagnostic.
2. **An identity narrower than the thing identified** — migrations by version
   (FND-0032), jobs by table rather than by kind (FND-0036a), Pushgateway groups by
   cron string (FND-0034). Each lets two distinct things share one key, and the
   system then silently treats them as one.
3. **Two sources for one fact, one of them silently defaulted** — the `-fn`
   schedule (FND-0034), schema compatibility (spec says unenforced, code attempts
   FULL, CI relies on it — FND-0040), Kafka transport security (architecture doc vs.
   manifests vs. chart values — FND-0039), and `sol.toml` vs. `sol.yml` strictness
   (FND-0033).

## Reviewed and not filed

- **Source-topic decode errors are ack-and-skipped** (`default_on_decode_error`,
  `kafka_service.ml:306-310`), even under `Retry_topics` where a DLQ exists. This
  is a documented, deliberate carve-out in the acknowledgement-ownership invariant
  (`sol-worker.md:258`, BUG-028 non-goals), so it is not a defect. It remains the
  one place the worker drops a message it could have transferred durably, and
  `Worker.Make*` offers no way to override it without leaving the framework.
  Recorded here so a future reader does not have to rediscover it. The second reviewer
  argues for reversing it; that argument and the missing alerts are FND-0049.
- **`decode_message` ignores the wire schema id** (`kafka_service_schema.ml:168`):
  a payload framed with another subject's id is decoded by this topic's decoder.
  Structural JSON decoding makes this benign today. Observation only.
- **Exhausted In_memory retries stop the whole consumer** (kafka-eio
  `consume_partitioned` `signal_stop` on exhaustion). Correct: fails loudly.
- **JWT verification path** (`auth_internal.ml:278-299`) enforces alg allow-list,
  signature, issuer and audience, and fails closed on JWKS fetch errors. A token
  with no `exp` is accepted indefinitely (library default); not filed.
- **Migration deploy gate** (`cmd_deploy.ml` `check_migration_prerequisite`) is
  properly tri-state (`Unavailable` fails closed). FND-0032 is about the
  *identity* it compares, not its failure handling.
- **Worker health**: an exhausted partition, a persistent poll error (no `on_poll`
  → liveness fails after 30s), and fatal ack failures all surface. Clean.
- CLI temp-file cleanup `with _ -> ()` sites (about 20) are cleanup only. Clean.

## Previously tracked, not re-filed

EXP-022 (BACKLOG) — generated `-fn` entrypoints do not pass `~pushgateway_url`.
**Confirmed still live:** no OCaml caller outside `sol-fn`'s own test passes it,
and `sol-fn` never reads `PUSHGATEWAY_URL` itself, so `sol_fn_invocations_total`
never leaves the process on the golden path although the manifest injects
`PUSHGATEWAY_URL`. It is a silent metric loss, not an experiment; recommend
promoting it (its text still says `sun`). FND-0013/INFRA-050 (deploy-time
per-workload Secrets) is adjacent to FND-0031 but distinct.

## Recommended order

1. **FND-0047 / INFRA-070** — small; closes an elevated-authority leak on every GCP failure.
2. **FND-0044** — settle which outputs case the frozen Attempt-6 state is in, offline
   (`terraform output -json` + `terraform plan` on a copy), **before** Attempt 7. Then
   INFRA-068.
3. **Port the cloud lifecycle to the `cmd_rollback.ml` shape** (`execute ~deps` returning a
   typed outcome; exit only at the command edge). This is the structural fix behind FND-0047
   and makes INFRA-068/069/071/072 small and testable offline with fakes. Filed as REFAC-091.
4. **FND-0031 / BUG-040** and **FND-0032 / BUG-041** — destructive or silent data outcomes.
5. INFRA-069, INFRA-071, INFRA-072 on the shared state inventory.
6. The remaining tickets. Owner decisions are in BACKLOG: FEAT-093 (Kafka TLS), DEC-044
   (decode policy), FEAT-094 (migration checksums).

## What is not established

- No finding was reproduced against a live cluster, broker or registry. FND-0031's
  loss of existing keys follows from `kubectl apply`'s documented client-side
  three-way merge, given the manifest the probe captured. The deletion itself was
  not observed against an API server.
- `sol-jobs` (FND-0036) was not run against Postgres: no disposable instance was
  available without guessing credentials on the operator's database. Each
  sub-finding names the SQL-level reproduction.
- Cloud findings FND-0044 to FND-0048 are `STATIC`. None was replayed against the frozen
  Attempt-6 state. FND-0044 names that replay as the first action.
- The TypeScript framework (`@sol-fab/*`) is out of repo and was not audited.
  DEC-022 parity for FND-0035/0036/0040 is therefore unassessed, not "equivalent".
- This audit is scoped, not exhaustive. Absence of a finding in an area not listed
  above is not a claim that the area is clean.
