# AWS qualification Run 7, attempt 7 — 2026-09-19

> Moved verbatim on 2026-09-24 from `internal/pipeline/tickets/READY_FOR_ENGINEERING/HARDEN-002.md` (lines 856–935 at `a9d7d827`), when the HARDEN-002 epic was closed as a ticket and its run history moved into the qualification ledger. Headings keep their original levels; the text is unchanged. Index: `docs/qualification/README.md`.

## Run 7 attempt 7 (executed 2026-09-19) — the first migration through a cloud target

Authority `main @ 7ea2ef43`, verified to carry INFRA-040 and the DEC-033 policy
verification before the run. Target `sol-qual11-116c2637`, `destroy_retention: none`,
static `Administrator` profile (the SSO refresh token is still expired).

### Platform: CONFORMANT for the third consecutive run

```text
lifecycle phase: CloudBootstrap
lifecycle phase: PlatformInstalling
lifecycle phase: Ready        Done.
```

Platform construction is no longer where the failures are. Every finding below is
above it.

### Rows qualified

- **The migration ran and completed on a cloud target, for the first time.**
  `sol migrate apply` reached `Done.`, and `sol deploy` then reported
  `Migrations: OK -- 1 declared migration(s) present in schema_migrations`. The
  migration gate that no previous attempt could pass, passed.
- **INFRA-040 is validated live.** Attempt 6's migration Job died with
  `CreateContainerConfigError: secret "sol-secrets" not found`; Attempt 7's container
  started and ran. The Secret identity agrees with the reference.
- **DEC-033's disposable-destroy contract is qualified live.** The destroy reported
  what it selected before doing it, verified against the selected policy rather than
  a single expected value, and ended with:

  ```text
  prepare: disabling RDS deletion protection, retaining nothing...
  verify preparation: RDS deletion protection disabled, final snapshot skipped
    (skip_final_snapshot=true) (target destroy_retention = none)
  retention: none (target destroy_retention = none) -- destroyed to Absent with no
    residual billable artifacts
  ```

  Independent verification: EKS none, RDS 0, **zero manual snapshots**, EC2
  terminated, NAT deleted, EIP/LB/EBS/VPC/ECR none. The target reached `Absent` with
  no manual step — the behavioural row Attempt 6 could only reach through an operator
  deviation.

### Findings

- **INFRA-043 (high, the current blocker):** the deploy identity cannot get or create
  `sol-boundary-lease-<workspace>` — Sol's own object, held by Sol's required deploy
  identity. Every `sol deploy` stops here, one grant short of a running workload.
- **INFRA-044 (high):** a failed migration printed the full Postgres URL, password
  included, into Sol's output and the Job's logs.
- **Procedure gap:** an RDS password containing URI-reserved characters must be
  percent-encoded by the operator; the documented step does not say so, and an
  unencoded password surfaces only as `connection failed`. The password generated for
  this qualification account contains such characters, so the first run through the
  migration path hit it.
- **INFRA-040's evidence-retention item is now demonstrated live,** not just argued:
  `sol deploy` said "see the Job logs" *after* deleting them, and that deletion cost
  the live diagnosis until the same operation was re-run through `sol migrate`.

### Deviations

1. `Administrator` (static) rather than the SSO profile, which is still expired.
2. The Postgres password was percent-encoded by the operator after the first failure;
   the run continued on the encoded form.
3. The workspace's `SOL_API_KEY` is required and still absent from the procedure's
   deploy step.

### Boundary this leaves

```text
CloudBootstrap        PASS
PlatformInstalling    PASS
Ready                 PASS
Application preflight PASS
Migration Job         PASS   <- first time
Deployment lease      FAIL   (INFRA-043: missing grant)
Workload              NOT REACHED
Release / rollback    NOT REACHED
```
