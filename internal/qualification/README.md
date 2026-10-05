# Qualification

Qualification answers one question: **does independent observation establish the claim Sol makes?**

## Evidence model

A claim has one current home: the matrix that owns that product or provider surface. A passing
row cites the evidence that established it. Run records under `records/` are immutable evidence,
not project-management state.

Evidence classes are not interchangeable:

- **STATIC** — source/configuration inspection.
- **MECHANISM** — an executable mechanism or rendered artifact behaves as required.
- **BEHAVIORAL** — the claimed behavior was observed against the real system/provider.

A behavioral production claim can pass only with behavioral evidence. A failed, timed-out,
unauthorized, malformed, or otherwise unreadable observation is **UNKNOWN**, never absence or
success. A skipped capability is named as skipped; it is not silently promoted.

## Live-run rules

1. Qualify the released artifact a user installs, not a checkout build. `sol-under-test.sh`
   resolves and records the release identity.
2. Give every disposable run a unique identity and evidence directory. `attempt.sh` refuses
   accidental reuse.
3. Exercise lifecycle through Sol. Qualification observes Sol; it must not reproduce Sol's
   Terraform/Helm resource orchestration.
4. Preserve evidence before cleanup. On any blocker while billable resources exist: capture the
   observation, run supported teardown, independently inventory the provider, and only then wait
   for human input.
5. `sol cloud destroy` or Terraform success is not proof of absence. Provider-backed inventory
   must positively establish every relevant target-owned resource class as absent. An unreadable
   class makes the verdict UNKNOWN.
6. Durable qualification prerequisites (for example state storage or delegated DNS) are distinct
   from disposable target resources. Teardown must neither silently delete nor mistake them for
   target residue.
7. Keep credentials short-lived and target-specific. Never create long-lived cloud service-account
   keys for qualification.
8. A phase or command exit code is not itself a claim. Record the observation that satisfies or
   falsifies each row.
9. Live cloud qualification may incur cost. Do not start it without explicit operator
   authorization.

## Current executable surfaces

- `local/local-qual.sh` plus `rows-ocaml.sh` / `rows-ts.sh` — integrated local behavioral
  evidence. Local evidence never promotes a provider claim.
- `aws/live-row.sh` — AWS lifecycle/application qualification and provider-backed absence
  inventory.
- `gcp/live-qual.sh` — GCP lifecycle/application qualification and provider-backed absence
  inventory.
- provider matrices — claims, required evidence class, scenario, pass condition, and current
  evidence references.
- `observability/observability-diagnostic-matrix.md` — observability claims.
- `run-record-template.md` — concise record format for evidence that changes a current verdict.

The offline harness tests protect fail-closed behavior and evidence accounting. They are regression
tests, not substitutes for live evidence.

## Records

Keep a record when a run establishes, falsifies, or materially limits a current claim. The record
must identify the release/revision, target/provider, time, operator or execution identity,
commands/observations used for each affected row, deviations, teardown result, and what the run
**does not** establish.

Do not add chronological incident narrative to this README or to run procedures. Historical
attempts remain available in Git; records still cited by a current matrix remain live evidence.
Actionable work belongs in GitHub Issues.
