---
id: CODE_LAYER-027
type: refactor
severity: medium
title: Derive the workspace substrate documents once, on the path ensure uses
source: internal/pipeline/audits/2026-10-02_code_layer_audit.md
premise: "rg -q '^let namespaces_of_services' cli/lib/deploy/sol_cli_substrate.ml"
---

Derive the workspace substrate documents once, on the path ensure uses

**Depends on:** None.

## Problem

`cli/lib/deploy/sol_cli_substrate.ml` derives the workspace substrate's
namespace/document set three times:

- `docs_for_namespaces` (`sol_cli_substrate.ml:12-16`) returns one namespace
  document plus deploy and operator RoleBindings per namespace. Its only caller
  is `cli/test/inline/test_substrate.ml:7`; the production path never uses it.
- `ensure` (`sol_cli_substrate.ml:107-111`) rebuilds the same list inline: the
  namespace documents, then `deploy_role_binding_doc` for every namespace, then
  `operator_role_binding_doc` for every namespace.
- `operator_binding_docs` (`sol_cli_substrate.ml:179-193`) computes the
  namespace set from services; `reconcile_operator_bindings`
  (`sol_cli_substrate.ml:196-200`) recomputes exactly that set inline instead of
  calling it.

So the two tests that assert `docs_for_namespaces` contains the right documents
are testing a model of the production set, not the set `ensure` creates. If
`ensure` gains or loses a document, they still pass. That is the failure mode
the substrate tests exist to prevent.

## Remediation

1. Make `ensure` consume `docs_for_namespaces`, so the tested function *is* the
   document set the production path writes. Its order already puts every
   namespace before every binding, which is what create-then-RoleBinding
   requires.
2. Extract the shared service-to-namespace derivation into one private
   `namespaces_of_services ~workspace services : string list`, and have both
   `operator_binding_docs` and `reconcile_operator_bindings` use it. `operator_binding_docs`
   then maps `operator_role_binding_doc` over it; `reconcile_operator_bindings`
   applies over it.
3. Keep `docs_for_namespaces` exported (the test drives it) and keep the
   document order it already promises.

## Acceptance criteria

- `ensure` and `docs_for_namespaces` cannot describe different document sets:
  `rg -n 'namespace_doc ~ns' cli/lib/deploy/sol_cli_substrate.ml` no longer
  appears in an `ensure`-local list, or the list is the one `docs_for_namespaces`
  returns.
- A mutation to `docs_for_namespaces` (drop the operator RoleBinding) fails
  `cli/test/inline/test_substrate.ml`, and the same mutation made to the
  production list changes the same behaviour — i.e. the two are one.
- `reconcile_operator_bindings` and `operator_binding_docs` derive their
  namespace set through the one helper.
- No behavioural change in the created/refused documents; the existing
  substrate tests pass unchanged in intent.
- Update a runnable example/demo for application-facing behavior, or record why
  this is an internal-only refactor.
- Record the per-language capability verdict for framework/application
  contracts, or explain why language parity is unaffected.

## Completion (2026-10-02)

- **Premise re-verified** at `origin/main` `8cb09659`: `docs_for_namespaces` was called only by `cli/test/inline/test_substrate.ml`, `ensure` rebuilt the same document list inline, and `reconcile_operator_bindings` recomputed the namespace set `operator_binding_docs` already computed.
- **Fix.** `ensure` now creates `docs_for_namespaces namespaces`, so the tested function *is* the production document set. Extracted `namespaces_of_services ~workspace services` and used it in both `operator_binding_docs` and `reconcile_operator_bindings`, removing the second inline derivation. Every namespace is still created before any RoleBinding, and the created/refused set is unchanged.
- **Tests.** `cli/test/inline/test_substrate.ml` passes; because `ensure` calls `docs_for_namespaces`, a change to that function now changes the production path by construction.
- **Guards.** `check_deploy_substrate_order.py`, `check_operator_diagnostics.py`, `check_managed_database_egress.py` and their mutation suites pass.
- Validation: full `dune build`; `dune fmt` clean.
- **Demo/example: not applicable** — internal deploy-substrate plumbing. **Language parity: no impact.**
