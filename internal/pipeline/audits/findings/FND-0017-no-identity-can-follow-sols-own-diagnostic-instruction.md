# FND-0017 — No identity in the profile can follow Sol's own diagnostic instruction

- **Classification:** `VERIFIED_DEFECT`
- **State:** `OPEN`
- **First identified:** 2026-09-20, AWS Run 8 (a read-only diagnosis that could not be completed)
- **Derived ticket:** `INFRA-056`
- **Invariant:** the counterpart of `INV-AUTH-5`/`INV-AUTH-6` for *reading*: an identity
  the profile provisions must be able to perform the operations Sol's own guidance
  sends it to perform
- **Evidence class:** `BEHAVIORAL` (live, four identities tried) + `STATIC` (the
  generated policy contract and the generated ClusterRole)

## The defect

`sol deploy` ends by telling the operator:

```text
Run 'sol status' to check pod health.
```

`sol status` renders unhealthy pods **with their last events** — that is the point
of `Sol_cli_rollout_diagnosis`, whose own header says it is "used by 'sol status'",
and `render_unhealthy_pods` (`sol_cli_rollout_diagnosis.ml:243`) emits a
`Last events:` section for exactly the case an operator is trying to understand.

`fetch_namespace_events` (`sol_cli_rollout_diagnosis.ml:397-404`) reads them with
`kubectl get events -n <ns> -o json`.

**No identity the production profile provides can supply that read.** Verified live
against the Run 8 target:

| Identity | `get pods` | `get events` | `pods/log` | `pods/portforward` |
|---|---|---|---|---|
| `sol-qual5-deploy` — the identity that runs the deploy | **ok** | **forbidden** | ok (returned empty) | **forbidden** |
| `sol-qual5-cluster-access` — the steady-state platform identity | **forbidden** | **forbidden** | — | — |
| `sol-qual5-operator` — declared in the target | **Unauthorized** (no access entry) | — | — | — |
| AWS SSO administrator | **Unauthorized** | — | — | — |

So the *deploying* identity can list pods but not explain them; the identities meant
for a human cannot authenticate at all. The instruction is addressed to an operator
who has no way to follow it.

## Why the identities are in this state

Each is deliberate on its own; the combination is the gap.

- **Deploy.** Its grant is the cluster-wide, resource-kind-scoped ClusterRole in
  `platform_deploy_rbac.tf`, bound per application namespace. It covers the
  workload objects Sol applies, and deliberately not `events` or `portforward`
  (neither is part of applying a workload).
- **`cluster-access`.** `aws/main.tf:153-166`: the `AmazonEKSClusterAdminPolicy`
  association exists **only while `provisioner_bootstrap_admin` is true**. At steady
  state the identity has group membership and nothing else, and the cluster-scoped
  provisioner ClusterRole states its own limit: *"Namespaced workload resources are
  deliberately omitted."* Being refused for pods is therefore intended.
- **Operator.** The generated contract
  (`bootstrap/main.tf:234-241`) is AWS-side only:
  `eks:DescribeCluster`, `eks:ListClusters`, `s3:GetObject`, `s3:ListBucket`. That is
  enough to *obtain* a kubeconfig and read state — and nothing on the Kubernetes
  side. `operator_role_arn` appears in exactly one place in the whole tree, an
  output description; **no EKS access entry and no RBAC binding is ever created for
  it.** The declared operator identity is therefore unreachable.

Note the asymmetry this leaves: the profile has a considered story for what each
identity may *change*, and none for what any identity may *observe*.

## The second problem, separable: the failure is invisible

`fetch_namespace_events` swallows every failure:

```ocaml
| Ok r when r.Sol_cli_process.exit_code = 0 -> parse_events_json r.Sol_cli_process.stdout
| _ -> []          (* forbidden, timeout, error — all become "no events" *)
```

A denied read is indistinguishable from a namespace with no events. So `sol status`
prints an unhealthy pod with no events and **no indication that the explanation was
unobtainable** — the operator cannot tell "nothing happened" from "I was not allowed
to look". This is the same silent-degradation shape as FND-0014's pointer and
FND-0011's predecessor, and it should be fixed regardless of who is granted what:
a diagnosis that could not read its evidence must say so.

## Minimum read-only diagnostic access (framed, not granted)

Derived from what the tools actually read, not from what would be convenient:

| Resource | Verbs | Needed by |
|---|---|---|
| `pods` | `get`, `list`, `watch` | `sol status`, `rollout_diagnosis` |
| `pods/log` | `get` | `sol open logs` |
| `deployments`, `replicasets` | `get`, `list`, `watch` | live image tag, rollout state |
| `events` | `get`, `list`, `watch` | the *explanation* — the part that is missing today |

Scope: the workspace's own namespaces only (the same dynamic set the deploy
ClusterRole is bound into). Explicitly **not** included: `secrets` (reading them is
not needed to explain a pod), `pods/exec`, `pods/portforward`, and any mutating verb.

Two questions the ticket must settle rather than assume:

1. **Which identity should hold it** — the operator identity (needs an EKS access
   entry to exist at all, plus a namespaced read-only Role), or the deploy identity
   (which already reaches the pods and only lacks `events`)? A different answer for
   the *deploy* path and the *human* path is plausible: the deploy could report
   events as part of its own failure output, while the operator needs standing
   read access for later inspection.
2. **Events expire.** Kubernetes keeps them for about an hour by default, so a
   profile that expects events to explain a failure is also relying on someone
   looking promptly. Whether the profile should capture them at deploy time, or
   accept the window, is a design question, not an implementation detail.

## Not classified here

**The `notify-worker` replica's own failure remains `UNDETERMINED`.** One replica of
the same spec is ready and the other is not, with empty logs and an unreadable
event stream; `exit 137`/`reason=Error` is consistent with a liveness kill and with
an OOM kill. Nothing in this finding claims the workload is defective, and it must
not be cited as though it did — it is the case that *exposed* the diagnostic gap.

## What would make this qualified

An operator holding only the profile's own identities runs `sol status` against a
deliberately unhealthy workload and receives the pod state **and** the events that
explain it — with a run record showing the command, the identity, and the output.

## Sources

- Live: Run 8, revision `d8d8c876`, target `qual/aws/us-east-1`; the four identity
  probes are verbatim in `docs/qualification/2026-09-20-run8-aws.md` §7.2.
- `cli/sol/lib/sol_cli_rollout_diagnosis.ml:1,243,397-404`
- `cli/sol/lib/sol_cli_workspace_scan.ml:34,84`
- `cli/sol/bin/cmd_status.ml:215-240`
- `cli/platform/infra/bootstrap/main.tf:234-241` (the operator contract),
  `cli/platform/infra/bootstrap/outputs.tf:37`
- `cli/platform/infra/aws/main.tf:146-175`
- `cli/platform/infra/base/platform_provisioner_rbac.tf` (the "deliberately omitted"
  comment) and `platform_deploy_rbac.tf`

## Live verification (2026-09-21) — partially successful, two defects found

The identity was built (DEC-038, parts A–D) and exercised against the preserved Run 8
target. What passed, verified live rather than argued:

- the operator principal authenticates (`sol-qual5-operator` access entry exists);
- it can read the evidence the diagnostic path needs — `list events`, `list pods`,
  `get pods/log` all **yes** in `pluto-checkout`, including `events`, which the deploy
  identity is refused;
- every negative holds: create/delete pods, patch deployments, create rolebindings,
  `pods/portforward`, `pods/exec`, and `secrets` are all **no**.

What did **not** pass — the operator could not obtain the diagnosis, so this finding
stays `OPEN`, and the two blockers are recorded as derived defects:

| Defect | What happened |
|---|---|
| `FND-0018` / `INFRA-058` | the binding is created per *command scope*, so `pluto-comms` — the namespace under investigation — has none, and the operator is refused all three reads there |
| `FND-0019` / `INFRA-059` | worse: with no read access, `sol status` printed **`healthy`**, where the identity that could read printed **`DEGRADED`** with the pod table and `notify_worker rollout failed` |

`FND-0019` is the more serious of the two and prompted a contract clarification
(DEC-038 §7): a verdict must be evidence-backed and three-valued.

### Methodology note — an invalid first comparison, and why it was caught

The first A/B was wrong and nearly became a false conclusion. `aws eks
update-kubeconfig --alias <a> --role-arn <b>` **rewrites the shared user entry**, so
after creating the operator's kubeconfig the context named `sol-qual5-deploy` was
still authenticating **as the operator**. The comparison therefore ran
operator-vs-operator, both printed `healthy`, and the natural reading — "the verdict
is wrong regardless of identity" — was not supported by it.

The contradiction is what exposed it: the claim required that the *deploy* identity
also be unable to read `pluto-comms`, but that identity deployed there. Re-running
with the deploy context genuinely regenerated produced the real contrast, which is
the evidence `FND-0019` rests on.

The rule this reinforces is the one HARDEN-003 already states: when an observation
contradicts an established one, the contradiction is evidence about the *method*
until the method is ruled out. Here the identity behind a context alias was the
variable, and it was invisible in the output. Any A/B comparing identities over
kubeconfig aliases must therefore re-issue `update-kubeconfig` for the identity
under test immediately before each side, and record which principal actually served
each read.
