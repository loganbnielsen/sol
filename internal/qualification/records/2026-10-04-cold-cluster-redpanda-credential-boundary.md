# Cold-cluster Redpanda credential boundary — mechanism reproduction (2026-10-04)

Offline mechanism characterization, not a live run. It exists to name the first failing
condition behind the paired alpha.7 cloud failures (`2026-10-04-alpha7-cloud-campaign.md`):
AWS attempt 2 and GCP attempt 5 both ended at `module.platform.helm_release.redpanda`
with `context deadline exceeded` after about 700 seconds, and the campaign record left
the first failing pod/hook condition uncaptured. This record reproduces it from a fixture
(`internal/fixtures/`-style local k3d cluster) instead of a live cloud run (BUG-206). It
establishes no qualification row.

## Inputs

- Pinned chart: `redpanda` `26.1.11` from `https://charts.redpanda.com`.
- Values: the `common` and `durable` layers of `redpanda` in
  `platform/shared/components.json`, plus the runtime overrides
  `platform/cloud/modules/platform/main.tf` applies
  (`statefulset.replicas=3`, `storage.persistentVolume.enabled=true`,
  `config.cluster.write_caching_default=false`). The `durable` layer is what the
  `production-single-region` profile selects, on both providers.
- The credential in the fixture is a placeholder. No real credential was created, read
  or logged, and nothing here is product evidence about credential values.

## Render: the chart requires a Secret it does not create

```bash
helm template redpanda redpanda/redpanda --version 26.1.11 -n redpanda -f /tmp/bug206-values.yaml
```

Verbatim fragments of that render (StatefulSet `redpanda` and Job
`redpanda-configuration`):

```yaml
# StatefulSet/redpanda, volumes
      - name: users
        secret:
          secretName: redpanda-users

# Job/redpanda-configuration, volumes
      - name: users
        secret:
          secretName: redpanda-users
```

Neither volume carries `optional: true`, so both are required. The chart's own three
Secret documents are `redpanda-sts-lifecycle`, `redpanda-configurator` and
`redpanda-bootstrap-user`; there is no `redpanda-users` document in the render. The
`redpanda-default-cert` / `redpanda-external-cert` secrets are cert-manager's, not the
chart's. `platform/shared/components.json` only *references* the Secret
(`redpanda.durable.auth.sasl.secretRef = "redpanda-users"`); nothing in the product
creates it, and neither provider harness did (INFRA-108, BUG-206).

## Fixture: the first failing condition

A single-node `k3d` cluster was created and the rendered manifests applied with the
certificate secrets stubbed and **no** `redpanda-users` Secret (cert-manager is not part
of the fixture):

```bash
k3d cluster create bug206 --wait
kubectl create namespace redpanda
kubectl -n redpanda create secret generic redpanda-default-cert --from-literal=ca.crt=placeholder ...
kubectl -n redpanda create secret generic redpanda-external-cert --from-literal=ca.crt=placeholder ...
kubectl -n redpanda apply -f /tmp/bug206-apply.yaml   # every rendered object except Certificate/Issuer
```

Verbatim observations after the kubelet attempted the mounts:

```text
$ kubectl -n redpanda get pods
NAME                           READY   STATUS     RESTARTS   AGE
redpanda-configuration-dzwwf   0/1     Init:0/1   0          27s
redpanda-2                     0/2     Pending    0          27s
redpanda-1                     0/2     Pending    0          27s
redpanda-0                     0/2     Init:0/3   0          27s
redpanda   0/3     28s
redpanda-configuration   0/1   27s

$ kubectl -n redpanda describe pod redpanda-0
  Warning  FailedMount  ...  kubelet  MountVolume.SetUp failed for volume "users" : secret "redpanda-users" not found

$ kubectl -n redpanda describe pod redpanda-configuration-dzwwf
  Warning  FailedMount  ...  kubelet  MountVolume.SetUp failed for volume "users" : secret "redpanda-users" not found
```

The earliest failing operation is therefore the **Redpanda broker pod's `users` volume
mount**: `redpanda-0` cannot leave `Init`/`ContainerCreating`, so the StatefulSet never
reaches `readyReplicas=3`; the post-install Job is blocked identically, so it never
completes either. `helm --wait` waits for exactly those conditions and returns
`context deadline exceeded` when its 600-second timeout expires. The `redpanda-1`/`-2`
`FailedScheduling` events in the fixture are a single-node artifact (pod anti-affinity),
not the cloud condition; they disappear on a multi-node cluster.

Counter-check: creating the Secret unblocks the mount without any other change.

```bash
kubectl -n redpanda create secret generic redpanda-users \
  --from-literal=users.txt='sol-workloads:placeholder-password:SCRAM-SHA-256'
```

Afterwards the init containers completed and the pod advanced past the volume:

```text
$ kubectl -n redpanda get pod redpanda-0 -o jsonpath='{range .status.initContainerStatuses[*]}{.name}{" ready="}{.ready}{"\n"}{end}'
tuning ready=true
redpanda-configurator ready=true
bootstrap-yaml-envsubst ready=false
```

No new `FailedMount` event for the `users` volume was recorded after the Secret existed.

## What this establishes, and what it does not

- **Establishes.** The mechanism that holds the Redpanda release back on a cold cluster is
  the missing operator-supplied `redpanda-users` Secret: two required volumes cannot mount,
  so the StatefulSet and Job never converge and Helm reports only its timeout. Supplying
  the Secret clears the mount condition.
- **Does not establish** that a live cloud install then succeeds: other prerequisites
  (cert-manager certificates, scheduling capacity, the identity boundary) are not
  exercised by this fixture, and the live rerun that credits `Ready` is its own
  authorized run ticket.
- The `durable` layer selects this behaviour on both providers, so the boundary applies to
  AWS and GCP alike. The product-side fix is provider-neutral and is checked against both
  renderings by the shared offline lifecycle suite (`internal/ci/context/test_cloud_lifecycle_offline.sh`).
