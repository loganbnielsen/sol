# FND-0050 — `sol-svc`'s JWKS cache holds a `Stdlib.Mutex` across its HTTPS fetch; a concurrent request gets an empty reply

- **Classification:** `VERIFIED_DEFECT`
- **State:** `OPEN`
- **First identified:** 2026-09-24, correctness audit pass 2
- **Last verified:** 2026-09-24 (`origin/main @ fd5c7e0c`)
- **Derived ticket:** `BUG-053`
- **Invariant:** fail loudly and correctly. A request that cannot be authenticated
  gets a 401/403/500 response and is counted, never a dropped connection.
- **Evidence class:** `BEHAVIORAL` (the real validator, run against two concurrent
  requests; cohttp-eio's behaviour when a callback raises)

## What is established

`get_jwks` (`framework/ocaml/sol-svc/lib/auth_internal.ml:182-198`) refreshes the
cache inside `Mutex.protect jwks_cache_mutex`. The fetch it runs there,
`fetch_jwks_over_https`, is an Eio HTTPS request, and Eio suspends the fiber while it
waits. Other request fibers on the same domain keep running. A second request that
misses the cache calls `Mutex.protect` on a mutex its own thread already holds.
OCaml 5 mutexes are error-checking, so that call raises
`Sys_error "Mutex.lock: Resource deadlock avoided"`.

Reproduced through `Test_auth_internal.validate` (the real `auth_internal.ml`), with
two concurrent validations and a `fetch_jwks` that sleeps 0.2 s the way a network fetch
yields:

```
PROBE request-2: raised Sys_error("Mutex.lock: Resource deadlock avoided")
PROBE request-1: Ok (verified)
```

The exception does not become a response. In `Service.dispatch`
(`framework/ocaml/sol-svc/lib/service.ml:145-173`), `auth_result` runs outside the
`try` that turns handler exceptions into a 500 (`:165`). So the exception propagates
into cohttp-eio's callback. A minimal cohttp-eio server whose callback raises gives:

```
on_error: Sys_error("Mutex.lock: Resource deadlock avoided")
curl: (52) Empty reply from server
http_code=000
```

The per-request metrics are recorded after `dispatch` returns
(`service.ml:361-379`), so nothing is counted either.

## When it happens

Every `Jwks_url` service, on every cache miss that overlaps another request: the first
requests after startup, and again each time the 300 s TTL (`jwks_ttl_s`) expires under
concurrent load.

## Related, same code

- A token signed with a key the IdP has just rotated in (new `kid`) is rejected with
  `JWT key id not found in JWKS` for up to 300 s, because a fresh cache is never
  refetched on a miss.
- The general shape: `dispatch`'s exception boundary covers only the handler. Any
  exception from authentication or body reading drops the connection without a
  response or a metric.

## Impact

High for services using `Jwks_url`: authenticated requests fail with no HTTP response,
at startup and periodically, with no metric.

## Remedy shape

Make the refresh single-flight and Eio-aware: an `Eio.Mutex`, or a shared
`Eio.Promise` that concurrent misses await. Widen `dispatch`'s exception boundary so
any exception outside the handler still becomes a counted 500. Refetch once on an
unknown `kid`, rate-limited. Test: two concurrent validations against a yielding fetch
both succeed, with exactly one fetch.
