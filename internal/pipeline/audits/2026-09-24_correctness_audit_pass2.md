# Correctness audit, pass 2: fail-loud and modeling (2026-09-24)

**Scope.** This pass covers what the 2026-09-21 fail-open audit and the 2026-09-23
correctness audit did not: `sol-svc`'s request path (routing, body limits,
authentication, JWKS), the observability exporters (`Sol_obs`, obs-loki-eio,
obs-tempo-eio), Kafka service configuration and publish, the Secret values that
deploy, `sol up`, rollback and `sol secret` write, and `sol-fn`'s push path.
Every finding was reproduced, not only read, except FND-0054. Nits and style are out of
scope. Base: `origin/main @ fd5c7e0c`.

## Findings

| Finding | Class | Severity | Evidence | Ticket |
|---|---|---|---|---|
| FND-0050 — the JWKS cache holds a `Stdlib.Mutex` across its HTTPS fetch; a request that misses the cache concurrently raises `Sys_error` and gets an empty reply, with no metric | `VERIFIED_DEFECT` | high | `BEHAVIORAL` | BUG-053 |
| FND-0051 — Loki/Tempo export runs synchronously in the caller's fiber (5 s timeout each), and `LOKI_URL` replaces stdout: a slow Loki slows every log call, a down Loki loses the lines | `DESIGN_GAP` | medium | `BEHAVIORAL` | OBS-048 |
| FND-0052 — every direct deploy, `sol up` or rollback re-renders `<svc>-secrets` values from the operator's shell, reverting `sol secret set` rotations and blanking an unset `SOL_API_KEY` | `VERIFIED_DEFECT` + `DESIGN_GAP` | high | `MECHANISM` + `BEHAVIORAL` (k3s) | BUG-054 (backlog: ownership decision) |
| FND-0053 — a `Jwks_url` with `http://` is fetched in plaintext and trusted for signature verification, although the spec promises TLS | `VERIFIED_DEFECT` | medium | `BEHAVIORAL` | SEC-009 |
| FND-0054 — `config_of_env` defaults unset Kafka, registry and admin addresses to localhost | `DESIGN_GAP` | low | `STATIC` | BUG-055 |

## How each was reproduced

- **FND-0050:** `Test_auth_internal.validate` (the real `auth_internal.ml`), with two
  concurrent validations and a fetch that sleeps 0.2 s. Result:
  `request-2: raised Sys_error("Mutex.lock: Resource deadlock avoided")`. A cohttp-eio
  server whose callback raises answers `curl: (52) Empty reply from server`. A
  standalone two-fiber program confirms OCaml 5's error-checking mutex under Eio.
- **FND-0051:** `Sol_obs.of_env` with `LOKI_URL` pointing at a listener that accepts and
  never answers. Result: `log_info returned after 5.00s`, with only a `backend_error`
  line on stderr.
- **FND-0052:** `render_spec ~secret_backend:Kubernetes_live` with both variables unset
  emits `POSTGRES_URL: ""` and `SOL_API_KEY: ""`. The deploy → `sol secret set` →
  deploy sequence, replayed with the same manifest shapes against a disposable
  `rancher/k3s:v1.30.4-k3s1` using its own kubeconfig, ended with the pre-rotation
  URL restored and `SOL_API_KEY` empty.
- **FND-0053:** `Jwks_url "http://127.0.0.1:18101/jwks.json"`, served by plain HTTP,
  through the real `fetch_jwks_over_https`. Result:
  `token VERIFIED with keys fetched over plaintext HTTP`.

The probes were throwaway test bodies and scratch programs, not committed. The
commands are in each finding.

## What the findings share

Three of the five are one shape: **a mechanism that is correct in isolation, placed in
a context whose concurrency or ownership it does not model.**

- A mutex correct for threads is used where fibers interleave (FND-0050).
- An exporter correct for a healthy backend runs on the request's critical path
  (FND-0051).
- A render correct for first creation is re-run against state another command owns
  (FND-0052).

The other two are the familiar silent-default shape: a documented guarantee, TLS for
JWKS, is never checked (FND-0053), and an unset address becomes localhost (FND-0054).

## Reviewed and not filed

- **Request body limit** (`service.ml:46-63`): `Content-Length` and a hard buffer limit
  are both enforced, and a malformed header falls through to the buffer limit. Clean.
- **Handler exceptions** become a logged 500 (`service.ml:165-172`). The gap is only
  outside the handler (FND-0050).
- **API key comparison** is constant-time. *Observation:* the principal's `key_id` is
  the first 8 characters of the presented key (`auth_internal.ml:32`). For the shared
  `SOL_API_KEY`, an application that logs the principal logs a prefix of the secret.
  Not filed: no Sol code logs it. Worth a one-line change if touched: derive `key_id`
  from a hash.
- **500 bodies** carry server-side configuration detail
  (`"API key not configured (set SOL_API_KEY…)"`, JWKS fetch errors). This is minor
  disclosure, not a correctness defect.
- **`Https_eio`** verifies certificates against the system CAs, with the host set.
  Clean for `https://`; FND-0053 is about the other schemes.
- **Rollout wait** (`sol_cli_up_execution.ml:114-157`) is tri-state per DEC-038.
  Clean.
- **Topic creation**: `Kafka.Producer.create_topic` maps already-exists to `Ok`.
  *Observation:* `Single_broker_loss` sets RF=3 without `min.insync.replicas`. That is
  safe on Redpanda, whose `acks=all` waits for a Raft majority, but not on an Apache
  Kafka substrate with a broker default of 1.
- **`sol-fn` Pushgateway failures** are logged and non-fatal by design (`fn.ml:72-86`).
- **`publish` has no key and partitions are fixed at 1**: design limits, not defects.

## Previously tracked, not re-filed

FND-0013 / INFRA-050 (placeholder Secret on a direct deploy) is fixed. FND-0052 is the
next consequence on the same surface. BUG-037 (TypeScript Loki status check) is
distinct from FND-0051.

## Recommended order

BUG-053 first: high severity, small and contained. Then SEC-009, same file, trivial.
Then OBS-048's in-repo stdout tee, which is independent of the exporter work. BUG-054
needs the ownership decision first. BUG-055 comes after SEC-007.

## What is not established

- FND-0052's apply sequence was replayed with hand-built manifests of the same shape
  as Sol's renders and `sol secret`'s manifest, not by running `sol deploy` and
  `sol secret set` end to end against a workspace.
- The TypeScript framework (`@sol-fab/*`) was not audited, beyond the parity notes in
  each ticket.
- Not exhaustive: `sol local` and its port-forwarding, pg-eio's pool behaviour, and the
  kafka-eio consumer under rebalance were out of scope. Absence of a finding there is
  not a claim that they are clean.
