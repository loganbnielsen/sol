---
id: DOCS-012
type: docs-finding
severity: medium
source: pipeline/audits/2026-09-08_docs_audit.md
---

`docs/audits/DOCS_AUDIT.md` template itself uses stale pre-rename paths

**Description:** Same class of issue as `AUDIT-066` (filed against `docs/audits/AUDIT.md`): `docs/audits/DOCS_AUDIT.md`'s own source-location pointers predate the `sun`→`sol` rename and the 2026-09-08 reorg — e.g. `cli/sun/bin/main.ml`, `cli/sun/bin/cmd_new.ml`, `cli/sun/lib/sun_cli_scaffold.ml`, section 5's `framework/kafka-eio-service/*.md` reference, and `sun new`/`sun dev` command examples throughout.

**Impact:** Every future docs-audit run has to manually re-derive current paths instead of following the template directly — the exact gap `AUDIT-066` already identified for the technical-audit template, just not yet fixed for this one.

**Remediation:** Update `docs/audits/DOCS_AUDIT.md`'s source-location references to current paths (`cli/sol/bin/`, `cli/sol/lib/sol_cli_cmd_new.ml`, `framework/kafka-eio-service/`, `framework/*/*.md`) and command examples (`sol new`, `sol dev`, etc.), mirroring whatever fix lands for `AUDIT-066`.
