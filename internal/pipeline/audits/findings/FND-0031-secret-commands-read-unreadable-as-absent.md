# FND-0031 — `sol secret set/delete/list` read an unreadable Secret as absent; `set` rewrites it without its existing data and reports success

- **Classification:** `VERIFIED_DEFECT`
- **State:** `FIXED_UNQUALIFIED` (BUG-040, 2026-09-23: unreadable reads are errors; fake-kubectl regression + mutation check; not exercised against a live API server)
- **First identified:** 2026-09-23, correctness audit (`2026-09-23_correctness_audit.md`)
- **Last verified:** 2026-09-23 (`origin/main @ f3e9480b`)
- **Derived ticket:** `BUG-040`
- **Invariant:** SEC-004 — "rotation must be verified, not assumed"
  (`sol_cli_secret.ml` comment above `list_live_workloads`); the fail-open definition
  of the 2026-09-21 audit.
- **Evidence class:** `MECHANISM` (a fake `kubectl` whose reads fail; the manifest Sol
  applied was captured). The data loss on the API server is `STATIC`: it follows from
  `kubectl apply`'s documented client-side merge and was not observed against a live cluster.

## What is established

`Sol_cli_kubectl.get` already turns a non-zero exit into `Error`. `get_named_secret_json`
(`cli/sol/lib/sol_cli_secret.ml:155-162`) then maps **every** failure — kubectl could
not run, NotFound, Forbidden, API unreachable, unparseable JSON — to `Ok None`, the
value that means "this Secret does not exist". Three sibling reads collapse the same
way into `[]`: `list_workload_secrets` (`:189`), `list_live_workloads` (`:248`), and
`list`'s per-namespace `Error _ -> Ok acc` (`:337`).

The consumers treat that value as a fact:

| Command | What a failed read becomes | What is reported |
|---|---|---|
| `set` (`:310`) | `existing_data = []` → applies a `sol-secrets` manifest with **no `data`**, only the new key; patches no per-workload `-secrets` (list read as empty); restarts and verifies **nothing** (workload list read as empty) | `secret set in 1 namespace(s)` |
| `delete` (`:348`) | "key not present" → **no patch issued** | `secret deleted from 1 namespace(s)` |
| `list` (`:337`) | namespace skipped | an empty or partial key list |

### Reproduction (run 2026-09-23)

A fake `kubectl` on `PATH` fails every `get` (`Unable to connect to the server: net/http:
TLS handshake timeout`, exit 1) and succeeds every `apply`. The probe links `sol_cli`
and calls the library entry points `cmd_secret.ml` passes straight through to:

```ocaml
Sol_cli_secret.set    ~ctx:Sol_cli_kube_destination.local_context ~env:"cloud"
  ~workspace:"demo" ~namespaces:["payments"] ~key:"NEW_KEY" ~value:"v"
Sol_cli_secret.delete ~ctx ~env:"cloud" ~workspace:"demo" ~namespaces:["payments"] ~key:"LEAKED_KEY"
Sol_cli_secret.list   ~ctx ~env:"cloud" ~workspace:"demo" ~namespaces:["payments"]
```

Observed:

```text
sol secret set NEW_KEY (every kubectl read fails) -> Ok: secret set in 1 namespace(s)
sol secret delete LEAKED_KEY (every kubectl read fails) -> Ok: secret deleted from 1 namespace(s)
sol secret list (every kubectl read fails) -> Ok:
```

The manifest `set` applied:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: sol-secrets
  namespace: payments
type: Opaque
stringData:
  NEW_KEY: "v"
```

`delete` issued no `kubectl patch`. No `rollout restart` or `rollout status` ran.

## Why it is destructive, not just misleading

`apply` is client-side `kubectl apply -f` (`sol_cli_kubectl.ml:20`), a three-way merge
against the `last-applied-configuration` annotation. After any successful `set`, that
annotation holds the previous keys under `data:`. Applying a manifest without `data`
therefore **removes** those keys. One transient read failure during `sol secret set`
can erase the workspace runtime Secret's other credentials. `set` then reports success
and skips the restart that would have exposed the loss. Workloads pick up the damage
at their next restart.

`delete` is the security-relevant half. An operator removing a leaked credential is
told it is gone when no patch was sent.

## Impact

High. The likelihood is lower than for FND-0024 (a read has to fail while the write
succeeds), but the consequence is silent credential loss or a false "revoked".

## Remedy shape (for the ticket)

Make the read tri-state, as FND-0024/0025 did: `Present json | Absent | Unreadable
reason`, with only a kubectl NotFound mapping to `Absent`. `set` and `delete` must fail
on `Unreadable`. The three list reads must return `Error`, not `[]`. `restart_and_verify`
must not report success over a workload list it could not read.

## Related

FND-0024 (same collapse, `probe`); FND-0025 (same collapse, pointer read); SEC-004
(rotation verification); FND-0013/INFRA-050 (deploy-time per-workload Secret, distinct).
