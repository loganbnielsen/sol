---
id: FRIC-008
type: dogfood-finding
severity: high
source: project/dogfood/RUN_2026-09-07.md
---

**Depends on:** None.

A local substrate from before the Sun→Sol rename (`sun-local` k3d cluster / `sun-registry` container) is neither detected nor migrated by `sol dev up`, causing a silent port collision when it tries to create the new `sol-local` cluster alongside it.

**Description:** FEAT-032 renamed Sol's own cluster/registry naming from `sun-local`/`sun-registry` to `sol-local`/`sol-registry` (`cmd_dev.ml:20-21`), as part of the broader Sun→Sol project rename. Any machine that had a running Sun-era local substrate before upgrading picks up the new `sol` binary with no awareness of the old cluster at all: `sol dev up` checks only for a cluster literally named `sol-local` (`cmd_dev.ml:71-73`), finds none, and tries to create a fresh one — whose registry container is hardcoded to bind host port 5000 (`cmd_dev.ml:84`), the same port the still-running `sun-registry` container already holds. The result: `k3d cluster create` fails with a port-bind conflict, and (compounding with FRIC-006) `sol dev up` reports only a generic `error: cluster creation failed` with no indication that an old cluster is the cause.

**Impact:** Scoped specifically to engineers who used Sun locally before the rename and are now trying Sol on the same machine — not a fresh-install issue. But that's a real, non-hypothetical population (this dogfood run hit it on exactly that kind of machine), and the failure mode is silent resource waste (an orphaned cluster/registry sitting around) plus a confusing, undiagnosable error rather than a clear "found an old Sun substrate, here's what to do" message.

**Remediation:** In `cmd_dev.ml`'s cluster-provisioning step, before attempting to create `sol-local`, check for a `sun-local` k3d cluster (`k3d cluster get sun-local`) and, if found, print a clear message pointing the user at how to migrate or remove it (e.g. `sol dev up` detected a pre-rename 'sun-local' cluster; run 'k3d cluster delete sun-local' to remove it, or rename it, before continuing) rather than silently attempting a conflicting create. This is a one-time migration concern, not a permanent feature — once enough time has passed that no one plausibly still has a `sun-local` cluster around, this check can be deleted.
