---
id: CODE_LAYER-019
type: code-layer-finding
severity: medium
source: https://github.com/loganbnielsen/sol/pull/170#discussion_r3964685511
---

# Model workspace discovery as typed project facts

`sol check`, service discovery, and deployment planning still infer workload
shape directly from `app/<domain>/<name>_{svc,worker,fn}` path conventions.
That is enough for the immediate preflight gap, but the next layer should parse
the workspace once into typed facts and let downstream checks consume that
model.

Add a small workspace/project model for:

```text
app directory -> domain -> workload path -> primitive -> sol.toml facts
```

Keep this as an internal library boundary. Do not add hosted APIs or change CLI
UX in this ticket.

Acceptance:
- One scan returns typed workload facts for `svc`, `worker`, and `fn`
  directories.
- Unexpected `app/<domain>/*` directories are represented as warnings or
  ignored facts instead of disappearing silently.
- `sol check` consumes the typed model instead of doing its own directory scan.
- Existing `discover_services` callers keep current behavior.
- `dune build @all` and `dune runtest cli/sol/test` pass.
