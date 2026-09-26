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

## Completion notes (2026-09-26)

Premise checked on `origin/main` (`bc9062b0`): `sol migrate` built its runner from the checkout, and no installed form existed. **Correction:** there *was* a release workflow (`.github/workflows/release.yml`, `v0.1.0-alpha.1…6`), which shipped `bin/sol` plus `framework/` and no `platform/`. It is replaced, and DEC-049 carries a correction.

**Version.** `cli/lib/base/gen_release_version.sh` generates `Sol_cli_build_info.release_version` through a dune rule that depends only on `(env_var SOL_RELEASE_VERSION)`. It is `Some v` exactly for a release build, and the value is validated as `^v?N.N.N(-pre)?$`, so a malformed value fails the build. `git describe` was rejected for this: CI checkouts are shallow and fetch no tags, and a dirty tree or a commit past a tag changes it. `sol --version` prints the release version, or `git describe` for a development build.

**Resolver** (`Sol_cli_platform_assets`), in DEC-049's order, as a pure function `resolve_from ~sol_home ~exe_dir ~release_version`:
1. a non-empty `SOL_HOME`: a checkout, or a bundle whose `VERSION` equals this binary's release; otherwise `Invalid_sol_home` or `Bundle_version_mismatch`, never a fall-through;
2. a release binary: `<exe_dir>/../share/sol/<v>/` (holding `VERSION` and `platform/`), or `Missing_bundle`. **A release never walks up to a checkout**, because that is exactly the reach-back that would hand it another version's assets;
3. a development build: the nearest checkout above the binary.

`migration_runner` returns `Build_from_source { context }` for a checkout. For an installed release it returns `Published ref`, where `ref` is read from the bundle's `migration-runner-image` and must be `<image>@sha256:<64 hex>`; a tag or a missing file is an error. `cmd_migrate`'s two runner paths are now one `obtain_runner_image`: a published runner needs no build and no registry.

**Release archive** (`internal/tooling/scripts/build-release-bundle.sh`): `sol-<v>/bin/sol` and `sol-<v>/share/sol/<v>/{VERSION, platform/ (tracked files only, via git ls-files), migration-runner-image, SUPPORT_REFS}`. It refuses a binary whose `--version` isn't `<v>` and a runner reference that isn't a digest. The archive is 9.0 MB with 90 entries.

**Runner versioning.** The release workflow builds the release binary once. It pushes `ghcr.io/<owner>/sol-migration-runner:<v>` from `internal/tooling/release/migration-runner.Dockerfile`, which is that same binary plus `libpq5`, `libgmp10` and CA certificates, with no compile. It refuses if `:<v>` already exists, then writes the pushed **digest** into the bundle. The installed CLI names that digest, so the image can't float. There's no circularity: the digest lives in the bundle, not the binary. The in-cluster runner runs `sol migrate apply --dir /migrations` (no `--target`, so `run_apply_local`), which never resolves assets, so the bundle-less runner image is correct.

**`sol assets`** (new command): shows the form and root, then runs the real consumers: every provider's Terraform roots, each component's merged values (`Sol_cli_platform_component.merged_values_yaml`), the dashboard ConfigMap and Alloy values (`Sol_cli_dev_observability`), and the migration runner (`Cmd_migrate.runner_source`). It needs no cluster or account. It is documented in the tutorial's command reference and install section, and in the README.

**Installed-layout smoke** (`internal/ci/smoke_installed_release.sh`, run in the CI `test` job and in the release workflow). It extracts the real archive into a container with only that install and `libpq5`/`libgmp10`: no checkout mounted, a read-only root and install, `--network none`, and no `SOL_HOME`. It checks:
- `sol --version`;
- `sol assets` resolves `installed release <v>` at `/opt/sol/share/sol/<v>` and names the bundle's digest;
- an invalid `SOL_HOME` fails.

Positive controls:
1. A development build in the same container finds no checkout.
2. A bundle with its dashboards removed fails.
3. The release binary placed inside a checkout without its bundle refuses, with `Missing_bundle`, instead of reaching back.

A local run passed all of these; the CI run is on the PR.

**Precedence tests** (`test_platform_assets.ml`, 13 cases): SOL_HOME beats installed; installed beats discovery, with the install inside a checkout; a release never discovers a checkout; a development build discovers and never uses a bundle; a SOL_HOME bundle must match the binary's release; an invalid SOL_HOME never falls through; an empty SOL_HOME counts as unset; the installed runner is the bundle's digest, while a tag or a missing file is refused.

**Stopped, per DEC-049's stop conditions:**
- **DEC-050** (filed in BACKLOG): Terraform runs *in* the platform roots (`-chdir`) and writes `.terraform/` and `errored.tfstate` there. So a bundle serves `sol cloud` only from a user-writable install, which the README and tutorial now say. A read-only system install needs a decision.
- **BUG-059** stays in BACKLOG: the CLI has no committed support-library snapshot. A release now *records* the one it built against (`SUPPORT_REFS`), so each release's revisions are on record regardless.

**Dropped from the old release, deliberately:** the standalone `sol-linux-x86_64` binary (a release binary without its bundle now refuses), and `framework/` in the archive (unused by `sol new` since DEC-025). The tutorial's stale "vendor link / SOL_HOME for sol new" note is replaced. Framework packages still come from a checkout's `prepare-framework-deps.sh` until RELEASE-005.

- Demo/example: `sol assets` is in the tutorial's install section and command reference. pluto's source-checkout migration flow is unchanged in code: the build-and-push moved into `obtain_runner_image` verbatim, and `sol assets` from a checkout reports "built from <checkout>". It was not re-run against a live cluster.
- Verification: `dune build`, `dune test cli/ --force` (60 suites, 0 failures), `internal/ci/check_ocamlformat.sh --all`, the ownership guard and its mutation test, `check_workflow_paths.sh`, YAML parse of both workflows, and a local build and run of the release runner image (`--version`, `migrate apply --help`).
- Language parity (DEC-022): no impact; the release carries the language-neutral CLI and platform.
