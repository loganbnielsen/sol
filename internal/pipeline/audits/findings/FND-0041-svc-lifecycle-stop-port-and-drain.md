# FND-0041 — `sol-svc` lifecycle: external `stop` never reaches the server, a malformed `PORT` is ignored, and SIGTERM stops accepting before endpoints drain

- **Classification:** (a) and (b) `VERIFIED_DEFECT`; (c) `QUALIFICATION_GAP`
- **State:** `OPEN`
- **First identified:** 2026-09-23, correctness audit
- **Last verified:** 2026-09-23 (`origin/main @ f3e9480b`)
- **Derived ticket:** `BUG-046` (a and b), `INFRA-073` (readiness/preStop)
- **Evidence class:** `BEHAVIORAL` for (a) and (b) (probe runs below); `STATIC` for (c)

## (a) External `stop` is raced against the drain timer, never delivered to the server

`Service.Make.run` (`framework/ocaml/sol-svc/lib/service.ml:359-370`) passes only
`signal_stop` to `Cohttp_eio.Server.run ~stop`. The caller's `?stop` promise feeds
`await_stop` in the *other* branch of `Fiber.first`, which sleeps `drain_timeout_s` and
raises `Drain_timeout`. So after an external stop the server **keeps accepting new
requests** for the full drain window (default 30s), then is force-cancelled and logs
`drain timeout reached, forcing shutdown`, even with nothing in flight. The `sol-svc`
tests pass `~drain_timeout_s:0.1`, which hides this.

Probe (links `sol_svc`; routes = []; `~stop` resolved from `on_listen`;
`~drain_timeout_s:3.0`):

```text
sol-svc listening on :46877
sol-svc: drain timeout reached, forcing shutdown
run returned Ok () after 3.00s (no request was in flight)
```

## (b) A malformed `PORT` silently falls back

`service.ml:241-247`: `try int_of_string (String.trim s) with _ -> port`. Probe with
`PORT=80800x` and `PORT=tcp://10.0.0.1:8080`: both start and listen on the fallback
port. No message names the bad value. In a pod, the Service and probes target the
intended port, so the result is a failing readiness probe with nothing pointing at the
cause. It should be `Error (`Config …)` like every other config error `run` returns.

## (c) SIGTERM stops accepting before the endpoint is removed

On SIGTERM, `Server.run ~stop` stops accepting at once. Kubernetes removes the pod from
Service endpoints asynchronously, and rendered manifests have no `preStop` hook
(`sol_cli_manifest_yaml.ml`: `terminationGracePeriodSeconds` only). `/healthz` serves
startup, liveness **and** readiness and never turns unready during drain. Requests routed
to a terminating pod in that window are refused, on every rolling deploy. Not observed
live, hence `QUALIFICATION_GAP`. The fix is a readiness flip plus a short pre-stop delay
before closing the listener.

## Impact

Medium. (a) mis-reports and delays every programmatic shutdown (tests, embedding, the
demo). (b) turns a config typo into an undiagnosed probe failure. (c) can drop requests
on each rollout.

## Related

FEAT-036 / FEAT-086 (drain behaviour); FND-0042 (signal handling).
