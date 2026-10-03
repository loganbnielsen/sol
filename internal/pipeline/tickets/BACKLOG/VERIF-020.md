---
id: VERIF-020
type: verification
severity: medium
title: Qualify secret projection on a throwaway cluster — rotation, pod status, identity isolation, and the Kubernetes-Secret P2 gap
source: DEC-029 (2026-10-02 resolution) — the saved local P1–P8 experiment plan
---

**Depends on:** None.

## Blocked On

A machine with a working container runtime, and the operator's explicit
authorization to run it. The 2026-10-02 session could not run it: this WSL2
distro's `docker` resolves to the Windows Docker Desktop client with WSL
integration off, `/var/run/docker.sock` is absent, and `k3d` cannot reach a
daemon. Nothing was committed for the attempt.

## Scope

Run the DEC-029 P1–P8 comparison empirically on a **throwaway** cluster
(`k3d`/`k3s`), never `sol-local`, on a machine-local `--context` created with
`--kubeconfig-update-default=false` (the default context here is a real EKS
deploy context). k3s images ≥1.30 crash-loop on this machine
(`Failed to set sysctl ... nf_conntrack_max: permission denied`); the
`v1.27.4-k3s1` image works, or try
`--k3s-arg "--kube-proxy-arg=conntrack-max-per-core=0@server:*"`. Some checks
need ≥1.30 (or 1.28/1.29 with the ValidatingAdmissionPolicy feature gate).

Install the Secrets Store CSI driver with a Vault dev-mode provider, then
exercise and record:

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


## Disposition (2026-10-03) — live/operator blocked

Requires a machine with a working container runtime (this WSL2 host has no
reachable `docker`/`k3d` daemon) and explicit authorization.

Gated on explicit authorization and/or the live reference-app campaign; see
AGENTS.md § Live qualification.
