---
id: REFAC-013
branch: REFAC-013/uri-pct-decode
worktree: /home/lbendtly/Code/sun-REFAC-013-uri-pct-decode
type: refactor
severity: low
source: codebase simplification review 2026-06-15
---

Replace hand-rolled `percent_decode` in `route.ml` with `Uri.pct_decode`

**Depends on:** None.

**Description:**

`framework/sun-svc/lib/route.ml:24–44` implements URL percent-decoding by hand:

```ocaml
let percent_decode s =
  let len = String.length s in
  let buf = Buffer.create len in
  let i = ref 0 in
  while !i < len do
    (match s.[!i] with
    | '%' when !i + 2 < len ->
      let hi = s.[!i + 1] in
      let lo = s.[!i + 2] in
      let is_hex c = ... in
      if is_hex hi && is_hex lo then begin
        let n = int_of_string (Printf.sprintf "0x%c%c" hi lo) in
        ...
```

The `uri` library is already a declared dependency of `sun-svc/lib/dune` (line 4: `libraries cohttp-eio http uri ...`) and provides `Uri.pct_decode` that does exactly this. The 20-line hand-rolled implementation is a maintenance burden: the `int_of_string (Printf.sprintf "0x%c%c" ...)` pattern is unusual and the `is_hex` predicate is inline rather than using Char utilities.

Note: `url_encode_logql` in `sun_cli_logs.ml` is intentionally selective (encodes only LogQL-specific characters to keep URLs readable) and should NOT be replaced with `Uri.pct_encode`.

**Remediation:**

1. In `route.ml`, delete `percent_decode` and replace the definition with:
   ```ocaml
   let percent_decode s = Uri.pct_decode s
   ```
   Or inline the call at the single use site (`route.ml:81`):
   ```ocaml
   go ps rs ((key, Uri.pct_decode r) :: acc)
   ```

2. Remove the now-unused `percent_decode` definition.

**Acceptance criteria:**

- `route.ml` contains no local `percent_decode` function.
- `dune build` passes.
- Existing route-matching tests pass (path parameters with percent-encoded characters are decoded correctly).

## Review — automated checks passed
Hand-rolled percent_decode removed from route.ml and route.mli; Uri.pct_decode used at call site; build clean; no ticket directory changes.
