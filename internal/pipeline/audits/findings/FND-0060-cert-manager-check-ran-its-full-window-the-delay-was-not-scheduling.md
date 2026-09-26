# FND-0060 — (FALSIFIED) The cert-manager check did not stop for a container-start delay; it ran its full 600s window

- **Classification:** `FALSIFIED` — the claim first recorded here after Attempt 10 (a ~9½-minute
  scheduling/container-start delay) is refuted by the same bundle's authoritative object fields and
  application logs. The interval was the check's own `--wait=10m` window.
- **State:** `FALSIFIED` — withdrawn; the actual root cause of Attempt 10's failure is recorded in
  FND-0010 and its fix is proposed in INFRA-088
- **First identified / falsified:** 2026-09-26, GCP Attempt 10 (`main @ bc9062b0`), falsified the
  same day by re-analysis of the same frozen bundle
- **Derived ticket:** none (`INFRA-087` is withdrawn)
- **Evidence class:** `LIVE` (bundle `/tmp/sol-gcp-qual-10`, 286 files)

## Why the original claim was wrong

The finding was reconstructed from Kubernetes **event ages** and read the `Created`/`Started`
events appearing 38s before capture as the pod's *first* container start. The authoritative fields
say otherwise:

| Field (authoritative) | Value |
|---|---|
| Job `metadata.creationTimestamp` / `status.startTime` | 15:16:58Z / **15:16:59Z** |
| Job container args | **`check api --wait=10m -v`** |
| Job `spec.backoffLimit` / `spec.activeDeadlineSeconds` | `1` / **unset** |
| Job pod `restartPolicy` | **`OnFailure`** |
| Job `status` | `failed: 1`, `succeeded: None`, `completionTime: None` |
| Job conditions | `FailureTarget`/`Failed` = `BackoffLimitExceeded`, lastTransition **15:27:29Z / 15:27:31Z** |
| Job describe | `Pods Statuses: 0 Active / 0 Succeeded / 1 Failed`, **one pod ever created** |

and the webhook's own log pins the check's runtime to the second:

| Evidence | Value |
|---|---|
| webhook TLS handshake failures | **122 lines, every ~5s, from 15:17:28 to 15:27:29 — 601s** |
| one of them | `remote error: tls: bad certificate` (the client rejecting the serving certificate) |
| the check's own output | `error: timed out waiting for the condition` |

601s of 5-second polls against `--wait=10m` is the check *running*, not a pod waiting to start. The
`38s` `Created`/`Started`/`Pulled (already present on machine)` events are the post-failure
**container restart** that `restartPolicy: OnFailure` performs, seconds before the Job deleted the
pod — a restart is not a first start, and event *ages* are not durations.

## What the evidence supports instead

`cert-manager` v1.14.4's chart defaults `global.leaderElection.namespace` to **`kube-system`**
(chart `values.yaml`), creates its leader-election `Role`/`RoleBinding` in that namespace, and
passes `--leader-election-namespace={{ .namespace }}` to both the controller and the cainjector. On
GKE Autopilot that namespace is managed, and both components were denied for the whole window:

```
User "system:serviceaccount:cert-manager:cert-manager" cannot create resource "leases"
in API group "coordination.k8s.io" in the namespace "kube-system":
GKE Warden authz [denied by managed-namespaces-limitation]: the namespace "kube-system"
is managed and the request's verb "create" is denied
```

30 such failures each (controller 15:16:46 → 15:27:59, cainjector 15:16:38 → 15:27:43), no
leadership ever acquired, and the `ValidatingWebhookConfiguration` (created 15:15:47Z) carries **no
`caBundle` field at all** — what a cainjector that never leads leaves behind. The chain and the
proposed fix live in FND-0010 / INFRA-088; this finding's own subject is withdrawn.

## Instrumentation lesson (recorded, and acted on in the harness)

Event ages are not durations, and one `Created`/`Started` pair cannot distinguish a first start from
a restart. The discriminator now captures the fields that can: pod YAML with `containerStatuses`
(`state`, `lastState`, `startedAt`, `finishedAt`, `restartCount`), the leader-election
`Role`/`RoleBinding`/`Lease` objects, and the controller/cainjector leader-election log lines.
