---
id: REFAC-061
type: audit-finding
severity: low
source: ocaml-type-safety-audit 2026-06-16
branch: REFAC-061/flatten-read-api-key
worktree: ../sun-REFAC-061-flatten-read-api-key
---

Flatten `read_api_key` three-level option nest in `auth.ml`

**Depends on:** None.

**Description:**

`framework/sun-svc/lib/auth.ml:36–57`:

```ocaml
let read_api_key () =
  match Sys.getenv_opt "SUN_API_KEY_FILE" with
  | Some path ->
    let mtime = try Some (Unix.stat path).Unix.st_mtime with _ -> None in
    (match mtime with
     | None -> None
     | Some mtime ->
       match Atomic.get key_cache with
       | Some (cached_mtime, key) when cached_mtime = mtime -> Some key
       | _ ->
         Mutex.protect key_cache_mutex (fun () ->
           match Atomic.get key_cache with
           | Some (cached_mtime, key) when cached_mtime = mtime -> Some key
           | _ -> ...))
  | None -> Sys.getenv_opt "SUN_API_KEY"
```

Three levels of nested `match` on `option`. The `mtime` match can be replaced with `Option.bind`; the two `Atomic.get` checks inside `Mutex.protect` are a double-checked locking pattern that is correct but hard to read in this layout.

**Remediation:**

1. Replace the `let mtime = ... in match mtime with` pattern:
   ```ocaml
   let* mtime = (try Some (Unix.stat path).Unix.st_mtime with _ -> None) in
   ```
   using `Option.bind` or `let*` for `option`.
2. Extract the cache-lookup-and-populate logic into a named helper `load_from_path path mtime` so `Mutex.protect`'s lambda is a single call.
3. The double-checked-locking structure itself is fine to keep; the goal is one level of nesting per step, not eliminating the locking.

## Review — automated checks passed
read_api_key flattened with Option.bind, load_from_path helper extracted, double-checked locking preserved, build and tests clean
