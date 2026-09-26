---
id: FRIC-018
type: dogfood-finding
severity: high
source: pipeline/dogfood/RUN_2026-09-13.md
---

**Depends on:** None.

`sol up` requires the buildx plugin, but Ubuntu's `docker.io` package doesn't ship it

**Description:** `Sol_cli_docker.build` (`cli/sol/lib/sol_cli_docker.ml:9-24`) always invokes `docker build --provenance=false --sbom=false`. Those flags are deliberate (DOGFOOD-011: EKS containerd fails to pull images whose index carries a BuildKit provenance/SBOM attestation). But on a stock Ubuntu `apt install docker.io` there is no `buildx` plugin, Docker falls back to the legacy builder, and the flags are rejected outright:

```
unknown flag: --provenance
Usage:  docker build [OPTIONS] PATH | URL | -
```

`sol up` fails with exit 125 before any build starts. Installing the `docker-buildx` apt package (candidate 0.30.1) or dropping the plugin binary into `~/.docker/cli-plugins/` fixes it.

**Impact:** `sol up` fails on the most obvious Docker installation path for Ubuntu users, with a message that looks like a sol bug. The prerequisite list ("Docker 29.x") does not mention buildx at all.

**Remediation:** Do not blindly drop the flags — they fix a real cloud pull bug. Instead: detect `docker buildx version` before building and, if absent, fail with an actionable message naming the `docker-buildx` package / `~/.docker/cli-plugins` path; document buildx as a prerequisite in `DOGFOOD.md` and the generated workspace README; and/or fall back to the legacy builder (without the flags) only where it is safe, with a warning.

Related: FRIC-019 (Ubuntu tool installs assume root), FRIC-024 (the Docker build path is also the cold-start cost).

## Completion notes

- Fixed in `cli/sol/lib/sol_cli_docker.ml`: `build` probes `docker buildx version` and only passes `--provenance=false --sbom=false` when BuildKit is available; on the legacy builder it prints a warning and omits the flags (the legacy builder never attaches an attestation, so the DOGFOOD-011 EKS fix is unaffected wherever BuildKit is in use).
- Documented both this and the FRIC-017 Docker/k3d API bridging in `internal/pipeline/dogfood/DOGFOOD.md`'s Kubernetes-toolchain section.
- Verified live with the buildx plugin temporarily hidden: `sol up` printed the fallback warning and proceeded to build — the previous `unknown flag: --provenance` / exit 125 was gone.
- Internal build-path change; no generated/manifest surface changed, so no example/demo update applies.
