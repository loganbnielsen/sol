---
id: FEAT-086
type: feature
severity: low
source: FEAT-036 follow-up (published-package rewiring, sol repo)
---

**Depends on:** FEAT-036 (done — `@sol-fab/svc@0.1.0` and `@sol-fab/worker@0.1.0` are published to npm, OIDC trust configured for both).

Replace `examples/pluto/app/demo_ts`'s hand-rolled shutdown code in `order_svc` and `fulfillment_worker` with the published `@sol-fab/svc`/`@sol-fab/worker` packages, and rerun the TypeScript golden path (`sol up --scope=demo_ts`) to prove the *distributed* packages work end to end — a different proof than FEAT-036's scratch/typecheck validation, which only established the API boundary was right.

## Premise check (2026-09-16)

- `npm view @sol-fab/svc version` → `0.1.0`, `npm view @sol-fab/worker version` → `0.1.0`. Both resolve on the public registry (checked after this ticket was filed, post npm-trust flip).
- `order_svc/src/index.ts` and `fulfillment_worker/src/index.ts` still hand-roll `DRAIN_TIMEOUT_MS`/signal guards as of `05c86c98` (FEAT-036's merge) — premise holds, not yet fixed.

## Remediation

1. `order_svc/package.json`: add `"@sol-fab/svc": "^0.1.0"` to `dependencies`. `order_svc/src/index.ts`: import `runService` from `@sol-fab/svc` and replace the hand-rolled `DRAIN_TIMEOUT_MS`/guard/`Promise.race` block with it — this exact wiring was already validated against a scratch copy in FEAT-036 (drain: `() => app.close()`, shutdownHooks: `producer.disconnect`, `shutdownTracing`).
2. `fulfillment_worker/package.json`: add `"@sol-fab/worker": "^0.1.0"`. `fulfillment_worker/src/index.ts`: import `runWorker`, replace the hand-rolled guard with it (drain: disconnect both consumers; shutdownHooks: producer disconnect, metrics server close, db close, tracing shutdown) — same shape already validated in FEAT-036.
3. Regenerate both units' `package-lock.json` (`npm install`) so the published versions are actually locked, not just declared.
4. Verify locally: `npm run build` (tsc) and existing unit tests (if any) in both units.
5. Run the real golden path: `sol local infra up` (or confirm already healthy), `sol up --scope=demo_ts` from a clean `examples/pluto` workspace, confirm both pods roll out healthy, and repeat FEAT-082's minimal transaction check (`POST /orders` → Kafka → worker → Postgres row) to confirm the swapped-in packages don't change runtime behavior.
6. Record the run's result in this ticket's completion notes (pass/fail, what was observed) — this is the proof FEAT-036 deferred.

## Non-goals

- Not re-deciding the `@sol-fab/svc`/`@sol-fab/worker` API — that's FEAT-036, already closed.
- Not touching `@sol-fab/kafka`/`@sol-fab/obs` wiring — already correct and unrelated to this change.
- Not `@sol-fab/fn` — no package exists, not in scope.

## Demo/example coverage

This ticket *is* the example/demo update (`examples/pluto/app/demo_ts`) — the runnable fixture itself is the artifact being fixed, so no separate example is needed beyond it.

## TypeScript-parity note (DEC-022)

No new capability or convention introduced — this replaces an in-app copy of an already-decided contract (FEAT-036) with the published package implementing it. No cross-language action needed.

## Completion notes (2026-09-16) — PASS

Both units rewired and verified against the real published packages, not
a scratch copy:

- `order_svc`/`fulfillment_worker` `package.json`: `"@sol-fab/svc":
  "^0.1.0"` / `"@sol-fab/worker": "^0.1.0"` added. `demo_ts`'s
  `package-lock.json` (the workspace's real lockfile — `order_svc`/
  `fulfillment_worker` are npm workspaces of `demo_ts`, not independent
  npm projects) pins both to the real registry tarball
  (`registry.npmjs.org/@sol-fab/svc/-/svc-0.1.0.tgz` etc.), not a local
  path.
- `npm run build --workspace=order_svc` / `--workspace=fulfillment_worker`
  (`tsc`) both clean.
- Real golden path, `sol up --scope=demo_ts` against the local cluster:
  both pods rolled out `Running 1/1`, 0 restarts, no `CrashLoopBackOff`.
- Full transaction, marker `feat086-e2e-1`: `POST /orders` → `202
  {"accepted":true}` → Kafka → `[worker] fulfilled order=feat086-e2e-1
  item=widget` → Postgres row confirmed by direct query
  (`feat086-e2e-1|widget|2|dedaf186`).
- Metrics intact: `sol_svc_requests_total{method="POST",route="/orders",status_class="2xx"} 1`.
- Graceful shutdown: deleted the `order-svc` pod with a 30s grace
  period; the replacement came up `Running 1/1` with 0 restarts on
  either pod and no `CrashLoopBackOff` — `@sol-fab/svc`'s drain path
  didn't hang or force-kill under normal (no in-flight-request) load.

This is the distributed-package proof FEAT-036 deferred: the scratch/
typecheck validation showed the API boundary was right; this run shows
the *published* packages work in the actual golden path, not just in
isolation.
