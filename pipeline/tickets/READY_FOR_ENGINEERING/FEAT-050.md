---
id: FEAT-050
type: feature
severity: high
title: Enforce immutable workload artifacts for the production profile
source: DEC-019 and production platform contract review 2026-09-16
---

**Depends on:** DEC-026, DEC-027.

Guarantee that a recorded production release and rollback always refer to the
same workload bytes. Let a deploy reference artifacts built elsewhere by digest,
and require resolved digests for the production profile.

## Scope

- **Accept an artifact reference** — `sol deploy --image-ref <repo>@sha256:<digest>`, per service or as a complete resolved set — so a caller that already built the images can hand them over.
- **Pin digests in the rendered plan** and deploy by digest rather than by mutable tag. A digest cannot silently change under a deployment, which is what makes promotion and rollback mean anything.
- **Require digests for `production-single-region`.** Mutable tags remain valid
  for local/development lanes but fail before mutation under the production
  profile.
- **Record each workload's resolved digest** in release and conformance evidence.
- **Close the fixed-tag gap at the root.** "The tag did not change, so nothing restarted" stops being a problem: a new digest is a new artifact, and an unchanged digest is genuinely the same thing already running.
- **Keep the local build path as the default** when no artifact is supplied — `sol up` and `sol deploy` behave exactly as they do today.

## Out of scope

The builder, registry and image publication; signature infrastructure, SBOM
policy and a generalized vulnerability gate. Add those when more than one
builder/trust domain or a stated compliance requirement makes them necessary.

## Acceptance criteria

- `sol deploy --image-ref …` deploys a supplied digest without building.
- Rendered manifests reference digests, and a redeploy of the same digest does not restart healthy pods.
- An artifact reference that does not exist fails before anything is applied, with a message naming what was missing.
- Without an artifact reference, behaviour is unchanged.
- A target claiming `production-single-region` rejects mutable tags before any
  cluster mutation.
- Moving a registry tag after deployment cannot change what a recorded rollback
  runs; the rollback manifest uses the recorded digest.
- The release record and HARDEN-002 evidence identify the digest for every
  workload.

**Implementation versus evidence:** This ticket implements digest acceptance,
enforcement and recording. HARDEN-002 proves promotion, repeat deploy and
rollback preserve byte identity.

**Demo/example coverage:** Update the production-target example to use digest
references; local examples may continue using tags.

**TypeScript parity:** No framework change; artifact identity applies equally to
all workload languages.
