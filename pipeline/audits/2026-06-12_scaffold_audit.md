# Sun Scaffold Quality Audit — 2026-06-12

**Template:** `docs/audits/SCAFFOLD_AUDIT.md`  
**Workspace:** `/tmp/sun-audit-2026-06-12/scaffold_audit`

## Executable Run

| Step | Result |
|------|--------|
| `sun new workspace scaffold_audit` | PASS, 25 files |
| `dune build` | PASS |
| `sun new svc payments/refund` | PASS |
| `sun new worker logistics/fulfillment` | PASS |
| `sun new fn billing/invoice` | PASS |
| `sun new event billing/payment_confirmed` | PASS |
| `sun new event payments/refunded` | PASS, existing `events/payments/dune` updated |
| Final `dune build` | PASS |

## Observations

- Generated storage and migration names are workspace-prefixed.
- Generated schema compatibility test exists at `test/test_schemas.ml`.
- New services, workers, functions, and events use workspace-namespaced library names.
- Adding a second event to an existing domain no longer requires a manual dune edit.
- Generated Dockerfiles still copy host-built binaries from `_build/default`; this remains covered by existing `AUDIT-026`.

## Findings

No new scaffold-quality tickets were opened from this pass.

