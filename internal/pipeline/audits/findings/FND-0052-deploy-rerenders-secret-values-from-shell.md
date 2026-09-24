# FND-0052 — Workload Secret values have two owners: every direct deploy, `sol up` or rollback re-renders them from the operator's shell, reverting `sol secret set` rotations and blanking unset defaults

- **Classification:** `VERIFIED_DEFECT` (the blanking and the revert) + `DESIGN_GAP` (ownership)
- **State:** `OPEN`
- **First identified:** 2026-09-24, correctness audit pass 2
- **Last verified:** 2026-09-24 (`origin/main @ fd5c7e0c`)
- **Derived ticket:** `BUG-054` (BACKLOG: needs an ownership decision)
- **Invariant:** `docs/deployment/credential-rotation.md` — *"`sol secret set` is
  therefore both the create path and the rotation path. The previous value is revoked
  by updating the same object in place."*
- **Evidence class:** `MECHANISM` (Sol's render) + `BEHAVIORAL` (the apply sequence
  against a disposable k3s API server)

## What is established

- With the `Kubernetes_live` backend (the default for a direct or local deploy, and
  hard-coded in `cmd_rollback.ml:58`), `render`
  (`cli/sol/lib/sol_cli_deployment_render.ml:96-128`) writes the workload's
  `<svc>-secrets` with values taken from the CLI process's environment:
  - declared `[infra.env] secrets`: required, and missing ones are an error;
  - the default keys `POSTGRES_URL` and `SOL_API_KEY` (`default_secrets`): read with
    `value_from_env`, which returns `""` when unset. That is not an error.
- `sol deploy` refuses an unset `POSTGRES_URL` (`cmd_deploy.ml:93-123`). It does not
  check `SOL_API_KEY`. `sol rollback` checks neither. `sol up` substitutes the local
  cluster's Postgres.
- `sol secret set` patches the same `<svc>-secrets` objects
  (`cli/sol/lib/sol_cli_secret.ml:378-393`).

Render with both variables unset (`render_spec ~secret_backend:Kubernetes_live`, test
helper `svc_spec`):

```
  name: charge-svc-secrets
  POSTGRES_URL: ""
  SOL_API_KEY: ""
```

The apply sequence, replayed with the same manifest shapes (`kubectl apply -f`, as
both paths do) against a disposable `rancher/k3s:v1.30.4-k3s1` using its own
kubeconfig:

```
after deploy #1:                  POSTGRES_URL=postgresql://app:OLD@db:5432/app SOL_API_KEY=key-1
after sol secret set (rotation):  POSTGRES_URL=postgresql://app:ROTATED@db:5432/app SOL_API_KEY=key-1
after deploy #2:                  POSTGRES_URL=postgresql://app:OLD@db:5432/app SOL_API_KEY=
```

Deploy #2 ran from a shell that still exported the pre-rotation URL and had no
`SOL_API_KEY`. `stringData` overwrites the stored `data` value on every apply.

## Impact

High. After a rotation, the next deploy or rollback silently restores the credential
the rotation revoked. A deploy from a shell without `SOL_API_KEY` blanks the internal
key, so every API-key-authenticated service fails its next start
(`api_key_reader` refuses an empty key) and every peer call is rejected. A rollback, the
incident tool, is the most likely to run from a different shell.

## Remedy shape

Needs an ownership decision (BUG-054). The recommended one: `sol secret` owns values.
A direct deploy creates `<svc>-secrets` only when it is absent. Otherwise it never
writes a value, and it fails when a declared or default key the workload needs is
missing from the live Secret. Either way, a deploy must never write an empty value.

## Related

FND-0013 / INFRA-050 is the earlier failure on this surface. There, a direct deploy
wrote the redacted placeholder Secret, so the workload got empty values. That fix
correctly made a direct deploy resolve to `Kubernetes_live`. This finding is the next
consequence: the live render takes its values from the deployer's shell, while
`sol secret set` and the workspace `sol-secrets` (written by `cloud apply` /
`migrate`) hold the values the operator actually manages. FND-0031 / BUG-040 made
`sol secret` read-before-write; nothing does the same for deploy.
