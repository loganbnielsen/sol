---
id: CODEX_STYLE_AUDIT-059
type: refactor
severity: medium
source: style audit
---

Replace deployment artifact names with validated Kubernetes name types.

**Depends on:** none.

**Problem:** `Sun_cli_deployment_plan.k8s_name_of` and `namespace_of` return raw
strings after simple character mapping. Manifest rendering then accepts these as
ordinary strings, so invalid or overlong Kubernetes names are not represented in
the type.

**Goal:** Introduce validated Kubernetes name and namespace types.

**Acceptance criteria:**

- Add constructors for DNS-label compatible names and namespaces with length
  checks.
- Use those types in deployment plans and manifest rendering.
- Keep string conversion at kubectl/YAML output boundaries.

**Completed:** Added validated Kubernetes DNS-label name/namespace types, wired
deployment plans and manifest rendering to use typed names, and kept explicit
string conversion at JSON, YAML, kubectl, control-plane, and file-output
boundaries.
