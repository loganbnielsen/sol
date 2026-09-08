---
id: AUDIT-046
type: audit-finding
severity: medium
source: codebase review 2026-06-13
branch: AUDIT-046/split-cli-orchestration-modules
worktree: /home/lbendtly/Code/sun-AUDIT-046-split-cli-orchestration-modules
---

Split oversized CLI modules into clear entry points and reusable orchestration components

**Depends on:** AUDIT-043, AUDIT-045.

**Description:** Several CLI modules are carrying too many responsibilities, making entry points hard to follow:

- `cli/sun/lib/sun_cli_cmd_new.ml` is about 1,167 lines and mixes workspace templates, generated source code, Dockerfile/CI templates, event/service/worker/function scaffolding, validation, and Cmdliner command wiring.
- `cli/sun/bin/cmd_cloud.ml` is about 823 lines and appears to mix Terraform orchestration, hosted/customer cloud model handling, Docker packaging, command execution, and CLI output.
- `tools/sundev/bin/cmd_pipeline.ml` is about 678 lines and mixes ticket parsing, git worktree/branch operations, conflict handling, review-result JSON parsing, performance baseline handling, and pipeline command routing.
- `cli/sun/bin/cmd_up.ml` and `cli/sun/bin/cmd_dev.ml` are also large and overlap on command execution, state dirs, port-forwards, and infra orchestration.
- `integrations/kafka/kafka-eio-service/lib/kafka_service.ml` is about 679 lines and mixes schema registry/admin HTTP, service registration, retry-topic behavior, TLS helpers, producer/consumer wiring, and hosted/local concerns.

**Impact:** These modules require a reader to understand many unrelated concerns before finding the public command flow. That slows down engineering work and raises regression risk because small changes to one behavior happen in files that also own several other behaviors. Repeated patterns such as port-forward management, build-context preparation, and ticket/git orchestration are not clearly abstracted.

**Remediation:**

1. Define small top-level entry modules for Cmdliner wiring only; move behavior into focused libraries:
   - `Sun_cli_port_forward` for PID files, liveness, stale forward detection, and wrapper lifecycle.
   - `Sun_cli_build_context` for Docker/rsync/copy-link build contexts.
   - `Sun_cli_dev_infra` for k3d/Helm substrate reconciliation.
   - `Sun_cli_scaffold_templates` and per-primitive scaffold modules for generated files.
   - `Sun_pipeline_ticket`, `Sun_pipeline_git`, and `Sun_pipeline_review` for `tools/sundev`.
   - Kafka service submodules for schema registry/admin client, retry topics, and service runtime wiring.
2. Keep each command's `run` function as a readable orchestration outline that calls named components.
3. Add module interfaces for the extracted components so the command-layer dependencies are explicit.
4. Preserve user-facing output and command-line flags while moving code.

**Acceptance criteria:**

- `cmd_up.ml`, `cmd_dev.ml`, `cmd_cloud.ml`, and `sun_cli_cmd_new.ml` each have a clear command entry point and delegate major work to named modules.
- Port-forward logic is implemented once and reused by `sun up` and `sun dev up/down/status`.
- Scaffold template generation is separated from command parsing.
- Focused tests cover the extracted modules without requiring real cloud, Docker, Helm, or Kubernetes access.

## Review — returned for revision
- `cli/sun/lib/sun_cli_scaffold_templates.ml:1` — New module sun_cli_scaffold_templates.ml has no .mli interface file. Sun conventions require every new module to have a matching .mli. sun_cli_port_forward.mli was added correctly but sun_cli_scaffold_templates.mli was omitted.

## Review — automated checks passed
sun_cli_scaffold_templates.mli added; build passes, all prior checks hold
