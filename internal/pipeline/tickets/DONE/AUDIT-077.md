---
id: AUDIT-077
type: audit-finding
severity: low
source: production-readiness review 2026-09-16 (adversarial Sol-over-Kubernetes review)
---

Release-record validation reports "corrupt" when the real cause is a stale `encoding_version`

## Program disposition

Useful diagnostic cleanup, but not a maturity-A guarantee or critical-path item.
Keep in backlog and address when the encoding version next changes or an operator
encounters the misleading error.

**Depends on:** None.

**Description:** `Sol_cli_release.validate` (`sol_cli_release.ml:140-162`)
recomputes a release's id from its stored content and compares it to the
stored id, failing with `"release record %s is corrupt: its content
rederives %s"` on any mismatch. BUG-026 already bumped
`encoding_version` once (`sol-release-v1` → `sol-release-v2`) specifically
because the projection changed what fields feed the id — meaning a record
written under an old encoding version will *always* fail this check under
a newer CLI, indistinguishable in the error message from a genuinely
corrupted record.

**Impact:** Low severity today — pre-alpha, no backwards-compatibility
constraint, and this has only actually happened once (BUG-026). But the
error message actively misleads whoever hits it: "corrupt" implies data
loss or tampering, when the real cause is an expected, deliberate
encoding-version bump. This will happen again (encoding_version has
already changed once and will change again as the release projection
evolves), and each time, an operator will spend time investigating
"corruption" that is actually just an old record meeting a newer CLI.

**Remediation:**

1. In `validate`, check `encoding_version` first: if it differs from the
   current version, fail with a distinct, accurate message ("record was
   written with encoding_version %s, current CLI expects %s — this
   record predates a release-identity format change and cannot be
   verified against it") rather than reusing the "corrupt" wording.
2. Only use "corrupt" wording when `encoding_version` matches the current
   version and the id still doesn't rederive — that's the actual
   corruption case this check exists to catch.
3. Test: a fixture with an old `encoding_version` and an otherwise
   internally-consistent record gets the new stale-version message, not
   "corrupt"; a fixture with the current `encoding_version` and tampered
   content still correctly reports corruption.

**Acceptance criteria:**

- The two failure causes (stale encoding version vs. genuine content
  mismatch) produce distinguishable error messages.
- No change to the fail-closed behavior itself — both cases still refuse
  to treat the record as valid, only the diagnosis differs.

**Demo/example coverage:** Not applicable — error-message clarity fix
only.

**TypeScript-parity note (DEC-022):** No language-parity impact — this is
release-record bookkeeping internal to the OCaml CLI, not a
framework-level contract either language's SDK participates in.

## Disposition (2026-10-03) — actionable pre-alpha

Premise re-checked against current `origin/main`; the work is still real.
Evidence: `Sol_cli_release.validate` (`cli/lib/deploy/sol_cli_release.ml:138-155`) still emits `"release record %s is corrupt: its content rederives %s"` without checking `encoding_version` (now `sol-release-v4`, `sol_cli_release_id.ml:33`).

Promoted to `READY_FOR_ENGINEERING/` by the pre-alpha BACKLOG adjudication
(`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`).

## Completion notes (2026-10-03)

**Premise verified, with one correction.** `Sol_cli_release.validate` did
still emit the single `"corrupt"` message, but the record carried no
`encoding_version` at all — the ticket's remediation ("check
`encoding_version` first") was not implementable as written, because there
was nothing on the record to check. The implementation therefore adds the
marker to the record body and then diagnoses from it:

- `to_json` writes `encoding_version` (the current
  `Sol_cli_release_id.encoding_version`); `of_json` reads it into a new
  `t.encoding_version : string option`, so a record round-trips the format
  it was written with (`None` = written before the marker existed).
- `validate` now distinguishes three outcomes, all fail-closed: a record
  declaring an older version is refused as predating a release-identity
  format change; a record declaring no marker whose content does not
  rederive is refused as unverifiable (format change and damage cannot be
  told apart); only a record declaring the current version that still fails
  to rederive its own id is reported as corrupt.

**Acceptance criteria met.** The stale-version and content-mismatch causes
produce different messages (`test_validate_reports_stale_encoding_version`,
`test_of_kubectl_item_reports_stale_encoding_version`), the undeclared-marker
case gets its own message instead of "corrupt"
(`test_validate_reports_undeclared_encoding_version`), a marker-less record
stays marker-less (`test_of_json_without_encoding_version_is_unmarked`), and
the corruption case still reports corruption
(`test_validate_rejects_corrupt_content`, unchanged). No case became
readable.

**Consequence to note:** the record body gained a field, so the canonical
record digest moved; the pinned known vector in
`cli/test/inline/test_release.ml` is updated to the new value. Release
identity itself is unchanged (it derives from the workload boundary, not
the record JSON), and an already-stored record still verifies against its
own stored `record_digest`.

**Checks:** `dune build cli/`, `dune build @cli/test/inline/runtest`
(only the two pre-existing `Test_scaffold` failures remain: this switch has
`sol-obs`/`sol-fn` uninstalled, so a scaffolded workspace cannot resolve
them here), `dune fmt`, `internal/ci/check_ocamlformat.sh --all`,
`internal/ci/run_fast_checks.sh` (0/97 static members failed).

**Demo/example coverage:** not applicable, as the ticket states — the
record body is internal to the CLI, and no app-author surface changed.

**TypeScript parity:** no impact, as the ticket states.
