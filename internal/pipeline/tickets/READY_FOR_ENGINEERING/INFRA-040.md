---
id: INFRA-040
type: bug
severity: high
title: The migration runner references a Secret name that nothing creates
source: HARDEN Run 6 / Attempt 6 — every migration fails at container start, so no
  workload can be deployed to a cloud target
---

**Related:** HARDEN-002 / the Run 6 record (evidence bundle
`~/.sol/harden-run6-attempt6/`), ADR 0002, `sol_cli_manifest_yaml`,
`sol_cli_substrate`.

## The finding

The first application-centric attempt reached a conformant platform
(`CloudBootstrap → PlatformInstalling → Ready`) and then could not deploy a single
workload. `sol deploy --scope checkout/checkout_svc` passed preflight — the first
time that scope ever has — and failed at the migration gate:

```text
error: cannot verify the required migration state: migration-status Job did not
complete within 120s
  A deploy against the production profile fails closed rather than assume the
  schema is compatible. Run `sol migrate apply cloud/aws/us-east-1` (which reports…
```

Following the prescribed remedy surfaced the real cause, which the deploy's message
had hidden:

```text
Pod sol-migrate-<ts>-<id>   CreateContainerConfigError
  waiting message: secret "sol-secrets" not found
  container envFrom: secretRef{name: sol-secrets}
```

and in the namespace:

```text
secret/sol-secrets-secrets   keys: POSTGRES_URL, SOL_API_KEY
```

The right keys, under the wrong name. The code makes the intent unambiguous:

- `sol_cli_manifest_yaml.ml:58` — `let runtime_secret_name = "sol-secrets"`
- `sol_cli_manifest_yaml.ml:167` — the creation template is `name: %s-secrets`,
  applied to a name that already carries the suffix, yielding
  `sol-secrets-secrets`
- `sol_cli_secret.ml:186-204` even documents `sol-secrets` as the shared object
  "patched separately", so it is meant to be the singleton both sides agree on.

Every consumer references `sol-secrets`; the substrate creates
`sol-secrets-secrets`. So the migration Job's container can never start, the gate
can never pass, and **no Sol workload can be deployed to a cloud target at all**.

## Why it took a second command to see

Two diagnostics gaps compound the defect, and they are part of this ticket because
each one is the difference between a five-minute diagnosis and an hour:

1. **The deploy reports a timeout, not the failure.** A Job whose container cannot
   start is not "slow"; it has already failed. Reporting `did not complete within
   120s` describes the symptom and hides the cause.
2. **The evidence is deleted.** The deploy removes the Job, so the reason is not
   discoverable afterwards; the operator must re-run a different command
   (`sol migrate apply`) to see it.
3. And that prescribed remedy accepts no `--scope`, so following it operates on a
   *different selection* than the scoped deploy that failed — the operator cannot
   reproduce the failing operation from the message that told them to.

## Acceptance criteria

- The Secret the substrate creates and the name every consumer references are the
  same object; a test pins the name on both sides rather than on one.
- A migration Job that fails to start surfaces the container's reason: at minimum
  the waiting reason and message, in the deploy's own output.
- Whatever evidence a failing migration Job produced is retrievable after the
  deploy returns, instead of being deleted with the Job.
- The prescribed remedy is reachable from the failing operation: if a scoped deploy
  can fail this way, the command it tells the operator to run can address the same
  scope.
- Covered offline: the rendered migration Job and the rendered substrate Secret
  agree on the name, and a Job that cannot start is reported with its reason.

## Not in scope

The deploy correctly fails closed rather than assume the schema is compatible.
That behaviour is right and this ticket must not weaken it — only its reporting.

**Demo/example coverage:** Not applicable.

**TypeScript parity:** No language-parity impact.
