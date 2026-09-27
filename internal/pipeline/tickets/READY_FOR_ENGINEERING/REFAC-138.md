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
