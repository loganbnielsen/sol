# Work Summary — Self-hosted refocus complete (2026-06-22)

## Latest: refactoring-pattern audit, REFAC-131..139 (2026-09-27)

- An audit of where the REFAC-104..130 rules had not reached filed REFAC-131..139 (#593): text-built manifests, ad-hoc JSON decoding, exceptions as control flow, spawns outside `Sol_cli_process`, library printing, per-tool error classifiers, `framework/` + soldev, the pinned `*-eio` libraries, and thin `cli/bin`.
- **REFAC-131:** every manifest Sol writes is a `Sol_cli_yaml` value rendered by libyaml; a hostile `sol.toml` value that broke the old ConfigMap now round-trips exactly, and pluto's 37 documents parse to identical values before and after. `check_manifests_are_values.sh` holds it.

## Latest: INFRA-093 + INFRA-092 — GKE Standard is the supported GCP substrate (2026-09-26)

- Attempt 14 measured the mismatch: on Autopilot the cloud root and prerequisites applied, then GKE's admission webhook refused `helm_release.prometheus` (hostNetwork/hostPID) and `helm_release.redpanda` (SYS_RESOURCE) — ten minutes and a billable cluster in, no path to `Ready` (FND-0064).
- `DEC-049`: the GCP driver provisions **GKE Standard**; Autopilot is not a supported substrate for the standard profile. The refusal is *defensive reconciliation* — for a Sol-managed target the driver's own configuration is Standard — and it happens read-only, **before any plan exists**, with a message about the profile's requirement rather than today's component list.
- Sizing is a **driver-owned default**: 3 x e2-standard-2, 100 GiB pd-balanced, one zone, regional control plane. No target keys, no sizing profile, no generic restricted-Kubernetes capability model.
- `check_gcp_standard_substrate.sh` + six mutations hold the contract by *ownership*, never the numbers, so a deliberate sizing change is not a guard failure. Two of its own checks were repaired while building it (a control-plane check a sibling resource could satisfy; a declaration check whose nested quoting matched nothing).
- INFRA-092: `ADMISSION_DENIED` classifies ahead of ambient scheduling symptoms, and the provisioner bindings are captured on the failure path too. `test-live-qual` → 144 assertions, 0 failures.
- FND-0064 → `FIXED_UNQUALIFIED`. Attempt 15 on a Standard cluster is the discriminator: install → `Ready` → supported Ready-state destruction.
