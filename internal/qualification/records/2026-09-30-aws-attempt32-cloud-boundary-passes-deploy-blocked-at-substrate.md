# AWS attempt 32: the cloud boundary passes end to end, and the deploy path stops at the workspace substrate (2026-09-30)

Target `qualreg/aws/us-east-1`, cluster `sol-qual-aws-32`, base domain `qual-aws.sol-fab.dev`.
Fresh specimen; the delegated hosted zone is the durable one owned by the AWS bootstrap root.

## Preconditions verified before starting

- **Delegation observable.** `NS qual-aws.sol-fab.dev` returns `Status: 0` with exactly the
  current four nameservers from both Google and Cloudflare resolvers, and the zone answers
  authoritatively: `dig`-equivalent SOA via the resolvers returns
  `ns-1335.awsdns-38.org. awsdns-hostmaster.amazon.com. 1 7200 900 1209600 86400`.
- **Durable root reconciled by the row itself.** The harness's new durable-root step ran as part
  of the cloud phase: `bootstrap: state bucket s3://sol-qual5-876701109436-tfstate present`,
  then `bootstrap: durable root already matches its declared state` — a no-op, which is also the
  first live exercise of that step.

## The cloud boundary passed, and the two earlier defects are now proven live

```
lifecycle phase: CloudBootstrap
  whoami capture: ~/.sol-qual/whoami-capture-….json
  whoami shape: parsed (identity source: extra.canonicalArn)
  cluster access identity: arn:aws:iam::876701109436:role/sol-qual5-cluster-access
  bootstrap window control: principal=confirmed arn:…:role/sol-qual5-cluster-access;
    escalate clusterroles=permitted, bind clusterroles=permitted
lifecycle phase: PlatformInstalling
  [platform-prerequisites-apply] ok (57.3s)
  [platform-apply] ok
  de-escalation verified as arn:aws:iam::876701109436:role/sol-qual5-cluster-access
lifecycle phase: Ready
Done.
```

Both fixes from the stopped row are exercised for real here: the window is managed against the
durable cluster-access identity (the gate parses instead of reading `Unauthorized`), and the
bootstrap-only capability set reads `escalate/bind clusterroles` — permitted inside the window,
which is what makes the later denial meaningful. `de-escalation verified` then appears with the
successor still holding what it needs, so the handoff proof ran in the success path too.

Independent checks on the specimen: `kubectl get nodes` as the cluster-access identity returns
four `Ready` nodes (`v1.36.4-eks`), and the identity is correctly narrow — it may read nodes but
not pods or certificates at cluster scope, which is the installed RBAC working as intended.

Observed and recorded, not yet explained: no ELBv2 load balancer exists in the account
(`describe-load-balancers` returns none), and the zone holds only NS and SOA records. The
platform is `Ready` with no cloud load balancer and no published record, which is consistent
with the documented boundary that DNS publication is the operator's and that reachability is a
separate level from lifecycle readiness — but it is worth a deliberate look, since
"Provisioned endpoints" printed nothing.

## Where the row stopped

Build and ECR push succeeded for `charge_svc` and `notify_worker`; `migrate-apply` then failed at
its first step, the workspace substrate:

```
error: kubectl create (workspace substrate): exited with code 1: Error from server (Forbidden):
error when creating "/tmp/sol-substrate-a94b42.yaml": rolebindings.rbac.authorization.k8s.io is
forbidden: User "arn:aws:sts::876701109436:assumed-role/sol-qual5-cluster-access/EKSGetTokenAuth"
cannot create resource "rolebindings" in API group "rbac.authorization.k8s.io" in the namespace
"pluto-checkout"
```

The identity is **cluster-access** in every variant tried, including when the ambient kubeconfig's
current context was the deploy context — so Sol selects that identity itself, not the shell's.
That matches the code: the deploy path reaches the cluster through `with_access`, and
`Sol_cli_aws_cluster.provisioner_kubeconfig` defaults `--role-arn` to
`cluster_access_role_arn` when none is given.

The authority the step needs exists in the shared platform module, bound to the **deploy**
identity. `platform/cloud/modules/platform/platform_deploy_rbac.tf` declares
`kubernetes_cluster_role.sol_deploy_bootstrap` with exactly the substrate's needs —
`namespaces` (get/list/watch/create), `rolebindings` (get/list/watch/create), and `bind` on the
named `sol-deploy` and `sol-operator-diagnostics` cluster roles — and binds it to group
`sol:deployers`. On AWS, `sol:deployers` is the **deploy** role's group
(`platform/cloud/aws/cluster/main.tf`), while cluster-access is in
`sol:platform-provisioners`, whose ClusterRole grants cluster-scoped `clusterroles` and
`clusterrolebindings` but no namespaced `rolebindings`.

So no identity satisfies the step: the one Sol uses lacks the grant, and the one holding the
grant is not the one Sol uses. Filed as **FND-0071** with the two candidate resolutions; this is
a security-boundary decision (widen a group's authority, or change which identity mutates what),
so the row stops here rather than choosing.

## Qualification-machinery defects found and fixed in this attempt

- **The substrate health check used the wrong identity.** `kubectl get nodes` ran as the deploy
  identity, which is namespace-scoped by design, so a healthy cluster reported `Forbidden`. The
  row now keeps a cluster-access context for cluster-scoped reads and a deploy context for
  namespace-scoped ones.
- **The row inherited the operator's kubeconfig.** `aws eks update-kubeconfig` calls made outside
  the harness had changed the current context in `~/.kube/config`, and the harness's kubectl
  inherited it — the first substrate failure named `sol-qual5-operator`. The harness now exports
  its own `KUBECONFIG` under the run's log directory, so the row cannot be influenced by whatever
  contexts the operator's shell has accumulated.
- **A quoting landmine in `${VAR:?message}`.** `CLUSTER="${CLUSTER:?Set CLUSTER to this run's EKS
  cluster name}"` compiles only because the apostrophe in `run's` opens a quote that a later
  apostrophe closes; removing the second one produced a parse error 50 lines further down. Both
  harnesses are now apostrophe-free in parameter-error messages. The GCP harness was already
  clean.

## Resumed after the actor-selection correction (same specimen)

The finding above was filed as a Sol actor-selection defect. The implementation evidence did not
support that, and the correction is in FND-0071: `aws eks update-kubeconfig` writes one shared
user entry per cluster, so the row's two contexts in one kubeconfig both authenticated as the role
written last. Sol resolves the deploy destination from the target's `kube_context`, as intended.

The row now gives each identity its own kubeconfig file and asserts the boundary live before any
application operation. On the resumed specimen:

```
identity-boundary   deploy creates rolebindings, cluster-access does not
```

and, with the deploy identity genuinely in use:

- `app-build`, `ecr-login`, `app-push` for both images: ok;
- `migrate-apply`: **ok** — the step that had failed at the workspace substrate now completes, and
  `pluto-checkout` ends up with `sol-deploy` and `sol-operator` bindings;
- `app-deploy`: **FAILED** at the server-side dry-run for `notify_worker` in `pluto-comms`, where
  every resource read is `Forbidden` for the deploy identity because that namespace holds no
  RoleBinding, although this same deploy created the namespace.

That is a second, distinct defect, filed as **FND-0072** (the deploy dry-runs a service's
manifests before that namespace's bindings exist, or its ensure does not cover that namespace and
its failure is silent). The row stops there rather than patching through, and nothing was widened
to make it pass.

The specimen remains standing at platform `Ready` with a partial workspace substrate, and is used
for discovery only — it is not the final qualification row, which still has to run fresh from
`cloud plan` through independently verified teardown once this is fixed.

## FND-0072 fixed, and the deploy path now completes on AWS

The defect was that the deploy path's only call to the substrate step sat behind the plan's
profile, so a profile-less target never bootstrapped a namespace: `sol deploy` created
`pluto-comms` and then had its server-side dry-run refused there, while `sol migrate apply`
looked healthy only because its own path calls the substrate unconditionally.

The substrate is now its own prerequisite — unconditional of the profile, derived from the plan's
namespaces, called before the dry-run and before the apply, and refusing a side-effect-free run
with an explanation instead of letting the gap surface as a cluster refusal
(`check_deploy_substrate_order.py` + ten mutations). The discovery specimen showed it working:

```
deploy-substrate
  pluto-payments: no sol-deploy RoleBinding yet
  pluto-comms: no sol-deploy RoleBinding yet
app-deploy
  the deploy established the scoped deploy RBAC in every namespace it entered
```

Neither namespace had the binding beforehand, so this is the clean case the finding asked for —
not a namespace that `sol migrate apply` had already prepared. The deploy then reported
"Done. 2 service(s) deployed.", `charge-svc` was `1/1 Running` on `:80`, and both images were
built and pushed from ECR.

## The application transaction does not complete (FND-0073)

The row's transaction then failed at its first request. The service accepts `POST /charges`,
reads the body, and never answers — 0 bytes back at both 15s and 30s, with nothing in its log
beyond `sol-svc listening on :8080`. Every dependency was checked live and is healthy: schema
registry HTTP 200, broker TCP open, Redpanda admin HTTP 200, RDS 5432 open, and the same
`POSTGRES_URL` carried a successful migration Job earlier in the attempt. Kafka itself sees the
service working — its topic `pluto-payments-charges` is created by the service's own retry loop
and the registry lists `pluto-payments-charges-value` — and the advertised internal listener is a
DNS name with all three brokers Ready.

So the request path reaches Kafka, registers its schema and creates its topic, and then does not
return. Filed as FND-0073 with the evidence; the remaining candidate is the produce/delivery
receipt path as exercised on EKS, which needs its own trace rather than a guessed timeout.

**The row's transaction method changed for a least-privilege reason.** It used
`kubectl port-forward`, which no Sol identity may perform — deploy holds `jobs` but not
`pods/portforward`, operator is `get`/`list` only, cluster-access holds no pod authority. The row
now drives the transaction the way the product reaches a service: a Job in the application
namespace using the deploy identity's existing `jobs` authority, read back from its log. Nothing
was widened.

## Specimen disposition

The discovery specimen was torndown through the supported path (`sol cloud destroy … --apply`)
after this, because the FND-0073 investigation will take materially longer than it is useful to
hold a `Ready` platform for. Attempt 32 is not a qualification run: it reached the application
contract, proved two fixes live, and exposed a third defect. AWS remains unqualified until one
fresh specimen completes the whole row.
