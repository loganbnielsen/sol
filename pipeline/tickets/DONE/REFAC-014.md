---
id: REFAC-014
branch: REFAC-014/with-temp-file
worktree: /home/lbendtly/Code/sun-REFAC-014-with-temp-file
type: refactor
severity: low
source: codebase simplification review 2026-06-15
---

Extract `with_temp_file` helper to centralize temp file cleanup in CLI commands

**Depends on:** None.

**Description:**

`cmd_up.ml` and `cmd_cloud.ml` each follow the same `Filename.temp_file` + manual `Sys.remove` pattern in at least 6 locations:

```ocaml
(* cmd_up.ml — pattern repeated at lines 33, 160, 183, 289, 317 *)
let tmp = Filename.temp_file "sun-ps-" ".tmp" in
(* ... use tmp ... *)
(try Sys.remove tmp with _ -> ());

(* cmd_cloud.ml — lines 33, 513 *)
let tmp = Filename.temp_file "sun-tf-out-" ".json" in
(* ... use tmp ... *)
(try Sys.remove tmp with _ -> ())
```

When the body raises an exception, `Sys.remove` is not called and the temp file leaks. The `cmd_cloud.ml:33–45` case is the clearest example — it wraps the remove in a `try` but uses `Sys.remove tmp` in the error branch without `try` protection:

```ocaml
let tmp = Filename.temp_file "sun-tf-out-" ".json" in
...
match ... with
| Error msg -> (try Sys.remove tmp with _ -> ()); Error msg
| Ok ()     ->
  ...
  Sys.remove tmp;   (* <-- raises if tmp was already removed or path changed *)
```

**Remediation:**

Add a helper to `cli/sun/lib/sun_cli_shell.ml` (or a new `sun_cli_fs.ml`):

```ocaml
(* Run [f tmp] with a guaranteed-deleted temp file. *)
let with_temp_file prefix suffix f =
  let path = Filename.temp_file prefix suffix in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () -> f path)
```

Then replace every `Filename.temp_file` + manual `Sys.remove` pair in `cmd_up.ml` and `cmd_cloud.ml` with calls to `with_temp_file`.

**Acceptance criteria:**

- `cmd_up.ml` and `cmd_cloud.ml` contain no direct calls to `Filename.temp_file`.
- Temp files are cleaned up even when the body raises.
- `dune build` passes.
- `sun up --dry-run` and `sun cloud tf-plan` (or equivalent) behave identically.

## Review — automated checks passed
with_temp_file added to sun_cli_shell.ml using Fun.protect; all five Filename.temp_file call sites in cmd_up.ml and cmd_cloud.ml migrated to the helper; build clean; no wrapped true; project/tickets untouched in worktree branch
