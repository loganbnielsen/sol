---
id: REFAC-156
type: refactor
severity: medium
source: "style-audit theme applied to the pinned support libraries, 2026-09-29 (REFAC-138 follow-up); operator: the *-eio repos should carry the same conventions as sol"
title: Give Aws.Http.signed_request a credential set and a request spec
---

Give `Aws.Http.signed_request` a credential set and a request spec

**Depends on:** None.

## Problem

`aws-eio/lib/aws_http.mli:37` declares `signed_request` with nineteen arguments:

```ocaml
val signed_request
  :  ?max_retries:int -> ?timeout:float -> ?scheme:[ `Http | `Https ]
  -> net:_ Eio.Net.t -> clock:_ Eio.Time.clock
  -> access_key_id:string -> secret_access_key:string -> ?session_token:string
  -> region:string -> service:string
  -> normalize_path:bool
  -> meth:Http.Method.t -> host:string -> ?port:int
  -> path:string -> ?query:(string * string) list
  -> ?extra_headers:(string * string) list -> ?payload_hash:string
  -> ?body:string -> unit
  -> (int * (string * string) list * string, Aws_error.t) result
```

Three separate problems, all of them themes sol's REFAC-104…155 series already
resolved in its own code:

1. **A hidden conceptual group.** `access_key_id` / `secret_access_key` /
   `session_token` are one credential set — and the package already has the
   type: `Aws_credentials.t` is `{ access_key_id; secret_access_key;
   session_token }` (`aws-eio/lib/aws_credentials.mli:22`), with IMDS/ECS
   resolution, `of_env`, and expiry. `signed_request` takes its three fields
   loose, so a caller holding a resolved `Aws.Credentials.t` destructures it and
   a caller with a swapped pair gets a runtime signature failure instead of a
   type error.
2. **A boolean trap.** `normalize_path:bool` means "S3 signs the path as
   written; every other service signs the normalized form" — a fact about the
   *service*, invisible at the call site, and documented only by a comment. Both
   call sites in this repository pass it positionally next to `~service`, which
   is exactly where a mistake is silent.
3. **Two request shapes in one list.** `meth`/`host`/`port`/`path`/`query`/
   `extra_headers`/`body`/`payload_hash` are the request being signed, and they
   travel together through both callers.

Callers: `s3-eio/lib/s3_client.ml:104`, `dynamodb-eio/lib/dynamodb_client.ml:212`,
`aws-eio/test/test_aws_live.ml:30`.

## Remediation

In `aws-eio`, in one PR:

1. `~credentials:Aws.Credentials.t` (or the request's own credential record if
   the resolved type carries more than signing needs), replacing the three
   loose fields.
2. A `request` record carrying the method, host, optional port, path, query,
   extra headers, payload hash and body — the shape `Aws_http.request` already
   takes as separate arguments, so the two entry points converge on one value.
3. Replace `normalize_path:bool` with a variant that names the two policies
   (`[ `Normalized | `As_written ]`, or a per-service property), so the call
   site says which it means.
4. Update the three call sites above, `aws-eio/lib/aws.mli`'s hand-written
   facade signature (see REFAC-158), the README, and the tests.
5. Then, in sol: `internal/tooling/scripts/bump-support-refs.sh aws-eio s3-eio
   dynamodb-eio` and Sol's CI on the bump.

## Acceptance criteria

- `signed_request` takes a credential value and a request value; no boolean
  parameter remains in its signature.
- `s3-eio`, `dynamodb-eio` and `aws-eio`'s own tests build and are green on
  their own CI, and `support-refs.txt` points at the merged commits.
- The signature in `aws-eio/lib/aws.mli` and the README match the `.mli`.
- Demo/example: not applicable (a support library's internal API; its
  app-facing surface is unchanged). Language parity: no impact.
