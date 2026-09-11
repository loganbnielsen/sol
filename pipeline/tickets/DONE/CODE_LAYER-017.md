---
id: CODE_LAYER-017
type: code-layer-finding
severity: medium
source: pipeline/audits/2026-09-09_code_layer_audit.md
---

# Reconcile the self-hosted substrate contract with current implementation

`docs/deployment/self-hosted-substrate-contract.md` describes `DATABASE_URL`,
`kafka_secret_name`, `postgres_secret_name`, `tls_secret_name`, and
`loki_url`/`pushgateway_url` `sol.toml` fields that do not match current code.

Update the doc to the implemented contract, or implement the documented fields.
Prefer updating the doc unless a field is already on the near-term product path.

Acceptance:
- The doc matches `Sol_cli_toml`, manifest rendering, and scaffolded examples.
- It uses `POSTGRES_URL` consistently if that remains the contract.
- It does not document unavailable `sol.toml` fields.
