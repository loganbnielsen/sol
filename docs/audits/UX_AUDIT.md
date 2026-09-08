# Sun Framework: Developer Experience Audit

This is a reusable audit template. When performing an audit, copy this file (e.g., `EXPERIENCE_FINDINGS_01.md`), work through every section as if you are a startup engineer encountering Sun for the first time, and record every gap in the Findings section using the format at the bottom.

**Who should run this audit:** Someone willing to play the role of a new user — ideally someone who did not write the feature being tested. Prior OCaml and Kubernetes knowledge should not be required to pass this audit. If the auditor needs that knowledge to get something working, that is itself a finding.

**What this audits:** Whether a startup engineer who wants to focus on business logic can start a project, develop it locally, and ship it to the cloud using only Sun's documented commands — without consulting external documentation, asking for help, or understanding the infrastructure underneath.

**Mission alignment lens:** The developer experience must teach Sun's architecture while staying frictionless. A passing UX does not merely get a service running; it makes domain ownership, typed event contracts, explicit auth, generated infrastructure, observability, and day-2 operations feel like the normal way to build.

**The promise being tested:**
```
sun new workspace myapp   # I have a project
sun dev up                # it runs on my laptop
sun dev run               # I can see it working
sun cloud init            # I have a cloud environment
sun deploy <target>       # I can ship
```

Each section has two gates that must both pass:
1. **Docs gate** — Does the necessary guide exist in the repo, and is it accurate?
2. **Reproduction gate** — Can the auditor follow the guide and have it work, without deviation?

A section fails if either gate fails.

---

## Stage 1: Installation

A startup engineer should be able to install Sun with a single command and immediately have a working `sun` binary. They should not need to install a language toolchain, understand package managers, or read a prerequisites list longer than one line.

### Docs gate
* [ ] The README or a linked getting-started guide explains how to install Sun in one step
* [ ] The installation method works on macOS, Linux, and WSL2 without platform-specific instructions
* [ ] The guide states the only prerequisite clearly (if any)

### Reproduction gate

Follow the installation instructions exactly as written.

```
# Run whatever the guide says here
```

**Invariants:**
* [ ] `sun --version` works immediately after following the installation guide
* [ ] No additional steps were required beyond what the guide described
* [ ] The auditor did not need to look up anything outside the repo

---

## Stage 2: Project Creation

After installing Sun, a new engineer should be able to scaffold a working project with one command and understand its structure from the generated files and documentation alone.

### Docs gate
* [ ] The README or getting-started guide shows the exact command to create a new workspace
* [ ] The guide explains what gets generated and how the pieces connect (service → Kafka → worker)
* [ ] The guide explains domain ownership: `events/<team>/` contracts are owned by publishers, while consumers import contracts rather than service internals
* [ ] The guide shows how to build the project after scaffolding

### Reproduction gate

```bash
sun new workspace myapp
cd myapp
eval $(opam env) && dune build
```

**Invariants:**
* [ ] `sun new workspace` runs without errors
* [ ] `dune build` produces zero warnings and zero errors on the generated code
* [ ] The auditor understands the project layout from reading the generated README alone — no prior Sun knowledge required
* [ ] The auditor can identify which domain owns each generated event, service, worker, database module, and migration

---

## Stage 3: Local Development

After creating a project, the engineer should be able to run the full stack locally — service, worker, Kafka, database, and observability — with a single command. They should be able to send a request, see it flow through to the worker, and observe it in Grafana, all without knowing what k3d, Redpanda, or Loki are.

### Docs gate
* [ ] The guide explains how to bring up local infrastructure in one command
* [ ] The guide explains how to run the services locally
* [ ] The guide shows how to verify the full message flow (HTTP request → Kafka → worker)
* [ ] The guide shows where to find logs and metrics (Grafana URL, what to look for)

### Reproduction gate

```bash
sun dev up
sun dev run
```

Then, following the guide:
- Send a test request to the local service
- Verify the worker processed it
- Open Grafana and confirm metrics and logs appear

**Invariants:**
* [ ] `sun dev up` starts all infrastructure without error and prints the addresses of every local service (Kafka, Grafana, Postgres) before exiting
* [ ] `sun dev run` starts all workspace services and tails their output in one terminal
* [ ] A `POST /charges` request to the local service produces a message that appears in the worker logs
* [ ] `sun_worker_messages_total` appears in Prometheus after at least one message is processed
* [ ] The trace/log/metric view lets the auditor follow the request across domain boundaries without manually correlating raw IDs from multiple tools
* [ ] The auditor did not run any command not shown in the guide (no manual `rpk`, `kubectl`, or `dune exec`)

---

## Stage 4: Cloud Setup

After validating locally, the engineer should be able to provision a production-grade cloud environment with a single command. They should not need to know Terraform, understand VPC networking, or configure IAM roles manually.

### Docs gate
* [ ] The guide explains how to provision a cloud environment, with separate instructions for AWS and GCP
* [ ] The guide lists the only required inputs (cloud credentials, region, project name) and nothing else
* [ ] The guide explains what gets provisioned (cluster, database, registry, DNS) at a high level
* [ ] The guide explains how to tear down the environment when done

### Reproduction gate

```bash
sun cloud init --aws    # or --gcp
```

**Invariants:**
* [ ] The command runs to completion without requiring any manual cloud console steps
* [ ] After the command completes, `sun status` shows a reachable cluster with no manual kubeconfig setup
* [ ] The guide's list of provisioned resources matches what actually exists in the cloud account
* [ ] The auditor did not run any `terraform`, `aws`, `gcloud`, or `kubectl` commands themselves

---

## Stage 5: First Deploy

With a local project and a cloud environment, the engineer should be able to deploy with one command. They should be able to verify the deploy worked without knowing kubectl.

### Docs gate
* [ ] The guide shows the exact `sun deploy` command with all required flags
* [ ] The guide explains how to verify the deploy succeeded
* [ ] The guide shows how to check that liveness probes are passing

### Reproduction gate

```bash
sun deploy <target>
```

Then, following the guide, verify the deploy.

**Invariants:**
* [ ] `sun deploy` builds images, pushes to the registry, applies manifests, and waits for rollout — all in one command
* [ ] The command prints the URL of the deployed service when it completes
* [ ] A `POST /charges` request to the cloud service URL succeeds
* [ ] The auditor did not run any `docker`, `kubectl`, or cloud CLI commands themselves

---

## Stage 6: Shipping a Change

The ongoing development loop should be as frictionless as the first deploy. Make a code change and ship it.

### Docs gate
* [ ] The guide explains the change → deploy cycle in terms of Sun commands only
* [ ] The guide explains how to roll back if a deploy goes wrong

### Reproduction gate

Make a visible change to the `charge_svc` handler (e.g., add a field to the response), then deploy it:

```bash
# edit app/payments/charge_svc/lib/handler.ml
sun deploy <target>
```

**Invariants:**
* [ ] `sun deploy` picks up the code change, rebuilds, and deploys without additional flags
* [ ] The change is live within 2 minutes of the command completing
* [ ] `sun rollback` (or equivalent) restores the previous version if called immediately after

---

## Stage 7: Day-2 Operations

After shipping, the engineer needs to observe and operate their system without learning kubectl or any cloud-provider CLI.

### Docs gate
* [ ] The guide explains how to stream logs from a running service
* [ ] The guide explains how to run database migrations
* [ ] The guide explains how to check the health of all running services
* [ ] The guide explains how to add a new service to an existing workspace

### Reproduction gate

```bash
sun logs charge_svc       # stream recent logs
sun migrate               # apply pending migrations
sun status                # show all running services and their health
sun new svc payments/refund  # add a new service
sun deploy <target>       # deploy the new service alongside existing ones
```

**Invariants:**
* [ ] `sun logs <service>` streams log output without kubectl knowledge
* [ ] `sun migrate` applies pending migrations and confirms idempotency when run twice
* [ ] `sun status` shows health, version, and endpoint for every deployed service
* [ ] A newly scaffolded service appears in the next `sun deploy` automatically — no manifest editing required

---

## Stage 8: Adding a Domain Event Flow

After the first project is running, the engineer should be able to add a new cross-domain workflow without learning Kafka internals, copying service code across teams, or editing infrastructure manifests.

### Docs gate
* [ ] The guide shows how to add a new event contract with `sun new event <domain>/<name>`
* [ ] The guide shows how to add a producer or worker that uses that event without importing another service's implementation
* [ ] The guide explains how schema compatibility is checked before deploy
* [ ] The guide explains what infrastructure Sun will synthesize for the new domain/service

### Reproduction gate

```bash
sun new event billing/payment_confirmed
sun new worker logistics/fulfillment
sun deploy <target>
```

Then, following the guide:
- Wire the worker to consume the new event
- Send or produce a sample event
- Verify the worker processed it
- Confirm no Kubernetes or Kafka manifest was edited by hand

**Invariants:**
* [ ] New event code lives under `events/billing/` and compiles without manual dune changes
* [ ] The worker imports the event contract module, not a producer service module
* [ ] Topic, consumer group, namespace, and service names reflect workspace/domain/service ownership
* [ ] Schema compatibility is checked by a documented Sun command or generated test path before deploy
* [ ] No manual `rpk`, Kafka admin call, Kubernetes manifest edit, or raw Terraform edit was required

---

## Stage 9: AI-Agent-Assisted Change

Sun is explicitly designed for AI-assisted development. A typical agent should be able to make a small feature change from the generated structure and local docs without guessing infrastructure details or inventing conventions.

### Docs gate
* [ ] Generated files have predictable names and enough local context for an agent to find handlers, event contracts, migrations, and service entrypoints
* [ ] The README or tutorial states the intended edit points for service logic, worker logic, event contracts, and migrations
* [ ] Framework-owned concerns are clearly separated from developer-owned business logic

### Reproduction gate

Ask an agent, using only the generated workspace and docs, to make a narrow change such as:

```text
Add a customer_email field to the charge request, persist it, include it in the Charged event, and show it in notifications.
```

**Invariants:**
* [ ] The agent edits the handler, event contract, storage module, and migration without touching generated infrastructure manifests
* [ ] The change compiles and the failure points are caught by types or tests, not by runtime guesswork
* [ ] The agent does not introduce cross-domain imports from service implementation modules
* [ ] The agent can verify the change with documented Sun commands only
* [ ] Any schema compatibility issue is surfaced clearly before production deploy

---

## Findings Log

Record every gap found during this audit run below. A finding can be a missing command, a missing or inaccurate doc, a step that required external knowledge, or an invariant that failed.

```
### [EXP-NNN] — Stage / Command Name
* **Stage:** 1 Installation | 2 Project Creation | 3 Local Development |
             4 Cloud Setup | 5 First Deploy | 6 Shipping a Change | 7 Day-2 Operations |
             8 Adding a Domain Event Flow | 9 AI-Agent-Assisted Change
* **Gate:** Docs | Reproduction
* **Severity:** Blocker | High | Medium | Low
* **Description:** What was missing, wrong, or required knowledge the engineer shouldn't need.
* **Impact:** What the engineer would have to do to work around it (and why that breaks the promise).
* **Remediation:** What needs to exist — a new command, a doc update, or both.
```
