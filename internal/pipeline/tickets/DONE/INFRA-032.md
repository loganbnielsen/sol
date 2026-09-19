---
id: INFRA-032
type: bug
severity: high
title: The alloy chart cannot be downloaded on a real target, failing the platform apply
source: HARDEN-002 Run 5 attempts 1 and 2, 2026-09-18/19 — reproduced on two
  independent live AWS targets
---

**Depends on:** None.

**Related:** INFRA-030 (the capacity defect that masked this in attempt 1),
HARDEN-002 (the run), OBS-039 (the Promtail -> Alloy migration this chart serves).

## What happens

`helm_release.alloy` fails the whole platform apply on a real target:

```
│ Error: could not download chart: Chart.yaml file is missing
│   with helm_release.alloy,
│   on main.tf line 728, in resource "helm_release" "alloy":
```

It is the **only** chart that fails. In attempt 2, `helm_release.redpanda` and
`helm_release.loki[0]` both reported `Creation complete`, and every other platform
component was observed `Running` — so this is the single remaining blocker for a
fresh `production-single-region/v1` target reaching `Ready`.

Attempt 1 was assumed transient because the pinned version was known to exist and
the failure sat behind a capacity defect. Attempt 2 provisioned a fresh target
with the corrected capacity contract and **reproduced it**, so it is not
transient and the "wait for a clean retry" position is now discharged.

## Why it fails

Alloy is the only chart in `cli/platform/infra/base` still sourced from the legacy
`https://grafana.github.io/helm-charts` repository. Every other Grafana chart in
that root — loki, grafana, tempo — uses
`https://grafana-community.github.io/helm-charts`.

The legacy index does **not** serve tarballs at the conventional
`<repo>/<chart>-<version>.tgz` path; it advertises archives on GitHub releases:

| URL | Result |
|---|---|
| index entry for alloy 1.12.1 → `github.com/grafana/helm-charts/releases/download/alloy-1.12.1/alloy-1.12.1.tgz` | HTTP 200, 32237 bytes |
| `grafana.github.io/helm-charts/alloy-1.12.1.tgz` (what the provider resolved) | **HTTP 404, 9379 bytes of HTML** |
| `helm pull alloy --repo <legacy> --version 1.12.1` | **succeeds**, 32237 bytes |

So the chart is fine, the version is fine, and helm (which follows the index)
works. The Terraform helm provider resolves the conventional path, receives the
404 page, and reports the missing `Chart.yaml`.

**Open question, recorded honestly:** a minimal local reproduction using the
pinned provider (hashicorp/helm 2.17.0) and the *same* repository/chart/version
against a local cluster **succeeds**, so the exact trigger is not proven — the
live failure sits somewhere in how the provider resolves this repository's index
under a real apply (a large legacy index, off-host archive URLs, and many
concurrent `helm_release` resources). What is established is that this is the only
chart that cannot be resolved, that it fails reproducibly on real targets, and
that its URL shape is the one outlier among all charts in the root.

## Remediation

Name the archive directly rather than relying on repository + version resolution:

```hcl
resource "helm_release" "alloy" {
  name  = "alloy"
  chart = "https://github.com/grafana/helm-charts/releases/download/alloy-1.12.1/alloy-1.12.1.tgz"
  ...
}
```

`repository` is dropped and `version` is not set — the URL *is* the pin, so this
also removes any index dependency. The alternative of moving to another
repository was checked and rejected: alloy is **not** published in the community
repository that the sibling charts use, and declaring the GitHub releases
*directory* as `repository` fails too (the provider fetches `<dir>/index.yaml` →
404).

## Acceptance criteria

- A fresh `production-single-region/v1` target completes the platform apply with
  alloy installed, on a real target (attempt 3 is the verification; the local
  isolated test cannot discriminate, as recorded above).
- The chart version stays pinned at 1.12.1 — by URL — so no chart silently moves.
- `terraform fmt -check` and `terraform validate` pass for the base root.
- No other chart's source changes.

**Verification performed before committing:** the exact `chart = <URL>` form was
applied against a local cluster with the same provider version the root pins, and
installed successfully (`Apply complete`, alloy pod Running). Scratch namespaces
and releases were removed afterwards.

**Demo/example coverage:** No example change; the platform root is not an example.

**TypeScript parity:** No language-parity impact.
