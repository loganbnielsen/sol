# AWS qualification Run 5, attempt 1 — 2026-09-18

> Moved verbatim on 2026-09-24 from `internal/pipeline/tickets/READY_FOR_ENGINEERING/HARDEN-002.md` (lines 534–628 at `a9d7d827`), when the HARDEN-002 epic was closed as a ticket and its run history moved into the qualification ledger. Headings keep their original levels; the text is unchanged. Index: `internal/qualification/README.md`.

## Run 5 attempt 1 (executed 2026-09-18) — NON-CONFORMANT: finding 16 blocking

First attempt at the Run 5 procedure below, against a fresh disposable target in the
qualification account (`cloud/aws/us-east-1`, cluster `sol-qual5-2ca50d57`,
`production-single-region/v1`, 111122223333 / us-east-1).

### Outcome

CloudBootstrap and the cloud substrate **succeeded**; the platform install **failed
and could not reach `Ready`**, so the attempt is non-conformant and was stopped
rather than continued into deploy/fault-injection scenarios on a non-conformant
platform. It was then torn down through Sol's public path and independently
verified absent.

| Stage | Result |
|---|---|
| `sol cloud plan` | clean, read-only; profile-derived vars correct |
| `terraform-apply` (cloud substrate) | **ok**, 849.7s — EKS `ACTIVE` at v1.36 (matches the module pin), RDS Multi-AZ with deletion protection, 5 ECR repos, dedicated VPC |
| `platform-prerequisites-apply` | ok, 49.5s |
| `platform-apply` | **FAILED**, 701.1s — the blocking finding |
| `provisioner-bootstrap-access-remove` | ok, 13.8s (privilege relinquished anyway) |

### finding 16 — blocking production defect

```
helm_release.redpanda: context deadline exceeded
helm_release.loki[0]:  context deadline exceeded
0/3 nodes are available: 3 Insufficient cpu.
```

Measured cause: the node group came from the provider root's **defaults**
(`node_instance_types = ["m6i.large"]` = 2 vCPU, `node_desired_size = 3`) → 6 vCPU
total, while the platform's own RF≥3 Redpanda requests **2 vCPU × 3 brokers = 6
vCPU by itself**; `loki-chunks-cache-0` was `Pending` for the same reason. This
section's own minimal harness already specifies "4x m6i.xlarge" — nothing enforced
it. Remediated by INFRA-030 (the profile now owns a capacity contract, with the
contract expressing capacity rather than an instance type).

### findings 17 / 18 — the matrix claimed more than the CLI could show

- **finding 17**: `CloudBootstrap`, `Ready` and `Destroying` were never operator-visible;
  only `PlatformInstalling`, `PlatformUpdating`, `PreparingDestroy` and `Absent`
  were ever printed. Rows I1/I3/I9 assert the others. Remediated by **INFRA-031**
  (report them where the lifecycle enters them) — the specification was *not*
  weakened to match the gap.
- **finding 18**: row I3 asserted a negative `can-i` for `create clusterroles` /
  `create clusterrolebindings`. The live attempt showed `create` is **permitted**
  by design (scoped platform management needs it) while `escalate` and `bind` are
  **denied**, which is the real boundary. Row I3 corrected accordingly.

### Alloy — recorded, not filed as a defect

`helm_release.alloy` failed with `could not download chart: Chart.yaml file is
missing`, but the pinned version (`1.12.1`) **exists** in the repository, so this
is treated as a transient download/extraction failure until a clean attempt
reproduces it. Filing a product defect on it now would be guessing.

### Positive evidence established (live behavioural)

These are legitimate live qualifications in their own right, even though the
attempt as a whole is non-conformant:

- **`lifecycle phase: PlatformInstalling`** reported during the platform apply;
- **temporary privileged authority was relinquished on a *failed* platform
  install** — the safe failure mode, rather than leaving cluster-admin behind;
- **ADR 0003 invariant 2 holds live**: after de-escalation `escalate clusterroles`
  and `bind clusterroles` both **denied**, `associatedAccessPolicies` **`[]`**,
  and cluster-wide reads `Forbidden`;
- **ADR 0003 invariant 6 / INFRA-029 holds live, on a real failure**: the target
  never reached `Ready`, yet `sol cloud destroy` entered
  **`lifecycle phase: PreparingDestroy`** and destroyed the partially installed
  target. The abort edge did real work here rather than being argued about;
- **finding 15's destroy-policy ordering** produced a real, uniquely named final
  snapshot that was confirmed `available`;
- **command completion is not infrastructure truth**: immediately after Sol
  reported `Done.`, describe calls still showed 3 EC2 instances and a NAT gateway,
  which were gone on subsequent observation. The plan's independent verification
  requirement earned its place here.

### Cost-clean verification

Independently verified after teardown with describe calls: EKS `list-clusters` empty,
RDS 0, ECR 0, non-default VPCs 0, ELBv2 0, EIPs 0, EBS volumes 0, NAT gateway
`deleted`, instances `terminated`. The disposable final snapshot was retained only
until this record captured its identifier and status, then deleted
(qualification-account hygiene; **Sol's production destroy behaviour is unchanged**
and still creates and preserves the required final snapshot).

### Attempt-2 preconditions

findings 16 and 17 must be on authoritative `main`, the complete offline gate green, and
this procedure re-read end to end. The profile's capacity contract means a conformant
attempt expects **4 × m6i.xlarge**; a target that provisions anything smaller is now
refused by preflight rather than discovered as `Insufficient cpu`.
