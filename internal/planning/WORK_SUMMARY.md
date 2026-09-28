# Work Summary — Self-hosted refocus complete (2026-06-22)

## Latest: FEAT-105 CI-gated native auto-merge verified (2026-09-28)

- Repository auto-merge is enabled; required test/admin enforcement remain, and
  approving-review count was already zero. PR #650 was queued through soldev while
  CI was pending, then squash-merged by GitHub after required checks succeeded.
- soldev removes universal review markers and worktree deletion/local sync from
  merges; immediate requests need successful required checks, and --auto delegates
  waiting to GitHub. Both pin the head and reject drafts/unresolved prerequisites.
- Worker/review/self-review/demo skills, local PR skill, and contributor/agent
  guidance now agree. Focused soldev tests and no-comments guard pass locally.
- REFAC implementation/merging is paused until BUG-066/FEAT-105's faster workflow
  has been verified, per operator direction.

## Latest: BUG-066 lightweight docs-only CI verified (2026-09-28)

- Exact-source cached ticket validator replaces the product bootstrap on warm
  docs-only runs; a cold cache falls back to full validation, never a false pass.
- Relevant ticket, specification, classification, and account-artifact checks stay.
  Execution-path and existing mutation suites pass locally. PR #650's live warm-cache
  required check passed in 11 seconds, with about 3 seconds of cache/validation work
  and 21 seconds total including the separate classification job and scheduling.
- Product setup/build/tests and unrelated suites explicitly skipped; all 814 tickets
  validated through the authoritative parser. Draft auto-merge refusal was verified.

## Latest: Logan review generalized into durable audit rules (2026-09-28)

- FEAT-105 captures the approved faster merge policy: green required CI by default,
  native squash auto-merge, optional risk-based review, and matching tooling/skills/docs.
  Filed READY_FOR_ENGINEERING; repository settings have not been changed by filing.
- BUG-066 separately captures the expensive docs-only CI bootstrap and unrelated
  guard suites, preserving ticket validation while restoring the lightweight path.
- REFAC-154 captures direct monadic composition only for semantically empty bindings.
- REFAC-148..153 turn the local review examples into whole-codebase work: unchanged
  Result propagation, eager argument normalization, conceptual collection grouping,
  bounded CLI effect boundaries, typed domain inputs, and visible state/phase pipelines.
- The style and code-layer audit skills now carry those same lenses, including the
  important restraints: grep only seeds manual review, short clear expressions stay
  inline, long signatures do not become vague dependency bags, and inherently streaming
  effects stay effectful.
- All six tickets are readable; five are immediately actionable and REFAC-149 waits on
  REFAC-148 so the Result-specific normalization lands before the broader sweep.

## Latest: GCP Attempt 19 — the TLS path is qualified (2026-09-28)

- **The whole path works, end to end, on a fresh target** (`352fd870`, `qual19/gcp/us-central1`,
  `cluster_issuer: letsencrypt-staging` declared): `platform-apply ok (180.5s)`, lifecycle **`Ready`**,
  80 pods running and none pending, both issuers deployed with `dns01.cloudDNS.project =
  sol-qualification`, the cert-manager pod annotated with its GSA, both ACME orders **valid**, both
  platform certificates **`Ready=True`**.
- **Verified independently, not inferred.** A TLS connection to the LoadBalancer IP with the hostname as
  SNI returns a certificate whose subject and SAN are that hostname, issued by the ACME *staging* CA, and
  the service answers over it (307 for Argo CD, 302 for Grafana).
- **The least-privilege design held as written** — an eight-permission record role bound on the managed
  zone, a two-permission zone-discovery role at project level, and nothing else but
  `roles/iam.workloadIdentityUser` for `cert-manager/cert-manager`. Nothing had to be widened, which is
  the evidence that the permission list is right rather than merely sufficient.
- **Attempt 18 is why this took two specimens**: the first version built the solver from a
  provider-conditional local, and the `kubernetes_manifest` provider could not coerce the unified type —
  which also blocked the *destroy*, so the substrate stood until the module was fixed and Sol's own
  destroy could converge it. Recorded in
  `internal/qualification/records/2026-09-28-gcp-attempt18-issuer-manifest-type-failure.md`.
- **`FND-0067` → `QUALIFIED` (GCP half)**; `INV-SUBSTRATE-1`'s ingress realization is qualified on GCP.
  AWS stays unqualified (no AWS run has reached a platform install).
- Two observations recorded, not acted on: neither provider publishes A records for the platform's own
  ingress hostnames (so name→address is outside Sol today), and the run's environment cannot resolve
  public DNS, so the certificate claim was verified by SNI against the IP, which is the stronger of the
  two for that claim.

## Latest: DEC-055 — a provider-native DNS-01 path, so GCP can issue certificates (2026-09-28)

- **The shared platform module no longer knows an AWS-only solver.** `DEC-055` decided GCP gets
  first-class TLS through **Cloud DNS DNS-01 + Workload Identity**, AWS keeps Route 53 and its own
  identity mechanism, and the boundary used is the one the module already had for Thanos's object-store
  identity — the module selects the solver and the pod's identity annotation from `var.cloud_provider`,
  and each provider root supplies its own values. No new certificate-provider abstraction.
- **Where each concern lives:** the solver (`route53` with a region the *AWS* root now owns, `cloudDNS`
  with the project the GCP root owns); the identity (IRSA role ARN vs a new GSA); the pod wiring
  (`eks.amazonaws.com/role-arn` vs `iam.gke.io/gcp-service-account`, bound through
  `roles/iam.workloadIdentityUser` for `cert-manager/cert-manager`); and least privilege (the AWS inline
  policy scoped to the workspace's zone, unchanged; on GCP a custom role carrying only the record and
  change permissions, bound **on the managed zone**, plus a project-level zone-discovery role).
- **Workload Identity was not enabled anywhere.** The repo declared `iam.gke.io/gcp-service-account`
  annotations and `roles/iam.workloadIdentityUser` bindings for Loki and Thanos, but never set the
  cluster's `workload_identity_config` nor the node pool's `workload_metadata_config` — so the pool served
  *node* credentials and those annotations were dead. That is a prerequisite of the mechanism `DEC-055`
  chose, so both are now set and guarded (two more mutations); the Loki/Thanos paths had never been
  exercised live, which is why it had not surfaced.
- **Fail closed:** both ClusterIssuers carry a plan-time `precondition`, so an empty provider identity
  fails the apply rather than deploying a solver with no credentials. The **GCP driver's install-time
  refusal is gone** — the gate it was built to be — so a GCP target declaring `cluster_issuer` now
  installs the issuer path instead of being refused, and the qualification harness's target declares one
  (`letsencrypt-staging` by default, overridable).
- **Coverage:** `internal/ci/check_provider_tls_path.py` + twelve mutations hold the contract, and the
  mutation test earned its keep twice — it caught a check that a solver name in the file satisfied while
  the issuers had been hardcoded, then one that a variable *name* satisfied while the reference was gone.
  It also forced the guard to fail closed on unparseable HCL. `#629`'s mirroring guard required the AWS
  root to mirror the new inputs, which is how that convention is enforced.
- **`FND-0067` → `FIXED_UNQUALIFIED`**; the live half (Attempt 18) is what observes a certificate issuing.
  AWS TLS stays unqualified too, and implementing this exposed a detail worth recording: the AWS path
  declared an IRSA role for cert-manager but never annotated the pod, and that role's trust policy is the
  cluster's OIDC provider — so the declared identity was arguably unreachable there as well.
- **New frontier, deliberately not settled:** Attempt 17 reported `Ready` while the platform's own
  certificates were `READY=False` → `FND-0068` / `DEC-056` (BACKLOG, decision required). `Ready`'s
  executable contract is component availability; the module requests certificates unconditionally; and
  there is no supported "no TLS" configuration despite the refusal sentence that claimed one. So whether
  certificate issuance belongs in `Ready` is a product-semantic choice — with the unpublished-delegation
  case as its sharp edge — and nothing in the lifecycle moved.

## Latest: GCP Attempt 17 — `Ready` on Standard, and the TLS blocker (2026-09-28)

- **The platform installs and reaches `Ready`.** Attempt 17 (`30ad9835`, fresh `qual17/gcp/us-central1`,
  4 × e2-standard-4) is the first run on GKE Standard to get past the platform apply:
  `platform-apply ok (166.6s)` where Attempt 16 was `FAILED (695.0s)`, **72 of 73 pods `Running` with
  none `Pending`**, all six PVCs `Bound`, and `lifecycle phase: Ready`. Nodes came up at
  `3920m / 13591676Ki` allocatable each — the estimate in FND-0066 said ≈ 3.9 CPU / ≈ 13 GiB, within 1%.
- **`FND-0066` → `QUALIFIED` (GCP half).** Nothing else changed between the two runs, so the driver-default
  change is what made the difference. The AWS half stays inference until an AWS run reaches a platform
  install.
- **Ready-state destruction exercised for the first time**: a supported `sol cloud destroy` from the
  `Ready` platform — `platform-destroy ok (131.7s)`, authority bracket removed, `terraform-destroy
  ok (583.6s)`, `teardown verified: absent`, no billable residue, both durable prerequisites standing.
- **New blocker: `FND-0067` / `DEC-055`.** The platform's only ACME DNS-01 solver is `route53` with a
  hardcoded `us-east-1`, declared in the *shared* platform module, and `cert_manager_irsa_role_arn`'s own
  description says "AWS only … leave empty on GCP". On GCP the role is empty, cert-manager falls back to
  an AWS credential chain that does not exist, and every challenge ends in `PresentError … Route 53 …
  NoCredentialProviders`. The platform is `Ready` while **no ingress — dashboard or application — can
  obtain a certificate**; `argocd-tls` and `grafana-tls` were still `READY=False` after 14 minutes. The
  decision space (a Cloud DNS solver + Workload Identity, a stated limitation on the profile, or a
  refusal) is in `DEC-055`.

## Latest: FND-0066 / DEC-054 — the driver defaults adopt the shape the profile recommends (2026-09-27)

- **GCP Attempt 16** (`c6d8a460`, fresh `qual16/gcp/us-central1`): the merged qualification observer was
  proven live on the code path that lost the evidence five attempts running — the run's credentials were
  established while the cluster became `RUNNING` (poll 61), the API probe's configured endpoint matched
  the provider's, and the failure capture completed **10 of 10** reads and let the run reach the
  cert-manager discriminator and a verified teardown. Full bundle: `/tmp/sol-gcp-qual-16`.
- The run then answered the Redpanda/Loki question. `platform-prerequisites-apply ok (52.4s)`, then the
  full `platform-apply` failed on exactly two releases (`redpanda`, `loki[0]`) with 58 of 62 pods
  `Running`. The four `Pending` pods are the finding: each redpanda broker asks **2.00 CPU** against
  **1.93 CPU** allocatable per node, and the loki chunk cache asks **9.60 GiB** against **5.88 GiB** —
  each larger than an entire node, so no node count and no autoscaler can schedule them. The pool was
  nowhere near full (the 58 scheduled pods committed 2.23 of 5.79 CPU), which is why this looked like a
  timeout rather than a fit failure.
- **`FND-0066`** records it with the three declarations that never agreed, and rules out storage, disk
  quota, taints, admission and the Helm timeout as causes. **`DEC-054`** was put to the operator with its
  tradeoffs; the answer was to size the substrate, implemented as the driver defaults adopting what
  `Sol_cli_profile` already declared: `min_vcpu_per_node = 4`, `largest_pod_vcpu = 2`,
  `platform_vcpu = 10` with one node held back, and `recommended_node_shape = m6i.xlarge x 4`.
- Concretely: GCP `node_machine_type` `e2-standard-2` → **`e2-standard-4`** and `node_count` 3 → **4**;
  AWS `node_instance_types` `m6i.large` → **`m6i.xlarge`** and `node_desired_size` 3 → **4**.
  `internal/ci/check_node_shape_fits_platform.py` + nine mutations read the requirements *out of the
  profile* rather than restating them, and carry the one constraint the envelope does not yet encode:
  the loki chart's 9.6 GiB chunk cache.
- Two residuals are recorded, not closed: the AWS half is inference until an AWS run reaches a platform
  install, and `Platform_capacity` in the profile preflight checks `recommended_node_shape` — a constant
  — so it never saw the substrate being provisioned. `FND-0066` → `FIXED_UNQUALIFIED`; the next live
  specimen is what observes the four pods scheduling.

## Latest: DOCS-025 — the readiness path depends on the declared language (2026-09-27)

- `docs/deployment/workload-availability.md` said an HTTP service is probed on `/healthz` for startup, readiness and liveness. True before INFRA-073: readiness is now `/readyz` for a declared OCaml `-svc`, and stays `/healthz` for a TypeScript or undeclared workload until the TypeScript framework serves it (FEAT-096). The bullet now says so, and notes that both deployment modes resolve it identically since BUG-056.
- The rest of the document matched the code and is unchanged.
- `AGENTS.md`'s comment policy now also records what is *not* enforced: dune files and Dockerfiles are policy-covered but absent from `check_no_comments.sh`'s file list, which the CI and tooling work owns.

## Latest: UX-003 — sol new workspace names the README it generated (2026-09-27)

- The scaffold's next-steps report gave the commands, the framework dependency and the CI/CD notes, but never named `README.md` — the file it had just written, and (since REFAC-143) the only place the generated Dockerfile's rationale lives. Two lines now name it after the command list.
- The test asserts the report names README.md *and* that the file exists in the generated workspace, so the pointer cannot dangle.
- Local note: running `test_scaffold.exe` directly (outside dune) fails two `existing_files` build cases because this switch lacks the framework packages; under dune they pass, and CI installs them. `test_destroy_completeness_check.sh` needs `python-hcl2`, which is not installed here — both are this machine, not the branch.

## Latest: BUG-064 — the unconditional guards get their tooling without the product build (2026-09-27)

- The `test` job's toolchain prefix is gated `!= 'docs-only'` and the guards below it are deliberately unconditional (a ticket-only change is what several of them check), so a docs-only PR failed the required check with the build skipped: `[FAIL] soldev is not built`. A second instance was latent behind it — `check_readiness_invocations.sh` requires kubectl, whose install step was gated.
- The toolchain steps that the guards' tooling needs (system deps, the OCaml switch, the opam cache, the pin action) are unconditional, a new unconditional step installs `--deps-only ./sol.opam` and builds exactly the three targets the guards invoke (`soldev`, the CLI, `print_providers`), and the pinned kubectl install is unconditional too. On a change that already ran the full build the new step rebuilds nothing.
- `internal/ci/check_unconditional_guard_tooling.py` asserts the invariant, derived from the workflow rather than hard-coded: every unconditional step whose reached scripts need an artifact or require a tool has an earlier unconditional step that provides it. Its six-case mutation test caught two false negatives in the guard's own first version (an exemption for the ticket guard, and treating a mention of a tool as installing it).
- Local contract: `bash internal/tooling/scripts/prepare-guard-tools.sh` installs the pinned Python guard deps (with a PEP 668 fallback this machine needed) and pinned shfmt, the same way CI does; CONTRIBUTING and AGENTS.md name it. All 77 `internal/ci` guards and mutation tests pass locally afterwards.

## Latest: REFAC-143 — no comments in dune files or Dockerfiles (2026-09-27)

- The policy is now written down: `AGENTS.md` gains a *Comments: none in covered formats* section — covered formats, tool directives as the only exception, invariants to types/shared definitions/guards/tests, durable rationale to the docs or the record that owns it, user-facing explanation to the documentation that ships with the artifact, and the categories deliberately left uncovered. Finding this by failing CI (as happened on BUG-063) was the weakest possible discovery path for an agent writing code here.
- dune files: 97 comment lines across 13 files removed; the facts they carried are in `AGENTS.md`, DONE/REFAC-104.md, DONE/REFAC-128.md and DONE/DEC-025.md, and in the rules' own failure text. Two `cli/test/dune` notes stay on purpose: they explain why two CI guards are not dune rules, and that reasoning belongs with the guards, which the CI and tooling work owns.
- Dockerfiles: 180 comment lines across 12 files removed, and the explanation *moved* rather than deleted — a Container images section in the scaffolded workspace README (verified in a real `sol new workspace` run), sections or extensions in the pluto and demo_ts READMEs, and a pointer in the tutorial. The uid-65534 invariant that a comment asserted is now a test comparing each template's `USER` with the rendered `runAsUser`/`runAsGroup`.
- Proven comment-only: for every Dockerfile the non-comment lines are byte-identical to `origin/main`'s. `docker build` of the demo_ts service from the example workspace succeeds against the stripped file. CLI suite 84/84, `dune build`/`dune fmt` clean, and the OCaml half of the no-comments check run directly (shfmt is absent locally): 427 files, none with a comment.

## Latest: BUG-063 — `pipeline ls` asks git for commits, not shas (2026-09-27)

- `worktree_snapshot_of_entry` reported "unpushed commits" whenever HEAD differed from the branch's upstream sha (or from `origin/main` when it has none), which is equally true of a worktree that is merely *behind* -- the ordinary state of one created before the last few merges. Found while resolving BUG-056, whose spent worktree was annotated that way while holding 0 commits ahead of main.
- It now asks `git rev-list --count <ref>..HEAD`: zero is clean whatever the shas are, and an unreadable count stays in the noisy direction because the flag exists to warn about work that might be lost. Squash-merged commits still read as unpushed, the same signal `git log main..HEAD` gives.
- `internal/tooling/soldev/test/test_merge.ml` covers it against a real repository in a temp dir -- seven assertions across behind/ahead of `origin/main` and of the branch's own upstream, plus an unresolvable ref -- and the test fails at `behind origin/main is not unpushed` when the old comparison is restored.

## Latest: BUG-056 — `sol up` plans from the same declared facts `sol deploy` does (2026-09-27)

- The divergence: `local_plan` called `of_services_result` with no declared configuration at all, while `sol deploy` passed its resolved `sol.yml`. Visible in rendered output from a copy of pluto — `charge-svc`/`checkout-svc` (declared OCaml) was probed on `/healthz` locally and `/readyz` against a target — and it was the cause of the TypeScript golden path's readiness failure INFRA-073 worked around.
- `Sol_cli_config.declared` is now the plan's input: the services `sol.yml` declares (language, scale range, resource uses), the resources, and the profile a resolved target selects. `declared_of_config` is what `sol deploy` supplies (the same facts as before); `load_declared ~root` is what `sol up` supplies from the manifest alone, with no profile because a profile is never selected by `sol.yml` (DEC-026). The narrowed type is the fix: a deployment mode can no longer omit the facts silently, which is what a `Sol_cli_config.t` (always carrying a target) forced a local-only mode to do.
- `cli/test/test_up_plan.ml` plans one fixture workspace both ways and asserts the acceptance: the plans agree on language, replicas and consumer groups; the local plan carries `scale: { min: 3 }` over sol.toml's `replicas = 2`, derives `ws.comms.notify_worker`, and renders `/readyz` for its declared OCaml `-svc`. Four tests, and non-vacuously so: dropping the declared facts makes three of them fail with `language: Expected "ocaml", Received "<none>"`.
- Behaviour: a local workspace that declares a language, a scale range or resource uses now renders them locally, including the consumer-group guard's set.

## Latest: BUG-060 — pipeline tickets fail closed on unreadable metadata (2026-09-27)

- The defect: a ticket whose frontmatter did not parse was visible but never *refused* — `pipeline ls` exited 0 with a marked row, a ticket with no frontmatter block at all read as a ticket with empty columns and `pipeline check` answered for it, and CI never parsed a ticket at all, so the ticket-transition guard (an `awk` over move rows that never opens a file) stayed green. Reproduced against the built binary before any change; REFAC-137 had already landed the "not silently omitted" half.
- `Soldev_ticket.unreadable ~path` is now the one rule — a frontmatter block, that it parses with the same parser `ls`/`check` read with, and `id`/`type`/`severity`/`source` present — used by both of those and by the new `soldev pipeline validate`, which reads the whole tree (DONE included). An unreadable ticket is an error naming the file; valid tickets are untouched (786 read across the three states).
- CI: `internal/ci/test_pipeline_validate.sh` runs the validator over the repository's own tree, unconditionally, and is its own mutation test — a readable control tree passes, then malformed frontmatter, a no-frontmatter ticket in DONE and a missing field are each rejected by name, and the listing goes green again when the plants are removed. Disabling the rule fails the guard at its first mutated case, so it tests the fix rather than the harness.
- Content corrections kept separate: `DONE/INFRA-042.md` (2026-09-19) gained the frontmatter its siblings have. Filed `BACKLOG/BUG-061.md`: `DEC-049.md` and `DEC-049-gke-standard-is-the-supported-gcp-substrate.md` are two different decisions sharing one id, so the GKE decision is unreachable by id — blocked on the live GCP stream, because the fix moves references in it.

## Latest: no code comments (2026-09-27)

- Every comment is gone from the OCaml tree (426 files, about 14,500 lines): names carry the meaning, and an invariant belongs in the code. `check_no_comments.sh` holds it, and AGENTS.md states the rule. The code is token-identical to before, verified by stripping comments from both trees.
- **REFAC-142:** the same for shell, Terraform and TypeScript (4,607 comment lines), each verified by its own parser. The two comment-based guard mechanisms became code: DEC-045 residue ownership is a registry in `Sol_cli_gcp_destruction`, and the unused `same-object-owner` exception is gone. `check_no_comments.sh` covers all four languages (shell through `shfmt`).
- What the comments had been holding up is filed: **BUG-062** (`sol migrate` and `sol deploy` name the migrations table differently from a subdirectory), **REFAC-141** (14 prose-only invariants to enforce in code), **REFAC-140** (split the 75 files that used section banners), **REFAC-142** (the same removal for shell, Terraform and TypeScript).

## Latest: refactoring-pattern audit, REFAC-131..139 (2026-09-27)

- An audit of where the REFAC-104..130 rules had not reached filed REFAC-131..139 (#593): text-built manifests, ad-hoc JSON decoding, exceptions as control flow, spawns outside `Sol_cli_process`, library printing, per-tool error classifiers, `framework/` + soldev, the pinned `*-eio` libraries, and thin `cli/bin`.
- **REFAC-131:** every manifest Sol writes is a `Sol_cli_yaml` value rendered by libyaml; a hostile `sol.toml` value that broke the old ConfigMap now round-trips exactly, and pluto's 37 documents parse to identical values before and after. `check_manifests_are_values.sh` holds it.
- **REFAC-137:** `let*` is `Result.Syntax` repository-wide (framework, fixtures, examples, scaffold templates), held by `check_result_syntax.sh`; the framework reads settings through `Sol_runtime.setting` (trimmed, blank is unset); soldev returns results and exits once, and reads ticket frontmatter with the yaml library -- every ticket's frontmatter must now be valid YAML.
- **REFAC-132:** JSON is read through one boundary (`Sol_cli_json`); a failed read is an error, never an empty answer -- fixed for Loki results, the GCP disk quota, migration status, release/deployment history, rollback's live workloads, Terraform outputs and component values.
- **REFAC-138:** the pinned `*-eio` libraries use `Result.Syntax`, and aws-eio returns malformed responses as errors in their own words; six library PRs merged and `support-refs.txt` bumped.
- **REFAC-133:** no exceptions for control flow in the CLI: `Deploy_failed` and every `failwith`-on-`Error` are results; what may still raise is a named invariant in `check_no_exception_control_flow.sh`.
- **REFAC-134:** every subprocess goes through `Sol_cli_process` (with `spawn` for background processes) and every filesystem chore through `Sol_cli_fs`; the build-context `rsync` became `copy_tree`, and `sol migrate`/`sol deploy`'s two hand-rolled port-forwards became `Sol_cli_kubectl.temporary_port_forward`. `check_single_runner.sh` holds it.
- **REFAC-135:** library code reports through `Logs` (`Sol_cli_report`), and `main.ml` installs the terminal reporter; output is byte-identical. `check_library_output.sh` holds it.
- **REFAC-136:** one classifier per cloud CLI (`Sol_cli_gcloud`, `Sol_cli_aws`); merging gcloud's two absence lists removed "could not fetch resource", which read a 403 as an absent cluster.
- **REFAC-139:** `cli/bin` parses, calls the library and renders. The migration Job, the migration gate, deploy selection and apply, the cloud lifecycle wiring (with INFRA-076/INFRA-042 as tested rules), and the local cluster/releases/endpoints moved into `cli/lib`, and each moved decision has a unit test. `cmd_cloud_tf` 1,839→593, `cmd_deploy` 1,180→688, `cmd_migrate` 1,022→416, `cmd_local` 1,042→519. The publisher/deployer guard now covers the library; a pre-existing crossing (checkout-mode `sol deploy` builds the migration runner) is filed as SEC-011. `.gitattributes` no longer union-merges dune files.
- **Remaining:** none of REFAC-131..139. Open from it: SEC-011 (BACKLOG, needs a decision on ADR 0002's deployer row).

## Latest: INFRA-093 + INFRA-092 — GKE Standard is the supported GCP substrate (2026-09-26)

- Attempt 14 measured the mismatch: on Autopilot the cloud root and prerequisites applied, then GKE's admission webhook refused `helm_release.prometheus` (hostNetwork/hostPID) and `helm_release.redpanda` (SYS_RESOURCE) — ten minutes and a billable cluster in, no path to `Ready` (FND-0064).
- `DEC-049`: the GCP driver provisions **GKE Standard**; Autopilot is not a supported substrate for the standard profile. The refusal is *defensive reconciliation* — for a Sol-managed target the driver's own configuration is Standard — and it happens read-only, **before any plan exists**, with a message about the profile's requirement rather than today's component list.
- Sizing is a **driver-owned default**: 3 x e2-standard-2, 100 GiB pd-balanced, one zone, regional control plane. No target keys, no sizing profile, no generic restricted-Kubernetes capability model. (**Changed 2026-09-27** to 4 x e2-standard-4 by `DEC-054` / `FND-0066`: see the next section.)
- `check_gcp_standard_substrate.py` + seven mutations hold the contract by *ownership*, never the numbers, so a deliberate sizing change is not a guard failure. Two of its own checks were repaired while building it (a control-plane check a sibling resource could satisfy; a declaration check whose nested quoting matched nothing).
- INFRA-092: `ADMISSION_DENIED` classifies ahead of ambient scheduling symptoms, and the provisioner bindings are captured on the failure path too. `test-live-qual` → 144 assertions, 0 failures.
- FND-0064 → `FIXED_UNQUALIFIED`. Attempt 15 on a Standard cluster is the discriminator: install → `Ready` → supported Ready-state destruction.

## REFAC queue continuation — Result propagation (2026-09-28)

- Filing and BUG-066/FEAT-105 are merged; the refreshed docs-only validator was
  verified with a 14-second required check. REFAC implementation has resumed.
- REFAC-148 reviewed all 55 identity-error seeds across CLI/framework, plus copied
  templates, examples and tooling. Linear Result composition replaces unchanged
  forwarding; deliberate NotFound/AlreadyExists recovery and nested access/process
  diagnostics remain explicit, with reasons in the ticket.
- Focused CLI and framework tests, all 52 scaffold tests, builds, formatting,
  no-comments and ticket-parser checks pass. Framework installation resolved the
  initial isolated scaffold build failures. No runtime/API/language-contract changes.
- REFAC-144 is queued on required CI; REFAC-145 waits for its shared-summary merge.
  REFAC-146/147 and the remaining generalized sweeps continue autonomously.
