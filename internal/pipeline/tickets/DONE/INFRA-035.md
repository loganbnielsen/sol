---
id: INFRA-035
type: bug
severity: high
title: Readiness runs kubectl invocations nothing validates, and four of them were invalid
source: HARDEN-002 Run 5 attempt 4, 2026-09-19 — `kubectl rollout status … --all`
  is not a valid invocation, so no target could reach Ready
---

**Depends on:** None.

**Related:** INFRA-034 (the single-sample gate that hid this behind a wait),
HARDEN-002 (the run), and the readiness-contract proposal this feeds: the five
proxy-based checks are deliberately **not** changed here, because whether
`sol cloud apply` should require API-server → pod/service proxy reachability is a
contract question, not a bug fix.

## What happens

Readiness is what licenses `PlatformInstalling -> Ready`, and each check is a
hand-built kubectl invocation. Nothing validated those argv against kubectl, and
four of the nine were not valid invocations at all:

```
$ kubectl rollout status deployment --all -n cert-manager --timeout=5s
error: unknown flag: --all
```

`rollout status` takes one named resource; it has no `--all`. The affected checks
were *cert-manager controllers*, *ingress-nginx*, *Argo CD* and the monitoring
daemonsets. Because readiness requires **zero** unmet checks, **no target could
ever reach `Ready`** — on any cluster, healthy or not.

That is what attempts 3 and 4 were actually hitting. It presented as nine
unhealthy components on a platform that was, minutes later, demonstrably healthy
(cert-manager 3 × `1/1`, Argo CD 7 × `1/1`, Redpanda 3 × `2/2`, Alloy 4 × `2/2`,
Loki/Grafana/Tempo/Prometheus ready, four nodes `Ready`), which is how it survived
review: the failure was misread as a platform problem.

The valid form was always available and works:

```
$ kubectl rollout status deployment -n cert-manager --timeout=5s
deployment "cert-manager" successfully rolled out
```

## Why nothing caught it

The offline lifecycle harness asserts a great deal about readiness — that it fails
closed, that privilege is relinquished first, that the phase is reported — but its
`kubectl` is a fake that **accepts any argv**. It can assert what Sol does with
kubectl's output; it can never assert that kubectl would accept the input. The
invocations were also inlined at their call sites, where nothing else could see
them either.

## Remediation

1. **The invocations are data.** A readiness check is now a record
   (`name`, `reason`, `accept`, `argv`) and `readiness` runs the spec list, so the
   argv that CI validates is exactly the argv that ships.
2. **Valid, kind-appropriate invocations.** Deployments wait on their own
   authoritative condition — `kubectl wait --for=condition=Available deployment
   --all -n <ns> --timeout=5s`, which does accept `--all`. DaemonSets have no
   condition `kubectl wait` understands, so their convergence is read from status
   instead (every daemonset's ready count equals its desired count, and desires at
   least one pod — a daemonset scheduling nothing is not converged, it is not
   running).
3. **CI validates the shipped argv against a real kubectl.** kubectl parses flags
   before it contacts anything, so running each invocation with no kubeconfig
   proves the argv is accepted: a parse error is distinguishable from the
   connection error that follows. No cluster is contacted, nothing is mutated.
   `readiness_invocations` exposes the list and
   `cli/sol/test/print_readiness_invocations.ml` prints it for the guard.
4. **The guard is mutation-tested.** `test_readiness_invocations_check.sh` feeds it
   the broken invocation, the repair, and the two ways it could pass vacuously
   (empty input, a check with no argv), and asserts the verdict flips each time.

## Acceptance criteria

- No readiness check invokes kubectl with arguments kubectl rejects; CI fails if
  one is added, naming the check and printing its argv.
- Deployment checks wait on the Deployment's own condition; DaemonSet convergence
  is read from status rather than from a command that cannot express it.
- The DaemonSet predicate is pinned: a daemonset short of its desired pods, one
  desiring none, and an empty namespace are all unmet.
- The guard fails on empty input rather than passing over nothing.
- The validation names the kubectl version it ran against, because acceptance is a
  property of a version.
- Offline tests and the lifecycle harness still pass.

**Verification performed:** all 40 invocations accepted by kubectl **v1.34.1** and
by **v1.29.0** (the version CI pins), the mutation test passes, and CI installs
that pinned kubectl in the job that runs the guard.

**Demo/example coverage:** No example change; the observable effect is that a
healthy platform can reach `Ready`.

**TypeScript parity:** No language-parity impact.
