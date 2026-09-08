---
id: REFAC-009
branch: REFAC-009/shared-pod-spec
worktree: /home/lbendtly/Code/sun-REFAC-009-shared-pod-spec
type: refactor
severity: medium
source: codebase simplification review 2026-06-15
---

Extract shared pod spec template from `deployment_doc` / `rollout_doc` in `sun_cli_manifest.ml`

**Depends on:** None.

**Description:**

`sun_cli_manifest.ml` contains two functions that render a full Kubernetes workload YAML — `deployment_doc` (lines 232–312) and `rollout_doc` (lines 343–419). Their pod template bodies are **byte-for-byte identical** across ~70 lines:

```
serviceAccountName: <name>
securityContext:
  runAsNonRoot: true
  runAsUser: 65534
  ...
containers:
- name: <name>
  image: <image>
  imagePullPolicy: Always
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
  <ports>
  <secret_env>
  envFrom: ...
  resources: ...
<probes>
```

The only differences between the two documents are the outer wrapper (kind: Deployment vs kind: argoproj.io Rollout) and the strategy block. Because the pod template is duplicated, any change to security policy — user ID, seccomp profile, `readOnlyRootFilesystem`, image pull policy, resource defaults — must be applied twice. A past pod-spec edit introduced `seccompProfile: RuntimeDefault` only in `deployment_doc`, and a later commit had to backport it to `rollout_doc`.

**Remediation:**

1. Extract a private helper `render_pod_spec` in `sun_cli_manifest.ml`:
   ```ocaml
   let render_pod_spec ~name ~image ~ports ~probes ~cpu ~memory
       ~extra_labels ~secret_keys ~config_hash =
     (* All the shared template lines between container spec and pod security context *)
     ...
   ```
   It should return the pod template string that both documents embed verbatim.

2. Rewrite `deployment_doc` to call `render_pod_spec` and wrap the result in the Deployment outer YAML.

3. Rewrite `rollout_doc` to call `render_pod_spec` and wrap the result in the Rollout outer YAML + strategy block.

4. Verify that the rendered output for a representative `svc` service is identical before and after (snapshot test or diff-based check).

**Acceptance criteria:**

- The security context fields (`runAsNonRoot`, `runAsUser`, `runAsGroup`, `seccompProfile`, `allowPrivilegeEscalation`, `readOnlyRootFilesystem`) appear in exactly one place in `sun_cli_manifest.ml`.
- `dune build` passes.
- `sun up --dry-run` and `sun deploy --dry-run` produce the same YAML as before the change (manually diff against a snapshot if no golden-file test exists).

## Review — returned for revision
- `cli/sun/lib/sun_cli_manifest.ml:524` — cronjob_doc contains its own copy of securityContext fields (runAsNonRoot, runAsUser, runAsGroup, seccompProfile, allowPrivilegeEscalation, readOnlyRootFilesystem) — these should be extracted into a shared helper or the acceptance criterion must be scoped only to deployment_doc/rollout_doc

## Review — automated checks passed
Build clean, diff scoped to cli/sun/lib/sun_cli_manifest.ml and tools/perf/perf_baseline.json, all security context fields appear exactly once, no wrapped true libraries introduced.
