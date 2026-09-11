---
id: FEAT-045
type: feature
severity: medium
source: FEAT-041 implementation 2026-09-09 (completion notes — trace continuity documented, not implemented)
---

**Depends on:** FEAT-041 (must be in `DONE`).

Add a small first-class outbound client helper for declared synchronous service calls that sets `x-api-key` and forwards the current `traceparent`, so app code does not hand-roll `cohttp-eio` header plumbing.

## Problem

FEAT-041 makes Sol wire a declared call: it injects `<SERVICE>_URL`, opens the per-pair NetworkPolicy, and emits `SOL_API_KEY` in the generated Secret. But the request itself is still entirely the app author's job:

- read the `<SERVICE>_URL` env var (easy to hardcode DNS instead),
- set `x-api-key` from `SOL_API_KEY_FILE`/`SOL_API_KEY` (miss it -> 401),
- serialize and forward the current W3C `traceparent` (`Obs_trace.inject_to_headers` from `Sol_obs.current_trace_context`) so the callee's span joins the caller's trace (miss it -> disconnected traces).

`docs/deployment/service-runtime-contract.md` documents the pattern, but nothing enforces it, and FEAT-041's CI check uses a probe pod rather than instrumented app code — so there is no test that a real caller is instrumented correctly. Getting either header wrong is silent at deploy time and only shows up later as a 401 or a broken trace in Tempo.

## Goal

A caller can make an instrumented request to a declared peer without re-deriving header names, env-var naming, or trace serialization — and a test proves the wiring.

## Remediation

- Add a minimal client helper (likely `framework/sol-svc`, or `sol-env` if it should be primitive-agnostic) — for example a low-level `with_peer_headers : ot:_ -> span:_ -> peer:string -> (string * string) list -> (string * string) list` that adds `x-api-key` and `traceparent`, plus optionally a typed `get`/`post_json` wrapper over `cohttp-eio`.
- Resolve `peer` to `<PEER>_URL` using the same env-var derivation FEAT-041 uses (`call_env_var`), so a typo fails loudly rather than hitting the wrong host.
- Keep it explicitly opt-in and events-first: no service registry, no automatic retries, no implicit caching.
- Add unit coverage for header injection and env-var resolution, and make at least one *instrumented* call in an example/smoke path so a missing header fails CI rather than only showing up in Tempo.
- Decide whether the TypeScript packages (`@sol/kafka`, `@sol/obs`) need a parallel helper; likely out of scope until a TS workspace has a real caller.

## Acceptance criteria

- A caller module can make a declared synchronous call at one call site, with `x-api-key` and `traceparent` set by the helper rather than by the app author.
- A unit test asserts both headers are set, and that `traceparent` comes from the current span's context.
- A deployed/e2e check exercises an *instrumented* app call (not only a probe pod), so a regression in header propagation fails CI.
- The "Synchronous service calls" docs section points at the helper instead of describing manual `cohttp-eio` plumbing.

## Completion notes

Implemented as `Sol_svc.Peer` (`framework/sol-svc/lib/peer.ml`):

- `Peer.env_var` derives `<PEER>_URL` from the declared source name, matching FEAT-041's `call_env_var` derivation.
- `Peer.url` reads that env var and rejects anything that is not an absolute http(s) URL, so a bad value fails loudly instead of silently hitting the wrong host.
- `Peer.headers` sets `x-api-key` from `SOL_API_KEY_FILE` (preferred) then `SOL_API_KEY`, and injects the W3C `traceparent` from a supplied `Obs_trace` context.

Tests (`framework/sol-svc/test/test_peer.ml`, 5 cases) cover env-var normalization, URL resolution, the relative-URL rejection, headers taken from the current span (asserting `traceparent` equals `Obs_trace.to_traceparent` of that span's context), and `SOL_API_KEY_FILE` precedence.

The call site is `charge_svc`'s `GET /checkout-quote` calling `checkout_svc`'s `GET /quote`; that route uses `` `Api_key`` auth, so the example fails with a 401 if the header wiring regresses. Docs: "Synchronous service calls" now points at `Peer` rather than manual plumbing, and `sol-svc.md` documents the module.

Review cleanup: `Peer.headers` originally took a `~peer:string` argument that was discarded (`~peer:_`). Removed from the implementation, interface, docs and tests — an argument every caller must pass and that does nothing is worse than no argument.

**Criterion 3 is not met as written.** "A deployed/e2e check exercises an instrumented app call" is not achievable on the pinned dev substrate: kube-router on k3s does not honour the generated per-pair policy, so a live cross-namespace call is refused regardless of header correctness (BUG-022). What exists instead: the unit tests above, the new `example-dockerfile-smoke` matrix entry for the example, and a host-local runnable path in `examples/pluto/README.md` (two host processes, `CHECKOUT_SVC_URL=http://127.0.0.1:8081`) that exercises the helper and its headers without a cluster. When BUG-022 is resolved this criterion should be revisited — it is the check that would catch a genuine propagation regression.
