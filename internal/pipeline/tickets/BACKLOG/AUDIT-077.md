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
