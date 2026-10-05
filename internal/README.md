# internal/

Maintainer-only support for the product. Nothing here is part of the public application
contract.

| Directory | Responsibility |
| --- | --- |
| `ci/` | Deterministic product/repository guards and their regression tests. |
| `qualification/` | Live claims, procedures, and evidence for behavior that CI cannot establish. |
| `fixtures/` | Test fixtures that are not user-facing examples. |
| `tooling/` | Small maintainer scripts, Git hooks, release support, and performance tooling. |
| `pipeline/audits/` | Reusable audit procedures; they create ordinary GitHub Issues when they find actionable work. |
| `pipeline/dogfood/` | The reusable dogfood procedure. |
| `specs/` | Maintainer-facing product contracts/inventories that do not belong in public reference docs. |

Product code lives in `cli/`, `framework/`, and `platform/`. User-facing documentation
lives in `docs/`; runnable examples live in `examples/`.

Do not create a second project-management system under `internal/`. GitHub Issues and pull
requests own work state.
