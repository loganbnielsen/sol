---
id: INFRA-102
type: audit-finding
severity: medium
source: internal/qualification/records/2026-10-04-local-alpha-1.md — the local integrated qualification's deploy path
---

**Depends on:** None.

`sol up` registers the workspace's event contracts at a literal
`http://localhost:8081` and reports success against whatever answers there, while the
manifests it is about to apply name the in-cluster schema registry. When any other
process owns `8081` on the host — the native dev Redpanda the repository's own local
workflow starts — the registration lands in that other registry, the deploy prints
`contract <name>: registered (schema id <n>)`, and every unit that verifies its contract
at startup then crash-loops with

```console
Fatal error: exception Failure("kafka register: schema registry for topic
pluto-comms-notifications: subject 'pluto-comms-notifications-value' has no registered
schema matching the declared contract")
```

## Observed (2026-10-04, `origin/main @ 5e5eba74`, staged bundle `v0.1.0-alpha.7`)

Fresh `sol local infra up` cluster; `sol up` in `examples/pluto`:

```console
$ 'sh' './contract/run' '--apply' '--scope' 'workspace'
contract Charged: registered (schema id 12)
contract Notification_sent: registered (schema id 13)
contract OrderPlaced: registered (schema id 3)
contract OrderFulfilled: registered (schema id 3)
  …
error: notify_worker rollout failed
```

The cluster's own registry is empty, read both ways:

```console
$ curl -s localhost:8081/subjects
[]
$ kubectl -n redpanda exec redpanda-0 -- curl -s http://localhost:8081/subjects
[]
```

The registration answered with schema ids `12`/`13`, which a freshly created registry
cannot have; the host's native Redpanda (user `redpanda`, pid 370, binding
`0.0.0.0:8081`/`0.0.0.0:9092`/`0.0.0.0:9644`) is what answered. The harness's forwards
bind the IPv6 loopback only (`kubectl … port-forward -n redpanda svc/redpanda 8081:8081`
→ `[::1]:8081`), so `localhost` resolves to the host broker. Topic provisioning goes to
the same wrong broker (`0.0.0.0:9644`).

## Why it matters

The failure is silent at the point of the mistake and loud only two steps later: the
deploy reports every contract registered, then blames the workload's rollout. Any host
that has ever run the local dev broker — which the repository documents as the default
local workflow — reproduces it, and the natural reading of the error
("…has no registered schema…") points at the registry rather than at the address `sol up`
chose. `cli/bin/cmd_up.ml:291` is the literal; `Sol_cli_local_run.dev_registry_url` is the
same constant for `sol local run`.

## Remediation

1. Resolve the registry address `sol up` registers against the way the rest of the local
   path resolves it, rather than a literal in the command — one place decides, so the
   registration and the manifests cannot disagree.
2. Fail closed when the address it reaches is not the registry the manifests name: a
   registry that answers does not prove it is *this* deployment's registry, and the
   current code cannot tell.
3. A local run needs no more than that: with the address agreement in place, a host dev
   broker on the port stops being silently load-bearing.

Filed from the local integrated qualification (`VERIF-027`) rather than fixed there: the
change decides which address the local deploy trusts, and the campaign's procedure
(`internal/qualification/local/local-run-procedure.md` §2.2) already treats the port
collision as an environment condition the run records.

## Completion notes (2026-10-04)

Promoted and fixed in this branch. **Mechanism** (established in
`internal/qualification/records/2026-10-04-local-alpha-1.md`): `sol up` passed a
literal `http://localhost:8081` to the contract step, and the port-forward
primitive called a port ready as soon as *something* accepted a connection — so a
host dev broker on that port took the registration (answering with schema ids a
fresh registry cannot have), while the deployed units address the in-cluster
registry and crash-looped.

**Fixed at the boundary, not for one machine.** The local platform module owns the
registry endpoint once (`schema_registry_forward`/`summary`, used by `endpoints`),
and `with_schema_registry_endpoint` reaches that endpoint through a forward this
command establishes on a free local port it picks, failing closed with a message
naming the intended registry; `sol up` uses it, so no literal address is trusted
and an unrelated listener on 8081 is irrelevant. The forward primitive refuses a
port another process already owns and treats a forward whose process exited as not
ready, so the false-ready path is gone for every caller (`sol local migrate`,
`sol deploy-event`, the contract step).

**Regression tests** (`cli/test/inline/test_kubectl_temporary_forward.ml`): an
unrelated listener on the requested port is refused, never adopted; a forward
whose process exits is not reported ready; a live forward that owns the port is
ready. `dune build @ci-unit` passes except the two `Test_scaffold` compile tests,
which fail identically on unmodified `main` on this host.

**Post-merge verification** is the resumed run: with the native dev broker still
holding 8081 on this host, `sol up` must register into the cluster's registry and
the units must roll out. That is `VERIF-027`'s next attempt.
