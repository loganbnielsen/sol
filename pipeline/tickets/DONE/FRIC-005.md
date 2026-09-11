---
id: FRIC-005
type: dogfood-finding
severity: medium
source: project/dogfood/RUN_2026-06-12e.md
branch: FRIC-005/dev-up-helm-noise
worktree: /home/lbendtly/Code/sun-FRIC-005-dev-up-helm-noise
---

**Depends on:** None.

`sun dev up` prints ~50 lines of noisy Helm NOTES and deprecation warnings, including a `loki-stack` deprecated-chart warning and a Bitnami paid-tier subscription notice

**Description:** `sun dev up` passes Helm `upgrade --install` output directly to stdout. Two sources of noise recur across every run:
1. `grafana/loki-stack` emits `WARNING: This chart is deprecated` — the chart is marked `deprecated: true` in its Chart.yaml. It still installs today, but it will stop receiving security patches and may eventually be removed from the chart repository, causing fresh-substrate `sun dev up` runs to fail.
2. Bitnami PostgreSQL prints a ~30-line `NOTES:` block including a prominent paid-subscription notice: _"Since August 28th, 2025, only a limited subset of images/charts are available for free."_ This is a marketing message (the chart still works with public images), but it reads as a hard requirement to first-time users, causing unnecessary confusion.

Both issues have recurred across at least three dogfood runs: `RUN_2026-06-10-full.md`, `RUN_2026-06-12.md`, and `RUN_2026-06-12e.md`.

**Impact:** A first-time startup engineer running `sun dev up` sees a wall of alarming text — deprecation warnings, paid-tier notices, rolling-tag advisories, and resource-limit warnings — mixed in with Sun's own clean structured output. The natural response is to stop and research each warning, adding several minutes of confusion and eroding trust in the platform. The loki-stack deprecation is also a latent time-bomb: when Grafana removes the chart or stops publishing updates, fresh cluster bootstraps will break with no clear migration path in Sun's docs.

**Remediation:**
1. In `cli/sun/bin/cmd_dev.ml`, capture stdout/stderr from each `helm upgrade --install` invocation and suppress chart `NOTES:` blocks and bare `WARNING:` lines before printing. Only emit Sun's own structured status line (e.g., `Installing Loki... ✓`). Non-zero exit codes should still be surfaced as errors.
2. Migrate the Loki install in `cmd_dev.ml` from the deprecated `grafana/loki-stack` chart (line 197) to `grafana/loki` (standalone Loki chart, actively maintained) paired with `grafana/grafana`. The `grafana/loki-stack` chart was the all-in-one convenience chart and is now deprecated; the replacement is to install `grafana/loki` and `grafana/grafana` as separate releases. Update the port-forward targets accordingly (`svc/loki` and `svc/grafana` instead of `svc/loki` and `svc/loki-grafana`).

## Review — automated checks passed
FRIC-005 correctly suppresses Helm NOTES: and WARNING: output via temp-file capture+filter, migrates Loki from deprecated grafana/loki-stack to standalone grafana/loki + grafana/grafana, and updates the Grafana port-forward target from svc/loki-grafana to svc/grafana; build and tests pass, only cli/sun/bin/cmd_dev.ml changed, project/tickets/ untouched
