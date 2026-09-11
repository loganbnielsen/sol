---
id: INFRA-008
type: bug
severity: low
source: PR #205 CI 2026-09-10 — an unrelated PR failed on an upstream opam fetch
---

**Depends on:** None.

CI fails on unrelated pull requests when a third-party upstream tarball host is briefly unavailable, because `pin-opam-packages` resolves dependency sources from whatever each package's metadata points at — frequently not GitHub.

## Evidence

On PR #205 (a `.github/workflows/ci.yml` + docs change, touching nothing opam-related) the `golden-path-smoke` job died in the **"Pin extracted opam packages"** step:

```
OpamSolution.Fetch_fail("https://erratique.ch/software/mtime/releases/mtime-2.2.0.tbz (curl failed: ...")
##[error]Process completed with exit code 40.
```

That step runs **before** k3d/kubectl/helm are installed and before any test executes, so the entire job was lost. The same URL returned HTTP 200 in 0.86s a few minutes later. Opam's own retries (`--retry 10 --retry-delay 2`, visible in the log) did not ride it out.

The cost is not the flake itself but its shape: it surfaces as a red PR that looks like the contributor's fault, on a change that cannot possibly have caused it, and it consumes a full ~18-minute cycle.

## Remediation options

1. **Cache the resolved opam switch / fetched sources** across runs, keyed on the pin file hash plus compiler version. A warm run then never touches upstream for dependencies that have not changed.
2. **Mirror or vendor** the pinned sources. The `*-eio` packages are already git-pinned to GitHub, but transitive dependencies like `mtime` are not.
3. **Retry the step once** on failure with a clear annotation, so a transient blip is distinguishable from a real resolution error.

Prefer (1) first: it also shortens every CI run, which is a win independent of flakiness.

## Acceptance criteria

- A transient upstream failure during dependency resolution does not fail a pull request that changes no dependencies — by caching, mirroring, or a bounded retry.
- When the step fails permanently, the message names the unreachable host so the diagnosis does not require reading the job log.
