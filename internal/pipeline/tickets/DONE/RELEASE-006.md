---
id: RELEASE-006
type: release
severity: high
title: Cut and verify the alpha campaign release from the frozen revision
source: internal/qualification/ALPHA_CAMPAIGN.md §4 — the clean-user starting condition has no released artifact of the S1-S4 surface
---

**Depends on:** None.

**Related:** FEAT-101, DEC-049, BUG-059, `internal/qualification/ALPHA_CAMPAIGN.md` rows A1/J1-J4.

**Premise checked (2026-10-03).** `gh release list` reports `v0.1.0-alpha.6`
(2026-06-11) as the newest release, and `.github/workflows/release.yml` plus the FEAT-101
bundle mechanism are present at `ed3f041f`. The premise holds: no release of the S1-S4
surface exists, and `internal/qualification/{aws,gcp}` defaulted to
`_build/default/cli/bin/main.exe`.

## Sequencing (RELEASE-006, part A)

The artifact is `sol-<version>-linux-x86_64.tar.gz`: `bin/sol` plus
`share/sol/<version>/{VERSION,platform/,migration-runner-image,SUPPORT_REFS}`, built by
`internal/tooling/scripts/build-release-bundle.sh` from the release binary and
`git ls-files -- platform`. `examples/pluto` is not part of it. FEAT-131/132/133 change
only `examples/pluto/**` (their scope and non-goals), so the bundle's *contents* are
independent of them: cutting `v0.1.0-alpha.7` today would not produce a content-stale
artifact.

The tag is deferred anyway, for two recorded reasons. `release.yml` produces the archive
and its runner digest *from the tag*, and a version is published once (the workflow
refuses a re-publish), so the tag is irreversible; and the campaign defines the release as
the frozen campaign revision and gates its version on the operator (§7.6, confirmed
alongside the live AWS authorization, which is not authorized). Everything reachable
without the tag is done: the mechanism is verified offline at the release version, the
harness change has landed, and the installed-layout smoke covers the reference-workspace
consumer and the reach-back controls. The only remaining action is the tag.

**The tag (operator-gated, single action):**

```bash
git -C <owned-main-checkout> fetch origin main
git -C <owned-main-checkout> tag v0.1.0-alpha.7 <frozen-campaign-commit>
git -C <owned-main-checkout> push origin v0.1.0-alpha.7
```

`release.yml` then builds the binary, pushes
`ghcr.io/loganbnielsen/sol-migration-runner:v0.1.0-alpha.7`, writes the pushed digest into
the bundle, runs the installed-layout smoke, and creates the GitHub release. The digest
cannot be known before the tag; that is why the archive cannot be produced ahead of it.

## Remediation

1. **Staged** — cut `v0.1.0-alpha.7` from the frozen campaign revision: see
   § *Sequencing*. The binary builds at the release version and the bundle builds and
   verifies offline; the tag is the only remaining action.
2. **Done (offline)** — installed-layout verification: `bin/sol` + `share/sol/<v>/` in a
   container with no checkout and no `SOL_HOME` exercises `sol --version`, `sol assets`,
   `sol cloud plan`, and now `sol plan` on the reference workspace
   (`internal/ci/smoke_installed_release.sh`).
3. **Done** — `internal/qualification/aws/{live-row.sh,live-smoke.sh}` and
   `internal/qualification/gcp/live-qual.sh` run the installed bundle from `SOL_INSTALL`
   through the shared `internal/qualification/sol-under-test.sh`, refusing a development
   build and a non-digest runner, recording the bundle version and runner digest in
   `$LOG_DIR/sol-identity.txt`; `run-record-template.md` carries both in run identity.
4. **Done** — the smoke's positive controls run on every execution: a planted
   checkout-only environment (`$root/.smoke-reachback`) makes a release binary refuse with
   `Missing_bundle`, a development build finds nothing, and a bundle with an asset removed
   fails.

## Acceptance criteria

- [x] `v0.1.0-alpha.7` is published and its three assets are retrievable; the workflow
  refuses a re-publish of the tag. *(published 2026-10-04T15:28:09Z; the runner image is
  anonymously retrievable by digest and tag; a second run is refused by name — see part B)*
- [x] `sol assets` succeeds in the no-checkout container and fails when one bundled asset
  is removed (positive control).
- [x] The installed `sol` names the migration-runner image of its own version.
- [x] The AWS and GCP harnesses invoke the installed bundle; `test-live-row.sh` and
  `test-live-qual.sh` pin it, and the run identity carries the bundle version and runner
  digest.
- [x] Demo/example: the `docs/guides/installation.md` walkthrough executed against the
  published archive with its observed output recorded. *(§1 verbatim against the published
  URL, §3 and §4–§7 recorded as NOT REACHED with their reasons — see part B and the record)*
- [x] Language parity: no application-facing contract change; the release carries the
  language-neutral CLI and platform (DEC-022).

## Completion notes (part A, 2026-10-03)

**Offline verification of the staged release.** On the implementation branch, at the
release version:

```console
$ eval $(opam env)
$ SOL_RELEASE_VERSION=v0.1.0-alpha.7 dune build cli/bin/main.exe
$ ./_build/default/cli/bin/main.exe --version
v0.1.0-alpha.7
$ RUNNER="ghcr.io/loganbnielsen/sol-migration-runner@sha256:$(printf '0%.0s' $(seq 64))"
$ archive=$(internal/tooling/scripts/build-release-bundle.sh --version v0.1.0-alpha.7 \
    --runner-image "$RUNNER" --support-refs support-refs.txt --out /tmp/dist | tail -1)
$ tar tzf "$archive" | wc -l
209
$ bash internal/ci/smoke_installed_release.sh "$archive" v0.1.0-alpha.7 "$RUNNER" /tmp/sol-dev
   ...
  [OK]   sol assets: installed bundle, every consumer ran, runner is ghcr.io/...@sha256:000...
  [OK]   sol cloud plan runs from the read-only install; Terraform works in its own directory
  [OK]   sol plan reads the reference workspace with no checkout and SOL_HOME unset
  [OK]   control: the install really is read-only there
  [OK]   control: a development build finds nothing to reach back to
  [OK]   control: a bundle missing an asset fails
  [OK]   control: a release binary never reaches back into a checkout
installed-release smoke: passed
```

The digest is synthetic on purpose: `release.yml` writes the *real* pushed digest into the
bundle, so the archive it publishes cannot exist before the tag. The offline run verifies
every step except the publish itself.

**The `docs/guides/installation.md` walkthrough, verbatim on the staged archive.** With
`SOL_HOME` unset and the archive extracted exactly as §1 instructs:

```console
$ tar xzf sol-v0.1.0-alpha.7-linux-x86_64.tar.gz
$ export PATH="$PWD/sol-v0.1.0-alpha.7/bin:$PATH"
$ sol --version
v0.1.0-alpha.7
$ sol assets
sol v0.1.0-alpha.7
assets: installed release v0.1.0-alpha.7
  root: /tmp/docwalk/sol-v0.1.0-alpha.7/share/sol/v0.1.0-alpha.7
  ... every consumer ok ...
  all assets present
```

The guide's `curl .../download/vX.Y.Z/...` URL is the one step that needs the published
release; the steps after it are verified.

**Harness tests.** `internal/qualification/aws/test-live-row.sh` (21 assertions) and
`internal/qualification/gcp/test-live-qual.sh` (249 assertions) pin that a release bundle
is required, that a development build and a non-digest runner reference are refused before
any Sol command runs, that the harness publishes no runner, and that the run identity
records the bundle version and digest.

**Docs.** `aws-run-procedure.md`, the AWS and GCP single-region matrices, and the campaign
artifact record the installed-bundle runner and the staging state.

**Release tag / runner digest.** Not yet produced; the tag above produces them, and this
section is completed when it lands.

## Part B (2026-10-04) — the tag is cut, and the workflow's publish step failed

`v0.1.0-alpha.7` was tagged at the frozen campaign revision `f4284422` and pushed, so
`release.yml` ran from that revision (`37210258576`). It built the release binary, published
`ghcr.io/loganbnielsen/sol-migration-runner:v0.1.0-alpha.7`, built the archive from the
revision's `platform/` tree and passed the installed-release smoke — then failed at
`gh release create`: `body is too long (maximum is 125000 characters)`, because
`--generate-notes` is unbounded and the campaign's range is large.

The runner image is published and a version is published once, so as the workflow stood the
version could not be completed: its runner step refuses an image that exists. Both halves of
that are `BUG-204`, now fixed — the body is bounded at a line boundary with a pointer to the
full compare range, the runner digest is reused rather than refused (it cannot move), a
version whose *release* exists is refused, and a `workflow_dispatch` `version` input lets the
publish resume from the default branch.

The tag **does not move**: the release is resumed against the same revision, so it still
names the frozen campaign revision, and the artifact is built from that revision's tree.

**Published and qualified.** The resume run (`37212693146`) completed every step: it logged
`ghcr.io/loganbnielsen/sol-migration-runner:v0.1.0-alpha.7 is already published; reusing its
digest rather than overwriting it` and published `v0.1.0-alpha.7` at
2026-10-04T15:28:09Z with `sol-v0.1.0-alpha.7-linux-x86_64.tar.gz` (9812981 bytes), a body of
100324 bytes carrying the revision `f4284422…`, the runner digest
`sha256:65f74feb5d2290e4e676bc292d971eaf9fc0188099169db7a82d1e93715aef4d` and a pointer to the
full compare range. A second dispatch was refused in its second step with
`v0.1.0-alpha.7 is already published, and a version is published once`, and the runner image
answers anonymously by digest and by tag (HTTP 200).

The clean-user qualification ran from the published archive with no checkout and no
`SOL_HOME`: the guide's §1 verbatim (`sol --version` → `v0.1.0-alpha.7`; `sol assets` → every
consumer ok, `all assets present`), the installed-release smoke against the published archive
with all four positive controls, the bundle's provenance (`VERSION`, `migration-runner-image`,
11 `SUPPORT_REFS` pins, 209 files, no framework source), and `sol cloud plan` / `sol plan` from
a read-only install. Guide §3 is optional and needs a cluster; §4–§7 need an authenticated
provider account. The record is
`internal/qualification/records/2026-10-04-release-alpha-7-clean-user.md`; the one environment
gap it found is that this host has no `dig` at all, which §4's delegation steps require.
