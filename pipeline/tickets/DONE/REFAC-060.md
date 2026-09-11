---
id: REFAC-060
type: audit-finding
severity: medium
source: ocaml-type-safety-audit 2026-06-16
branch: REFAC-060/flatten-validate-jwt
worktree: ../sun-REFAC-060-flatten-validate-jwt
---

Flatten `validate_jwt` pyramid in `auth.ml` with `let*`

**Depends on:** None.

**Description:**

`framework/sun-svc/lib/auth.ml:108–147` contains a four-level-deep nested match inside `validate_jwt`:

```
match Http.Header.get headers "authorization"     (* level 1 *)
| Some auth ->
    match String.split_on_char '.' token           (* level 2 *)
    | [_hdr; payload_b64; _sig] ->
        match base64url_decode payload_b64          (* level 3 *)
        | Some payload_str ->
            match Yojson.Safe.from_string payload_str  (* level 4 *)
            | json ->
                match missing with                  (* level 5 *)
```

The happy path is buried at the fifth indentation level. Each guard failure exits immediately as `Error (...)`, which is exactly what `Result.bind` is designed to express.

**Remediation:**

Introduce a local `let*` binding:

```ocaml
let ( let* ) = Result.bind

let validate_jwt config headers =
  if not config.allow_unverified_v1_unsafe then
    Error (`Not_implemented "...")
  else
    let* auth = Http.Header.get headers "authorization"
      |> Option.to_result ~none:(`Unauthorized "Missing Authorization header") in
    let* token =
      let prefix = "Bearer " in
      if String.length auth >= String.length prefix
         && String.sub auth 0 (String.length prefix) = prefix
      then Ok (String.sub auth (String.length prefix) ...)
      else Error (`Unauthorized "Authorization header must be 'Bearer <token>'") in
    let* parts = (match String.split_on_char '.' token with
      | [h; p; s] -> Ok (h, p, s)
      | _ -> Error (`Unauthorized "Malformed JWT: expected header.payload.signature")) in
    let* payload_str = base64url_decode (snd3 parts)
      |> Option.to_result ~none:(`Unauthorized "Malformed JWT: cannot decode payload") in
    ...
```

The exact form can vary; the goal is that no match arm nests deeper than one level.

## Review — automated checks passed
validate_jwt refactored to flat let* chain; build clean, all tests pass, error strings preserved, no ticket files touched
