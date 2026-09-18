---
id: FEAT-053
type: feature
severity: medium
source: DEC-019 (platform repository boundary) — the CLI half of build-time secret handling
---

**Depends on:** DEC-016.

Let a service declare which secrets its **build** needs, separately from the secrets it needs at **runtime**, and export those names in the machine-readable plan so a builder knows what to provide. The tool declares and validates; for a hosted build it never holds the values.

## Scope

- **Separate the two sets in `sol.toml`.** Build-time and runtime secrets arrive through the same channels today, and that is exactly how they get conflated — a build that can read runtime secrets is a build that can leak them.
- **Validate and fail closed.** An undeclared build-time secret, or a runtime secret referenced at build time, is an error rather than a silently empty value.
- **Export the names in `--emit-plan-to`**, so the platform — or any CI — knows what to supply without having to know this repository's conventions.
- **Names only, never values**, in anything the tool emits or logs.

## Out of scope

Injection, log redaction, and image-layer hygiene at build time — platform work in its own repository (DEC-019).

## Acceptance criteria

- `sol.toml` distinguishes build-time from runtime secrets, and the distinction survives into the deployment plan.
- An undeclared or mis-scoped secret fails validation, naming the service and the key.
- `--emit-plan-to` exports declared build-time secret *names*, and no secret value appears in any emitted output.
