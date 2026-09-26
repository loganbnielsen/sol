# AWS qualification Run 5, attempt 3 — 2026-09-19

> Moved verbatim on 2026-09-24 from `internal/pipeline/tickets/READY_FOR_ENGINEERING/HARDEN-002.md` (lines 680–728 at `a9d7d827`), when the HARDEN-002 epic was closed as a ticket and its run history moved into the qualification ledger. Headings keep their original levels; the text is unchanged. Index: `internal/qualification/README.md`.

## Run 5 attempt 3 (executed 2026-09-19) — NON-CONFORMANT: finding 20 blocking

Fresh disposable target `sol-qual7-3904198d`, after INFRA-032 was on `main`.

| Stage | Result |
|---|---|
| `terraform-apply` (cloud) | **ok**, 860.3s — EKS v1.36.4 `ACTIVE`, 4 nodes |
| `platform-prerequisites-apply` | ok, 49.4s |
| `platform-apply` | **ok**, 171.0s — **every chart installed, alloy included** |
| `provisioner-bootstrap-access-remove` | ok, 13.6s |
| platform readiness | **FAILED** — every component reported unavailable |

### finding 20 — a fresh install is judged by one readiness sample (INFRA-034)

`platform-apply` succeeded and then readiness reported **nine** components as
unavailable, immediately. Minutes later, on that same target: cert-manager 3 × `1/1`,
ingress-nginx `1/1`, Argo CD 7 × `1/1`, Redpanda 3 × `2/2`, Alloy 4 × `2/2`,
Loki/Grafana/Tempo/Prometheus all ready, four nodes `Ready`. The gate sampled once the
instant the apply returned and never re-checked; `readiness` contains no wait, retry or
sleep. Helm reporting a release as deployed means the objects were created, not that
the controllers behind them are serving, so a single sample cannot describe a fresh
install. Fixed by INFRA-034 (bounded wait, progress reporting, same fail-closed
outcome on timeout).

The run relinquished privilege before reporting the failure, so the operator is told
the target failed when the platform is fine.

### The one check that could not have fixed itself, and a fixture pitfall

Of the nine, the `ClusterIssuer` had a different and genuine cause: Let's Encrypt
rejected the ACME registration (`ErrRegisterACMEAccount`) because the contact email's
domain is on LE's forbidden list — `contact email has forbidden domain "example.com"`.
The qualification target file had been given a documentation-style address
(`…@example.invalid`, then `…@example.com`), and **no reserved documentation domain can
ever satisfy this check**. A qualification target must use a syntactically valid,
non-forbidden domain; verified against the live ACME server that
`qualification@sol-harden-qualification.dev` registers (`ACMEAccountRegistered`).

This is a fixture-input error, not a product defect — but it is recorded because it
cost two attempts, and because the readiness summary reporting nine components at once
is what made the real cause hard to see (INFRA-034's progress reporting addresses the
diagnosis half of that).

### Cost-clean verification

EKS `ResourceNotFound` and `list-clusters` empty; RDS 0; 4 instances `terminated`; NAT
`deleted`; EIP 0; ELBv2 0; EBS 0; non-default VPCs 0; ECR 0. Final snapshot recorded
then deleted.
