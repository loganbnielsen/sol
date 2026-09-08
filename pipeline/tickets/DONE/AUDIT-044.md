---
id: AUDIT-044
type: audit-finding
severity: high
source: codebase review 2026-06-13
branch: AUDIT-044/typed-kubernetes-manifests
worktree: /home/lbendtly/Code/sun-AUDIT-044-typed-kubernetes-manifests
---

Replace hand-built Kubernetes YAML strings with structured manifest generation and parsing

**Depends on:** AUDIT-043.

**Description:** Kubernetes manifests are assembled as large interpolated strings in `cli/sun/lib/sun_cli_manifest.ml`:

- ConfigMaps, Secrets, ExternalSecrets, Deployments, Rollouts, Services, Ingresses, NetworkPolicies, and CronJobs are emitted with `Printf.sprintf` templates.
- `render_env_block`, `render_extra_labels`, `render_secret_key_refs`, `render_canary_step`, and related helpers manually manage YAML quoting and indentation.
- `cli/sun/lib/sun_cli_release_inspection.ml` then parses rendered manifests with line splitting and `field_after_prefix` to recover `kind:` and `metadata.name`.
- `cli/sun/lib/sun_cli_secret.ml` has a separate `yaml_quote` path for secret manifests.

The repo already depends on structured serialization libraries such as `yojson`, but YAML output remains handwritten.

**Impact:** This code is difficult to review and easy to break with a small indentation or quoting change. User-provided values from `sun.toml` such as env config, labels, ingress host/path, ExternalSecret keys, and secret names flow into YAML strings. Even when tests cover common cases, edge cases like `:`, `#`, newlines, quotes, empty strings, and unusual label values can produce invalid or surprising manifests. The release-inspection parser can also drift from the renderer because it is parsing YAML as text.

**Remediation:**

1. Introduce a structured Kubernetes manifest representation using either:
   - a maintained YAML library available to OCaml, or
   - a local typed AST that serializes through a single YAML emitter with one quoting/indentation implementation.
2. Move manifest construction out of large string templates and into typed builders for each resource kind.
3. Make `sun_cli_release_inspection.ml` consume the structured resource values before serialization, or parse generated YAML through the same YAML library instead of prefix scanning.
4. Unify secret YAML handling so `sun_cli_secret.ml` and `sun_cli_manifest.ml` share the same serializer.
5. Keep `kubectl apply --dry-run=server` as an integration validation step, but do not rely on it as the first line of defense against malformed YAML.

**Acceptance criteria:**

- New manifest resources are built from typed values, not raw multiline YAML templates.
- YAML escaping/quoting is covered by focused tests for strings containing quotes, colons, hashes, newlines, and empty values.
- Release inspection no longer extracts `kind` or name by searching for raw `kind:` / `name:` lines.
- Existing manifest-render tests pass without weakening expected security settings.

## Review — automated checks passed
YAML emitter centralised in Sun_cli_yaml.emit_scalar, release inspection improved to use indented name: lookup, all tests pass with full escaping coverage
