# Run record — template

> **How to use.** Copy this file to `docs/qualification/<YYYY-MM-DD>-run<N>-<provider>.md`,
> fill every field, and link it from the epic ticket (`HARDEN-002` for AWS,
> `HARDEN-004` for GCP) and from `internal/pipeline/audits/QUALIFICATION_STATUS.md`.
>
> **Rules that make the record usable.**
> - A field that was not observed is `NOT REACHED` or `NOT OBSERVED`. Never blank,
>   never inferred from a later command's output, never filled from configuration.
> - Quote output **verbatim** where it carries evidence, and say where the full log
>   lives. Terminal history is not durable; this file is.
> - Record the result of each assertion as **PASS / FAIL / NOT REACHED /
>   NOT OBSERVED / SKIPPED (reason)**. Interpretation goes in the note, never in
>   the result field.
> - The record states what the run does **not** establish. A run that reached
>   `Ready` has not qualified what it never exercised.

---

## 1. Run identity (fill before any mutation)

| Field | Value | Source |
|---|---|---|
| Sol revision | | `git rev-parse HEAD` at run start |
| Working tree clean | | `git status --porcelain` (must be empty) |
| Profile | | target config `profile:` |
| Target | | target config path, e.g. `qual/aws/us-east-1` |
| Account / project | | |
| Region / zone | | |
| Cluster name | | |
| Reconciliation authority | | DEC-027 selection (`direct`) |
| Kubernetes version observed | | `aws eks describe-cluster … --query cluster.version` / `gcloud container clusters describe` |
| Operator identity running Sol | | `aws sts get-caller-identity` / `gcloud auth list` |
| Declared identities | provisioner / cluster-access / deploy / operator ARNs from the target config | |
| Started (UTC) | | `date -u +%FT%TZ` |
| Finished (UTC) | | |
| Evidence bundle directory | | path, and whether it is outside the repository |

## 2. Entry point and environment

- **Procedure followed:** `<link>` + section name (AWS: `HARDEN-002` §"Exact
  command sequence"; GCP: `docs/qualification/gcp-production-single-region-v1-matrix.md`
  §"Before the next attempt").
- **Commands executed, in order, as run** — copied from the log, not reconstructed:

  ```sh
  # 1: …
  # 2: …
  ```

- **Environment prerequisites actually present at start.** State which were set,
  and for the credential that it was percent-encoded:
  - `AWS_PROFILE` / `AWS_REGION` / `CLUSTER` (or the GCP equivalents):
  - `POSTGRES_URL` set: yes/no — password percent-encoded: yes/no
  - `SOL_API_KEY` set: yes/no
  - Registry to publish the workload image: `<repo>`

## 3. Step log (one block per step, in order)

Repeat for every step of the procedure.

### Step `<n>` — `<name>`

- **Command:** `<exact argv>`
- **Times:** start `…` / end `…`
- **Lifecycle phase line printed:** `<verbatim>`
- **Observed output** (verbatim excerpts that carry the evidence; name the file
  holding the full log):

  ```text
  …
  ```

- **Assertion under test:** `<matrix row / invariant id>`
- **Result:** `PASS | FAIL | NOT REACHED | NOT OBSERVED | SKIPPED (reason)`
- **If FAIL or NOT OBSERVED:** the smallest failing observation, and whether the
  run continued afterwards.

## 4. Row roll-up

Mirror the matrix. One line per row that the run touched; rows it did not touch
are listed once at the end as `NOT REACHED` with the reason.

| Row | Required evidence class | Result | Evidence reference (file + what it shows) |
|---|---|---|---|
| | `MECHANISM` / `BEHAVIORAL` | | |

## 5. Run-specific assertions

Fill the block that applies to this run; delete the other.

### AWS Run 8 (from `production-single-region-v1-matrix.md` §"Before the next run")

- **Absence checks fired.** How and when the residual was left in place (or the
  real leftover observed); `verify_aws_destroy` output verbatim; result.
- **Steady-state authority, as the named identity.** Which identity; the exact
  command attempted; the observed denial verbatim; the `can-i` positives and
  negatives **with the identity that produced each**; result.
- **Migration gate end to end.** Command; result; and if it failed, the
  `migration-status Job evidence` block verbatim (this is what INFRA-040 added).

### GCP Attempt 5 (from `gcp-production-single-region-v1-matrix.md` §"Before the next attempt")

- **Narrowed provisioner role sufficient.** Evidence the platform stage reached
  the cluster with the four-permission custom role; result. Plus the denied
  Kubernetes-object operation, verbatim.
- **`startupapicheck` capture (FND-0010).** The container log, Job events, the
  webhook Service `targetPort`, and the cluster firewall listing — verbatim — with
  the branch they select (unreachable webhook vs CA bundle not injected).
- **Matrix results file.** Path to the results TSV and
  `internal/qualification/gcp/verify-matrix.sh` output.

## 6. Measurements (only what was actually measured)

| Target | Required bound | Measured | Method | Within bound? |
|---|---|---|---|---|
| | | | | |

A bound with no measurement is `NOT OBSERVED`, not a pass.

## 7. Deviations

Every departure from the procedure, with time, reason, who authorized it, and what
it changed about the evidence:

| Time | Step | What was done differently | Why | Authorized by | Effect on evidence |
|---|---|---|---|---|---|
| | | | | | |

## 8. Cleanup and final state

- **Destroy command and time:** `<argv>` / `…`; exit status `…`.
- **Provider-side absence checks performed:** each command + verbatim result.
- **Manual steps required:** none / list them.
- **Resources left behind:** none / list, with why.
- **`retention:` setting in force:** `<value>`.

## 9. What this run does not establish

- Rows not reached, with the reason.
- Capabilities the workload does not use (recorded as skipped, never as passed).
- Any check that ran but could not have failed, and why that is known.

## 10. Ledger and findings updates implied

Proposed, not applied — the qualification lead applies them with the run identity
as the citation.

| Finding / row | State before | Would move to | Because (evidence reference) |
|---|---|---|---|
| | | | |
