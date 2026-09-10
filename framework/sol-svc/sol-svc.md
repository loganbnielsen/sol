# sol-svc

HTTP service layer for Sol. Provides route definition, authentication middleware,
request/response types, and the `Sol_svc.Service.Make` functor that owns the
complete server lifecycle under Eio. Route handlers are pure OCaml functions —
they never import cohttp types.

HTTP engine: **cohttp-eio**. Entirely hidden behind `Sol_svc.Service.Make`.
Swappable without touching user space.

---

## Package Structure

```
http/
  dune-project
  sol-svc/
    lib/
      sol_svc.ml          ← entry point: re-exports Auth, Route, Request, Response, Service
      auth.ml/.mli        ← auth levels, principals, internal validation
      request.ml/.mli     ← request type seen by handlers
      response.ml/.mli    ← response helpers
      route.ml/.mli       ← route type and constructors
      service.ml/.mli     ← HANDLER module type + Make functor
      dune
    test/
      test_routing.ml     ← path matching, method dispatch (no server)
      test_auth.ml        ← auth validation logic (no server)
      test_service.ml     ← full round-trip tests (live server, OS-assigned port)
      dune
    sol-svc.md
```

Single dune workspace under `http/`. Library name `sol-svc`, OCaml name `sol_svc`,
**`(wrapped true)` (default)** — all modules are namespaced under `Sol_svc`.

### Why `(wrapped true)`

The existing packages use `(wrapped false)` for internal packages where names are
unique enough to be safe globally (`Kafka_error`, `Obs_trace`, etc.). For
`sol-svc`, the module names (`Auth`, `Route`, `Request`, `Response`, `Service`)
are short and highly collision-prone with third-party libraries. `(wrapped true)` is
the ecosystem-standard convention; modules live under `Sol_svc` and cannot clash
with anything external.

### Entry point: `sol_svc.ml`

```ocaml
(* sol_svc.ml — re-exports internal modules under clean names *)
module Auth     = Auth
module Route    = Route
module Request  = Request
module Response = Response
module Service  = Service
```

Users either fully qualify (`Sol_svc.Route.post`) or `open Sol_svc` once.
All examples below use the qualified form.

---

## Module: `Sol_svc.Auth`

### Types

```ocaml
(** Authentication strategy, declared explicitly on every route.
    Sol does not infer auth from path conventions. *)
type level =
  [ `Public
  | `Api_key
  | `Jwt of jwt_config
  ]

and jwt_config =
  { scopes       : string list
  (** Required scopes, e.g. ["write:payments"]. All must be present. *)
  ; verification : jwt_verification
  (** [Verified_signature_required] is the production-facing mode: signature,
      issuer, audience, and algorithm allowlist are all checked before a
      token is trusted. [Unverified_dev_only] decodes unsigned v1 tokens and
      must only be used for local development and tests. *)
  }

and jwt_verification =
  | Verified_signature_required of jwt_verified_config
  | Unverified_dev_only

and jwt_algorithm = [ `HS256 | `RS256 | `ES256 | `ES384 | `ES512 ]

and jwt_key_source =
  | Hs256_secret of string
      (** Shared secret. Verified through [jose]'s HS256 path — never a
          hand-rolled HMAC comparison. *)
  | Jwks_static  of string
      (** A JWKS document (RFC 7517), e.g. baked into config for a fixed,
          non-rotating key set. *)
  | Jwks_url     of string
      (** HTTPS URL of a JWKS endpoint (Auth0/Cognito/Okta-style). Fetched
          over TLS and cached for 5 minutes; never fetched on every request. *)

and jwt_verified_config =
  { issuer     : string
  ; audience   : string
  ; algorithms : jwt_algorithm list
  (** Allowlist. A token whose header [alg] is not in this list is rejected
      before any key lookup or signature check runs. *)
  ; key_source : jwt_key_source
  }

(** Resolved identity after successful validation.
    Available in the handler via [Request.t.auth]. *)
type principal =
  | Public
  | Service of { key_id : string }
      (** [key_id] = first 8 chars of validated key. Safe to log. *)
  | User of
      { sub    : string
      ; scopes : string list
      ; claims : Yojson.Safe.t
        (** Full decoded JWT payload as JSON. JWT claims are not always strings
            ([exp] is int, custom claims may be arrays or objects). Returning the
            raw [Yojson.Safe.t] avoids lossy coercion to [(string * string) list]. *)
      }

type context = { principal : principal }
```

### Public API

`Auth` exposes only types in its `.mli`. The validation function is internal,
called by `Service.Make`, not by user code.

### Auth strategy details

**`` `Public ``** — no validation. Returns `{ principal = Public }` immediately.

**`` `Api_key ``** — validates `X-Api-Key: <key>` header. Key source resolution
(checked in order):

1. `SOL_API_KEY_FILE` env var — path to a file containing the key. Read on every
   validation so k8s secret volume remounts take effect without restart.
2. `SOL_API_KEY` env var — direct value; for local development only.

Environment variables do not update in a running process on Linux. Relying on
`SOL_API_KEY` alone means a secret rotation requires a pod restart. Use
`SOL_API_KEY_FILE` pointing to a k8s `Secret` volume mount for production.

On success: `Service { key_id }` where `key_id` is the first 8 characters of the
validated key. Missing header or wrong value → 401.

**`` `Jwt config ``** — validates `Authorization: Bearer <token>`.
For v1 development mode (`verification = Unverified_dev_only`):

1. Split on `.`, assert three segments (header.payload.signature).
2. Base64url-decode the payload. Parse as JSON with `Yojson.Safe.from_string`.
3. Check `exp` claim (integer) is not in the past (`Unix.gettimeofday`).
4. Check every scope in `config.scopes` is present in the token's `scope` claim
   (space-separated string or JSON array).
5. Return `User { sub; scopes = token_scopes; claims = full_payload_json }`.

For production mode (`verification = Verified_signature_required vconfig`):

1. Parse the token (header + payload) with [`jose`](https://github.com/ulrikstrid/ocaml-jose) —
   no hand-rolled base64/signature comparison anywhere in this path.
2. Reject if the header's `alg` is not in `vconfig.algorithms` — before any key
   lookup or signature check.
3. Resolve the verification key from `vconfig.key_source`:
   - `Hs256_secret secret` — a `jose` HS256 (`Oct`) key built from the shared secret.
   - `Jwks_static doc` — parse the JWKS document, look up by the token's `kid`.
   - `Jwks_url url` — fetch the JWKS over HTTPS (`https-eio`, so RNG seeding and
     CA-bundle handling are inherited, not reimplemented), cache it for 5 minutes,
     look up by `kid`. A fetch or parse failure returns `Server_error` (500) —
     it never falls back to `Unverified_dev_only` behavior.
4. Verify the signature and `exp` via `Jose.Jwt.validate`.
5. Check `iss` equals `vconfig.issuer` and `aud` contains `vconfig.audience`
   (`aud` may be a single string or a JSON array per RFC 7519).
6. Check every scope in `config.scopes` is present in the token's `scope` claim.
7. Return `User { sub; scopes = token_scopes; claims = full_payload_json }`.

HS256 support exists alongside JWKS-based RS256/ES256/ES384/ES512 because plenty
of real deployments are HS256-only — but it always goes through the same `jose`
verification call, never a separate hand-rolled comparison. There is no code
path where an attacker-supplied `alg` can force HMAC verification against an
RSA/EC public key: `jose`'s `Jws.validate` dispatches on the concrete key value
you pass it (a GADT), not on the token's claimed `alg`, so key selection is
driven by `kid` lookup in the JWKS, not by attacker input.

**Error responses:**

| Condition | HTTP status |
|---|---|
| Missing `Authorization` / `X-Api-Key` header | 401 |
| Wrong API key | 401 |
| `SOL_API_KEY` and `SOL_API_KEY_FILE` both unset | 500 (misconfiguration) |
| Malformed JWT (not three base64 segments, in dev mode) | 401 |
| Expired JWT | 401 |
| JWT missing a required scope | 403 |
| Verified mode: malformed token, `alg` not in allowlist, unknown/missing `kid`, invalid signature, wrong `iss`/`aud` | 401 |
| Verified mode: JWKS fetch or parse failure (`Jwks_url`) | 500 (fail closed) |

---

## Module: `Peer`

`Peer` is the outbound helper for declared `[service] calls`.

```ocaml
val env_var : string -> string
val url : string -> (Uri.t, [ `Config of string ]) result

val headers
  :  env:< fs : Eio.Fs.dir_ty Eio.Path.t ; .. >
  -> ?trace_ctx:Obs_trace.t
  -> ?headers:(string * string) list
  -> unit
  -> ((string * string) list, [ `Config of string ]) result
```

`Peer.url "checkout_svc"` reads `CHECKOUT_SVC_URL`, matching the env var Sol
injects for `calls = ["checkout/checkout_svc"]`. `Peer.headers` sets
`x-api-key` from `SOL_API_KEY_FILE`/`SOL_API_KEY` and adds `traceparent` when
given the current span context.

---

## Module: `Sol_svc.Route`

### Types

```ocaml
type method_ = [ `GET | `POST | `PUT | `PATCH | `DELETE ]

type handler = Request.t -> Response.t

type t =
  { method_  : method_
  ; pattern  : string   (* e.g. "/users/:id/posts/:post_id" *)
  ; auth     : Auth.level
  ; handler  : handler
  }
```

### Public API

```ocaml
val get    : string -> auth:Auth.level -> handler -> t
val post   : string -> auth:Auth.level -> handler -> t
val put    : string -> auth:Auth.level -> handler -> t
val patch  : string -> auth:Auth.level -> handler -> t
val delete : string -> auth:Auth.level -> handler -> t
```

### HTTP method mapping

cohttp exposes `Http.Method.t`, which includes `HEAD`, `OPTIONS`, `CONNECT`,
`TRACE`, and an open `Other of string` catch-all. The framework maps incoming
methods to `Route.method_` internally:

```ocaml
let method_of_http : Http.Method.t -> method_ option = function
  | `GET    -> Some `GET
  | `POST   -> Some `POST
  | `PUT    -> Some `PUT
  | `PATCH  -> Some `PATCH
  | `DELETE -> Some `DELETE
  | _       -> None
```

`None` (HEAD, OPTIONS, etc.) → 405 before routing. This prevents a pattern-match
exception from an unhandled constructor. `HEAD` and `OPTIONS` support deferred to
a later phase.

### Path matching

Route patterns use `:name` segments to declare path parameters:

| Pattern | Request path | Match? | Params |
|---|---|---|---|
| `/users/:id` | `/users/42` | yes | `[("id","42")]` |
| `/users/:uid/posts/:pid` | `/users/1/posts/99` | yes | `[("uid","1");("pid","99")]` |
| `/users` | `/users/` | no | — trailing slash is significant |
| `/users/:id` | `/users/1/extra` | no | — segment count differs |

**Rules:**
- Split path on `/`, filter empty strings. Segment counts must be equal.
- Literal segments match exactly (case-sensitive).
- `:name` captures one segment (no slashes within a capture).
- No wildcards, no optional segments in v1.

**Matching order — strictly top-to-bottom:**
1. Built-in routes: `/healthz` first, then `/metrics`.
2. User routes (`H.routes`) in declaration order; first match wins.
3. Method mismatch on a path that matches → 405.
4. No match → 404.

Built-in routes are not shadowable by user-defined routes. If a user defines
`GET /healthz`, it is never reached. The `/metrics` auth level is configurable
via the `~metrics_auth` argument on `run` (see below) — there is no need to
shadow it with a user route.

---

## Module: `Sol_svc.Request`

```ocaml
type t =
  { method_  : Route.method_
  ; path     : string
  ; headers  : Http.Header.t
  (** [Http.Header.t] from the [http] package. Case-insensitive, O(log N) lookup. *)
  ; params   : (string * string) list   (* extracted path params *)
  ; uri      : Uri.t
  (** Full request URI. Use [Uri] functions for query string access. *)
  ; body     : string                   (* pre-read, bounded by max_body_bytes *)
  ; auth     : Auth.context
  }

val param : t -> string -> string option
(** Path parameter lookup. [param req "id"] → [Some "42"] or [None]. *)

val param_exn : t -> string -> string
(** Path parameter lookup; raises [Not_found] if absent.
    Use when the route pattern guarantees the param — e.g. in a GET /users/:id handler,
    [param_exn req "id"] is always safe. *)

val query_param : t -> string -> string option
(** First value of a query parameter. [query_param req "page"].
    Uses [Uri.get_query_param] — handles percent-decoding, bare flags, multi-value. *)

val query_params : t -> string -> string list
(** All values of a query parameter. [query_params req "tags"] for [?tags=a&tags=b]. *)

val header : t -> string -> string option
(** Case-insensitive header lookup via [Http.Header.get]. [header req "content-type"] *)
```

**`Http.Header.t`:** The `http` package (bundled with cohttp-eio) provides a
normalised header representation with correct case-insensitive semantics and O(log N)
lookup. A plain `(string * string) list` requires manual case folding and O(N) scan.

**`Uri.t` for queries:** `Uri.get_query_param` and `Uri.get_query_params` handle
percent-decoding, multi-value params, and bare flags correctly. Parse once at request
construction time; all query helpers delegate to it.

**Body pre-reading:** The framework reads the entire body before calling the handler,
up to `max_body_bytes`. Streaming bodies deferred to a later phase.

---

## Module: `Sol_svc.Response`

```ocaml
type t =
  { status  : int
  ; headers : (string * string) list
  ; body    : string
  }

(* 2xx *)
val ok          : ?headers:(string * string) list -> string -> t   (* 200 *)
val created     : ?headers:(string * string) list -> string -> t   (* 201 *)
val no_content  : t                                                 (* 204 *)

(* 4xx *)
val bad_request     : string -> t   (* 400, Content-Type: text/plain *)
val unauthorized    : t             (* 401 *)
val forbidden       : t             (* 403 *)
val not_found       : t             (* 404 *)
val unprocessable   : string -> t   (* 422, Content-Type: text/plain *)
val payload_too_large : t           (* 413, returned by framework before handler *)

(* 5xx *)
val internal_error  : string -> t   (* 500, Content-Type: text/plain *)
val not_implemented : t             (* 501, returned for unsafe JWT with false flag *)

(** [json ?status ?headers body] sets Content-Type: application/json automatically.
    [status] defaults to 200. *)
val json : ?status:int -> ?headers:(string * string) list -> string -> t
```

---

## Module: `Sol_svc.Service`

### `HANDLER` module type

```ocaml
module type HANDLER = sig
  val routes : Route.t list
end
```

### `Make` functor

```ocaml
module Make (H : HANDLER) : sig
  val run
    :  env:_ Eio.Stdenv.t
    -> ?port:int
       (** Default: 8080. Overridden by PORT env var if set. Pass 0 for
           OS-assigned port (use with [on_listen] in tests). *)
    -> ?ot:Sol_obs.t
       (** Observability handle. When provided, sol_svc_requests_total/
           sol_svc_request_duration_seconds are emitted per request, and
           GET /metrics renders from the same handle. If omitted,
           GET /metrics → 404. *)
    -> ?metrics_auth:Auth.level
       (** Auth strategy for the built-in /metrics endpoint. Default: [`Public].
           Set to [`Api_key] for production clusters that don't use NetworkPolicy
           to restrict Prometheus scraper access. *)
    -> ?max_body_bytes:int
       (** Maximum request body size in bytes. Default: 10_485_760 (10 MB).
           Requests exceeding this limit receive 413 before the handler is called. *)
    -> ?drain_timeout_s:float
       (** Seconds to wait for active requests after shutdown signal. Default: 30.0. *)
    -> ?on_listen:(int -> unit)
       (** Called with the actual bound port immediately before the accept loop.
           Use with [~port:0] in tests to discover the OS-assigned port. *)
    -> unit
    -> unit
end
```

`run` never returns under normal operation. Exits after SIGTERM/SIGINT + drain.

---

## Runtime Loop

### Startup sequence

```
1. Resolve port: PORT env var > ~port arg > 8080
2. Bind: Eio.Net.listen ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.any, port))
3. Discover actual port via Eio.Net.listening_addr (handles port 0)
4. Call on_listen actual_port (if provided)
5. Log "sol-svc listening on :<port>" to stderr
6. Enter structured shutdown + accept loop
```

### Structured shutdown model

The design requires two properties:
- Receiving SIGTERM while idle (no active connections) must exit promptly, not wait
  for the next TCP connection to arrive.
- Active connections must drain cleanly after the accept loop stops, but the drain
  window must cap out at `drain_timeout_s` — the server must not hang indefinitely
  if connections are slow.

**The flaw in a pure nested-switch approach:** forking the timeout fiber into
`connections_sw` prevents early exit — the timeout keeps the switch alive even
after all connections finish. An `Eio.Fiber.first` drain race is required instead.

**The flaw in a `Promise.peek` accept loop:** `Eio.Net.accept_fork` blocks until
a connection arrives. SIGTERM on an idle server resolves the stop promise, but the
loop does not observe it until the next connection — potentially never. The signal
fiber must cancel the accept switch directly.

**Correct model — three scopes:**

```
outer_sw         — entire server lifespan
  accept_sw      — governs only the accept loop; signal fiber cancels this
  connections_sw — governs all connection handler fibers; outlives accept_sw
```

```ocaml
Eio.Switch.run (fun outer_sw ->
  Eio.Switch.run (fun connections_sw ->
    let active       = Atomic.make 0 in
    let all_done, all_done_r = Eio.Promise.create () in

    (try
      Eio.Switch.run (fun accept_sw ->
        (* Signal fiber: cancels the accept loop, not the connection handlers *)
        Eio.Fiber.fork ~sw:outer_sw (fun () ->
          await_signal ();
          Eio.Switch.turn_off accept_sw Exit
        );
        while true do
          Eio.Net.accept_fork ~sw:connections_sw socket ~on_error:log_exn
            (fun conn _addr ->
              Atomic.incr active;
              Fun.protect
                ~finally:(fun () ->
                  (* Resolve all_done when the last connection finishes *)
                  if Atomic.fetch_and_add active (-1) = 1 then
                    (try Eio.Promise.resolve all_done_r ()
                     with Invalid_argument _ -> ()))
                (fun () -> handle_connection conn))
        done
      )
    with Exit | Eio.Cancel.Cancelled _ -> ());

    (* Accept loop stopped. Drain: race all handlers finishing vs timeout.
       Eio.Fiber.first runs both fibers in its own internal switch — they do
       NOT live in connections_sw, so neither extends the switch lifetime. *)
    if Atomic.get active = 0 then
      (try Eio.Promise.resolve all_done_r () with Invalid_argument _ -> ());

    Eio.Fiber.first
      (fun () -> Eio.Promise.await all_done)
      (fun () ->
        Eio.Time.sleep env#clock drain_timeout_s;
        Eio.Switch.turn_off connections_sw Exit)
  )
)
```

**Why `Eio.Fiber.first` is correct here:**
- `Eio.Fiber.first` runs its two fibers in its own internal switch, independent of
  `connections_sw`. The timeout fiber does not hold `connections_sw` open.
- If all connections finish first: `all_done` resolves, `Eio.Fiber.first` cancels
  the timeout fiber and returns.
- If timeout fires first: `Eio.Switch.turn_off connections_sw Exit` cancels all
  remaining connection fibers, then `Eio.Fiber.first` completes.
- Zero-connection idle server: `Atomic.get active = 0` after the accept loop
  pre-resolves `all_done_r`; `Eio.Fiber.first` returns immediately.
- The `Invalid_argument` catch guards against the rare race where the last
  connection finishes between the `active = 0` check and the manual resolve.

**Note on `await_signal`:** The exact OCaml surface depends on the Eio version in
use (`Eio_unix.Signal`, `Sys.set_signal` from within a fiber, etc.). The contract
is: block until SIGTERM or SIGINT, then return. Validate against the Eio version
in use at implementation time.

### Connection lifecycle (single request)

```
TCP accept
  └─ map Http.Method.t → Route.method_
  │     unknown method  → 405, close
  └─ read headers       (Http.Header.t)
  └─ read body, enforce max_body_bytes
  │     exceeded        → 413, close (do not call handler)
  └─ parse URI          (Uri.of_string)
  └─ match method + path
  │     no match        → 404, close
  │     method mismatch → 405, close
  └─ validate auth      (Auth internal)
  │     Unauthorized    → 401, close
  │     Forbidden       → 403, close
  │     v2 not ready    → 501, close
  │     misconfigured   → 500, close
  └─ call handler
  │     exception       → 500, log via obs, close
  └─ write response     (cohttp-eio)
  └─ close connection
```

Keep-alive: not supported in v1. One request per TCP connection.

---

## Built-in Endpoints

Checked before any route in `H.routes`. Cannot be shadowed by user routes.

| Path | Method | Auth | Response |
|---|---|---|---|
| `/healthz` | GET | `` `Public `` | 200 `{"status":"ok"}`, `application/json` |
| `/metrics` | GET | `~metrics_auth` arg | 200 Prometheus text (if renderer wired), else 404 |

**`/healthz` always `Public`:** k8s `livenessProbe` and `readinessProbe` call this
without credentials. It must never require auth.

**`/healthz` not `/health`:** The `z` suffix is the k8s control-plane convention
(kube-apiserver, etcd, kubelet). The ROADMAP listed `/health`; this spec supersedes it.

**`/metrics` auth is configurable:** Pass `~metrics_auth:\`Api_key` if the cluster
does not use `NetworkPolicy` to restrict Prometheus scraper access. Default is
`` `Public `` because in a properly configured cluster, the `NetworkPolicy` is the
access control boundary. The `~metrics_auth` arg eliminates the need for user-defined
shadowing routes, which the routing order would make unreachable anyway.

---

## Dune Setup

```
http/dune-project:
  (lang dune 3.23.1)

http/sol-svc/lib/dune:
  (library
   (name sol_svc)
   (libraries cohttp-eio http uri yojson obs-eio eio eio.unix))
   (* wrapped true is the dune default — omit the flag *)

http/sol-svc/test/dune:
  (tests
   (names test_routing test_auth test_service)
   (libraries sol_svc obs-eio eio eio_main alcotest cohttp-eio))
```

**opam packages:** `cohttp-eio`, `http` (bundled with cohttp), `uri`, `yojson`.

---

## Test Plan

All pure-logic tests run without a server. Only `test_service.ml` starts a live
listener on an OS-assigned port.

### Port discovery pattern in `test_service.ml`

```ocaml
let actual_port = ref 0 in
let server_ready, resolve_ready = Eio.Promise.create () in
Eio.Fiber.fork ~sw (fun () ->
  Sol_svc.Service.Make(H).run ~env ~obs ~port:0
    ~on_listen:(fun p ->
      actual_port := p;
      Eio.Promise.resolve resolve_ready ())
    ()
);
Eio.Promise.await server_ready;
(* fire client requests at localhost:!actual_port *)
```

### `test_routing.ml`

- Exact literal match routes to correct handler
- Trailing slash distinction: `/users` ≠ `/users/`
- Single param: `/users/:id` vs `/users/42` → `params = [("id","42")]`
- Multi-param correct extraction
- Method discrimination: GET route vs POST request → 405
- Unknown HTTP method (OPTIONS) → 405
- First-match-wins: two overlapping user patterns, first wins
- Built-in `/healthz` not reachable via user route of same path
- Unknown path → 404

### `test_auth.ml`

- Public: no headers → `Public` principal
- Api_key from `SOL_API_KEY` env → `Service { key_id }`, truncated key
- Api_key from `SOL_API_KEY_FILE` env → same, reads file
- Api_key wrong → 401; missing header → 401
- Both env vars unset → 500
- Jwt valid, all scopes → `User` principal, claims is `Yojson.Safe.t`
- Jwt missing one scope → 403
- Jwt expired → 401; malformed → 401
- Jwt scope superset (token has more than required) → ok
- `verification = Verified_signature_required`, HS256 secret, valid → `User` principal
- `verification = Verified_signature_required`, RS256 via `Jwks_static`, valid → `User` principal
- Verified: tampered signature → 401; `alg` outside allowlist → 401
- Verified: wrong `iss` → 401; wrong `aud` → 401; expired → 401; missing scope → 403
- Verified: `Jwks_url` unreachable → 500 (fails closed, no fallback to unverified)

### `test_service.ml`

- GET `/healthz` → 200 `{"status":"ok"}`
- GET `/metrics` without renderer → 404
- GET `/metrics` with renderer → 200 Prometheus text
- GET `/metrics` with `~metrics_auth:\`Api_key`, correct key → 200
- GET `/metrics` with `~metrics_auth:\`Api_key`, no key → 401
- POST body under limit → handler receives full body
- POST body over `max_body_bytes` → 413, handler not called
- POST to `Public` route → 200
- POST to `Jwt` route without token → 401
- POST to `Jwt` route with expired token → 401
- POST to `Jwt` route with missing scope → 403
- POST to `Jwt` route with valid token → 200
- Handler raising exception → 500, server continues accepting
- Unknown path → 404; wrong method → 405
- Graceful shutdown: SIGTERM stops new accepts, active request completes cleanly
- Drain timeout: active request that exceeds drain window is cancelled

---

## Example Usage

```ocaml
(* app/payments/charge-svc/bin/main.ml *)
open Sol_svc

let handle_charge req =
  let _body = req.Request.body in
  (* parse body, validate, charge ... *)
  Response.json ~status:201 {|{"status":"charged"}|}

let handle_internal req =
  let _who = req.Request.auth.Auth.principal in
  Response.json ~status:201 {|{"status":"charged"}|}

module H = struct
  let routes =
    [ Route.post "/payments/charge"
        ~auth:(`Jwt { scopes = ["write:payments"]; verification = Unverified_dev_only })
        handle_charge
    ; Route.post "/payments/internal/charge"
        ~auth:`Api_key
        handle_internal
    ]
end

let () =
  Eio_main.run (fun env ->
    let obs = Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
                ~service:"charge-svc" () in
    Service.Make(H).run ~env ~ot:obs ()
  )
```

---

## Out of Scope (v1)

- **JWT signature verification** — `Unverified_dev_only` is the v1 local-development mode;
  `Verified_signature_required` triggers a 501 until v2 JWKS verification is implemented
- **HTTPS / TLS** — terminate at k8s ingress; plain HTTP inside the cluster
- **HTTP keep-alive** — one request per TCP connection
- **Request body streaming** — body pre-read to string (bounded by `max_body_bytes`)
- **HEAD / OPTIONS / CONNECT / TRACE** — unknown methods return 405
- **Routing trie** — linear scan only; add if >100 routes appears in profiling
- **Path wildcards / optional segments** — strict segment-count matching only
- **User middleware chain** — auth is the only framework middleware in v1
- **Auto-metrics per route** (request count, latency, error rate) — Phase 3
- **WebSocket / SSE** — HTTP/1.1 request-response only
- **Multi-domain parallelism** — single Eio domain; add `Domain_manager` if benchmarks show need
- **Request ID propagation** — Phase 3 observability auto-wiring
