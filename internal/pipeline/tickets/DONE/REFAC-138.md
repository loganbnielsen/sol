---
id: REFAC-138
type: refactor
severity: low
title: Carry the code conventions into the pinned support libraries (*-eio) and bump support-refs.txt
source: "pattern audit of the REFAC-104..130 series (2026-09-26); operator: \"it's also possible that these need to be fixed for our *-eio ocaml libraries … perhaps we should consider updating there as well\""
---

**Depends on:** None.

## The problem

The support libraries Sol pins through `support-refs.txt` (https-eio, kafka-eio, obs-*, pg-eio, aws-eio, s3-eio, dynamodb-eio, lambda-eio; each its own repository, owned by the operator) carry the patterns Sol's CLI just removed. Library code only, tests and demos excluded, at the commits `support-refs.txt` pins (2026-09-26):

- **Hand-written `let ( let* ) = Result.bind`**: `kafka-eio` (4: `kafka_consumer.ml`, `kafka_producer.ml`, `kafka_security.ml` ×2), `pg-eio` (`pg_db.ml`, `migration.ml`), `aws-eio` (`aws_credentials.ml`), `s3-eio` (`s3_client.ml`), `dynamodb-eio` (`dynamodb_client.ml`, `dynamodb_value.ml`), `lambda-eio` (`lambda_event.ml`, `lambda_runtime.ml`).
- **A runtime failure raised instead of returned**, inside code that otherwise returns results:
  - `aws-eio/lib/aws_http.ml:107-108` parses the HTTP status line with `failwith`, and `:147-148` turns an `Error` from https-eio into `failwith`;
  - `pg-eio/lib/pg_table.ml:60-61` turns a query `Error` into `invalid_arg`.
- **Blank decided at the use site**: `kafka-eio/lib/kafka_security.ml:64` treats `""` as unset but not whitespace, while Sol's framework trims; `pg-eio/lib/pg_db.ml:57` and `https-eio/lib/https_eio.ml:19` match `Some ""` by hand.
- **Decoders that read "malformed" as an answer**: `obs-eio/lib/obs_trace.ml:85-86` (`with _ -> None` in trace-context parsing -- check whether "absent" and "malformed" must differ there per W3C: a malformed `traceparent` *is* treated as absent by the spec, so this may be correct and should be recorded, not changed).

Constructor argument checks that raise `Invalid_argument` on a *programmer* error (`obs-eio` metric names, `obs-loki-eio`/`obs-tempo-eio` `create` options, `kafka_topic_name`'s literal-name helper) are idiomatic OCaml and are **out of scope**, unless a caller can reach them with runtime data -- say which in the notes.

## Remediation

Per repository, one PR in that repository:

1. `Result.Syntax` for `let*` (OCaml ≥ 5.1 is already required by these packages -- confirm per package).
2. Runtime failures return their `Error` through the package's existing error type; no new exception.
3. Env reads decide blank once per package, with blank = unset, trimmed.
4. Each repository's CI green on the PR; merge.

Then in Sol: `internal/tooling/scripts/bump-support-refs.sh <packages>`, rebuild, run `dune test framework/` and `dune test cli/`, and land the bump.

## Acceptance criteria

- Each changed repository has a merged PR, listed in the completion notes with its merge commit.
- `support-refs.txt` points at those commits; `internal/ci/check_support_refs.sh` passes; Sol's CI is green on the bump.
- No public signature of a support library changes except where a raising function becomes result-returning; each such change and its Sol call sites are listed.
- Demo/example: not applicable (library internals). Language parity: the blank-env rule is shared with REFAC-137's note.

## Completion notes

**Premise verified (2026-09-27)** at the commits `support-refs.txt` pinned, library code only: `rg -n 'let \( let\* \) =' */lib` listed the 12 hand-written `let*` sites above; `aws_http.ml` raised `failwith` in `read_response`/`do_once`.

**Merged, one PR per repository (each repository's CI green on its head):**

| Repository | PR | Merge commit | Change |
|---|---|---|---|
| aws-eio | #27 | `5a295443` | `read_response`/`do_once` return `Error` in the parser's own words; `request_once`'s catch-all is left for Eio's I/O exceptions. Before, a malformed status line surfaced as `network error: Failure("bad status line: …")`. New test `malformed status line is its own error`, shown failing on the old code. `aws_credentials` uses `Result.Syntax`. |
| kafka-eio | #25 | `4b6d4204` | `Result.Syntax` (4 sites) |
| pg-eio | #22 | `1cfc9b51` | `Result.Syntax` (2 lib sites + the test file) |
| s3-eio | #20 | `7cca2fc1` | `Result.Syntax` |
| dynamodb-eio | #18 | `3e4bbec6` | `Result.Syntax` (2 sites) |
| lambda-eio | #21 | `4a0cf964` | `Result.Syntax` (2 sites) |

`internal/tooling/scripts/bump-support-refs.sh` moved those six in `support-refs.txt` and, in lockstep, the pins in `sol-fn.opam`, `sol-jobs.opam`, pluto's and venus's opam files and the workspace template; `check_support_refs.sh` passes. CI on this PR pins and builds against them.

**Examined and left, with the reason:**
- `kafka-eio`'s `env_opt` treats `""` as unset without trimming. It reads `KAFKA_SASL_PASSWORD`, whose whitespace is data, so not trimming is correct for this library (Sol's framework decides blank for its own settings, REFAC-137).
- `pg-eio`'s `Identifier.of_string_exn` validates a functor's static schema identifiers (a programmer error), `migration.ml`'s `failwith` is a documented unreachable case, and `pg_db`'s `App_error` is a local exception carried through Caqti's `use` callback and caught immediately.
- `obs-eio`'s `of_traceparent` reads a malformed header as `None`, which is what W3C Trace Context requires (a malformed `traceparent` is treated as absent); its catch-all cannot fire after the hex checks.
- Constructor argument checks raising `Invalid_argument` (`obs-eio` metric names, `obs-loki-eio`/`obs-tempo-eio` `create` options) are programmer errors on static configuration.
- `https-eio`'s `None | Some ""` is a URI host check at its own parse boundary.

No public signature changed. **Demo/example:** not applicable (library internals; pluto's and venus's pins move with the bump). **Language parity:** no impact.
