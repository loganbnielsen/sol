---
id: CODE_LAYER-018
type: code-layer-finding
severity: medium
source: pipeline/audits/2026-09-09_code_layer_audit.md
---

# Define the internal factory API before hosted HTTP APIs

Hosted mode should call the same factory contract as the CLI. Today the stable
shape is implicit across command handlers, deployment plans, executors, release
inspection, and release-event telemetry.

Create a small internal module boundary around:

```text
workspace scan -> deployment plan -> execution request -> execution result -> release record
```

Do not add hosted HTTP endpoints in this ticket.

Acceptance:
- The internal API is callable without Cmdliner.
- CLI commands can keep their current UX while delegating to the boundary.
- The execution result includes enough data for release inspection and telemetry
  without re-reading command-local state.
