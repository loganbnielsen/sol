---
id: DOCS-002
type: docs-finding
severity: medium
source: project/audits/2026-06-22_docs_audit.md
branch: DOCS-002/fix-prometheus-port
worktree: ../sun-DOCS-002-fix-prometheus-port
---

Tutorial `sun dev up` endpoint table lists `Prometheus localhost:9090` — not forwarded

**Description:** `docs/guides/TUTORIAL.md` line 75 lists `Prometheus localhost:9090` in the endpoint table shown after `sun dev up`. `sun dev up` (`cli/sun/bin/cmd_dev.ml`) does not port-forward Prometheus's scrape port at all — it only forwards the Pushgateway to `localhost:9091`. The Prometheus server port 9090 is never exposed on the host.

**Impact:** A user following the Tutorial will try to open `localhost:9090` and get connection refused, breaking trust in the quickstart.

**Remediation:** Replace the `Prometheus localhost:9090` row in the Tutorial endpoint table with `Pushgateway localhost:9091`. Also verify whether the README quickstart has the same error and fix it there too.

## Review — automated checks passed
TUTORIAL.md endpoint table correctly updated from Prometheus localhost:9090 to Pushgateway localhost:9091; README.md has no localhost:9090 reference; cmd_dev.ml confirms 9091 is the correct Pushgateway port; project/tickets/ is untouched; build succeeds.
