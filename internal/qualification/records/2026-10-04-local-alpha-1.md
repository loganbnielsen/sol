# Run record — 2026-10-04, local integrated alpha qualification (attempt 1)

`VERIF-027` · target `local` (k3d on this host) · status: **not runnable in this
environment** — the deploy path is blocked by a host service the run may not stop. No
acceptance row is promoted by this attempt; this record exists so the blocker is not
re-derived.

## 1. Run identity

| Field | Value | Source |
|---|---|---|
| Sol revision | `5e5eba743aa369601818c5ffb5f18cfc6fe6d011` | `$LOG_DIR/run-identity.txt` |
| Sol bundle version | `v0.1.0-alpha.7` | staged bundle, `sol --version` |
| Sol install prefix | `/tmp/sol-install/sol-v0.1.0-alpha.7` | `internal/tooling/scripts/build-release-bundle.sh --version v0.1.0-alpha.7` |
| Migration runner image | `ghcr.io/loganbnielsen/sol-migration-runner@sha256:000…` (synthetic) | the staged bundle's `share/sol/<v>/migration-runner-image` |
| Workspace | the revision's own `examples/pluto` in the run's worktree | `sol.yml` |
| Profile | local (`sol local infra up` — dev runs the profile's charts at single-replica scale) | `internal/qualification/local/local-run-procedure.md` §1 |
| Cluster | `sol-local`, created fresh at `02:16Z` by `sol local infra up` | `infra-up.log`, `infra-status.log` |
| Account / project | none — no cloud account, no provider call, no spend | — |
| Started / finished (UTC) | `2026-10-04T02:16:20Z` / `2026-10-04T03:27Z` | `run-identity.txt`, this record |
| Evidence bundle | `/tmp/alpha-verif027-20261004-021601/` (outside the repository) | — |
| Ambient kube context | `sol-qual11-116c2637-deploy` (stale, recorded, never used) | `run-identity.txt` |

The bundle is the *staged* release: `release.yml` writes the real runner digest into the
archive it publishes, so the archive cannot exist before the operator's tag
(`RELEASE-006`). Everything the local run uses — `bin/sol` and
`share/sol/v0.1.0-alpha.7/platform` — is the artifact the tag would publish; the digest
is synthetic and is recorded as such. `sol-under-test.sh`'s checks (non-`dev` version, a
platform bundle, a digest-pinned runner) all pass.

## 2. Entry point and environment

Procedure: `internal/qualification/local/local-run-procedure.md`, harness
`internal/qualification/local/local-qual.sh`. Commands (all with `SOL_HOME` unset):

```console
$ LOG_DIR=/tmp/alpha-verif027-20261004-021601
$ SOL=/tmp/sol-install/sol-v0.1.0-alpha.7/bin/sol WORKSPACE=<worktree>/examples/pluto \
    bash internal/qualification/local/local-qual.sh preflight   # ok, run identity written
$ ... local-qual.sh infra                                       # ok, cluster + 10 forwards running
$ ... $SOL local secret set POSTGRES_URL --value <redacted>     # secret set in 4 namespace(s)
$ ... $SOL local secret set SOL_API_KEY --value dev-internal-key
$ ... $SOL local migrate                                        # Applying migrations … Done.
$ ... $SOL up                                                   # FAILED: notify_worker rollout failed
```

**Deviations from the procedure, recorded.**

1. **The cluster was not empty.** It held a 17-day-old `pluto-demo-ts` deployment from the
   TypeScript stream's development. Its inventory is preserved in
   `pre-existing-cluster.txt`; the cluster was deleted and recreated per § *A fresh run*.
2. **Host services held the run's declared ports.** The native dev Redpanda
   (`/opt/redpanda/bin/redpanda`, owned by user `redpanda`, pid 370, up 25 h) held
   `0.0.0.0:9092`, `0.0.0.0:8081` and `0.0.0.0:9644`; the `redpanda` and `sol-postgres`
   Docker dev containers held `9092`/`8081`/`9644` and `5432`; a native Loki held `3100`.
   The containers were stopped (they are restartable with `platform/local/scripts/ensure-*.sh`).
   **The native Redpanda could not be stopped**: it runs as another user and
   `kill 370` → `Operation not permitted` (no password-less `sudo` on this host).
3. **`psql` is not installed on this host.** The row drivers' DB probes ran through
   `kubectl exec … postgresql-0 -- psql` (`QUAL_PSQL`), and the broker probes through
   `kubectl exec … redpanda-0 -- rpk` (`QUAL_RPK`); the run kubeconfig extracted by the
   harness was used for every `kubectl` call (`QUAL_KUBECTL`). The documented
   port-forwards are otherwise the ones the harness established.
4. **The workspace is the revision's own `examples/pluto`,** not a copy outside the
   checkout: this host's opam switch carries no framework libraries, so a workspace
   outside the monorepo cannot build (`Library "kafka-eio-service" not found`). The
   clean-user property (no checkout, no `SOL_HOME`) is what `J2`/`J3` and the
   installed-release smoke establish; it is not re-established here.

## 3. What the run observed, and where it stopped

**Reached.** A fresh `sol-local` cluster; the whole infrastructure through the harness's
own port-forwards (`infra-status.log`: Redpanda, PostgreSQL, Loki, Alloy, Prometheus,
Grafana, Tempo, ingress all `running`); the workspace's migrations applied
(`$ sol local migrate` → `Applying migrations from …/db/migrations...` / `Done.`);
`sol up` provisioned topics and ran the contract step:

```console
$ 'sh' './contract/run' '--apply' '--scope' 'workspace'
contract Charged: registered (schema id 12)
contract Notification_sent: registered (schema id 13)
contract OrderPlaced: registered (schema id 3)
contract OrderFulfilled: registered (schema id 3)
```

**Stopped.** The rollout failed, and every unit that verifies its contract at startup
crash-looped:

```console
$ kubectl -n pluto-comms logs notify-worker-6b755bcc75-xdhzq
Fatal error: exception Failure("kafka register: schema registry for topic
pluto-comms-notifications: subject 'pluto-comms-notifications-value' has no registered
schema matching the declared contract")
```

**Mechanism (established, not inferred).** The registration above did not reach the
cluster's schema registry. The cluster's registry is empty, read both through the
harness's forward and from inside the cluster:

```console
$ curl -s localhost:8081/subjects
[]
$ kubectl -n redpanda exec redpanda-0 -- curl -s http://localhost:8081/subjects
[]
```

It reached the **native dev broker on the host**, whose registry answered with schema ids
`12`/`13` — a registry with history, where a fresh cluster's registry would answer `1`.
Two facts make `localhost:8081` mean the host broker rather than the cluster:

- `cli/bin/cmd_up.ml:291` passes `~registry_url:"http://localhost:8081"` to
  `Sol_cli_contract.report`, so `sol up` registers at that literal address.
- The harness's port-forwards bind the IPv6 loopback only
  (`kubectl … port-forward -n redpanda svc/redpanda 8081:8081` → `[::1]:8081`), while the
  native broker binds `0.0.0.0:8081`. `localhost` therefore resolves to the native broker.

The same collision applies to topic provisioning (`0.0.0.0:9644`) and to the broker itself
(`0.0.0.0:9092`). The deployed units address the *in-cluster* services, so the host-side
registration is invisible to them. This is the environment condition
`local-run-procedure.md` §2.2 anticipates ("Leftover `ensure-*.sh` containers or native
backends from earlier runs collide with these; stop them … and record which") — with the
addition that on this host the *native* backend cannot be stopped by the run.

**Not a product defect established by this attempt.** `sol up`'s literal
`http://localhost:8081` is correct in the environment the campaign documents (where the
port-forwards own the loopback); the run observed a *silent* mismatch whose only symptom
is a crash-loop. Whether `sol up` should fail closed when the registry it reaches is not
the one the manifests name is a product question, filed separately
(`BACKLOG/INFRA-102`); no acceptance row is changed by it.

## 4. Row verdicts

Every `local` row of `ALPHA_CAMPAIGN.md` §3 is **BLOCKED** for this attempt, with the
mechanism above. This is not a row failure: the workloads never started, so there is
nothing to observe, and `NOT RUN`/`FAIL` would both overstate what happened.

| Rows | Verdict | Why |
|---|---|---|
| `A1`, `A2`, `A3`, `A5`, `B7`, `D6`, `F9`, `J2`, `J4` | unchanged (`PASS OFFLINE` / `NOT RUN` as before) | These need the installed bundle, not the cluster. The bundle's `sol assets`, `sol plan` and the installed-layout smoke are `RELEASE-006`'s evidence; this attempt did not re-run them. |
| `B1`–`B8`, `C1`–`C6`, `D1`–`D6`, `E1`, `E3`, `F6`, `F8`, `H1`, `H2`, `H7`, `G1`–`G9` | **BLOCKED** (this attempt) | The reference application cannot be deployed: contract registration reaches the host dev broker, the deployed units verify against the in-cluster registry, and every unit crash-loops. |
| `I*`, `D7`, `D8`, `E2`, `E4`–`E8`, `F1`–`F5`, `F7`, `H3`–`H6` | unchanged (`NOT RUN` / `BLOCKED`, cloud) | Provider rows; a local cluster cannot establish them (§1 of the procedure). |

## 5. What this attempt does not establish

- Nothing about the scenario's behaviour: no `POST /orders` reached a running service.
- Nothing about the cluster's schema registry, broker or databases: the only rows observed
  there are the migrations applying (`sol local migrate` → `Done.`) and one topic created
  by an early attempt.
- No teardown: the cluster was kept to diagnose the crash-loop (the procedure's §6
  deviation from the cloud cost rule). `sol local infra down --cluster` has not been run
  by this attempt.

## 6. The blocker, exactly

**An operator action on this host:** stop the native dev Redpanda (user `redpanda`, pid
370 — `rpk redpanda stop` or `sudo systemctl`/`pkill` as its owner) so the harness's
port-forwards own `9092`/`8081`/`9644`, or grant the run password-less `sudo` to do it.
With that done, the sequence in §2 deploys and the rows can be driven; the drivers are
landed and their offline suites pass (§7).

## 7. Delivered by this attempt

- `internal/qualification/local/rows-ts.sh` — the TypeScript namespace's row driver
  (`b1`, `b2`, `b5`, `b6`, `d5`/`h1`), the counterpart `local-run-procedure.md` §5
  records as the run's to compose; `test-rows-ts.sh` is its offline, mutation-checked
  suite (9 checks: a correct implementation passes every row, and each injected failure —
  a leaked duplicate job, a stalled read-back, a missing DLQ record, a republished fact,
  an unknown row, a missing tool — fails for the reason under test).
- `internal/qualification/local/rows-ocaml.sh` and the procedure: the deploy step used
  `sol up local`, which the CLI refuses (`too many arguments, don't know what to do with
  local`); `sol up` is the command, `--scope=demo_ts` the scoped form. Found by this run,
  fixed here.
- `test-rows-ts.sh`'s group-scoped DLQ expectation is derived from the TS namespace's own
  group id, so the two drivers' suites do not share a constant.

## 8. Defects filed

- `BACKLOG/INFRA-102` — `sol up` registers contracts at a literal
  `http://localhost:8081` and reports success against whatever answers there, while the
  manifests name the in-cluster registry; on a host whose dev broker owns the port the
  deploy crash-loops with "no registered schema matching the declared contract".
  Filed, not fixed: the fix changes which address the local deploy trusts, and the
  campaign's own procedure treats the collision as an environment condition.

## Resume (2026-10-04, attempt 2) — deployed, OCaml rows observed

Attempt 1 was blocked by `INFRA-102` (the contract registration went to the host dev
broker rather than the cluster's registry). That is fixed and merged (`449d933c`), and the
staged bundle was rebuilt from that revision (`/tmp/sol-install-fixed/`). The same cluster
and run directory were reused; the host's native dev broker still owns `8081`, which is
now harmless by construction.

**Two defects the resume exposed and fixed** (both independent of `INFRA-102`):

- `BUG-200` — the reference workspace's `contract/run` sent every scope but `demo_ts/*` to
  the OCaml runner, so an unscoped `sol up` never registered the TypeScript scope's two
  events; `pluto-demo-ts/order-svc` fatally verified `sol-demo-ts-orders-value` and
  crash-looped. The dispatcher now runs every scope for a workspace-wide deploy. Evidence
  (pod status, events, logs) is in the ticket; the log line that named the mechanism:
  `[order-svc-ts] fatal: Error: subject 'sol-demo-ts-orders-value' has no registered schema
  matching the declared contract`.
- Environment, not a defect: the TypeScript scope's runner needs `tsc`, so
  `app/demo_ts` must have `npm ci` run once before a whole-workspace deploy
  (`sh: 1: tsc: not found`, exit 127). Recorded as a prerequisite of this run.

**Deployed state after both fixes.**

```console
$ sol up                      # unscoped, from examples/pluto, bundle v0.1.0-alpha.7 @ 449d933c(+BUG-200)
exit 0                        # every rollout waited successfully
$ kubectl -n redpanda exec redpanda-0 -- curl -s http://localhost:8081/subjects
["sol-demo-ts-orders-value","pluto-comms-notifications-value","pluto-payments-charges-value",
 "orders-fulfilled.v1-value","sol-demo-ts-fulfilled-value","orders.v1-value"]
$ curl -s localhost:8081/subjects      # the unrelated host broker on the same port
[]
```

Both namespaces run: `pluto-comms/notify-worker` ×2, `pluto-comms/fulfilment-worker`,
`pluto-checkout/checkout-svc`, `pluto-payments/charge-svc`, `pluto-payments/orders-svc`,
`pluto-demo-ts/order-svc`, `pluto-demo-ts/fulfillment-worker`.

### OCaml-lane rows (`rows-ocaml.sh all`, `ROWS_OCAML_SKIP_DEPLOY=1`)

```console
row b1: PASS     row b2: PASS     row b5: PASS
row b6: FAIL (2 assertion(s))
row d5: FAIL (4 assertion(s))
row h2: PASS
rows-ocaml: 2/6 row(s) failed
```

| Row | Verdict | Observation |
|---|---|---|
| `B1` | **PASS (LOCAL)** | `POST /orders` → `202 accepted`; duplicate idempotent; exactly one `orders` row and one `send_confirmation` job; the relay drains the key's outbox. |
| `B2` | **PASS (LOCAL)** | A pre-inserted `sol_outbox (key, ord)` collision makes the request fail (500) and leaves no domain row and no job — the transaction rolls back whole. |
| `B5` | **PASS (LOCAL)** | Read-back reaches `confirmed` through `fulfilled`; exactly one `fulfilled_orders` row, one `order_confirmations` row, one `release_inventory` job, one `send_confirmation` job; the relays drain. |
| `B6` | **FAIL (LOCAL)** | The duplicate-absorption assertions that passed (`one fulfilled row`, `one release_inventory job`, `one confirmation`, `no pending outbox`), but `orders-fulfilled.v1` carries **no record** for the key: "the OrderFulfilled fact is published before the duplicate: not satisfied after 90s" and "exactly one OrderFulfilled was published: expected [1], observed [0]". Mechanism not yet established (`B5` passes, so the flow completes): either the OCaml half never publishes `OrderFulfilled`, or the driver's probe of the topic is wrong. Next: `rpk topic consume orders-fulfilled.v1 -o beginning` and the relay's own log for that key. |
| `D5`/`H1` | **FAIL (LOCAL)** | The undecodable record produced **no** DLQ record on the group-scoped DLQ topic, `sol_worker_decode_errors_total` did not advance (`0 -> 0`), and a later valid order stayed `accepted` — the consumer did not advance past the poisoned record. Mechanism not yet established: either the decode path does not engage locally, or the driver's DLQ topic name differs from the worker's. Next: the worker's log for the poisoned key, and `rpk topic list` for the actual DLQ topic. |
| `H2` | **PASS (LOCAL)** | With the broker scaled to zero the requests still commit and the outbox holds the intent; after the broker returns and the workloads restart, both keys drain and reach `confirmed`. |

`B3`, `B4`, `C5`, `C6` were already `PASS (LOCAL)` from earlier evidence and are consistent
with `B1`/`B2`/`B5` here (one fact, one row, one job, one intent, ordering per key).

### Not yet run

- The TypeScript-lane rows (`rows-ts.sh all`) and the capability rows (`C1`–`C3`, `D1`–`D4`,
  `D6`, `F6`/`F8`/`F9`, `G1`–`G9`, `H7`), `capture`, and `teardown`. The deployment is
  healthy and the harness is in place, so these are observations, not blockers.
- `B6` and `D5`/`H1` above stay `FAIL` until their mechanisms are established; neither row
  is weakened to make the matrix look green.
