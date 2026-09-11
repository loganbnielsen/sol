---
id: FEAT-050
type: feature
severity: medium
source: DEC-019 (platform repository boundary) — the CLI half of "the platform builds the artifact"
---

**Depends on:** DEC-016.

Let a deploy reference an artifact built elsewhere, pinned by digest, instead of building locally. This is the CLI half of the hosted model: the platform builds and publishes, and the tool deploys what it is handed.

## Scope

- **Accept an artifact reference** — `sol deploy --image-ref <repo>@sha256:<digest>`, per service or as a complete resolved set — so a caller that already built the images can hand them over.
- **Pin digests in the rendered plan** and deploy by digest rather than by mutable tag. A digest cannot silently change under a deployment, which is what makes promotion and rollback mean anything.
- **Close the fixed-tag gap at the root.** "The tag did not change, so nothing restarted" stops being a problem: a new digest is a new artifact, and an unchanged digest is genuinely the same thing already running.
- **Keep the local build path as the default** when no artifact is supplied — `sol up` and `sol deploy` behave exactly as they do today.

## Out of scope

The builder, the registry, and image publication — platform work in its own repository (DEC-019).

## Acceptance criteria

- `sol deploy --image-ref …` deploys a supplied digest without building.
- Rendered manifests reference digests, and a redeploy of the same digest does not restart healthy pods.
- An artifact reference that does not exist fails before anything is applied, with a message naming what was missing.
- Without an artifact reference, behaviour is unchanged.
