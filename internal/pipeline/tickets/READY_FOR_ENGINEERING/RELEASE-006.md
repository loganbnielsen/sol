---
id: RELEASE-006
type: release
severity: high
title: Cut and verify the alpha campaign release from the frozen revision
source: internal/qualification/ALPHA_CAMPAIGN.md §4 — the clean-user starting condition has no released artifact of the S1-S4 surface
---

**Depends on:** None.

**Related:** FEAT-101, DEC-049, BUG-059, `internal/qualification/ALPHA_CAMPAIGN.md` rows A1/J1-J4.

The alpha campaign qualifies the product a *new user installs*. The release mechanism
landed (FEAT-101, DEC-049: binary + platform bundle + version-aligned migration-runner,
published by `.github/workflows/release.yml` on a `v*` tag), and the installed-layout
smoke passes in CI — but the newest published release is `v0.1.0-alpha.6`
(2026-06-11), which predates the entire S1-S4 surface. No alpha acceptance row that
starts from a released install can be observed until a release of the current revision
exists.

## Remediation

1. Cut `v0.1.0-alpha.7` from the frozen campaign revision (the campaign lead's
   recommendation; the operator confirms or overrides the version alongside the cloud
   authorization). Push the tag and let `release.yml` publish the binary, the platform
   bundle and `ghcr.io/<owner>/sol-migration-runner:v0.1.0-alpha.7`.
2. Verify the published archive in a container that holds only the bundle and the
   documented runtime libraries, with `SOL_HOME` unset: `sol --version` reports the
   tag, `sol assets` reports every asset present, and a representative consumer
   (`sol plan` on the reference workspace) runs without a checkout.
3. Move the AWS and GCP live harnesses (`internal/qualification/aws/`,
   `internal/qualification/gcp/`) off a source checkout and onto the installed bundle,
   so the live runs qualify the artifact a user installs rather than a development
   build. Record the bundle version and the runner image digest in the run identity.
4. Re-run the installed-layout smoke with a planted checkout-only asset as the
   positive control, so the reach-back is shown to fail the smoke.

## Acceptance criteria

- `v0.1.0-alpha.7` is published and its three assets are retrievable; the workflow
  refuses a re-publish of the tag.
- `sol assets` succeeds in the no-checkout container and fails when one bundled asset
  is removed (positive control).
- The installed `sol` names the migration-runner image of its own version.
- The AWS and GCP harnesses invoke the installed bundle; the change is pinned by a
  harness test and the run record carries the bundle version.
- Demo/example: the `docs/guides/installation.md` walkthrough is executed against the
  published archive and its observed output recorded.
- Language parity: no application-facing contract change; state that in one line.

## Completion notes

Leave the release tag and the runner digest here, plus the container command used for
the installed-layout verification.
