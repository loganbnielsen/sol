# Run record — `byo` × Kubernetes secret projection on a throwaway cluster

**Ticket:** `VERIF-020`. **Provider:** `byo` (local, throwaway — not a cloud cell).
**Record:** `internal/qualification/records/2026-10-03-byo-run1-secret-projection.md`.

This run exercises the DEC-029 "External CSI-compatible store (e.g. Vault) ×
`byo` × Kubernetes" projection mechanism on a disposable local cluster, so the
`to qualify` cells in DEC-029's comparison become observed verdicts. It is a
**local behavioural** run: the mechanism is real Kubernetes, the store is Vault,
and nothing is mocked.

## 1. Run identity

| Field | Value | Source |
|---|---|---|
| Sol revision | `dbd8c0ba4ef694b7fb131a67592f6befcf7efff9` | `git rev-parse HEAD` (worktree `sol-VERIF-020-secret-projection`, branch `VERIF-020/secret-projection-experiment`) |
| Working tree state | clean; this record is the only change | `git status --porcelain` |
| Substrate | k3d `v5.6.0` on Docker `29.5.3`, WSL2 (`6.6.87.2-microsoft-standard-WSL2`) | `k3d version`, `docker version` |
| Kubernetes observed | `v1.27.4+k3s1`, node `k3d-verif020-server-0` | `kubectl get nodes` |
| Cluster | `verif020` (throwaway) | `k3d cluster create …` |
| Kubeconfig | `/tmp/verif020/kubeconfig.yaml`, isolated | `k3d cluster create --kubeconfig-update-default=false --kubeconfig-switch-context=false`, then `k3d kubeconfig get verif020` |
| Default context untouched | `sol-qual11-116c2637-deploy` before and after | `kubectl config current-context` (no `KUBECONFIG` override) |
| Components | secrets-store-csi-driver chart `1.4.8`; Vault chart `hashicorp/vault` with `server.dev.enabled=true`, `csi.enabled=true`; Vault observed `2.0.4` | `helm install`/`helm upgrade` |
| Started (UTC) | `2026-10-03T17:24Z` | first `k3d cluster create` |
| Finished (UTC) | `2026-10-03T17:51Z` | last recovery observation |
| Evidence bundle | `/tmp/verif020/` (`01`–`08` logs, manifests `10`–`50`), outside the repository | |

The default kubeconfig was never written: creation used
`--kubeconfig-update-default=false --kubeconfig-switch-context=false`, and the
`verify` commands ran with `KUBECONFIG=/tmp/verif020/kubeconfig.yaml`. The
`sol-local` cluster and the `sol-qual11-…-deploy` context were not touched.

## 2. Setup, as run

```sh
k3d cluster create verif020 --image rancher/k3s:v1.27.4-k3s1 \
  --kubeconfig-update-default=false --kubeconfig-switch-context=false \
  --k3s-arg "--kube-apiserver-arg=feature-gates=ValidatingAdmissionPolicy=true@server:*" \
  --k3s-arg "--kube-apiserver-arg=runtime-config=admissionregistration.k8s.io/v1alpha1=true@server:*" \
  --wait
helm install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
  --version 1.4.8 -n kube-system \
  --set syncSecret.enabled=true --set enableSecretRotation=true --set rotationPollInterval=30s
helm install vault hashicorp/vault -n vault --create-namespace \
  --set server.dev.enabled=true --set csi.enabled=true --set injector.enabled=false
```

Vault configuration (dev-mode root token, in-container `vault` CLI):

```sh
kubectl -n vault exec vault-0 -- vault kv put secret/workload-a password=s3cr3t-a
kubectl -n vault exec vault-0 -- vault kv put secret/workload-b password=s3cr3t-b
printf 'path "secret/data/workload-a" { capabilities = ["read"] }\n' \
  | kubectl -n vault exec -i vault-0 -- vault policy write workload-a -
kubectl -n vault exec vault-0 -- vault auth enable kubernetes
kubectl -n vault exec vault-0 -- sh -c \
  'vault write auth/kubernetes/config kubernetes_host="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT"'
kubectl -n vault exec vault-0 -- vault write auth/kubernetes/role/workload-a \
  bound_service_account_names=workload-a bound_service_account_namespaces=demo policies=workload-a ttl=1h
```

A `demo` namespace held ServiceAccounts `workload-a` and `workload-b`. The
`SecretProviderClass` `vault-workload-a` used `provider: vault`, `roleName:
workload-a`, and one `objects` entry (`objectName: password`, `secretPath:
secret/data/workload-a`, `secretKey: password`) — **no `secretObjects`**. Pod
`workload-a` (SA `workload-a`) mounted it at `/run/secrets` read-only.

## 3. Step log

### Step 1 — baseline mount, mount type, delivered version (P3, P6, and delivery-is-a-file)

- **Command:** `kubectl -n demo exec workload-a -- cat /run/secrets/password`,
  `… cat /proc/mounts | grep run/secrets`, `… stat -f -c %T /run/secrets`,
  `kubectl -n demo get secretproviderclasspodstatus -o yaml`
- **Observed:**

  ```text
  s3cr3t-a
  tmpfs /run/secrets tmpfs ro,relatime 0 0
  tmpfs
  ```

  ```text
  status:
    mounted: true
    objects:
    - id: password
      version: yi8B1cuNCSw4nM0QCGsPdeTlLPfTeDKIPFthWJf1A_8=
    podName: workload-a
    secretProviderClassName: vault-workload-a
  ```

- **Assertion under test:** the value is delivered as a **file on a tmpfs
  mount**, and a per-object version is observable (P3/P6).
- **Result:** `PASS` — tmpfs, and a version is present.

### Step 2 — rotation enabled, measured delay (P4, P8)

- **Command:** `kubectl -n vault exec vault-0 -- vault kv put secret/workload-a
  password=s3cr3t-a-v2`, then poll `cat /run/secrets/password` every 5 s.
- **Driver args in force:**

  ```text
  --enable-secret-rotation=true --rotation-poll-interval=30s
  ```

- **Observed:**

  ```text
  t=+0s value=s3cr3t-a
  t=+5s value=s3cr3t-a
  t=+11s value=s3cr3t-a
  t=+16s value=s3cr3t-a
  t=+21s value=s3cr3t-a
  t=+26s value=s3cr3t-a-v2
  ```

  The `SecretProviderClassPodStatus` version changed from
  `yi8B1cuNCSw4nM0QCGsPdeTlLPfTeDKIPFthWJf1A_8=` to
  `jIVUv_8fcjLrakkgzA7fdftda3vr5twQOtrR2Jn-5Zg=`.
- **Assertion under test:** rotation completes with no manifest edit, and the
  bound is the poll interval.
- **Result:** `PASS` — the file changed between `+21 s` and `+26 s` after the
  store write, within one `30 s` poll interval.

### Step 3 — rotation disabled, staleness (P4, P8)

- **Command:** `helm upgrade … --set enableSecretRotation=false`, wait for the
  DaemonSet, write `password=s3cr3t-a-v3`, poll for 80 s.
- **Observed:**

  ```text
  t=+37s value=s3cr3t-a-v2
  … (every 6 s) …
  t=+80s value=s3cr3t-a-v2
  ```

- **Assertion under test:** with rotation off the mounted file does not refresh.
- **Result:** `PASS` — the file stayed at v2 for the whole window; the value is
  stale until a pod-level remount.

### Step 4 — rotation re-enabled, catch-up

- **Command:** `helm upgrade … --set enableSecretRotation=true
  --set rotationPollInterval=30s`, poll.
- **Observed:**

  ```text
  t=+0s value=s3cr3t-a-v2
  …
  t=+31s value=s3cr3t-a-v3
  ```

- **Result:** `PASS` — the reconciler caught up within one poll interval.

### Step 5 — `secretObjects` syncing, and the policy that refuses it (P7 invariant)

- **Command (before the policy):** create a `SecretProviderClass` with
  `secretObjects` and a pod that mounts it; then read the synced Secret.
- **Observed (the risk is real):**

  ```text
  secretproviderclass.secrets-store.csi.x-k8s.io/vault-workload-a-sync created
  pod/workload-a-sync created
  pod/workload-a-sync condition met
  # kubectl -n demo get secret workload-a-synced -o jsonpath='{.data.password}' | base64 -d
  s3cr3t-a-v3
  ```

- **Command (the guard):** apply a `ValidatingAdmissionPolicy` +
  binding (v1alpha1) that denies any `secretproviderclasses` whose
  `spec.secretObjects` is non-empty, `validationActions: ["Deny"]`; then
  re-apply the same SPC.
- **Observed:**

  ```text
  validatingadmissionpolicy.admissionregistration.k8s.io/sol-refuse-secret-object-sync created
  validatingadmissionpolicybinding.admissionregistration.k8s.io/sol-refuse-secret-object-sync created
  The secretproviderclasses "vault-workload-a-sync" is invalid: : ValidatingAdmissionPolicy 'sol-refuse-secret-object-sync' with binding 'sol-refuse-secret-object-sync' denied request: Sol never syncs a CSI secret into a Kubernetes Secret (DEC-029 invariant)
  ```

- **Assertion under test:** a cluster policy can hold the "syncing stays off"
  invariant even though the driver supports syncing.
- **Result:** `PASS` — without the policy the driver copied the value into a
  plain Kubernetes Secret; with the policy the same object is refused.

### Step 6 — a forbidden ServiceAccount reading another workload's path (P2)

- **Command:** an SPC referencing `roleName: workload-a`, mounted by a pod whose
  ServiceAccount is `workload-b`.
- **Observed:**

  ```text
  workload-b-forbidden   0/1     ContainerCreating
  MountVolume.SetUp failed for volume "secrets" : … error making mount request:
  couldn't read secret "password": failed to login: … Code: 403. Errors:
  * service account name not authorized
  ```

- **Assertion under test:** access is per unit identity, not per namespace.
- **Result:** `PASS` — the Vault role binding denied a different ServiceAccount.

### Step 7 — a plain Kubernetes Secret mounted by another SA (the `byo` P2 gap)

- **Command:** a plain Secret `workload-a-plain` mounted by a pod with SA
  `workload-b` in the same namespace; read it.
- **Observed:**

  ```text
  plain-s3cr3t
  ```

- **Assertion under test:** Kubernetes Secrets are namespace-scoped, not
  per-workload.
- **Result:** `PASS (gap confirmed)` — a different ServiceAccount read another
  workload's Secret.

### Step 8 — authority unavailable (P8)

- **Command (1b, running pod):** with `workload-a` running, delete
  `svc/vault`, then read the mounted file.
- **Observed (1b):**

  ```text
  # before outage
  s3cr3t-a-v3
  service "vault" deleted
  # after ~12 s with the authority unreachable
  s3cr3t-a-v3
  ```

- **Command (1a, new pod):** create `workload-a-down` while the authority is
  down.
- **Observed (1a):**

  ```text
  workload-a-down   0/1     ContainerCreating
  MountVolume.SetUp failed … dial tcp: lookup vault.vault.svc.cluster.local on 10.43.0.10:53: no such host
  ```

- **Command (2, container restart):** stop the running container through the
  runtime (`crictl stop --timeout 0 <id>`), then read the file.
- **Observed (2):**

  ```text
  workload-a   1/1   Running   1 (31s ago)
  # kubectl -n demo exec workload-a -- cat /run/secrets/password
  s3cr3t-a-v3
  ```

- **Command (recovery):** recreate `svc/vault`; the stalled pod became Ready
  and read `s3cr3t-a-v3`.
- **Assertion under test:** a new unit fails closed when the authority is
  unavailable, a running unit keeps its last-known value, and a container
  restart does not require a fresh authority read.
- **Result:** `PASS` — 1a fails closed; 1b holds the last-known value; a
  container restart reuses the pod-level mount (the file stayed readable with
  the authority down); the stalled pod recovered once the authority returned.

## 4. Row roll-up

| DEC-029 property | Required evidence class | Result | Evidence |
|---|---|---|---|
| P1 — Sol never needs the plaintext | BEHAVIORAL | `PASS (cell-level)` | the value lived only in Vault and reached the pod as a file; the declaration was an SPC + role |
| P2 — per unit identity, auditable | BEHAVIORAL | `PASS` | step 6: 403 `service account name not authorized` for a different SA |
| P3 — values are versioned | BEHAVIORAL | `PASS` | step 1/2: PodStatus `version` present and changed across rotations |
| P4 — rotation without a manifest edit | BEHAVIORAL | `PASS` | step 2: file changed within one 30 s interval; step 4: catch-up |
| P5 — survives cluster loss | — | `NOT ESTABLISHED` | the run's store was an in-cluster Vault dev server, which is cluster-local; an external store is architectural, not observed here |
| P6 — delivered vN distinguishable from stale/failed | BEHAVIORAL | `PASS` | PodStatus `version` vs the mounted value; step 3 shows stale is distinguishable |
| P7 — no new always-on component unless re-qualified | — | `CONFIRMED (cost)` | the mechanism adds the CSI driver, the provider and the authority; none are in the supported set (see §6) |
| P8 — stated per-runtime bounds | BEHAVIORAL | `PASS` | step 2 (staleness ≤ poll interval), step 8 (fail-closed new pod; running pod keeps the last-known value; container restart reuses the mount) |
| `byo` × Kubernetes Secrets P2 | BEHAVIORAL | `CONFIRMED UNMET` | step 7: namespace scoping is the bound |
| `byo` × Kubernetes Secrets P3 | BEHAVIORAL | `CONFIRMED UNMET` | a plain Secret has no per-value version |

## 5. Measurements

| Target | Required bound | Measured | Method | Within bound? |
|---|---|---|---|---|
| Rotation, enabled | ≤ poll interval + fetch | changed between `+21 s` and `+26 s`; `+31 s` on catch-up | poll `cat` every 5 s after a store write, `rotationPollInterval=30s` | yes |
| Rotation, disabled | no refresh | stale `>80 s` | poll `cat` every 6 s | yes |
| Authority loss, new pod | fail closed | `ContainerCreating`, `FailedMount` (DNS fail) | create pod with `svc/vault` deleted | yes |
| Authority loss, running pod | keep last-known value | unchanged `s3cr3t-a-v3` | read the mounted file after the outage | yes |
| Container restart, authority down | pod-level mount survives | file readable, pod `1/1` (`RESTARTS 1`) | `crictl stop` the container, then read | observed |

## 6. Deviations and environment notes

| Time (UTC) | Step | What was done differently | Why | Effect on evidence |
|---|---|---|---|---|
| 17:25 | cluster | k3d/k3s image `v1.30.5-k3s1` failed to start (`failed to get ready … stopped returning log lines`; container `ExitCode=1`, no logs); `v1.29.9-k3s1` failed the same way | this host cannot start those k3s images, as VERIF-020 recorded | none — the experiment ran on `v1.27.4-k3s1`, which starts |
| 17:26 | CSI driver | chart `1.4.8` installed instead of the latest `1.6.1` | `1.6.1` declares `kubeVersion >=1.30.0-0`, incompatible with 1.27 | recorded: the driver version is a compatibility input |
| 17:30 | CSI driver | the DaemonSet could not start: `path "/var/lib/kubelet/pods" is mounted on "/var/lib/kubelet" but it is not a shared mount`; fixed with `mount --bind /var/lib/kubelet/pods /var/lib/kubelet/pods && mount --make-rshared /var/lib/kubelet/pods` inside the node | k3d/k3s-in-Docker exposes `/var/lib/kubelet` with a duplicate, partially-slave mount, so the driver's Bidirectional propagation is refused | none on the mechanism; a procedure prerequisite for any future k3d run |
| 17:26 | VAP | ValidatingAdmissionPolicy required the alpha feature gate on 1.27: `--kube-apiserver-arg=feature-gates=ValidatingAdmissionPolicy=true` and `runtime-config=admissionregistration.k8s.io/v1alpha1=true` | VAP is GA in 1.30 but alpha on 1.27 | recorded: the policy guard needs ≥1.28 (beta) / ≥1.30 (GA), or the alpha gate |
| — | DEC-040 bootstrap capture | not applicable | this run provisions no cloud bootstrap | not part of this run's evidence |

## 7. Cleanup

- **Destroy command and time:** `k3d cluster delete verif020`, 2026-10-03T18:04Z;
  exit status `0`.
- **Observed:**

  ```text
  Deleting cluster 'verif020'
  Deleting cluster network 'k3d-verif020'
  Deleting 1 attached volumes...
  Successfully deleted cluster verif020!
  ```

- **Absence check:** `k3d cluster list` then showed only `sol-local` (untouched);
  the isolated kubeconfig `/tmp/verif020/kubeconfig.yaml` is a scratch file.
- **Default context after teardown:** `sol-qual11-116c2637-deploy`, unchanged.
- No cloud resources exist; there is no billable residue and no account to
  inventory. The working tree carries only this record and the ledger edits.

## 8. What this run does not establish

- **P5 for an external store.** The store was in-cluster Vault dev mode;
  durability across cluster loss is architectural, not observed.
- **The production profile.** This is a `byo` local mechanism check; it does
  not qualify the AWS/GCP cells, which are separate live runs.
- **Sol's own code.** Sol does not yet implement the CSI projection; this run
  qualifies the mechanism DEC-029 selected, not a Sol behavior. No Sol defect
  was exposed.
- **`secretObjects` under Sol.** The policy that refuses it is a demonstration,
  not a shipped guard.
- **The mounted-file contract under Sol's framework.** `Secret.get` and any
  reload hook were not exercised.

## 9. Ledger updates implied

| Item | State before | Would move to | Because |
|---|---|---|---|
| DEC-029 Vault row, P1/P2/P3/P4/P6 | `to qualify` (documentation-derived) | observed (`PASS`) | steps 1–6 |
| DEC-029 Vault row, P8 | `to qualify` | observed (`PASS`), with the bounds in §5 | steps 2, 3, 8 |
| DEC-029 Vault row, P5 | `meets` (architectural) | `NOT ESTABLISHED` by this run | §8 |
| DEC-029 Vault row, P7 | `fails today` | confirmed: driver `1.4.8` + provider + authority are new always-on components | §6 |
| DEC-029 `byo` Kubernetes Secrets row, P2 | `does not meet` | confirmed by observation | step 7 |
| FEAT-088 component set | — | the three components are named as candidates, not accepted | §6 |
