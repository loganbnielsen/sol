# Pluto

A Sol workspace with OCaml service examples (`charge_svc`, `checkout_svc`,
`notify_worker`) and the existing TypeScript demo pair under `app/demo_ts`.

## Build

```bash
eval $(opam env)
dune build
dune runtest test
```

`test_charges` exercises the typed charge decoder and database operation boundary
without HTTP or a database. The handler's routes only connect decoding, the operation,
and response rendering; Pluto accepts through Postgres, while the workspace scaffold
accepts by publishing a Kafka event.

## Run locally

```bash
# Start Kafka (Redpanda) and Postgres
bash <path-to-sol>/platform/local/scripts/ensure-broker.sh
bash <path-to-sol>/platform/local/scripts/ensure-postgres.sh

# Run the worker (POSTGRES_URL is required — both services depend on Postgres)
KAFKA_SECURITY_PROTOCOL=plaintext KAFKA_BROKERS=localhost:9092 SCHEMA_REGISTRY_URL=http://localhost:8081 REDPANDA_ADMIN_URL=http://localhost:9644 POSTGRES_URL=postgresql://postgres:dev@localhost:5432/sol_dev \
  dune exec app/comms/notify_worker/bin/main.exe

# In another terminal, run checkout. SOL_API_KEY is the shared internal key.
PORT=8081 SOL_API_KEY=dev-internal-key dune exec app/checkout/checkout_svc/bin/main.exe

# In another terminal, run payments. It calls checkout through CHECKOUT_SVC_URL.
POSTGRES_URL=postgresql://postgres:dev@localhost:5432/sol_dev \
  CHECKOUT_SVC_URL=http://127.0.0.1:8081 SOL_API_KEY=dev-internal-key \
  dune exec app/payments/charge_svc/bin/main.exe
```

`charge_svc` declares `calls = ["checkout/checkout_svc"]`. In a Sol cluster
that injects `CHECKOUT_SVC_URL` as a cluster DNS URL for the checkout
ClusterIP, so the east-west request never leaves the cluster network. The
generated per-pair NetworkPolicy is what permits that caller/target path.

```bash
curl localhost:8080/checkout-quote
# {"shipping_cents":799,"currency":"USD","trace_id":"..."}
```

With `sol local infra up`, `checkout_svc` is exposed through the local north-south URL:

```bash
curl -H 'Host: checkout-svc.pluto-checkout.localhost' \
  -H 'x-api-key: dev-internal-key' \
  http://localhost:8088/quote
```

For customer-cloud, set `ingress_host` in `checkout_svc/sol.toml` to your DNS
name, run `sol deploy customer_cloud/aws/us-east-1`, then create an
`A`/`CNAME` record for that host pointing at the ingress load balancer.
Cert-manager uses the configured cluster issuer for TLS.

## Production profile

In `sol/environments.yml`, the `pilot` environment selects the
`production-single-region` profile; `prod` deliberately does not, because an
environment's name never makes a production claim.

The profile runs Kafka as SASL_SSL. Before the first deploy, create the broker's
SASL users Secret and give the workload namespaces the credential and the CA;
`sol deploy` fails closed without them:

```bash
kubectl create secret generic redpanda-users -n redpanda \
  --from-literal=users.txt="sol-workloads:$KAFKA_SASL_PASSWORD:SCRAM-SHA-256"
sol secret set KAFKA_SASL_PASSWORD --value "$KAFKA_SASL_PASSWORD" --target pilot/aws/us-east-1
kubectl get secret redpanda-default-cert -n redpanda -o jsonpath='{.data.ca\.crt}' \
  | base64 -d | sol secret set KAFKA_SSL_CA_CERT --target pilot/aws/us-east-1
```

See [production bootstrap](../../docs/deployment/production-bootstrap.md) for the
full procedure.

A production target deploys immutable artifacts, not mutable tags. Pin each
workload to the digest the build pushed:

```bash
REGISTRY=123456789012.dkr.ecr.us-east-1.amazonaws.com
sol deploy pilot/aws/us-east-1 \
  --image-ref charge_svc="$REGISTRY/pluto/charge-svc@sha256:$CHARGE_DIGEST"
```

A bare `--image-ref <ref>` is accepted when the scope selects exactly one
service; a whole-workspace deploy needs one `<service>=<ref>` per workload (the
`app/demo_ts` services deploy the same way). `sol deploy` verifies each
reference exists in its registry before it applies anything.

```bash
sol deploy pilot/aws/us-east-1 --scope payments/charge_svc --dry-run \
  --image-ref charge_svc="$REGISTRY/pluto/charge-svc@sha256:$CHARGE_DIGEST"
```

A scoped deploy keeps the cross-domain callers it did not select. This
workspace's `payments/charge_svc` calls `checkout/checkout_svc`
(`calls = ["checkout/checkout_svc"]` in `app/payments/charge_svc/sol.toml`), so
deploying the callee alone:

```bash
sol deploy pilot/aws/us-east-1 --scope checkout --dry-run
```

deploys `checkout/checkout_svc` and nothing else, and the NetworkPolicy it
renders still admits `payments/charge_svc` — the incoming edge comes from the
whole workspace declaration rather than from the selection, so a caller that is
already running keeps access to the callee it was pointed at.

Either form runs the profile preflight before anything touches a cluster. It
refuses until the target establishes every guarantee the profile requires — a
tag reference is itself one unmet guarantee — and lists each unmet guarantee
with who must act.

Every workload declares its framework language in `sol.yml`. This workspace's
OCaml services declare `language: ocaml`; the `app/demo_ts` pair declares
`language: typescript`, so the preflight reports TypeScript as not yet
qualified for the first profile (DEC-026 §2) rather than silently admitting it.
The exact supported set — CLI, OCaml version, Kubernetes, provider module and
chart versions — is published in
`docs/deployment/compatibility.md` in the Sol repository.

The pilot target declares the alert-delivery contract
(`alert_receiver_type`/`alert_receiver_url`/`alert_owner`/`alert_runbook_url`).
Exercise that route without a real incident:

```bash
kubectl -n monitoring port-forward svc/prometheus-alertmanager 9093:9093 &
sol alert test --target pilot/aws/us-east-1
```

The command's exit status proves the route is configured and reachable; the
delivered-and-acknowledged result is HARDEN-002's live evidence. Runbooks for
each required alert are in `docs/deployment/alert-runbooks.md`.

Availability is declared, not inferred from replica count (AUDIT-080).
`notify_worker` declares `availability = "node-failure-tolerant"` (with two
replicas and a consumer readiness/liveness pair on `/readyz`//`livez`), so Sol
renders a topology spread, a PodDisruptionBudget and an explicit drain grace for
it; `charge_svc` stays `single` and is reported honestly as such. The pilot and
prod targets declare the fixed `node_failure_headroom_nodes` the claim needs.
See `docs/deployment/workload-availability.md`.

A production deploy refuses to roll code out against an unapplied migration
(AUDIT-069). This workspace has one migration, `db/migrations/0001_notifications.sql`,
with a matching `0001_notifications.down.sql` for `sol migrate rollback`.
`sol migrate apply --dry-run` connects to the target database and prints only
unapplied migration SQL; set `POSTGRES_URL` when previewing a remote target.
The two deploy cases are:

- **Compatible** — after `sol migrate apply prod/aws/us-east-1`, `sol deploy
  prod/aws/us-east-1` verifies `0001_notifications` against the authoritative
  `schema_migrations` table and proceeds.
- **Deliberately blocked** — drop a new file in (say `0002_add_index.sql`)
  without running `sol migrate apply`: the deploy fails before any workload
  moves, naming the missing migration and the command to fix it. `--dry-run`
  stays side-effect free and reports the prerequisite as not verified.

See `docs/deployment/migration-ordering.md`.

See the "Production Profile" section of
`docs/reference/substrate.md` in the Sol repository.

## Once per account: the installation

The installation is the durable, account-level layer — the Terraform state backend
and its locking, the provisioning/cluster-access/deploy/operator identities, and the
delegated DNS zone when Sol owns one. It outlives every environment: `sol cloud
destroy <target>` removes an environment, never the installation.

It is declared where the environment's durable state already lives, in the target:

```yaml
prod:
  targets:
    aws/us-east-1:
      cluster_name: pluto-prod
      base_domain: pluto.example.com
      state_bucket: pluto-tfstate
      aws:
        state_lock_table: pluto-tflock
        provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
        cluster_access_role_arn: arn:aws:iam::111122223333:role/sol-cluster-access
        deploy_role_arn: arn:aws:iam::111122223333:role/sol-deploy
        operator_role_arn: arn:aws:iam::111122223333:role/sol-operator
```

Sol creates the durable state, but the four identities are yours to create: it
generates each least-privilege policy document and you attach it to a role of your
own (`AUDIT-072`). Reconciling the durable root writes those documents beneath the
root's working directory and prints their paths, so no Terraform output has to be
read by hand:

```text
    provisioning identity        declare aws.provisioner_role_arn
      contract: ~/.local/share/sol/terraform/aws-bootstrap-…/identity-contracts/provisioner_policy_json.json
```

Then observe it, and reconcile it once:

```bash
sol cloud bootstrap prod/aws/us-east-1          # report: what is established, what is not
sol cloud bootstrap prod/aws/us-east-1 --apply  # reconcile the durable root
```

### The ordinary path: `sol deploy` detects it

That pair is the explicit administrative route. The ordinary one needs no
separate command: `sol deploy` observes the same installation, and when it is not
established — which is what a target with no cluster to reach looks like on a
fresh account — it reports what it found and offers to set it up:

```text
$ sol deploy prod/aws/us-east-1 --image-ref charge_svc="$REGISTRY/pluto/charge-svc@sha256:$DIGEST"

Sol is not installed for prod/aws/us-east-1 yet:

  what Sol observed at the provider, never inferred from configuration:
  terraform state backend      Unmet: An error occurred (404) ... Not Found
  terraform state lock         Unmet: An error occurred (ResourceNotFoundException) ...
  provisioning identity        Unmet: An error occurred (NoSuchEntity) ...
  ...
  delegated DNS zone           Unmet: no Route53 hosted zone named pluto.example.com, ...

  the installation the target declares:
  state bucket             pluto-tfstate
  state prefix             bootstrap/aws
  region                   us-east-1
  lock table               pluto-tflock
  ...

  Sol does this for you:
  reconcile the durable installation root, which keeps a Terraform state of its own:
    its state backend and its locking, and the durable resources it declares
  create the DNS zone for pluto.example.com, or adopt the zone that is already
  there rather than create a second one with different nameservers, ...

  One action may be required from you:
    when the zone that publishes pluto.example.com is not in this account, add the
    exact NS records Sol prints at that zone; Sol then waits for the delegation and
    confirms it from a public resolver, never from written configuration
Set up Sol for prod/aws/us-east-1 now? [Y/n]
```

Accepting reconciles the durable root, prints the exact NS records to add when
the parent zone is outside the account, waits for the delegation to become
visible and confirms it from a public resolver, then re-observes and continues
into the deploy. An observation Sol could not make — a refused read, or a CI
identity that is not allowed to read the durable layer — is `UNKNOWN`, never
treated as an absent prerequisite (`DEC-052`).

The same vocabulary covers the substrate this workspace runs on. `sol target show
--target prod/aws/us-east-1 --check` reports each self-hosted input
(`docs/reference/substrate.md`) as `Established`, `Unmet` or `UNKNOWN`, so you can see
which parts of the contract Sol actually observed for this target and which ones only
the cluster's own network can answer:

```text
kubernetes    reachable
substrate: kubernetes cluster Established
substrate: container registry UNKNOWN: the prefix is registry.example.test/pluto; Sol
cannot make a node pull an image, so whether the cluster can pull from it is unverified
substrate: postgres connection Established
substrate: kafka and schema registry UNKNOWN: the broker addresses and schema-registry
URL are workspace configuration; whether the workloads can reach them, and the broker's
security posture, are properties of the cluster's network, and are observed there rather
than here
```

Declining, or running where no one can answer (CI, `--dry-run`, `--emit-to`),
never prompts and never sets anything up: it prints the same observation and the
command that does it explicitly, so a pipeline fails with an explanation instead
of hanging or skipping installation:

```text
Sol is not installed for prod/aws/us-east-1, and this run is not interactive, so
Sol will not set it up and will not continue as if it were there.
...
Set the installation up once, then run this deploy again:
  sol cloud bootstrap prod/aws/us-east-1 --apply
```

An account that already has an installation is deployed to with no one-time setup
and no prompt; and because the run only ever *observes* it in that case, no
durable resource is touched again.

The environment is created in place as well, and that is the same stage
`sol cloud apply` drives — not a second implementation. Once the installation is
established, the run reconciles the environment (network, cluster, database and
platform) and then reaches the cluster it created as the *deploy* identity, so it
continues straight into migration and deployment:

```text
$ sol deploy prod/aws/us-east-1 --image-ref charge_svc="$REGISTRY/pluto/charge-svc@sha256:$DIGEST"

Profile: production-single-region/v1 (preflight passed)

Sol does this for you: reconcile the environment for prod/aws/us-east-1 — network,
cluster, database and platform — from the durable installation, and establish this
run's own cluster access.
...
The environment for prod/aws/us-east-1 is provisioned.
  cluster access identity: arn:aws:iam::<account>:role/sol-deploy (this run, ephemeral)
...
```

The plan and the profile preflight are built *before* anything is provisioned, so
a blocker that can be named now is named now rather than after the billable
boundary. The deploy identity's cluster access is a temporary kubeconfig for that
run: Sol never writes your `~/.kube/config` or the target file, and never reaches
the cluster as the provisioning identity (`DEC-058`, `DEC-034`). `sol cloud apply
prod/aws/us-east-1` remains the explicit route for the same stage, and is what
`sol status`, `sol logs` and `sol migrate` need: those read the target's declared
`kube_context`, so run the printed `deploy_kubeconfig_command` once and add the
context name it writes. Where a provider declares no deploy identity — GCP today —
the deploy stops after provisioning and prints exactly that command and context.

A second environment needs **no** installation work: it deploys against the
installation that already exists, which is why redeploying never means redoing
registrar or DNS work.

```bash
sol deploy prod/aws/us-east-1     # first environment
sol deploy pilot/aws/us-east-1    # a second one, same installation
```

## Granting a workload cloud authority: `sol grants`, then `sol deploy`

A unit that declares `secrets = ["stripe"]` needs a cloud identity and an IAM grant
of its own. That is a lifecycle separate from infrastructure and from deployment
(DEC-062): a fenced reconciler reconciles the whole target's workload identities and
grants, `sol cloud apply` creates that reconciler's identity and its fence, and
`sol deploy` only *observes* the resulting access — it never creates or repairs it.

```bash
sol grants plan prod/aws/us-east-1   # review: + payments-api → secret/stripe
sol grants apply prod/aws/us-east-1  # the reconciler establishes it
sol deploy prod/aws/us-east-1        # consumes it; grants nothing
```

The plan names the unit, the capability and the resource, so a production credential
being granted is visible before it is granted. The reconciler is target-wide with no
`--scope`: a partial reconcile would revoke every unselected unit's grants, so the
operation does not accept one. A removal is revoked only when the declarations no
longer require it *and* no deployed workload still records using it; when the deployed
state cannot be observed, nothing is revoked.

The target must declare the reconciler's trust principal (`aws.reconciler_trust_principal_arn`
for AWS, `gcp.reconciler_trust_principal` for GCP) and the reconciler's own identity
(`aws.reconciler_role_arn` / `gcp.reconciler_service_account`). A target without them
skips the authorization lifecycle, and `sol grants` refuses to run as the deploy
identity.

`sol deploy` proves the grants are effective before it applies anything, read-only: on
AWS it simulates `secretsmanager:GetSecretValue` against the unit's role for the
declared secret (`iam:SimulatePrincipalPolicy`; its fidelity is `VERIF-021`), on GCP it
reads the secret's IAM policy for the unit's Workload Identity principal. A grant that
is declared but not yet established fails the deploy at plan time, naming the unit, the
grant and the reconciliation to run — so no pod is left waiting in `ContainerCreating`
for a credential that does not exist:

```text
$ sol deploy prod/aws/us-east-1
unit charge-svc does not have effective access to secret/stripe in prod/aws/us-east-1:
the reconciler has not established the grant. Run `sol grants apply prod/aws/us-east-1`,
then re-run this deploy (DEC-062 rule 3).
```

The deploy identity holds no IAM-mutating permission at all — only read-only IAM
visibility — so it can observe effective access but can never create, widen or repair a
grant (`check_deploy_identity_iam.py` holds that structurally).

## Tearing down: destroy an environment, or uninstall Sol

The two operations remove different things, and neither removes the other's.

```bash
sol cloud destroy prod/aws/us-east-1 --apply   # environment only
```

That removes the environment's network, cluster, database and workloads, verifies
their absence independently, and leaves the installation standing: the state
backend, the identities, and the delegated DNS zone survive, so redeploying the
same environment needs no registrar or DNS work again. Sol reports what it
retained and why.

Removing the installation is its own command and is never implied by an
environment destroy:

```bash
sol uninstall prod/aws/us-east-1
```

Without `--confirm` it prints the plan and changes nothing. The plan names what
it would remove (the state facility, and the delegated zone when Sol owns it) and
what it keeps, with the reason: a user-supplied or externally delegated zone,
the registrar NS records (which live outside every provider API Sol can call),
and the four identities, which the durable root does not create — the operator
creates them from its policy output.

When the zone going away is a Sol-created one, it needs its own confirmation
naming the exact domain, because the delegation at the registrar becomes stale
and a recreated zone gets different nameservers:

```bash
sol uninstall prod/aws/us-east-1 --confirm --confirm-dns-zone pluto.example.com
```

After the removal Sol re-observes each resource with the installation's own
probes and reports which are absent; an unqueryable answer is UNKNOWN and fails
closed rather than being reported as removed.

## CLI commands

```bash
sol local infra up        # provision local k3d cluster + infra
# Secrets are the one input a deploy never writes; create them first.
sol local secret set POSTGRES_URL --value postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev
sol local secret set SOL_API_KEY --value dev-internal-key
sol up                    # verify the secrets, then build and apply the workloads
sol local status  # show running pods and endpoints
sol local migrate # apply database migrations
```

## Container images

The OCaml units use the same two-stage Dockerfile a scaffolded workspace gets: a
glibc-pinned builder that installs this workspace's dependencies from
`pluto.opam`, then a minimal `ubuntu:24.04` runtime. The build context is the
workspace root -- this directory -- and the images run as uid 65534 to match the
`securityContext` Sol renders into the manifests. To build one by hand:

```bash
docker build -f app/payments/charge_svc/Dockerfile -t pluto-charge-svc .
```

The TypeScript pair has its own story -- npm workspaces, and a runtime stage that
ships only the unit it serves: see `app/demo_ts/README.md`.

## Project layout

```
events/payments/            ← Charged event contract (payments team owns)
app/payments/charge_svc/         ← OCaml HTTP service (POST /charges, calls checkout)
app/checkout/checkout_svc/       ← OCaml HTTP service (GET /quote, ingress exposure)
app/comms/notify_worker/         ← OCaml Kafka consumer (subscribes to Charged)
app/demo_ts/order_svc/           ← TypeScript HTTP service demo
app/demo_ts/fulfillment_worker/  ← TypeScript worker demo
db/migrations/                   ← SQL migration files
```
