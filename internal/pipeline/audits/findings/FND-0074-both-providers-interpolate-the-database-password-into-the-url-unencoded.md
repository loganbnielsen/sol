---
id: FND-0074
type: audit-finding
severity: medium
source: FND-0073 investigation — reading the connection URL Sol hands an application
---

**Depends on:** None.

**Related:** FND-0073 (the request that hangs before its query), `platform/cloud/aws/cluster/outputs.tf`,
`platform/cloud/gcp/cluster/outputs.tf`.

# Both providers interpolate the database password into the connection URL unencoded

Found while tracing FND-0073. Sol builds `POSTGRES_URL` by string interpolation, in both cluster
roots, with the password placed into the authority section raw:

```hcl
output "postgres_url" {
  description = "POSTGRES_URL for Sol services — set this in your CI secrets and sol.toml [infra.env]"
  value       = var.create_rds ? "postgresql://postgres:${var.db_password}@${aws_db_instance.postgres[0].endpoint}/app" : null
  sensitive   = true
}
```

```hcl
output "postgres_url" {
  description = "POSTGRES_URL for Sol services"
  value       = "postgresql://postgres:${var.db_password}@${google_sql_database_instance.postgres.private_ip_address}/app"
  sensitive   = true
}
```

`db_password` reaches Sol as a caller-supplied variable (`TF_VAR_db_password`), and nothing
constrains its alphabet. A password containing `@`, `:`, `/`, `?`, `#` or `%` changes the URL's
parse: `@` re-splits the authority, `#` turns the rest into a fragment and drops the `/app` path,
`%` starts a percent-escape. The result is a URL that no longer means what it says — a wrong
password, a wrong host or a missing database name — and the failure surfaces as an authentication
or connection error with nothing pointing at the cause.

This is recorded rather than fixed now because FND-0073's live trace is blocked on an expired SSO
session, and because the fix should be made once, provider-neutrally, rather than in whichever
root the next investigation happens to touch.

## Acceptance criteria

- Both providers percent-encode the password (or use a credential form that does not need it) so
  any password a caller supplies yields a URL that names the same host, database and credentials.
- Coverage: a password containing `@`, `:` and `#` produces a URL that still parses to the
  intended host, database and password, on both providers — a mutation test on the generated URL.
- The qualification harness is not the only thing that notices: a deploy that supplies such a
  password must either work or fail with a message that names the encoding.
