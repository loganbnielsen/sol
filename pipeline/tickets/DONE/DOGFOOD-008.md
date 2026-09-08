---
id: DOGFOOD-008
type: bug
severity: blocker
source: dogfood/2026-06-11_DOGFOOD-002_local_dev_lifecycle.md
branch: DOGFOOD-008/redpanda-advertised-listener
worktree: /home/lbendtly/Code/sun-DOGFOOD-008-redpanda-advertised-listener
---

Fix Redpanda advertised listener so `sun dev run` services can reach Kafka.

**Depends on:** None.

**Problem:** `sun dev run` starts services as local processes connecting to Kafka via the `localhost:9092` port-forward. librdkafka bootstraps successfully on `localhost:9092`, but the broker's metadata response advertises the internal cluster hostname `redpanda-0.redpanda.redpanda.svc.cluster.local:9093`. librdkafka then reconnects to that hostname, which is unresolvable from outside the k3d cluster:

```
Failed to resolve 'redpanda-0.redpanda.redpanda.svc.cluster.local.:9093': Name or service not known
Fatal error: kafka register: could not provision topic ...: Local: Timed out
```

**Impact:** `sun dev run` is completely non-functional for any service that uses Kafka. The core local dev loop is broken.

**Remediation:**

Configure Redpanda in `cmd_dev.ml`'s `helm_install` call to advertise `localhost:9092` as its external listener address. The Redpanda Helm chart supports this via:

```ocaml
("listeners.kafka.external.default.enabled",           Val "true");
("listeners.kafka.external.default.port",              Val "9093");
("external.enabled",                                   Val "true");
("external.addresses[0]",                              Str "localhost");
```

And update the port-forward for Kafka to map `localhost:9092` to the external listener port.

Verify the fix by running `sun dev run` in a scaffolded workspace and confirming services start and process Kafka events without DNS errors.

**Acceptance criteria:**

- `sun dev run` starts `charge_svc` and `notify_worker` without Kafka errors.
- A `POST /charges` request produces a Kafka event visible in `rpk topic consume`.
- No manual `/etc/hosts` or DNS workaround required.
