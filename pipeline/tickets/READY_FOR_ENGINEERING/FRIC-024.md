---
id: FRIC-024
type: dogfood-finding
severity: high
source: pipeline/dogfood/RUN_2026-09-13.md
---

**Depends on:** None.

The two-minute claim only holds with a warm Docker image cache; the first `sol up` is ~5m34s

**Description:** Measured two ways on the same machine/substrate:

- **First-ever workspace** (no image had ever been built): `sol new workspace` 0.03s + `dune build` 3.0s + `sol up` **334.5s** + `sol migrate` + `curl` → ~5.6 minutes through first `/health`. `sol up` is dominated by pulling `ocaml/opam:ubuntu-24.04-ocaml-5.4` and running apt + `opam pin`/`opam install` of 8 GitHub packages *inside each image build*.
- **Second fresh workspace, same substrate, layers warm** (the skill's stated scenario): scaffold 16ms + `dune build` 3.02s + `sol up` 22.2s + `sol migrate` 0.83s + `curl` 42ms → **26.1s**.

A warm redeploy of the same workspace is 4.35s. So the claim is true "after first run", but the dogfood skill asks to measure "from `sol new workspace` through first successful `curl`" without distinguishing a cold image build, and the README's Quickstart implies the same.

**Impact:** A genuinely first-time user's "create, deploy, reach a service in minutes" experience is ~5.6 minutes, not two — and the expensive part (in-image dependency compilation) happens before the user has any signal that it is normal. The gap between expectation and reality is the product claim's whole point.

**Remediation:** Either (a) prebuild/publish a base image carrying the shared opam dependencies so a first workspace only compiles app code, or (b) state the cold-start cost explicitly and separate "substrate bootstrap", "first image build", and "deploy" in the claim/runbook. The generated Dockerfiles' comments already explain *why* the pins exist; they could also say the first build is expensive and cached afterwards.

Related: FRIC-014 (Dockerfile template drift), FRIC-018 (buildx prerequisite for the same build path).
