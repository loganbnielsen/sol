---
id: REFAC-012
branch: REFAC-012/str-binding-scanner
worktree: /home/lbendtly/Code/sun-REFAC-012-str-binding-scanner
type: refactor
severity: low
source: codebase simplification review 2026-06-15
---

Replace fragile byte-scanner in `discover_topics` and `extract_schedule` with `Str` regex

**Depends on:** None.

**Description:**

Two functions use the same fragile byte-scanner pattern to extract string literal values from `.ml` source files:

**`sun_cli_deployment_plan.ml:218–258` — `discover_topics`**
```ocaml
let marker = {|let topic_name = "|}
```

**`sun_cli_manifest.ml:71–105` — `extract_schedule`**
```ocaml
let marker = {|schedule = "|}
```

Both are raw substring searches with the same `String.sub content i ml = marker` loop. Both break silently on the same set of formatting variations:
- No space around `=`: `let topic_name="my-topic"` or `schedule="0 * * * *"`
- OCaml comment lines containing the pattern are extracted as real values

`discover_topics` has a concrete failure mode: a user's topic is silently **not provisioned** at deploy time. The service starts, tries to publish, and gets a "topic does not exist" error from Kafka. `extract_schedule` falls back to `"0 * * * *"` (every hour) when it fails to find the schedule — wrong cron spec deployed silently.

Both functions are also structurally duplicated: same `found = ref None` loop, same `let j = ref (i + ml)` quote-extraction logic.

**Remediation:**

1. Extract a shared helper `scan_ml_binding` in `sun_cli_manifest.ml` (or a new `sun_cli_source_scan.ml`):
   ```ocaml
   (* Scan [content] line by line for [let <binding> = "<value>"] with
      flexible whitespace. Returns all matched values. Skips comment lines. *)
   let scan_binding binding content =
     let re = Str.regexp
       (Printf.sprintf {|let +%s *= *"\([^"]*\)"|} (Str.quote binding))
     in
     let lines = String.split_on_char '\n' content in
     List.filter_map (fun line ->
       let t = String.trim line in
       if t = "" || t.[0] = '(' then None  (* skip comments *)
       else
         (try
           ignore (Str.search_forward re line 0);
           let v = Str.matched_group 1 line in
           if v = "" then None else Some v
         with Not_found -> None)
     ) lines
   ```
   `Str` is already in the `(depends ...)` list of `dune-project`.

2. Rewrite `discover_topics` to use `scan_binding "topic_name"`.

3. Rewrite `extract_schedule` to use `scan_binding "schedule"` (taking the first match, falling back to `"0 * * * *"` as before).

4. Add a validation step in `of_services`: after `discover_topics`, warn for any name not matching `[a-zA-Z0-9._-]{1,249}`.

**Acceptance criteria:**

- `discover_topics` and `extract_schedule` share a single scanning implementation with no duplicated loop logic.
- Both correctly extract values from files formatted with or without spaces around `=`.
- Comment lines containing either pattern are not extracted.
- `dune build` passes.
- A unit test covers the whitespace variants and the comment case for both bindings.

## Review — returned for revision
- `cli/sun/test/test_deployment_plan.ml:0` — No unit tests added for scan_binding: acceptance criteria require tests covering whitespace variants (e.g. 'let topic_name="foo"' and 'let topic_name =  "foo"') and the comment-skip behaviour (lines starting with '(')
- `cli/sun/lib/sun_cli_manifest.ml:79` — Regex for ~is_let:false ('schedule *= *"..."') lacks a word-boundary anchor: it will also match identifiers like 'my_schedule = "..."', producing false positives for extract_schedule

## Review — automated checks passed
Build clean, all 27 tests pass, old byte-scanner patterns removed, test file has 9 test cases, no ticket directory changes, word-boundary regex and comment-skip logic present.
