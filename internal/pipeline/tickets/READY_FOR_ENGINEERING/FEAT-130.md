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
  recorded value as `observed → desired`, in whichever command the Decision Required
  selects.
- A no-op deploy reports no contract change.
- Non-reconcilable changes (rename, reduction, key change) fail closed and name the
  reason.

**Demo/example coverage:** `examples/pluto` must show a declared change (for example
`partitions` 3 → 6) reported against a deployed record, not merely printed.

**TypeScript parity:** the record is language-neutral if the declaration is; the
TypeScript binding (FEAT-129) supplies the same facts, so this must not assume OCaml.
