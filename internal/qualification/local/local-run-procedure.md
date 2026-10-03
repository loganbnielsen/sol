# Local integrated-qualification run procedure

This is the procedure `VERIF-027` follows to observe the alpha acceptance matrix's
local rows against the reference application, on one host, with the released `sol`
bundle. It is preparation for that run, not evidence of it: nothing here is
`PASS` until a run record says so at the class the row needs.

The executable contract is `internal/qualification/ALPHA_CAMPAIGN.md` §3 — the rows
whose target includes `local`. The harness is `local-qual.sh`; its offline suite is
`test-local-qual.sh`.

## 1. What the local run can and cannot establish

| Class | Meaning here |
|---|---|
| `LOCAL` | Observed on this host against the real k3d cluster, the real framework runtime and the real `sol` binary. |
| `LIVE` | **Not reachable locally.** Provider, authority, retention, multi-AZ and alert-acknowledgement rows stay `NOT RUN`; they belong to `HARDEN-007`/`HARDEN-008`. |

The local run is the closest practical clean-user environment before the cloud runs.
It exercises the same charts (`dev` runs the profile's charts at single-replica
scale), the same rendering path and the same framework primitives — but it does not
observe a provider, so no provider claim may be promoted from it.

## 2. Environment prerequisites (observed 2026-10-03)

1. **One `sol-local` cluster, so local runs serialize.** `Sol_cli_local_cluster.name`
   is the literal `sol-local`; `sol local infra up` manages exactly that cluster.
   Two local actors cannot run concurrently. Record which actor held it.
2. **The run owns the host ports it declares.** `sol local infra up` port-forwards
   kafka `9092`, schema registry `8081`, postgres `5432`, loki `3100`, grafana
   `3000`, prometheus `9090`, pushgateway `9091`, tempo `4318`, tempo-query `3200`
   and ingress `8088`, and the k3d registry binds `5000`. Leftover `ensure-*.sh`
   containers or native backends from earlier runs collide with these; stop them or
   accept the harness's port-forward warnings, and record which.
3. **Kubeconfig isolation.** The ambient `~/.kube/config` on the campaign host had a
   stale, unreachable EKS current-context. The harness extracts
   `k3d kubeconfig get sol-local` into `$LOG_DIR/run-kubeconfig.yaml` and drives every
   `kubectl`/`helm` read through that file. The ambient context is recorded in
   `run-identity.txt`, never used. (This is why `BUG-130` was fixed before the run.)
4. **Host toolchain.** `docker` (daemon up), `k3d`, `helm`, `kubectl`, and a `sol`
   binary — the released bundle's `bin/sol` for a clean-user row, or the checkout
   build for development. The harness fails closed naming whichever is missing.
5. **A workspace.** `examples/pluto` is the reference workspace. `sol local infra up`
   reads its declared resources (`sol.yml`), so run it from the workspace root.

## 3. Phases and commands

The harness takes a `SOL`, `WORKSPACE`, `CLUSTER`, `LOG_DIR` and (for rows) `ROWS_SH`.
Every phase is idempotent and writes into `$LOG_DIR`.

```sh
H=internal/qualification/local/local-qual.sh

# record identity, check tools, record the ambient context — no mutation
SOL=<bin/sol> WORKSPACE=examples/pluto LOG_DIR=/tmp/qual-local-1 bash $H preflight

# provision/reconcile the cluster and capture its inventory
... bash $H infra

# capture status (the operator's own view) after any change
... bash $H status

# drive the acceptance rows (needs the reference applications; see §5)
... ROWS_SH=.../local-rows.sh bash $H rows

# freeze the evidence bundle
... bash $H capture

# delete the cluster and verify absence
... bash $H teardown
```

`all` runs `preflight`, `infra` and `capture`.

### A fresh run

A clean-user local run starts from a fresh cluster:

```sh
(cd examples/pluto && sol local infra down --cluster)
... bash $H preflight && ... bash $H infra
```

Do **not** delete a cluster another actor is using; check `git worktree list` and the
harness's `run-identity.txt` first. Recording an existing cluster instead of a fresh
one is a deviation, and the run record must say so.

## 4. Evidence bundle

`$LOG_DIR` is the bundle. `capture` writes `evidence-manifest.txt` (path and size per
file). Members: `run-identity.txt` (revision, `sol --version`, workspace, cluster,
start time, ambient context, tool versions), `infra-up.log`, `infra-status.log`,
`namespaces.txt`, `helm-releases.txt`, `pods.txt`, `teardown-verdict.txt`, and the
row drivers' own logs. Copy the bundle outside Sol's 20-run pruning window
(`internal/qualification/README.md`, lesson 5) before it can be lost.

**Absence is tri-state.** `teardown` records `cluster` and `containers` verdicts
(`ABSENT` / `PRESENT` / `UNKNOWN`) and refuses to report success unless both are
`ABSENT`. A failed `k3d cluster list` is `UNKNOWN`, never `ABSENT` — the suite
mutation-checks exactly that. Local absence is a fact about this host, not a provider
inventory; it does not satisfy `INV-DESTROY-*`, which needs the provider.

## 5. Row drivers

The environment phases are application-independent. The rows need the reference
scenario (`FEAT-131`/`FEAT-132`/`FEAT-133`), so `rows` takes a `ROWS_SH` script and
refuses without one. `local-rows.sh` should drive, per `ALPHA_CAMPAIGN.md` §3:

- **B1–B6** — `POST /orders` through the OCaml and TS namespaces; one row/one job/one
  intent/one effect; duplicate delivery; the outbox relay's ordering.
- **C1–C3, C5–C6** — `sol migrate apply`, the deploy gate's `required ⊆ applied`
  failure, a checksum mismatch, a job lease/retry, the relay under a blocked head.
- **D1–D6** — topic provisioning at the declared partition count, registration
  fatality, retry/DLQ topology, an undecodable record.
- **F6, F8, F9** — immutable artifact refusal, the observed→desired contract change,
  `sol plan` reading the declaration.
- **G1–G9** — the six identity dimensions on logs, metrics and traces; one request's
  three signals agreeing; `sol logs`/`sol status`/`sol open`/`sol check`; dashboard
  proxy queries; the alert delivery route to a local receiver.
- **H1–H2, H7** — DLQ, broker-unavailable-then-recovered, relay restart, telemetry
  loss, and deploy → failure → diagnose → rollback → recover.

Each row records the verbatim command and output; a local observation is `LOCAL`, and
a row that needs a cluster-with-provider stays `NOT RUN`.

## 6. Deviations from the cloud run rules, and why

- **No forced teardown.** The ledger's cost rule (tear down before asking) exists
  because cloud resources bill; a local cluster does not. The run may keep the cluster
  to diagnose, and `teardown` is an explicit phase.
- **Teardown verdict is local.** It is `k3d`/`docker` on this host, not a provider API
  inventory, so it cannot be cited for `INV-DESTROY-*`.
- **The charts are the same, the substrate is not.** `dev` and the profile run the
  same charts, but only the cloud run observes provider-realized substrate.

## 7. Updating the campaign

A run produces a record from `run-record-template.md` and updates the rows it moved in
`ALPHA_CAMPAIGN.md` §3 (and, for observability rows, the observability matrix). A row
changes verdict only with evidence of the class it needs; a defect the run exposes is
filed, fixed if bounded and unowned, mutation-tested, merged, and the row rerun.
