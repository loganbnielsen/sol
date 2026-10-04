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

## Resume (2026-10-04, attempt 3) — probe defect fixed; B6 and D5/H1 mechanisms narrowed

`BUG-200` is merged (`f4bcaa5e` + the transition-guard relaxations) and the staged
`v0.1.0-alpha.7` candidate was rebuilt from the resulting `origin/main`
(`/tmp/sol-install-fixed/`, revision recorded in the run identity). The deployment under
test is the one attempt 2 produced.

### Defect in the run's own tooling (found, fixed here)

`rows-ocaml.sh` (and the TypeScript driver copied from it) read topics with
`rpk topic consume … -o beginning`, which this `rpk` rejects:

```console
$ timeout 6 rpk topic consume orders-fulfilled.v1 -o beginning
invalid --offset "beginning": unable to parse offset: cannot parse
```

Every topic read therefore returned nothing, and two assertions in the previous attempt
were unproven rather than failing: `B6`'s "OrderFulfilled was published" and
`D5`/`H1`'s "the DLQ topic receives the raw record". Both drivers now use `-o start`
(`rows-ocaml.sh:topic_records`, `rows-ts.sh:topic_records`).

### `B6` — the topic does hold the fact; the mechanism is elsewhere

With the read fixed, `orders-fulfilled.v1` holds the records (`rpk topic consume
orders-fulfilled.v1 -o start` → one per order key, including `qual-b6-…`), and the rerun
asserts:

```console
ok: B6 the order reaches confirmed before the duplicate
ok: B6 the OrderFulfilled fact is published before the duplicate
ok: B6 the duplicate is absorbed: one fulfilled_orders row
ok: B6 the duplicate is absorbed: one release_inventory job
ok: B6 the duplicate is absorbed: one confirmation effect
ok: B6 the duplicate publishes no second OrderFulfilled
FAIL: B6 exactly one OrderFulfilled was published: expected [1], observed [2]
verdict FAIL 1
```

So the duplicate injection does **not** add a third record — the third assertion is about
the count before it. The observation is that **two `OrderFulfilled` records exist for one
order before any injected duplicate**. Leading mechanism, to be confirmed next:
`sol_outbox` carries the intent as a unique `(aggregate_key, ord)` row that the relay
**deletes after the broker acknowledges**, so a redelivery of `OrderPlaced` — or a relay
republish after an unacknowledged send — re-creates `(key, 1)` and publishes a second
fact; the domain-row, job and confirmation dedupe absorb the redelivery at the effects,
but nothing gates the *intent*. Next probes: `sol_outbox` row id/ord history for the key
under a fresh row, the relay's publish log for both sends, and the consumer group's
offsets for the partition at the moment of the second publish. `B6` stays `FAIL`.

### `D5`/`H1` — the poisoned record does not take the decode-error path

Rerun after the probe fix (row executing at the time of writing; the earlier attempt's
observations below). The poisoned record is consumed — the group is `Stable` with
`TOTAL-LAG 0` and its offsets at `LOG-END-OFFSET` — yet:

```console
$ rpk group describe pluto-orders-fulfilment-worker
STATE Stable   TOTAL-LAG 0      # orders.v1 offsets 3/1/3 == log-end
$ curl -s --data-urlencode 'query=sol_worker_decode_errors_total' localhost:9090/api/v1/query
{"metric":{"__name__":"sol_worker_decode_errors_total", … "pod":"notify-worker-…"}}   # present, value 0
$ rpk topic consume orders.v1.pluto-orders-fulfilment-worker-97a0a6dbb628.dlq -o start | wc -l
0                                                                                      # the DLQ topic exists, empty
$ psql -c "select count(*) from fulfilled_orders where order_id='qual-d5-follow-20261004051500'"   # the later valid order
0        # while orders=1, sol_jobs=1, confirmations=0, sol_outbox=0
```

and the worker's log (last 25 lines) carries no decode/DLQ line at all.

Three facts, all independent of the broken probe: the DLQ topic exists and is empty; the
decode-error counter did not move; and the valid order that followed the poisoned record
was **never fulfilled** (`fulfilled_orders = 0`) although its `send_confirmation` job
exists. So the poisoned record neither produced the required decode log/metric/DLQ nor
left the consumer able to apply what followed it — while the offsets advanced. That is a
concrete, bounded defect in the OCaml worker's decode-error path (or in how the local
profile configures it), and it is the next thing to file and fix. `D5`/`H1` stay `FAIL`.

### Still not run

The TypeScript-lane rows (`rows-ts.sh all`), the capability rows (`C1`–`C3`, `D1`–`D4`,
`D6`, `F6`/`F8`/`F9`, `G1`–`G9`, `H7`), `capture` and `teardown`. The deployment is
healthy (both namespaces, all six subjects registered, the unrelated host broker on the
same port holding none), so these are observations rather than blockers.

## Resume (2026-10-04, final run at `47fc2266`) — the local rows qualify

Run identity: revision `47fc2266971bdd3db4ca1643e36e93dabd75984b`, staged bundle
`v0.1.0-alpha.7` (`bin/sol` + `share/sol/v0.1.0-alpha.7/platform`; runner digest synthetic,
as attempt 1 recorded), workspace `examples/pluto` of that revision, target `local` (k3d
`sol-local`), no cloud account and no provider call. Started `2026-10-04T07:16:09Z`;
`sol up` `[apply] ok (87.1s)`, 7 services, every unit on image tag `47fc2266`. Evidence
bundle `/tmp/alpha-verif027-47fc2266/` (33 entries, `evidence-manifest.txt`).

### What the candidate is, exactly

`origin/main` at `47fc2266` carries all of: `BUG-201` (#1063, the OCaml outbox relay drains
only the kinds it owns); `VERIF-027, part D` (#1064, the drivers inject a real duplicate
intent and terminate the produced record); `VERIF-027, part E` (#1065, poll the decode
metric; prove B5's ordering from timestamps); `BUG-202` (#1066, the TypeScript confirmation
requires a fulfilled order). The staged bundle was built from that revision, and the app
images were built from it too — the Docker build cache was pruned first, so the OCaml
framework was fetched fresh from the fixed `main` rather than reusing the pre-`BUG-201`
layer.

### Deviations, recorded

1. **`sol local infra up` could not re-reconcile.** Helm could not fetch the
   `bitnami/postgresql` chart from `registry-1.docker.io` (`UtilAcceptVsock … accept4
   failed 110`), so that phase failed before writing the run kubeconfig. The cluster from
   the preceding attempt was reused (Postgres, Redpanda, Loki, Grafana, Prometheus, Tempo
   and ingress already `Running`); the run kubeconfig and the namespace/release/pod
   inventory were captured directly (`k3d kubeconfig get`, `kubectl`, `helm list`). The
   cluster was **not** recreated, so this run does not independently re-establish
   provisioning from empty.
2. The unrelated native dev broker still owns `0.0.0.0:9092`/`8081`/`9644`; the deployed
   units and the drivers address the cluster (the drivers through `kubectl exec`), so it is
   inert.
3. **`sol local infra down` wrote its verdict to the default log dir** (the env was not
   exported into that invocation); its verdict — `cluster ABSENT`, `containers ABSENT` — is
   copied into the bundle as `teardown-verdict.txt`.

### Row verdicts

| Row | Verdict | Observation |
|---|---|---|
| `B1` OCaml + TS | **PASS (LOCAL)** | `POST /orders` → 202; duplicate idempotent; one row and one job in each namespace. |
| `B2` OCaml + TS | **PASS (LOCAL)** | The injected `sol_outbox (key, ord)` collision fails the request (500); no domain row and no job survive the rollback. |
| `B5` OCaml + TS | **PASS (LOCAL)** | Read-back `accepted → fulfilled → confirmed`, proven by `accepted_at <= fulfilled_at <= confirmed_at`; one row, job and effect. |
| `B6` OCaml + TS | **PASS (LOCAL)** | A duplicate `OrderPlaced` intent is relayed to the topic and absorbed: one row, one job, one effect, and **exactly one** `OrderFulfilled`. |
| `D5` / `H1` OCaml + TS | **PASS (LOCAL)** | An undecodable record → the structured decode log, `sol_worker_decode_errors_total` `0→1` (OCaml) and `1→2` (TS), a DLQ record carrying the raw bytes, and the next valid order still fulfilled. |
| `H2` | **PASS (LOCAL)** | Broker scaled to zero: requests commit and the outbox holds; after recovery and a relay restart both keys drain to `confirmed`. |
| `C1` | **PASS (LOCAL)** | `sol local migrate` → `Applying migrations …` / `Done.` |
| `D1` | **PASS (LOCAL)** | Every declared topic at 3 partitions (`orders.v1`, `orders-fulfilled.v1`, `sol-demo-ts-*`). |
| `D2` | **PASS (LOCAL)** | All six declared subjects present in the cluster registry. |
| `D3` | **PASS (LOCAL)** | A key's records all on one partition (`qual-b6-…` → partition 0). |
| `D4` | **PASS (LOCAL)** | Group-scoped `.dlq` topics exist for both namespaces; `D5` exercises the route. |
| `D6` | **PASS (LOCAL)** | `sol contract generate --check` → `the checked-in bindings match the declaration`. |
| `G1` | **PASS (LOCAL)** | `sol local logs --scope payments/orders-svc` returns that unit's lines with the identity fields on each. |
| `G2` | **PASS (LOCAL)** | `sol_worker_messages_total` carries `status`; `sol_svc_requests_total` carries `method`/`route`/`status_class`; both carry `workspace`/`domain`/`service`/`primitive`/`release`. The `env` dimension was **not** present on these series — recorded, not promoted. |
| `G6` | **PASS (LOCAL)** | `sol local status` → every domain `healthy`; observability `logs`/`metrics` `healthy`. |
| `G7` | **PASS (LOCAL)** | `sol check` → `ok`, exit 0. |
| `B3`, `B4`, `C5`, `C6` | unchanged `PASS (LOCAL)` | Prior evidence; B1/B2/B5/B6 re-exercise the same relay/job/outbox paths here. |
| `C3`, `F8`, `F9`, `G3`–`G5`, `G8`, `G9`, `H7` | **NOT RUN (this run)** | Not observed here; they keep their prior verdicts (mostly `PASS OFFLINE`/`PASS (LOCAL)`). No verdict was weakened. |
| `B7`, `A*`, `F6`, `J*` | unchanged | Need the installed bundle or a cross-language contract that is `NOT RUN`/`OFFLINE` as before. |
| `C2`, `C4`, `D7`, `D8`, `E2`, `E4`–`E8`, `F1`–`F5`, `F7`, `H3`–`H6`, `I*` | unchanged | Provider rows; a local cluster cannot establish them. |

Capability-row commands and output are in `/tmp/alpha-verif027-47fc2266/capability/`.

Teardown: `sol local infra down --cluster` → `cluster ABSENT`, `containers ABSENT`.

### Defects this campaign exposed, and their state

- `INFRA-102` — `sol up` registered contracts at a literal `localhost:8081` that is the
  native dev broker on this host. Fixed and merged (`449d933c`).
- `BUG-200` — the workspace's `contract/run` sent the whole-workspace scope only to the
  OCaml runner, so the TypeScript scope was never registered. Fixed and merged (`9c59d4be`).
- `BUG-201` — `Sol_outbox.Make(E).relay` drained every kind in the shared `sol_outbox`
  table, so each relay cross-published another unit's rows (two `OrderFulfilled` records
  for one order before `B6`'s injection). Fixed, mutation-tested and merged (`478bd72c`);
  `B6` reruns green above.
- `BUG-202` — the TypeScript `send_confirmation` job confirmed with no `fulfilled_at`
  guard, so a job claimed before `OrderPlaced` was consumed confirmed an unfulfilled order
  (`confirmed_at` preceded `fulfilled_at`) and the read-back never reached `confirmed`.
  Fixed, mutation-tested and merged (`47fc2266`); TS `B5`/`B6` rerun green above.
- The run's own drivers carried three defects, fixed in the campaign's own PRs: `rpk topic
  consume -o beginning` rejected by this `rpk` (part C); a payload with no trailing newline
  (never produced) and a raw-JSON duplicate that is not Confluent-framed (part D); and a
  decode-metric read taken before Prometheus scraped, plus a race-prone transient
  `fulfilled` sample (part E). Each mutation-checked.

### What this run does not establish

- Nothing provider-side: `C2`, `C4`, `D7`/`D8`, `E2`, `E4`–`E8`, `F1`–`F5`, `F7`,
  `H3`–`H6` and `I*` stay `NOT RUN`/`BLOCKED`.
- `A1`, `J1`–`J4` need the published release; this bundle is the staged archive with a
  synthetic runner digest, as attempts 1–3 recorded.
- The cluster was reused rather than recreated (deviation 1).

