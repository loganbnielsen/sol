---
id: FEAT-101
type: feature
severity: medium
title: Ship Sol as a self-contained, version-aligned release -- binary, platform bundle, and migration-runner image
source: operator code-review notes (2026-09-26); reshaped under DEC-049
---

**Depends on:** DEC-049, REFAC-114.

## The problem

A `sol` binary only works where it can find a Sol source checkout (DEC-049 lists the four consumers). `sol migrate` also compiles the CLI into a Docker image on every run. Sol has no release artifact.

## Remediation (per DEC-049)

- **Version:** the release build embeds its version. The resolver uses it to find `<prefix>/share/sol/<version>/`, and `sol --version` prints it. A source build reports a development version and never matches an installed bundle.
- **Resolver:** add the installed form to `Sol_cli_platform_assets`, giving the order `SOL_HOME` > installed bundle > source discovery. `SOL_HOME` may name either form's root.
- **Bundle:** a release archive `sol-<version>-linux-x86_64.tar.gz` containing `bin/sol` and `share/sol/<version>/platform/` (the platform tree the consumers read), produced by one script that CI and the release workflow both use.
- **Migration runner:** a release publishes `ghcr.io/<owner>/sol-migration-runner:<version>`, built from the same commit and support snapshot as the binary. An installed `sol` references exactly that tag. The release workflow refuses to overwrite an existing version tag, so the tag can't float. A source build keeps building the runner from its checkout.
- **Release workflow:** on a `v*` tag, build the binary, the bundle and the runner image, and publish all three.
- **Installed-layout smoke (CI):** build the bundle, and run it in a container that holds only the bundle and the documented runtime libraries, never the checkout, with `SOL_HOME` unset. Exercise representative consumers there. Plant a checkout-only asset to prove the test would catch a reach-back.

## Acceptance criteria

- Precedence tests: `SOL_HOME` > installed > source; an invalid `SOL_HOME` is an error.
- The installed-layout smoke passes in CI and fails on a planted reach-back (positive control).
- An installed `sol` names the runner image of its own version; a test pins that.
- Demo/example: pluto's migration flow is unchanged for source users; state how that was checked.
