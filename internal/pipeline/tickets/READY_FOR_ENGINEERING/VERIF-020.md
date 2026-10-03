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
