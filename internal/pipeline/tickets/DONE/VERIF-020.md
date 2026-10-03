---
id: VERIF-020
type: verification
severity: medium
title: Qualify secret projection on a throwaway cluster — rotation, pod status, identity isolation, and the Kubernetes-Secret P2 gap
source: DEC-029 (2026-10-02 resolution) — the saved local P1–P8 experiment plan
---

**Depends on:** None.

**Authorized 2026-10-03** by the operator (S1 workstream): run the complete
DEC-029 P1–P8 throwaway-cluster experiment, record the evidence, and fix concrete
defects it exposes. The 2026-10-02 blocker was an environment state — this WSL2
host had no reachable `docker`/`k3d` daemon — and that state has changed: the
daemon is reachable, so the remaining gate was the authorization above. The run
and its evidence land in the implementation PR that moves this ticket to
`DONE/`.

## Scope

Run the DEC-029 P1–P8 comparison empirically on a **throwaway** cluster
(`k3d`/`k3s`), never `sol-local`, on a machine-local `--context` created with
`--kubeconfig-update-default=false` (the default context here is a real EKS
deploy context). Install the Secrets Store CSI driver with a Vault dev-mode
provider, then exercise and record:

1. authority down at pod start, and authority down after startup;
2. a container restart while the authority is down (does the mounted volume
   survive?);
3. rotation on and off, measuring the delay until the file changes;
4. `SecretProviderClassPodStatus` object versions (P3/P6);
5. a forbidden ServiceAccount reading another workload's path (P2);
6. `secretObjects` with syncing, and a ValidatingAdmissionPolicy that refuses it
   (the invariant is that syncing stays off);
7. a plain Kubernetes Secret mounted by another SA in the same namespace (the
   `byo` P2 gap);
8. whether the mount is tmpfs.

## Acceptance criteria

- Each P1–P8 verdict for the `byo` × Kubernetes cells is recorded from observed
  behaviour, with the verbatim commands and outputs, or a cell is explicitly left
  `unqualified` with the reason.
- The DEC-029 comparison table for the Vault-provider row is updated from
  `to qualify` to the observed verdicts.
- Any new always-on component is named for the `FEAT-088` compatibility matrix.
- Language parity: no application-facing contract change; state that in one line.
- Demo/example: not applicable — a qualification experiment, not an
  app-author-visible change.

## Outcome (2026-10-03) — run complete, local behavioural evidence

Record:
`internal/qualification/records/2026-10-03-byo-run1-secret-projection.md`
(Sol revision `dbd8c0ba`, throwaway k3d cluster `verif020`, k3s `v1.27.4+k3s1`,
Secrets Store CSI driver chart `1.4.8` with a Vault dev-mode provider). The
default kubeconfig was never written.

All eight checks reached a verdict:

- **P1** the value reached the pod as a tmpfs file from Vault; the declaration was
  a `SecretProviderClass` + role.
- **P2** a pod whose ServiceAccount was `workload-b` using role `workload-a` got
  `403 service account name not authorized` — access is per unit identity.
- **P3/P6** `SecretProviderClassPodStatus` carries a per-object `version`
  (`yi8B…` → `jIVU…` across rotations), so "delivered vN" is observable.
- **P4** the mounted file changed within one `30 s` `rotationPollInterval` with no
  manifest edit; with rotation disabled it stayed stale for `>80 s` and caught up
  within one interval once re-enabled.
- **P5** **NOT ESTABLISHED** — the run's store was an in-cluster Vault dev server,
  which is cluster-local; external durability is architectural, not observed.
- **P7** confirmed as a cost: the driver, the provider and the authority are new
  always-on components, named in `docs/deployment/compatibility.md` as candidates
  (not accepted). Kubernetes `≥1.28` is needed for the VAP guard (GA at `1.30`).
- **P8** a new pod fails closed while the authority is down (`FailedMount`); a
  running pod keeps its last-known value; a **container restart reuses the
  pod-level mount** (the file stayed readable with the authority down), while a
  **pod recreation** requires a fresh read and fails closed.
- The `byo` × Kubernetes Secrets P2/P3 gaps were confirmed directly: a different
  ServiceAccount read a plain Secret, and a plain Secret has no version.
- `secretObjects` syncing did copy the value into a plain Kubernetes Secret when
  allowed, and a `ValidatingAdmissionPolicy` refused the same object once applied —
  the "syncing stays off" invariant is enforceable.

**No Sol defect was exposed**: Sol does not implement the CSI projection, so the
run qualifies the mechanism DEC-029 selected rather than Sol behaviour. Two
environment prerequisites are recorded in the run (the k3d kubelet shared-mount
fix; the VAP feature gate).

### Premise check

At run start on `origin/main @ dbd8c0ba`, `docker info` succeeded and
`/var/run/docker.sock` was present, so the "no reachable container runtime"
blocker was stale; `k3d cluster create` on `v1.30.5-k3s1` and `v1.29.9-k3s1`
still failed to start (as the ticket recorded), and `v1.27.4-k3s1` worked.

### Language parity

No application-facing contract change — this run qualifies a mechanism; OCaml and
TypeScript are unaffected.

### Demo/example coverage

Not applicable: a qualification experiment with no app-author-visible change.
