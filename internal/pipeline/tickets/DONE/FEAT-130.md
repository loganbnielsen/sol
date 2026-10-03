---
id: FEAT-130
type: feature
severity: medium
source: operator review of the FEAT-116 landing (2026-10-03) — release metadata / DEC-065 planning semantics
title: "Record the deployed event contract and report a contract change against it"
---

Record the deployed event contract and report a contract change against it

**Depends on:** None.

**Related:** FEAT-110 (the durable owner of release/rollback metadata, which this
extends), FEAT-116 (which made the declaration canonical and reads it for the plan),
DEC-065 (`sol plan` reads the declaration), ADR 0005 (the Sol-owned boundary).

## Problem

FEAT-116 made `events/<team>/sol.toml` canonical and made `sol plan` read it, but the
plan prints only the **desired** declaration. The rest of the planning semantics the
ticket also named — "*names a change to either [partitions or key] against what is
deployed*" — is not delivered: the plan cannot show `partitions: 6 → 12`, because the
deployed contract is recorded nowhere Sol can compare it against. The source-of-truth
half landed; the observed-target half did not.

Evidence at `origin/main`:

- `Sol_cli_release_id.workload` (`cli/lib/base/sol_cli_release_id.ml`) carries
  `domain`, `name`, `primitive`, `image`, `config`, `secrets`, `schedule`,
  `scheduled_concurrency`, `backoff_limit`, `replicas`, `availability`,
  `consumes_kafka`, `cpu`, `memory`, `extra_labels`, `volumes`, `rollout`,
  `ingress_host`, `ingress_path`, `cluster_issuer`, `calls` — no topic, partitions,
  key, or schema. `Sol_cli_release.t` adds only `migrations`, `apply_mode`,
  `encoding_version`.
- The only deployed-contract observation today is the partition guard
  (`framework/ocaml/kafka-eio-service/lib/kafka_service.ml`, `partition_guard`): it
  queries the live topic at register time and raises `Partition_count_reduction`
  naming `current` and `requested`. That is a deploy-time error on one property, not
  a plan diff.
- `sol plan <target>` loads workspace and target config only; it does not read the
  target.

## Decision (2026-10-03) — recorded contract, compared in deployment planning

Operator decision: **option 1**. `sol plan` stays offline and deterministic — it
keeps reading the declaration and renders no target-aware diff. The observed →
desired comparison belongs to **deployment planning**: the deployed contract is
persisted with the durable release metadata FEAT-110 established (the immutable
`sol-release-<id>` ConfigMap in the customer's own namespace, and the same record
in a GitOps `--emit-to` repository), and `sol deploy` — including `--dry-run` and
`--emit-to` — loads it and renders the change. A change that cannot be reconciled
in place (partition reduction, key change, topic rename) fails closed and names the
reason before anything is applied. ADR 0005 still bounds this to topics the
declaration owns.

Implements DEC-065's planning semantics: the declaration is canonical and
language-neutral; the record is the observed target-side state.

## Remediation

- **Record the deployed contract.** Extend the release record with each Sol-owned
  event's contract facts — topic identity, partitions, key field, and schema identity
  (registry subject/version or a digest) — and version the encoding
  (`sol-release-v5`). This is release metadata; it belongs with the record whose
  durable owner FEAT-110 names.
- **Render a change as `observed → desired`**, not the desired value alone, for
  partitions, key, topic identity, and schema. A no-change contract prints nothing.
- **Fail closed where a change is not reconcilable.** A topic rename is a new topic,
  a partition reduction is already refused, and a key change repartitions an existing
  topic; each must be named rather than silently applied.

## Acceptance criteria

- The release record carries the deployed contract, is readable from the target after
  a deploy, and a rollback restores it.
- A change to the declared partitions, key, topic, or schema is reported against the
  recorded value as `observed → desired`, in deployment planning (`sol deploy`,
  including `--dry-run` and `--emit-to`).
- A no-op deploy reports no contract change.
- Non-reconcilable changes (rename, reduction, key change) fail closed and name the
  reason.

**Demo/example coverage:** `examples/pluto` must show a declared change (for example
`partitions` 3 → 6) reported against a deployed record, not merely printed.

**TypeScript parity:** the record is language-neutral if the declaration is; the
TypeScript binding (FEAT-129) supplies the same facts, so this must not assume OCaml.

## Completion notes (2026-10-03)

**The record carries the contract.** `Sol_cli_release_id` gained a language-neutral
`contract_fact` (`subject`, `topic`, `partitions`, `key`, `schema_digest`) and the
release identity folds it in; the encoding is now `sol-release-v5`, so a
contract-only change is a distinct release a rollback can name, and a record written
by the previous encoding is reported as a format change (AUDIT-077's path), not as
corruption. `Sol_cli_release.t.contract` is serialized in the record JSON, the
`sol-release-<id>` ConfigMap and the GitOps `--emit-to` bundle, and `of_plan` fills
it from the plan's declaration, so both `sol deploy` and `sol up` persist it.
`contract_of_facts` derives the facts from the same `events/<team>/sol.toml`
declaration FEAT-116/FEAT-129 generate bindings from — it reads no language-specific
file, so the TS contract (FEAT-129) contributes identical facts.

**The change renders in deployment planning.** `Sol_cli_deployment_plan` carries the
desired contract and, once `with_observed_contract` is applied, a `contract_change
list`; `pp_summary`, `to_json` and the deploy console render each change as
`observed → desired` (`payments.Charged  partitions 3 → 6`). `sol deploy` — apply,
`--dry-run` and `--emit-to` — reads the previous release's record after the
destination resolves and enriches the plan before it is printed, persisted to the run
log, or written with `--emit-plan-to`; `sol up` does the same against its local
cluster. `sol plan` is untouched: it stays offline and reads the declaration, per the
recorded decision.

**`Incompatible_contract_change` fails closed**, naming the reason: a partition
reduction, a record-key change, or a topic rename aborts the plan before anything is
applied. Additions, removals and schema-digest changes are reported (a breaking
schema change is still refused by registry FULL compatibility at apply).

**Deliberate choice, recorded:** an *unreadable* record (target not answering) is
treated as no observed contract rather than a hard failure, so the established
unreachable-cluster guidance and GitOps `--emit-to` still work; only a change that
cannot be reconciled in place fails closed. The register-time partition guard remains
the apply-time backstop.

**Demo/example coverage:** `examples/pluto`'s declared contract is the fixture —
a new `Test_workspace_model` case derives `payments.Charged` from pluto's declaration,
reports `partitions 3 → 6` against a recorded contract, and the deploy-plan suite
covers rendering, the no-op, additions/removals/schema, and each fail-closed case.
No new runnable demo file was needed: the reference app's own contract is what the
test drives.

**Checks:** `dune build @all`, `dune fmt`, `internal/ci/check_ocamlformat.sh --all`,
`dune test cli/test` (new: release-id contract identity, record round trip, plan
rendering, fail-closed cases, pluto demo), `internal/ci/run_fast_checks.sh`, and
`cli/test/test_deploy_first_run.sh` (the unreachable-cluster path is preserved).

**Not verified here:** no live cluster in this session, so the record is exercised by
tests with a fabricated/loaded declaration rather than by a real deploy/read against
a target; HARDEN-007's live run owns that step.

**TypeScript parity (DEC-022):** no further impact — the record and the diff are
language-neutral and read the shared declaration; FEAT-129 already supplied the
TypeScript binding, so the TS reference app contributes the same facts.
