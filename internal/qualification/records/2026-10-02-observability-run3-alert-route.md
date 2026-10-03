# Observability local qualification run 3 — 2026-10-02

Addendum to run 2
([`2026-10-02-observability-run2-local.md`](2026-10-02-observability-run2-local.md)):
the alert *route* was the last row executable on this host without a cluster.

## OB-F1 — the alert-to-owner route is a working mechanism, not a documented one

Run 2 and the earlier audit left OB-F1's firing/delivery `BLOCKED` for want of an
Alertmanager. A native Alertmanager 0.27.0 plus a webhook receiver were started
on this host (no Kubernetes involved):

```yaml
# am.yml — route every alert to one webhook receiver
route:    { receiver: sol-webhook, group_by: ['alertname'], group_wait: 1s }
receivers:
  - name: sol-webhook
    webhook_configs: [ { url: http://localhost:9099/webhook } ]
```

A scaffolded workspace's target declared the required receiver contract, and the
command was pointed at the running Alertmanager:

```text
$ sol alert test --target prod/aws/us-east-1 --alertmanager-url http://localhost:9093 --dry-run
Would POST to http://localhost:9093/api/v2/alerts:
[{"labels":{"alertname":"SolSyntheticAlert","severity":"warning","synthetic":"true","owner":"obs-qualification"},
  "annotations":{"summary":"Synthetic Sol alert: confirms the production alert route reaches its named owner",
                 "runbook_url":"https://runbooks.example.test/sol-synthetic-alert"},"startsAt":"…"}]

$ sol alert test --target prod/aws/us-east-1 --alertmanager-url http://localhost:9093
Sent a synthetic alert through http://localhost:9093/api/v2/alerts.
Alertmanager accepted the synthetic alert.
```

Alertmanager held it and routed it:

```text
$ curl -s localhost:9093/api/v2/alerts
→ [{"alertname":"SolSyntheticAlert","owner":"obs-qualification","status":"active"}]

$ cat /tmp/am-webhook.log        # the receiver's own record
2026-10-03T00:15:52Z /webhook {"receiver":"sol-webhook","status":"firing",
  "alerts":[{"status":"firing","labels":{"alertname":"SolSyntheticAlert","owner":"obs-qualification",…},…}]}
```

So: the target contract is validated before anything is sent (`--dry-run` shows the
exact body), the synthetic alert is accepted by Alertmanager's v2 API, becomes
`active`, and Alertmanager **delivers a firing notification to the configured
receiver**. The synthetic alert also verifies the `owner` label survives the route.

**Verdict:** OB-F1's firing/delivery half moves from `BLOCKED` to
`QUALIFIED (LOCAL)` — the *mechanism* is observed end to end, with a receiver that
actually received. What remains is the **delivered-and-acknowledged by a human
owner** result, which is HARDEN-002's operator-gated evidence, not this run's:
`sol alert test`'s own output says exactly that.

Also observed: the target with no receiver contract is refused before any send
(the `Sol_cli_alerting.validate` preflight), which is what makes this a contract
rather than a convention.

## Row roll-up after run 3

| Row | Result |
|---|---|
| OB-F1 alert route: contract, acceptance, routing, delivery | `QUALIFIED (LOCAL)` |
| OB-F1 delivered-and-acknowledged by the owner | `BLOCKED` (operator / HARDEN-002) |

## What is left

After run 3, every row executable on this host without Kubernetes or a cloud
account has been run. The remainder is genuinely substrate- or operator-gated:

- a Kubernetes cluster (`sol local infra up`) — workload health, the `kubectl`
  log fallback, deployed-backend URL resolution, panel data under the taxonomy
  labels, and the deploy → rollback → recovery loop;
- a cloud account — `self_hosted_durable`, `external`, managed-resource
  dashboards, retention/durability;
- the operator — the delivered-and-acknowledged HARDEN-002 evidence.

Nothing above is `LIVE`.
