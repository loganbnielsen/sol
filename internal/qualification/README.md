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
   resolves and records the release identity, including the revision the bundle was built from,
   and the run builds the application under test from that revision: `candidate-binding.sh`
   refuses a workspace at another revision, a tree with modified tracked files, or a framework
   pin still on a moving ref, before anything is built. A stale checkout must not be able to
   substitute another revision's application while the run reports evidence for the candidate.
2. Name the candidate, not just the prefix. `SOL_CANDIDATE` is the draft's `candidate.json`, and
   `sol-under-test.sh` verifies the installed release is that candidate — version, revision and
   pinned runner image — before anything is provisioned. An install prefix alone cannot say which
   candidate it holds, so a run told only a prefix could file another candidate's evidence under
   this one's name.
3. Give every disposable run a unique identity and evidence directory. `attempt.sh` refuses
   accidental reuse: one attempt is one candidate and one specimen, and a credential an earlier run
   left behind is never read as the current run's.
4. Exercise lifecycle through Sol. Qualification observes Sol; it must not reproduce Sol's
   Terraform/Helm resource orchestration.
5. Preserve evidence before cleanup. On any blocker while billable resources exist: capture the
   observation, run supported teardown, independently inventory the provider, and only then wait
   for human input.
6. `sol destroy` or Terraform success is not proof of absence. Provider-backed inventory
   must positively establish every relevant target-owned resource class as absent. An unreadable
   class makes the verdict UNKNOWN.
7. Durable qualification prerequisites (for example state storage or delegated DNS) are distinct
   from disposable target resources. Teardown must neither silently delete nor mistake them for
   target residue.
8. Keep credentials short-lived and target-specific. Never create long-lived cloud service-account
   keys for qualification.
9. A phase or command exit code is not itself a claim. Record the observation that satisfies or
   falsifies each row.
10. Live cloud qualification may incur cost. Do not start it without explicit operator
   authorization.

## Current executable surfaces

- `local/local-qual.sh` plus `rows-ocaml.sh` / `rows-ts.sh` — integrated local behavioral
  evidence. Local evidence never promotes a provider claim.
- `aws/live-row.sh` — AWS lifecycle/application qualification; its `verify` phase runs
  `aws/absence.py`, the read-only tri-state absence inventory that decides teardown.
- `transaction.py` — the structural predicate both transaction execution paths share: an
  operation response must carry a typed nonempty identity and a read-back must contain an
  exact matching effect. Textual substring matching cannot establish a worker effect.
- `gcp/live-qual.sh` — GCP lifecycle/application qualification and provider-backed absence
  inventory.
- provider matrices — claims, required evidence class, scenario, pass condition, and current
  evidence references.
- `observability/observability-diagnostic-matrix.md` — observability claims.
- `run-record-template.md` — concise record format for evidence that changes a current verdict.

The AWS and GCP cloud phases begin with the installed release's whole-target
`sol deploy <target>`, which establishes the durable installation inline (a fresh
account's setup offer is confirmed through a pty, using `script` from util-linux, which
the host must provide). The target declaration owns installation
configuration, including state storage, identities, and DNS ownership. An Unmet or
UNKNOWN installation stops the phase before disposable infrastructure is applied;
resolve the operator inputs named by Sol and continue the same attempt. Durable
installation resources remain distinct from disposable cleanup. `PLAN_ONLY=1` on
GCP skips bootstrap mutation entirely.

The offline harness tests protect fail-closed behavior and evidence accounting. They are regression
tests, not substitutes for live evidence.

## Release qualification

A Sol release is published only from an immutable candidate, and only after the
AWS and GCP verdicts for that exact candidate are attached to it. The two-stage
model, the `qualification-verdict.json` schema, and the exact operator action
are in [`internal/tooling/release/README.md`](../tooling/release/README.md).
Promotion refuses a verdict that is missing, failed, stale or for another
candidate; a successful workflow run and a Terraform exit code are still not
qualification or absence evidence.

## Records

Keep a record when a run establishes, falsifies, or materially limits a current claim. The record
must identify the release/revision, target/provider, time, operator or execution identity,
commands/observations used for each affected row, deviations, teardown result, and what the run
**does not** establish.

Do not add chronological incident narrative to this README or to run procedures. Historical
attempts remain available in Git; records still cited by a current matrix remain live evidence.
Actionable work belongs in GitHub Issues.
