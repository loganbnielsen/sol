# Sol Dogfood Runbook

This runbook is for engineers validating Sol as a first-time user would: create
a fresh workspace, deploy it to the local substrate, hit the running service,
and record every point of friction.

The goal is not to prove that individual components work. The goal is to prove
the product claim:

> From a prepared Sol substrate, a developer can create, deploy, and reach a new
> service in minutes without writing Kubernetes, Helm, Terraform, or CI glue.

Run reports live in `pipeline/dogfood/`. Each run produces one dated file there.

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
| kubectl | **v1.29.0** |
| helm | **v3.21.0** |

```bash
# All three install user-locally with no root; ~/.local/bin is on PATH on most
# setups. Pin the tested versions.
BIN="$HOME/.local/bin"; mkdir -p "$BIN"

# k3d — release binary directly. The upstream install.sh targets /usr/local/bin
# (root), and its K3D_INSTALL_DIR override has been observed to fall back to a
# sudo prompt anyway (FRIC-019).
curl -fsSL -o "$BIN/k3d" \
  https://github.com/k3d-io/k3d/releases/download/v5.6.0/k3d-linux-amd64
chmod +x "$BIN/k3d"

# helm — the official get-helm-3 script likewise defaults to /usr/local/bin.
curl -fsSL https://get.helm.sh/helm-v3.21.0-linux-amd64.tar.gz | tar xz -C /tmp
install -m 0755 /tmp/linux-amd64/helm "$BIN/helm"

# kubectl
curl -fsSL -o "$BIN/kubectl" \
  https://dl.k8s.io/release/v1.29.0/bin/linux/amd64/kubectl
chmod +x "$BIN/kubectl"

hash -r
which sol k3d helm kubectl   # sol must be the binary you built, not /usr/games/sol
```

If Docker was installed via apt and your user is not yet in the `docker` group,
either re-login or run `newgrp docker` before `sol local infra up` — otherwise
every k3d/kubectl call fails to reach the daemon.

k3d v5.6.0 is pinned because `sol local infra up` passes chart values tuned against
that version (Redpanda CPU/replica settings, node-exporter disable flag). Older
k3d versions may reject those values or install different chart defaults.

Docker Engine 29 removed every Docker API below 1.44, while k3d v5.6.0's client
still speaks 1.43. `sol local infra up` bridges that automatically: it pins
`DOCKER_API_VERSION` to the daemon's minimum for its k3d calls (FRIC-017), so the
combination in the table above works without any manual environment changes.

`sol up` builds through BuildKit when the `docker-buildx` plugin is present
(recommended: the generated Dockerfiles disable provenance/SBOM attestations,
which some cloud container runtimes cannot pull). Stock Ubuntu `docker.io`
ships no buildx plugin, so without it `sol up` falls back to Docker's legacy
builder — which rejects the attestation flags outright — and prints a warning
instead (FRIC-018). Installing the `docker-buildx` package or dropping the
plugin into `~/.docker/cli-plugins/` restores the BuildKit path.

Separately, know what this substrate does **not** do: the k3s it ships (v1.27.4)
uses kube-router, which does not honour cross-namespace `namespaceSelector`
NetworkPolicy rules — `ipBlock` rules work, `namespaceSelector` rules never do,
and egress policy is not enforced at all. Expect that when testing policy
changes locally, and do not read a 200 from a policy experiment as proof the rule
matched. Bumping k3s does not change it: measured identically on v1.27.4 and
v1.35.5 (BUG-024).

These three versions are also hardcoded in `.github/workflows/ci.yml`'s
`golden-path-smoke` job (FRIC-009). No automated check keeps the two in
sync — update both by hand on any bump.

### Required on `PATH`

```
sol  dune  docker  kubectl  k3d  helm
```

### Building the CLI from source

The `sol` binary is an OCaml 5.4+ project with eleven external `*-eio` opam
dependencies, several of which are not on opam yet. From a fresh machine:

```bash
# 1. Refresh the opam index (a stale index does not know about OCaml 5.4.1).
opam update

# 2. Toolchain. `dune-project` requires OCaml >= 5.4.0, and a new switch has no dune.
opam switch create 5.4.1
eval $(opam env)
opam install -y dune

# 3. Pin the external packages from source, then install sol's dependency closure.
for p in kafka-eio obs-eio obs-loki-eio obs-prometheus-eio obs-tempo-eio \
         pg-eio aws-eio s3-eio dynamodb-eio lambda-eio https-eio; do
  opam pin add -y "$p" "https://github.com/loganbnielsen/$p.git"
done
opam install -y --deps-only --with-test .

# 4. Build the CLI.
dune build cli/sol/bin/main.exe
```

`librdkafka-dev`, `libpq-dev`, and `libpq5` (above) are required for step 3 to
compile the C stubs; `dune` alone is not enough.

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
/usr/bin/time -f 'elapsed=%E' sol local infra up
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

Copy this into a new file `pipeline/dogfood/RUN_<YYYY-MM-DD>.md` for each run.

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
| sol local infra up, fresh cluster | |
| sol local infra up, existing cluster | |
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

- The local dogfood path uses a source link into a Sol checkout under
  `vendor/framework`. This unblocks dogfood, but it is
  not the final distribution model. The long-term answer is opam packages or an
  explicit `sol sdk vendor` command.
- `sol local infra up` is substrate bootstrap/reconcile work. It should not be counted as
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
