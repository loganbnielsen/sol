---
id: FRIC-019
type: dogfood-finding
severity: medium
source: pipeline/dogfood/RUN_2026-09-13.md
---

**Depends on:** None.

Kubernetes toolchain install instructions assume root; k3d's installer falls back to sudo despite `K3D_INSTALL_DIR`

**Description:** `docs/dogfood/DOGFOOD.md`'s tool install steps all assume a writable `/usr/local/bin` or root:
- k3d: `curl -s .../install.sh | TAG=v5.6.0 bash` — no install dir; targets `/usr/local/bin`.
- helm: the official `get-helm-3` script likewise defaults to `/usr/local/bin`.
- kubectl: the version table names v1.29.0 but gives no install command at all.

On a non-root machine the k3d script fails and falls through to a `sudo` password prompt. Setting `K3D_INSTALL_DIR="$HOME/.local/bin"` did not help: it printed "Preparing to install k3d into /home/logan/.local/bin" and then "Failed to install k3d", again ending in a sudo prompt. Workaround used: download the pinned k3d and helm release binaries (and the kubectl binary) directly into `~/.local/bin`, which is already on PATH.

**Impact:** A non-root user cannot complete the documented prerequisites; the failure mode is a password prompt rather than a clear "install to a writable directory" message.

**Remediation:** Document user-local installs: direct release binaries (or `K3D_INSTALL_DIR` / `HELM_INSTALL_DIR` pointed at `~/.local/bin`) plus the kubectl binary URL; and either verify/fix the k3d install script's `K3D_INSTALL_DIR` handling or stop recommending that script. Keep the pinned versions (k3d v5.6.0 / helm v3.21.0 / kubectl v1.29.0) so it stays reproducible.

Related: FRIC-017 (k3d version choice), FRIC-009 (version sync with CI).

## Completion notes

- Replaced the root-requiring k3d/helm one-liners in `docs/dogfood/DOGFOOD.md` with user-local release-binary installs for k3d, helm, and kubectl (previously kubectl had no install command at all), and documented the observed k3d `K3D_INSTALL_DIR` → sudo fallback plus the docker-group requirement.
- Doc-only; no generated/manifest surface, so no example/demo update applies.
