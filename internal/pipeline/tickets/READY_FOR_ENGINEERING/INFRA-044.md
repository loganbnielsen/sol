---
id: INFRA-044
type: bug
severity: high
title: A failed migration prints the database URL, password included, into Sol's output
source: HARDEN Run 7 / Attempt 7 — the connection failure echoed the full Postgres URL
---

**Related:** HARDEN-002 (the Run 7 record), the migration runner, `sol migrate`,
`sol deploy`'s migration gate, INFRA-040 (the diagnostics around the same path).

## The finding

When the migration Job could not reach the database, Sol reproduced the runner's
error verbatim, and the runner had included the connection string it was using:

```text
error: migration error: create migrations table: connection failed:
  Failed to connect to <postgresql://postgres:<the-account-password>@<host>:5432/app>
```

The password is in Sol's own output, in the Job's logs, and in any log sink those
reach. A connection error is the *most likely* place for this to happen, because the
failing input is exactly the string that must not be printed.

This is not a hypothetical exposure: `POSTGRES_URL` is a workspace secret that
deployment, migration and runtime all hold, and a qualification or CI run puts this
output into a terminal, a run log and a captured evidence bundle by default.

## What is needed

- A connection URL is redacted wherever Sol reproduces a migration or runtime error:
  the credentials are replaced with a placeholder that still shows the shape (user,
  host, database), because those are the parts an operator needs to diagnose.
- Redaction happens at the boundary where the error is rendered, not only in logs Sol
  writes itself — the runner's own output is the leak here, so scrubbing after the
  fact would leave it in the Job's logs.
- The rule is exercised: a test drives a failing connection with a known password and
  asserts the password does not appear in Sol's output or in the Job logs.
- Anything else in the same family — any surfaced error that can carry a secret value
  — is covered by the same mechanism rather than fixed one message at a time.

## Note

The related diagnostics gap is INFRA-040's: it said "see the Job logs" after deleting
them. That is recorded there; this ticket is only about what the output contains.

**Demo/example coverage:** Not applicable.

**TypeScript parity:** No language-parity impact.
