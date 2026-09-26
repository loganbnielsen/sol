# Work Summary — Self-hosted refocus complete (2026-06-22)

## Latest: INFRA-089 — one Kubernetes object, one Terraform owner (2026-09-26)

- FND-0061's fix: the two pairs of platform RoleBindings that shared one Kubernetes name are now one resource each, carrying both subjects (the AWS group and the GCP provisioner identity) — same `roleRef`, same namespaces, same lifetime, so they were never two authorizations. The duplicate `_gcp` resources are deleted, along with the two AWS `moved` blocks that named them (a dangling `moved` destination is a config error).
- New guard `check_kubernetes_object_ownership.sh` enforces the invariant rather than the incident: no two Terraform resources in a platform root may resolve to one `(kind, namespace, name)`, with a `same-object-owner:` marker as the only declared exception. Nine mutation cases, including the collision that failed the live apply and its cluster-scoped twin.
- Migration analysis: none needed for retained addresses; the removed addresses cannot exist in any supported state (all five qualification-bucket states read, AWS structurally empty via an empty instance set).
- Qualification instrument corrected: the classifier now prefers the failed operation's own error (`TERRAFORM_ALREADY_EXISTS`) over ambient cluster symptoms, and calls the fallback `SCHEDULING_AMBIENT`. **FND-0061 is `FIXED_UNQUALIFIED`** — the next live run is the discriminator.
