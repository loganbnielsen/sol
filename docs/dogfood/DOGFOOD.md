# Sol Dogfood Runbook

This runbook is for engineers validating Sol as a first-time user would: create
a fresh workspace, deploy it to the local substrate, hit the running service,
and record every point of friction.

The goal is not to prove that individual components work. The goal is to prove
the product claim:

> From a prepared Sol substrate, a developer can create, deploy, and reach a new
> service in minutes without writing Kubernetes, Helm, Terraform, or CI glue.

Run reports live in `project/dogfood/`. Each run produces one dated file there.

---

## Rules

- Start from a fresh generated workspace outside `examples/`.
- Do the first pass manually. Do not build a harness until the manual path is
  boring.
- Time each major command.
- Record every failure, confusing message, missing default, stale process, and
  documentation mismatch.
- Do not paper over failures with private knowledge. If a step requires context
  that is not in the command output or docs, log it.

---

## Prerequisites

### System packages (Ubuntu/Debian)

```bash
sudo apt-get update
sudo apt-get install -y \
  librdkafka-dev \
  libpq-dev \
  libpq5 \
  pkg-config \
  build-essential
```

`librdkafka-dev` and `libpq-dev` are needed at build time because the generated
workspace links Sol framework source (including C FFI stubs) via `vendor/`.
`libpq5` is a runtime dependency of the `sol` binary itself — install it before
running any `sol` command, not just before `dune build`.

### OCaml toolchain

Install opam and OCaml 5.4.1:

```bash
bash -c "$(curl -fsSL https://opam.ocaml.org/install.sh)"
opam init --bare
opam switch create 5.4.1
eval $(opam env)
```

Install required packages:

```bash
opam install -y \
  eio eio_main \
  cohttp-eio \
  yojson \
  base64 \
  alcotest \
  cmdliner \
  caqti caqti-driver-postgresql caqti-eio
```

### Kubernetes toolchain

Tested versions — other versions may work but are not validated:

| Tool | Version |
|------|---------|
| Docker | 29.x |
| k3d | **v5.6.0** |
| kubectl | 1.29+ |
| helm | **v3.21.0** |

```bash
# k3d
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | TAG=v5.6.0 bash
# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | DESIRED_VERSION=v3.21.0 bash
```

k3d v5.6.0 is pinned because `sol dev up` passes chart values tuned against
that version (Redpanda CPU/replica settings, node-exporter disable flag). Older
k3d versions may reject those values or install different chart defaults.

### Required on `PATH`

```
sol  dune  docker  kubectl  k3d  helm
```

### Sol checkout

`sol new workspace` infers the Sol checkout from the binary path via
`/proc/self/exe`. If inference fails, set:

```bash
export SOL_HOME=/path/to/sol/checkout
```

---

## Fresh Run

Build the current CLI and put it first on PATH:

```bash
cd <your-sol-checkout>
eval $(opam env)
dune build cli/sol/bin/main.exe
export SOL_HOME=$(pwd)
mkdir -p "$SOL_HOME/.dogfood-bin"
ln -sf "$SOL_HOME/_build/default/cli/sol/bin/main.exe" "$SOL_HOME/.dogfood-bin/sol"
export PATH="$SOL_HOME/.dogfood-bin:$PATH"
hash -r
which sol   # must point at the freshly built binary
```

Do not dogfood an older installed `sol` from `~/.local/bin` or another checkout.

Create a fresh dogfood area:

```bash
mkdir -p ~/sol-dogfood
cd ~/sol-dogfood
rm -rf <workspace-name>
```

Generate a workspace:

```bash
/usr/bin/time -f 'elapsed=%E' sol new workspace <workspace-name>
cd <workspace-name>
```

Verify the generated workspace builds:

```bash
/usr/bin/time -f 'elapsed=%E' dune build
```

Provision or reconcile local substrate:

```bash
/usr/bin/time -f 'elapsed=%E' sol dev up
```

Deploy services:

```bash
/usr/bin/time -f 'elapsed=%E' sol up
```

Apply migrations:

```bash
/usr/bin/time -f 'elapsed=%E' sol migrate --table <workspace-name>_migrations
```

Check status:

```bash
sol status
```

Exercise the service:

```bash
curl http://localhost:8080/health

curl -X POST http://localhost:8080/charges \
  -H 'Content-Type: application/json' \
  -d '{"customer_id":"cus_test","amount_cents":777,"currency":"usd"}'

curl http://localhost:8080/notifications
```

Expected results:

- `/health` returns `ok`.
- `POST /charges` returns `{"id":"ch_...","accepted":true}`.
- `/notifications` includes the row — written by `notify_worker` after consuming
  the `Charged` Kafka event, not directly by the HTTP service.

---

## Useful Diagnostics

Cluster state:

```bash
kubectl get pods -A
k3d cluster list
```

Workspace pods (substitute your workspace name):

```bash
kubectl get pods -n <workspace>-payments
kubectl get pods -n <workspace>-comms
```

Logs:

```bash
kubectl logs -n <workspace>-payments deploy/charge-svc --tail=120
kubectl logs -n <workspace>-comms deploy/notify-worker --tail=120
```

Generated runtime env:

```bash
kubectl get configmap -n <workspace>-payments charge-svc-env -o yaml
kubectl get configmap -n <workspace>-comms notify-worker-env -o yaml
```

Port-forward state:

```bash
ps -eo pid,sid,cmd | grep 'kubectl port-forward'
cat /tmp/sol-pf-charge-svc.log 2>/dev/null || true
```

---

## Run Report Template

Copy this into a new file `project/dogfood/RUN_<YYYY-MM-DD>.md` for each run.

```markdown
# Dogfood Run — <YYYY-MM-DD>

Engineer:
Machine/OS:
Sol commit:

## Tool versions

Docker:
k3d:
kubectl:
helm:
dune:
OCaml:

## Timings

| Step | Elapsed |
|------|---------|
| sol new workspace | |
| dune build | |
| sol dev up, fresh cluster | |
| sol dev up, existing cluster | |
| sol up | |
| sol migrate | |
| first successful curl | |

Did the flow complete without manual intervention? yes/no
Could a new engineer understand the failure messages? yes/no

## Friction Log

_(one entry per issue; delete section if none)_

**Step:**
**Command:**
**Expected:**
**Actual:**
**Time lost:**
**Workaround:**
**Blocks two-minute claim?** yes/no
**Suggested fix:**

## Findings

_(anything discovered about correctness, messaging, or missing defaults)_

## Tickets filed

_(links or IDs of any tickets created from friction/findings above)_
```

---

## Current Known Gaps

- The local dogfood path uses source links into a Sol checkout under
  `vendor/framework` and `vendor/integrations`. This unblocks dogfood, but it is
  not the final distribution model. The long-term answer is opam packages or an
  explicit `sol sdk vendor` command.
- `sol dev up` is substrate bootstrap/reconcile work. It should not be counted as
  everyday deploy latency once a substrate exists.

---

## Success Bar

A run is successful when an engineer can start from an empty dogfood directory
and reach all of these without editing generated files:

- generated workspace builds
- local substrate is healthy
- `sol up` deploys all generated services
- `sol migrate` applies migrations
- `sol status` shows ready pods and a reachable URL
- `curl /health` succeeds
- `POST /charges` publishes a `Charged` Kafka event
- `notify_worker` consumes the event and writes the notification row
- `GET /notifications` shows the worker-written record
