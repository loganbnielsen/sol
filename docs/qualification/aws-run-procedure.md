# AWS qualification run procedure (written for Run 5; used by Runs 5–7)

> Moved verbatim on 2026-09-24 from `internal/pipeline/tickets/READY_FOR_ENGINEERING/HARDEN-002.md` (lines 1002–1357 at `a9d7d827`), when the HARDEN-002 epic was closed as a ticket and its run history moved into the qualification ledger. Headings keep their original levels; the text is unchanged. Index: `docs/qualification/README.md`.

## Run 5 — procedure (executed as Attempts 5, 6 and 7; requires explicit operator authorization)

### Prerequisites the procedure assumes

Two things bit the first three executions. Both are properties of the environment,
not of the target, so they belong here rather than in a run record:

- **`POSTGRES_URL` and `SOL_API_KEY` must be in the operator's environment** before
  `sol deploy` or `sol migrate`. The deploy's own error names a missing one, but the
  workspace's secret set is not otherwise discoverable from the target file.
- **`POSTGRES_URL` must percent-encode the password.** An RDS password generated with
  URI-reserved characters (`#`, `+`, `^`, `/`, `@`) is not a valid URI as written, and
  the failure surfaces only as `connection failed` from inside the migration Job —
  with the URL echoed in full (INFRA-044). Encode it:

  ```bash
  ENC="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$PGPASSWORD")"
  export POSTGRES_URL="postgresql://postgres:${ENC}@${HOST}:5432/app"
  ```

### Where the evidence lives

Run records in this ticket are the durable account: attempts, findings, deviations,
and which matrix rows each attempt did and did not establish. A captured evidence
bundle (`~/.sol/harden-run<N>-attempt<N>/`, referenced from the run records) is
machine-local and is **not** in the repository — if the record and a bundle disagree,
the record is what other actors can see, so anything load-bearing belongs in the
record.

This section was written as run 3's proposed plan. Runs 3 and 4 then executed and
their findings changed the lifecycle model (ADR 0003), so this is now the
qualification procedure for the model on `main` and has been updated for it: the
phase, authority and desired-state-policy semantics are asserted live here, and
their matrix rows are section **I**.

**This section is preparation only.** Producing it touches no AWS account,
no Terraform state, no live target. Execution requires explicit,
present-operator authorization — the same boundary as every prior run.

### Why Run 5's achievable scope is materially larger than run 2's

Run 2's own results table recorded `B1-B7, C1-C5, D1-D8, E2-E11, F1-F4` as
**NOT REACHED — blocked by findings 7 and 8**. Since then, in this
reconciliation pass:

- **Findings 5, 7, 8** — confirmed already fixed by reading current code
  (not commit messages): cert-manager/CRD staging is now part of `sol cloud
  apply`'s own sequencing (finding 5); the AWS/base roots provision the EBS
  CSI addon, IRSA and default `StorageClass` (finding 7); `Sol_cli_substrate.ensure`
  is called from both `cmd_deploy.ml` and `cmd_migrate.ml` (finding 8). See
  the "Remediation queue" section above for the exact file references.
- **Finding 9b** (INFRA-023) — `sol cloud destroy` now disables RDS deletion
  protection through a real targeted `terraform apply` with a unique
  per-attempt final-snapshot identity, verified before destroy proceeds.
- **Finding 6** (INFRA-026) — the bootstrap root now generates a `publisher`
  IAM policy contract (ECR push only, explicit deny on infra/IAM/repo-lifecycle
  mutation); the provisioner gained ECR repository-*lifecycle* actions with
  an explicit deny on the data-plane publish actions.
- **The `sol cloud init` / deploy-identity destination gap** (DEC-030,
  INFRA-025) — `deploy_role_arn` is now wired into a real EKS access entry
  and namespace-scoped Kubernetes RBAC (a `sol-deploy` `ClusterRole` bound
  per application namespace, never cluster-wide). This is the fix that
  actually unblocks `B1` at all: run 2 had no way for `sol deploy` to reach
  the cluster as a real, RBAC-scoped identity, only run 2's ad hoc
  workaround of hand-configuring a broad credential.

So Run 5 can plausibly reach every matrix section — now including section I's
lifecycle rows, which no previous run could have asserted because the model did
not exist yet — except the alerting rows (`G1-G3`, still blocked on a real
receiver, unchanged since run 1) and whatever new defect it finds along the way.
HARDEN runs exist to find those, not to have none.

### Preconditions (must all be true before any AWS command runs)

1. A fresh, disposable, isolated AWS account/profile — never reuse any previous
   run's.
2. `cli/platform/infra/bootstrap` applied: state bucket + lock table.
3. **Four** IAM roles created by the operator (not Sol — AUDIT-072/INFRA-026:
   Sol owns the policy contracts, never role lifecycle) from the bootstrap
   root's four generated documents: `provisioner_policy_json`,
   `publisher_policy_json` (new since run 2), `deploy_policy_json`,
   `operator_policy_json`. The publisher role needs its own assume-role
   session, used by nothing else — reusing the provisioner's or deploy's
   session to publish would silently re-introduce the identity conflation
   INFRA-024/INFRA-026 exist to prevent.
4. Target file declaring: `profile: production-single-region`, region,
   `aws.provisioner_role_arn`, `aws.deploy_role_arn`, `aws.operator_role_arn`, a
   `cluster_endpoint_cidr` that is not `0.0.0.0/0`, `state_bucket` /
   `aws.state_lock_table`. Alert receiver fields only if pursuing `G1-G3`.
5. Confirm the qualification workload is still OCaml-only (Pluto minus its
   TypeScript services), matching run 2's negative-case strategy — check
   DEC-026 §2's named TypeScript-qualification triggers before assuming this
   still holds; if one has fired since run 2, that changes the workload
   selection, not this plan's mechanism.
6. A real alert receiver + owner, only if attempting `G1-G3` this run;
   otherwise they stay recorded skipped, same reasoning as runs 1 and 2
   (DEC-026 §8: a local sink does not qualify the target).
7. **The lifecycle contract is in scope for this run** (matrix section I). The
   runner must be able to capture, per `sol cloud` invocation, the verbatim
   `lifecycle phase:` line, the terraform argv (the `-var` order matters — it is
   how the Destroy policy is shown to win, row I7), and an independent
   observation for the authority in force (`aws sts get-caller-identity` and
   `kubectl auth can-i`, including **negative** checks — rows I2/I3/I5/I6).
   A run that captures the phase but no independent observation does not satisfy
   section I.
8. **A deliberate abort is part of the run, not an accident** (rows I10–I12).
   Schedule the failure-path scenarios below before final teardown: they need a
   target that exists but whose platform install did not complete, which is a
   state the run has to create on purpose. This is the one place where a
   deliberately non-conformant lifecycle state is required, and it is followed by
   a public `sol cloud destroy` — never by out-of-band resource deletion.

### Exact command sequence, mapped to `docs/qualification/production-single-region-v1-matrix.md`
### Read-only networking inspection (INFRA-036 — record the mechanism, change nothing)

Perform this before teardown, and change no networking in response to it.

`kubectl logs` succeeded on real targets while API-server access to pod and service
endpoints timed out, and the EKS module's default node-security-group rules admit
the control plane only on the admission-webhook ports (4443/6443/8443/9443). So
control-plane → kubelet is explained by something not yet read, or it is a real gap
— and that path matters well beyond readiness, because it is what `sol logs`,
port-forward and exec rely on.

Record, without modifying anything:

1. the node security group's effective ingress rules, including any rule whose
   source is the cluster security group, with ports and protocols;
2. whether the control plane can reach a node's kubelet — `kubectl logs` against a
   pod on a known node is the observable;
3. which Sol capabilities actually depend on that path, from the surfaces in
   `cli/sol/` (`sol logs`, port-forward, exec).

Then state the conclusion in exactly one of two forms:

- the path **is** part of the production contract, *because a Sol capability
  requires it* — in which case it becomes an explicit contract entry with a direct
  test; or
- it is not, in which case nothing depends on it and it is recorded as observed
  but unrequired.

Do not add or widen a security-group rule to preserve behaviour until that
question has been answered. Widening the network so a check passes is designing
the infrastructure around the test.


1. `sol cloud plan <target>` — before any apply. Verify zero mutation and
   the honest-plan invariants (Deferred vs. Plannable phases, ADR 0002).
2. `sol cloud apply <target>` — reconcile through Ready. Evidence: run log;
   separate `cloud.tfstate`/`platform.tfstate` keys; EKS `ACTIVE` at the
   pinned Kubernetes version; EBS CSI addon + default `StorageClass`;
   cert-manager CRDs `Established` before any `ClusterIssuer`; the
   provisioner's bootstrap-admin window opened then closed, with effective
   RBAC (positive **and** negative `can-i` checks) verified after
   de-escalation.
   **Lifecycle rows I1–I4 are captured from this step** and are now part of its
   pass condition, not an observer's note: the run must report
   `CloudBootstrap` before any platform mutation (I1), still hold the privileged
   installation authority after chart RBAC and the `sol-deploy` ClusterRole are
   created (I2 — this is the live check for finding 14), report `Ready` only
   after revoking that authority and verifying the bounded provisioner (I3), and
   show `rds_deletion_protection = true` in force while `Ready` (I4). "The apply
   succeeded" is not evidence for any of these: each pairs the reported phase
   with the identity/RBAC/describe observation named in the row.

   **What `Ready` means here (INFRA-036; matrix row I14).** The gate is
   authoritative Kubernetes convergence — CRDs `Established`, Deployments
   `Available`, StatefulSets/DaemonSets reporting every declared replica, PVCs
   `Bound`, nodes `Ready`, the default `StorageClass` and EBS CSI driver
   registered, the ingress endpoint assigned, and Redpanda's own broker-native
   health — and nothing else. It deliberately does not probe the platform across
   the network, and does not require an external ACME round trip. So "the target
   reached `Ready`" is evidence of *convergence*, not of *capability*: capability
   is what the observability, ingress, broker and storage scenarios below qualify.
   A `Ready` target whose external CA is unreachable is the expected outcome, not
   a defect to report.
3. **`PlatformUpdating` re-entry and return to Ready (rows I5–I6).** Immediately
   after `Ready` is reached and before any teardown, run a second
   `sol cloud apply <target>` carrying a platform change. The run must report
   `PlatformUpdating` — never `PlatformInstalling` — hold the elevated authority
   only for that operation, and return to `Ready` with the provisioner
   re-verified. This is the one deliberately *repeated* lifecycle transition in
   the run, and it is the live check that a privileged platform change is an
   explicit re-entry rather than a silent widening of `Ready` (invariant 3).
4. Capture the printed `deploy_kubeconfig_command` / `deploy_kube_context`
   output (INFRA-025) and actually run it — `aws eks update-kubeconfig
   --role-arn <deploy_role_arn> --alias <cluster>-deploy` — then add
   `kube_context: <cluster>-deploy` to the target. This step is itself
   qualification-relevant: does the printed instruction actually work
   end to end for a first-time reader, not just in the abstract.
5. In a **separate** session, assume the publisher role (INFRA-026),
   authenticate `docker`/`aws ecr get-login-password` as it, and push the
   qualification workload's images. This is the step that actually closes
   run 2's recorded deviation ("images were published with the operator's
   own credential").
6. `sol deploy <target> --image-ref <svc>=<repo>@sha256:<digest>` per
   service, using step 5's digests — exercises `B1`/`B2` and `C1`-`C5`
   (migration gate before workload mutation; the new namespace + RoleBinding
   bootstrap actually running as the deploy identity for the first time
   ever, not a hand-configured broad credential).
7. `B3`-`B7`: one representative transaction; a deliberately failed deploy;
   rollback to the prior release (and across a `contract` migration
   boundary, expecting a refusal); drift detection/correction.
8. `D1`-`D8`: tolerant-workload placement inspection; graceful drain;
   unplanned node loss with **measured** restoration time; drain grace;
   slow-start not liveness-killed; Kafka-worker readiness tied to
   consumer-join in both directions; a hung consumer replaced by liveness,
   not readiness; broker-unreachable-at-startup does not crash-loop.
9. `E1`-`E11`: Postgres Multi-AZ inspection (already passed live in run 2);
   **measured** infra-failure failover RTO/RPO; **measured** PITR RPO;
   **measured** restore-into-a-clean-target RTO with an application-level
   transaction proving it, not just "the provider job completed"; Kafka
   broker-loss zero-acknowledged-message-loss; **measured** consumer
   auto-resume; the qualified Kafka policy (RF≥3, `acks=all`, write caching
   off); volume-tier claim boundaries; control-state recovery from a clean
   runner (this is also the first live exercise of anything destroy-adjacent
   from INFRA-023, if the recovery procedure is exercised via a
   destroy/recreate cycle rather than only backend-object recovery);
   telemetry-loss is non-durable and does not touch the business-data claim;
   a real transaction after every recovery.
10. `F1`-`F5`: no ambient ServiceAccount token (already offline-proven,
   confirm live); credential rotation completes and the workload returns
   healthy; the old credential is rejected; zero secret values anywhere in
   the evidence bundle; and **`F5` is now a four-identity check, not
   three** — provisioner (ECR lifecycle allowed, ECR push denied,
   cluster-creator admin never standing), publisher (ECR push allowed,
   infra/IAM/repository-lifecycle denied), deploy (namespace-scoped
   application mutation allowed via `sol-deploy`, platform-namespace
   mutation denied), operator (read-only). Include one deliberate negative
   test of INFRA-025's documented residual gap: attempt to create a
   `RoleBinding` named `sol-deploy` directly inside a platform namespace via
   raw `kubectl`, authenticated as the deploy identity, bypassing `sol
   deploy`/`sol migrate` entirely. This is **expected to still succeed**
   today — SEC-005 (the admission-control closure) is intentionally
   deferred — so a success here confirms a known, already-documented gap,
   not a new defect. Record it as such; do not treat it as a Run 5 failure.
11. **Destroy lifecycle, including the failure path (rows I7–I12).** In order:
    1. `sol cloud destroy <target> --apply` on the `Ready` target: prepare →
       verify preparation → destroy → verify absence (matrix section H's
       teardown rows, section I's I7–I9, and INFRA-023's first live exercise).
       Confirm the unique per-attempt final-snapshot identity **in the actual
       RDS snapshot list**, not just the terraform argv (I8), and that **no**
       post-prepare reconciliation sets `rds_deletion_protection=true` (I7 —
       the live check for finding 15, read from the `-var` order in each
       argv).
    2. Re-run `sol cloud destroy <target> --apply` against the now-`Absent`
       target (I11): it must exit 0, report `Absent`, and prepare nothing.
    3. **The abort scenarios (I10, I12).** Re-provision, then *deliberately*
       stop the platform install partway so the target exists but its platform
       is incomplete, and run `sol cloud destroy <target> --apply`. It must
       **succeed** and enter `PreparingDestroy` — not be refused for being in
       `PlatformInstalling`. Without this, invariant 6 is unqualified, and
       invariant 6 is the one that decides whether a *failed* Run 5 can be
       cleaned up by Sol at all.
    4. Interrupt a destroy between preparation and destruction, then re-run it
       (I12): the second run completes, without reusing the first attempt's
       final-snapshot identity.
12. `G1`-`G3` only if a real receiver was set up per precondition 6;
    otherwise recorded skipped, unchanged from runs 1-2.

### Evidence must establish the identity of its own observations (HARDEN-003)

> Qualification evidence must establish both the asserted condition **and** the
> identity/provenance of the observation used to establish it. A check that cannot
> demonstrate it is observing the intended target, endpoint, process, artifact, or
> output is not qualifying evidence.

> A qualification assertion must be demonstrated capable of failing when its
> claimed condition is violated.

Both halves were learned the same way on Attempt 5, from two incidents that look
unrelated and are not. A Loki query returned nothing because a `port-forward
svc/loki` established before the `PlatformUpdating` rollout kept serving the
replaced pod — the observation targeted the wrong endpoint. An offline assertion
grepped a file the CLI never writes to — the observation targeted the wrong output
channel. Each produced something that looked authoritative and was false; the
second could not have failed at all, which is worse, because a check that cannot
fail is invisible in a green run.

In practice, for every behavioural row:

- record **what was observed and how it was reached**, including the resolved
  endpoint where a name goes through an indirection (service, proxy, load balancer,
  port-forward);
- pair any **absence** with a positive control — a canary, a known recent event, the
  endpoint's own health metric — so "nothing found" is distinguishable from
  "nothing asked";
- **re-establish connections** across anything that can replace the process behind
  a name, or pin to the thing itself rather than the thing that redirects;
- for scripted assertions, **demonstrate the failure**: feed the violated condition
  and confirm the assertion rejects it. The offline harness does this with
  `internal/ci/qualification_assertions.sh` (guarded assertions whose target cannot
  be missing) and `test_qualification_assertions.sh` (the mutation test proving they
  can fail).

### Evidence classification (unchanged framework, restated because it matters here)

1. **Static/configuration evidence** — Terraform variable defaults, RBAC
   rule text, IAM policy JSON shape. This session's offline additions
   (`cli/sol/test/check_production_infra.sh`,
   `internal/ci/test_cloud_lifecycle_offline.sh`,
   `internal/ci/test_publisher_deployer_boundary.sh`) are entirely this
   tier. Necessary, never sufficient.
2. **Mechanism/renderability evidence** — `sol cloud plan` producing correct
   Deferred/Plannable phases; `terraform validate`/`fmt` clean; an RBAC
   binding structurally namespace-scoped rather than cluster-wide; the
   lifecycle's transition/policy semantics as asserted by the unit tests and
   `internal/ci/test_cloud_lifecycle_offline.sh`. All of this is already proven
   offline. Still not sufficient for any `A`–`I` matrix row's **behavioural**
   pass condition.
3. **Real target behavioral qualification** — everything in the command
   sequence above, executed against a real disposable AWS account. This is
   the **only** tier that may mark a matrix row's Pass condition as met.
   Tiers 1 and 2 are not promoted into tier 3 anywhere in this plan or in
   its execution. This matters most for section I, where the offline harness
   proves the *mechanism* (a first install reports `PlatformInstalling`, a
   re-apply reports `PlatformUpdating`, a partially installed target is
   destructible) while only a real target proves the *authority* — that the
   privileged association is genuinely present during the phase and genuinely
   gone after it.

### Explicitly out of scope for Run 5

- `G1`-`G3` without a real alert receiver — recorded skipped, not attempted.
- SEC-005 (admission-control hardening of the deploy-bootstrap RBAC gap) —
  not a Run 5 blocker. Its residual is exactly what the `F5` negative test
  in step 10 reconfirms exists; Run 5 is not expected to close it.
- GCP or any non-AWS provider — still explicitly unqualified, fails closed
  upstream of everything in this plan.
- DEC-026's own explicit exclusions, unchanged: zone-failure tolerance,
  multi-team RBAC, admission policy, federation, signing/SBOM, automated
  volume backup.

### Qualification harness discipline

The harness may orchestrate Sol's own public commands and independently
read AWS/Kubernetes state to verify results (`aws rds describe-db-instances`,
`kubectl get`, `aws ecr describe-images`, `aws sts get-caller-identity`,
`kubectl auth can-i`, ...). It must **never** invoke `terraform` or `helm`
itself to provision or repair a phase — `internal/ci/check_public_cloud_lifecycle.sh`
already enforces this structurally for `internal/qualification/aws/live-smoke.sh`;
the Run 5 harness reusing or extending that script inherits the same guard.
Every command's exact invocation, Sol commit SHA, profile version, the verbatim
`lifecycle phase:` line per invocation, substrate
module versions, and the workload image's framework versions
(`sol-svc`/`sol-worker`/`kafka-eio`/`pg-eio`) go into the run identity
header, per the matrix's own "Run identity" table — unchanged from runs 1
and 2.

### Explicit non-execution boundary

This plan is preparation only. Executing any part of steps 1-12 requires
explicit operator authorization and presence, the same as every AWS command
in this repository's HARDEN history. Nothing above is run by writing it
down.
