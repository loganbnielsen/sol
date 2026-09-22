---
id: INFRA-063
type: bug
severity: low
title: Report "could not check" distinctly from "not deployed" in `sol logs` and `sol fn run`
source: audit finding FND-0024 — fail-open audit 2026-09-21
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0024-kubectl-probe-collapses-unrunnable-into-absent.md`

**Depends on:** none.

## The defect

`Sol_cli_kubectl.probe` (`sol_cli_kubectl.ml:126-131`) maps both "kubectl ran and
answered no" and "kubectl could not be run" (`Error`) to `false`:

```ocaml
| Ok (0, _) -> true
| Ok _ | Error _ -> false
```

[`probe_result`](cli/sol/lib/sol_cli_kubectl.ml) already distinguishes them, and
`cmd_target.ml:55,77` already uses it for exactly this reason. The two remaining
production callers read `false` as a definite negative:

- `cmd_fn.ml:97-102` prints `-fn <domain>/<name> is not deployed in namespace <ns>`;
- `cmd_logs.ml:44-50` (`workload_exists`) reports the workload as not found.

So on a machine with the wrong kubeconfig, an unreachable context, or no `kubectl`,
the operator is told a fact about the cluster that was never established — the
same shape as FND-0017 (a denied read shown as "no events").

## Impact

Misleading diagnosis on the two commands an operator reaches for when a deploy
looks wrong, pointing them at `sol status` (which will correctly say `UNKNOWN`
for the same underlying reason). The command still exits non-zero, so this is a
diagnosis defect, not a false success. Low severity.

## Remediation

Carry the third state to the message, as `sol_cli_status.ml`'s `ns_presence`
already does:

1. Have both callers use `probe_result` and match three ways: `Ok (0, _)` →
   present; `Ok (code, reason)` → not deployed, keep today's message; `Error why`
   → a distinct "could not check: <why>" message (still exit 1).
2. Keep `probe` if anything else needs a bool, but stop using it where the answer
   is printed as a fact about the cluster — or delete it if the two callers were
   its only users.

## Acceptance criteria

1. On an unreachable/absent cluster, `sol logs` and `sol fn run` say they could
   not check, naming the reason, and never claim the workload is not deployed.
2. A genuine non-zero exit from kubectl still says "not deployed".
3. A unit test at the adapter level pins the three cases (the test doubles
   already model a runner), so the collapse cannot come back.
