---
id: DOCS-017
type: docs-finding
severity: medium
source: pipeline/audits/2026-09-16_docs_audit.md
---

**Depends on:** None.

# Bring framework package specs back to their public API contracts

The Kafka-service and service package specs contain stale signature blocks:
`config_of_env` drops its `result`, old flat Kafka module names remain,
decode-error bytes have the wrong optionality, `Response.not_implemented` is
documented but not public, `Request.t` omits `trace_ctx`, and `Service.run` has
the wrong result type and omits `?stop`.

## Acceptance criteria

- Every public signature shown in `framework/kafka-eio-service/*.md` and
  `framework/sol-svc/*.md` matches its current `.mli` exactly.
- Obsolete public members and module names are removed.
- Code examples compile, or are explicitly marked illustrative.
- Add the smallest maintainable drift check: compiled snippets if practical,
  otherwise a focused signature/doc assertion; do not build a documentation
  framework.

## Completion (2026-09-22)

The specs live at `framework/ocaml/<pkg>/<pkg>.md` now, not `framework/<pkg>/`.

**Fourteen stale declarations, all fixed** — every one found by the guard rather
than by reading, which is the point. The six the ticket names, plus eight more the
same check turned up: `Auth`'s types were `and`-joined and reordered rather than
the `.mli`'s six separate declarations; `Route.t` documented a `string` pattern
where the `.mli` has a private `pattern` record and omitted `pattern_segment`
entirely; `Peer.url`/`Peer.headers` wrote `[ \`Config of string ]` inline instead
of the library's own `error`; `Response.t` was correct but `not_implemented` was
documented as public when `response.mli` has never exported it; the kafka
`config` record used `Kafka_security.t` (flat, old) instead of `Kafka.Security.t`;
and `consume`/`consume_partitioned` were missing `clock:`/`net:`, the
`on_assigned`/`on_revoked`/`on_poll` hooks, `bytes option` on the decode-error
payload, `?on_relay_publish`, and the right return type
(`consume_partitioned_error`, not `Kafka.Error.t`).

**The drift check** is `internal/ci/check_framework_doc_signatures.sh` — inline
python3 in a shell guard, following the existing guard pattern. It parses
declarations out of the ```ocaml blocks, strips comments, collapses whitespace and
requires each declaration shown to exist in the `.mli` mapped to that *section*.
Three design choices worth stating:

1. **Section-scoped, with an explicit manifest.** Comparing a doc against all of a
   package's mlis at once produces false positives — `type t` exists in five
   modules, and the kafka doc's message-contract sample contains a user's own
   `type t`. Sections are mapped to modules deliberately, so only real specs are
   checked and `type t` is never compared against the wrong file.
2. **A subset is allowed.** A spec that shows fewer declarations than the `.mli`
   passes; a spec that shows a *different* one fails. These are specs, not
   transcriptions, and a check that demanded full transcription would be switched
   off.
3. **Comments and formatting are not compared**, only declarations — so a block may
   carry richer prose than the `.mli` (the Auth block does) without the guard
   forcing the prose out.

`internal/ci/test_framework_doc_signatures.sh` is the mutation test, against a
scratch copy of both spec trees: the committed state passes; five named drifts fail
(a dropped `Request.t` field, a signature that lost its `result`, a member the
`.mli` does not export, an old flat module name, and a changed argument shape); and
removing a declaration from a spec still passes, pinning the subset rule. Both steps
run **unconditionally** in CI, because a spec-only change is classified docs-only
and that is exactly the change that drifts.

**Examples.** The two kafka examples are marked illustrative, as the criterion
allows — they are hand-written caller sketches and CI compiles no snippet. They were
also corrected while there: `Kafka_service.config_of_env ()` now returns a `result`,
so the example that did `let cfg = ... in` and then passed `cfg` to `create` could
not have compiled, and it used `Kafka_error.to_string`/`Kafka_consumer.Continue`
(the old flat names). Illustrative is now true rather than a way of not looking.

**Honest scope.** The guard covers the two spec files this ticket names. A quick
pass with the same rules over the other four (`sol-worker`, `sol-fn`, `sol-obs`,
`sol-jobs`) found the same class of drift in each — filed as DOCS-020 rather than
silently widened here, so this ticket's claim stays exactly as wide as its evidence.

## Demo/example coverage

Documentation/API-contract correction only; no runnable app behavior changes.
