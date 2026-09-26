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
| Working tree state | | `git status --porcelain`. Must show **only** the untracked qualification target (see below) and nothing else |
| Qualification target contents | | the target file is untracked, so the revision does not pin it: paste its contents, or a SHA-256 of them, plus the path |
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

**The qualification target is untracked, on purpose.** It is a `qual` environment in
`<workspace>/sol/environments.local.yml` (start from
`docs/qualification/run8-aws-target.example.yml`; FEAT-100), and the repository
forbids tracking that file — `internal/ci/check_no_account_artifacts.sh` fails on a
tracked `sol/environments.local.yml` or any tracked `sol/qual*/` path, because a real
target carries a real account, registry and role ARNs. HARDEN-002 run 2 is the incident where one
was committed and had to be removed.

Two things follow, and both are why the two rows above exist: the revision does
**not** pin the target, so the record must carry its contents; and the working tree
is not literally clean during the run — exactly that one file is expected as `??`
and nothing else may be modified.

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

### The public-TLS row needs a namespace, and that is the test's requirement

The model, recorded once here because two matrices reference it and it is easy to
misread as a provider quirk:

```text
qualification row "public TLS issuance"
        ↓ requires
a DNS-01 challenge the CA can resolve
        ↓ requires
the run is authoritative for a real namespace
        ↓ hence
a subdomain delegated to that cloud's DNS service
```

**A cloud does not need a subdomain. A capability test does.** Proving public DNS →
ACME → TLS requires control of a real zone on Cloud DNS *and* Route 53 alike; what
decides whether a delegation exists today is whether that profile's matrix carries
the row. Recorded in `DEC-042`, which fixed one delegated label per cloud —
`qual-gcp.sol-fab.dev` for GCP and `qual-aws.sol-fab.dev` reserved for AWS — because
a name can be delegated exactly once and a rename would force re-delegation and
re-issuance.

Three consequences for a run record:

- **The delegation is a prerequisite, not a finding.** A missing one is recorded as
  `BLOCKED` with the reason (`FND-0007` did exactly that), never as a failed row.
- **The zone is created by Sol's cloud root** (`create_dns_zone` /
  `create_route53_zone`; `dns_nameservers` / `route53_nameservers` are the registrar
  hand-off). A hand-created zone sits outside Terraform state and collides on the
  next apply.
- **The zone must outlive the target.** Recreating it assigns *new* nameservers, so a
  teardown that removes it silently invalidates the pasted delegation and the TLS
  failure that follows does not name the cause. If the zone is removed, the run
  record must say the delegation has to be redone.

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

## Mandatory: DEC-040 live capture during bootstrap (a hard gate, not a nice-to-have)

`Ready` is a claim that the provisioner's bootstrap elevation is gone, and an offline
harness cannot establish it — the harness emulates the cluster keyed on
`provisioner_bootstrap_admin`, so it can show the code is self-consistent but not that a
real cluster behaves that way. This capture is therefore **required before `Ready` is
accepted**, and the run is not evidence without it.

Record, with the command and its output, in this order:

1. **The principal.** Which principal P's bootstrap elevation this run exercises — the
   role ARN, and confirmation (`kubectl auth whoami -o json` or equivalent) that it is the
   principal the probe interrogates. A mismatch on either side invalidates everything
   below.
2. **The capability observed available, inside the window.** Before de-escalation, as P:
   the bootstrap-only capability set (`create clusterroles`, `create clusterrolebindings`,
   `escalate clusterroles`) answered **permitted** by the effective authorizer. Without
   this the later denial proves nothing — a credential that never worked looks identical.
3. **The window actually open.** The bootstrap access established during this run
   (the phase log line), so the observation in (2) is known to be *inside* the window and
   not merely a pre-existing grant.
4. **De-escalation performed.** The phase log line for the bootstrap access removal.
5. **The capability observed denied, after, as the same P.** Same principal, same
   capability set, same authorizer — answered **denied**.
6. **`Ready` only then.** The phase transition, after (5).

These six items are the **install** path's evidence, and they end at `Ready`. The
**destroy** path removes the same bootstrap access, and it reports the effective-surface
probe's verdict, but that probe is **advisory** — it does not gate teardown (ADR 0003
invariant 6) and a destroy never declares a verified de-escalation. So a bootstrap-access
removal observed during teardown **cannot** be cited as item (4)/(5) for this section; the
install path's own before/after pair is what establishes it. See `DEC-040`'s scope note and
`INFRA-061`.

The **shape of the authorizer's answer** is checked automatically, in the first minutes
after the cluster is reachable -- after the cloud apply, before the platform install.
`sol cloud apply` retries the probe with backoff (a fresh EKS endpoint is briefly unable to
authenticate its own principal) and then **fails the run** unless it observes all four of:

1. an answer at all — unreachability after the retry window is a **failure**, not a pass,
   because the gate not having run means the shape is unchecked;
2. a response the parser can identify a principal from;
3. **the expected provisioner**, not merely some principal — a leftover credential of
   another identity must not pass a shape check;
4. an identity taken from **`canonicalArn`**, the field the de-escalation comparison
   depends on. A pass via the `arn` or `username` fallbacks would validate a path the
   comparison does not use, so it stops the run too.

Record here which of those the run reported, and the identity source field it printed. The
raw response is written to `$SOL_QUALIFICATION_CAPTURE_DIR/whoami-capture-<run_id>.json`
(`~/.sol-qual/` by default) so it survives teardown — **attach it to this record**, and
promote it to a fixture if it differs from what the parser is tested against.

**A green offline harness is not shape validation.** That harness emits the shape recalled
from the API, so it shows the wiring works; only this capture shows the shape is right.

**If the capture disagrees with the shape the parser expects: trust the capture.** Fix the
parser against it, record the discrepancy here, and promote the capture to a fixture. The
fixtures are the recalled shape; the cluster is the truth.

Promoting it needs one more step, because a real response carries a 12-digit account id and
the account-artifact guard rejects those -- correctly:

```
internal/pipeline/qualification/scrub-whoami-capture.sh <capture.json>
```

which replaces the account with the repository's documented placeholder while preserving
array wrapping, key names and ARN shape, and refuses to emit a file that still carries an
account id. **Keep the raw capture outside the repository** and attach the scrubbed one.

If any of steps 1–5 cannot be obtained, the verification is `Undetermined` and the run
must not accept `Ready` — record the failure, do not proceed.
