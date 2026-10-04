# Run record — `v0.1.0-alpha.7` cut, and the clean-user installed-release qualification

**Ticket:** `RELEASE-006` (part B) · **Campaign:** `internal/qualification/ALPHA_CAMPAIGN.md`
§4, rows `A1`, `J1`, `J2`, `J4`.

## 1. Run identity

| Field | Value | Source |
|---|---|---|
| Sol revision | `f4284422203d341e82cddf1f20b0bd43423499cc` | `git rev-parse origin/main` when the tag was cut |
| Tag | `v0.1.0-alpha.7` → `f4284422…` (not moved afterwards) | `git ls-remote --tags origin v0.1.0-alpha.7` |
| Release workflow | run `37210258576` (tag push, failed at the publish step), run `37212693146` (resume, all steps green) | `gh run list --workflow=release.yml` |
| Re-publish control | run `37213192587`, refused in its second step | `gh run view --job … --log-failed` |
| Release | `https://github.com/loganbnielsen/sol/releases/tag/v0.1.0-alpha.7`, published `2026-10-04T15:28:09Z` | `gh release view` |
| Release asset | `sol-v0.1.0-alpha.7-linux-x86_64.tar.gz`, 9812981 bytes, `uploaded` | `gh release view --json assets` |
| Archive SHA-256 (as downloaded) | `f7b34b0510d9fde9e364cb7aeeab770df4dbaccff3dfa15fd1b16bc6d3230d92` | `sha256sum` in the clean directory |
| Sol bundle version | `v0.1.0-alpha.7` | `sol --version` under the installed prefix |
| Sol install prefix | `/tmp/clean-user/release/sol-v0.1.0-alpha.7` | the extracted archive |
| Migration runner image | `ghcr.io/loganbnielsen/sol-migration-runner@sha256:65f74feb5d2290e4e676bc292d971eaf9fc0188099169db7a82d1e93715aef4d` | `share/sol/v0.1.0-alpha.7/migration-runner-image`, the release body, and `sol assets` |
| Profile / target / account / region / cluster | **N/A** — this is the clean-user install and artifact-integrity qualification; it reaches no provider target | — |
| Started / finished (UTC) | 2026-10-04T14:42Z (tag push) — 2026-10-04T15:41Z (smoke) | workflow and shell timestamps |
| Evidence bundle | `/tmp/clean-user/` (`A1-install.txt`, `J2-smoke.txt`, `sol-dev-control`), outside the repository | — |

## 2. Entry point and environment

- **Procedure:** `docs/guides/installation.md` §1 *Install the CLI*, executed verbatim
  against the published URL, with `SOL_HOME` unset and no Sol checkout anywhere in the
  working directory (`/tmp/clean-user/release`).
- **Host tools** the guide's table names: `aws`, `terraform` (1.5+), `kubectl`, `docker`,
  `dig`. All present except **`dig`** — this host has no `dig`, `nslookup`, `host`, `drill`
  or `delv` (recorded below; it gates the DNS-delegation steps of §4, not this run).
- **No checkout, no `SOL_HOME`:** every command ran from `/tmp/clean-user/release`, and the
  installed-release smoke's own controls assert that a release binary never reaches back
  into a checkout.

## 3. What was executed

### 3.1 Canonical install, verbatim (`A1`)

```console
$ cd /tmp/clean-user/release            # no checkout; SOL_HOME unset
$ curl -sSL https://github.com/loganbnielsen/sol/releases/download/v0.1.0-alpha.7/sol-v0.1.0-alpha.7-linux-x86_64.tar.gz -o sol-v0.1.0-alpha.7-linux-x86_64.tar.gz
$ sha256sum sol-v0.1.0-alpha.7-linux-x86_64.tar.gz
f7b34b0510d9fde9e364cb7aeeab770df4dbaccff3dfa15fd1b16bc6d3230d92  sol-v0.1.0-alpha.7-linux-x86_64.tar.gz
$ tar xzf sol-v0.1.0-alpha.7-linux-x86_64.tar.gz
$ export PATH="$PWD/sol-v0.1.0-alpha.7/bin:$PATH"
$ sol --version
v0.1.0-alpha.7
$ sol assets
sol v0.1.0-alpha.7
assets: installed release v0.1.0-alpha.7
  root: /tmp/clean-user/release/sol-v0.1.0-alpha.7/share/sol/v0.1.0-alpha.7

  ok  terraform  platform/cloud/aws/cluster
  ok  terraform  platform/cloud/aws/platform
  ok  terraform  platform/cloud/gcp/cluster
  ok  terraform  platform/cloud/gcp/platform
  ok  component  grafana
  ok  component  loki
  ok  component  postgresql
  ok  component  prometheus
  ok  component  redpanda
  ok  component  tempo
  ok  templates workspace  37 files
  ok  templates svc  6 files
  ok  templates worker  6 files
  ok  templates fn  6 files
  ok  templates event  3 files
  ok  dashboards
  ok  alloy
  ok  migration runner  ghcr.io/loganbnielsen/sol-migration-runner@sha256:65f74feb5d2290e4e676bc292d971eaf9fc0188099169db7a82d1e93715aef4d

all assets present
```

### 3.2 The bundle and its provenance (`J1`, `J4`)

```console
$ tar tzf sol-v0.1.0-alpha.7-linux-x86_64.tar.gz | wc -l
209
$ cat share/sol/v0.1.0-alpha.7/VERSION
v0.1.0-alpha.7
$ cat share/sol/v0.1.0-alpha.7/migration-runner-image
ghcr.io/loganbnielsen/sol-migration-runner@sha256:65f74feb5d2290e4e676bc292d971eaf9fc0188099169db7a82d1e93715aef4d
$ wc -l < share/sol/v0.1.0-alpha.7/SUPPORT_REFS      # 11 pins, each a 40-hex commit
11
```

The archive carries exactly `bin/sol` (27806624 bytes) plus
`share/sol/v0.1.0-alpha.7/{VERSION, platform/, migration-runner-image, SUPPORT_REFS}` — no
framework source, no checkout. The digest the bundle names is the digest the release body
names, and it is the one the first (failed) run pushed: the resume reused it rather than
rebuilding.

### 3.3 The installed-release smoke, on the **published** archive (`J2`)

```console
$ bash internal/ci/smoke_installed_release.sh \
    /tmp/clean-user/release/sol-v0.1.0-alpha.7-linux-x86_64.tar.gz v0.1.0-alpha.7 "$RUNNER" /tmp/clean-user/sol-dev-control
...
  [OK]   sol --version is v0.1.0-alpha.7
  [OK]   sol assets: installed bundle, every consumer ran, runner is ghcr.io/loganbnielsen/sol-migration-runner@sha256:65f74feb…
  [OK]   an invalid SOL_HOME is an error, not a fall-through
  [OK]   sol cloud plan runs from the read-only install; Terraform works in its own directory
  [OK]   sol plan reads the reference workspace with no checkout and SOL_HOME unset
  [OK]   control: the install really is read-only there
  [OK]   control: a development build finds nothing to reach back to
  [OK]   control: a bundle missing an asset fails
  [OK]   control: a release binary never reaches back into a checkout
installed-release smoke: passed
```

16.6 s wall clock, in containers with `--network none` and a read-only install.

### 3.4 A version is published once (`J1`)

```console
$ gh workflow run release.yml -f version=v0.1.0-alpha.7 --ref main   # run 37213192587
$ gh run view --job … --log-failed | tail -1
##[error]v0.1.0-alpha.7 is already published, and a version is published once
```

The refusal happens in the second step, before anything is built; every later step is
skipped.

### 3.5 The runner image is retrievable without credentials

```console
$ TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:loganbnielsen/sol-migration-runner:pull" | jq -r .token)
$ curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" …/manifests/sha256:65f74feb…
200
$ curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" …/manifests/v0.1.0-alpha.7
200
```

## 4. Row results

| Row | Result | Evidence |
|---|---|---|
| `A1` Released install | **PASS** | §3.1: the canonical `curl \| tar xz`, `sol --version`, `sol assets` → `all assets present`, with no `SOL_HOME` and no checkout. |
| `J1` Release publishes one aligned unit | **PASS** | §3.2 + §3.4: one tag publishes `bin/sol` + `share/sol/v0.1.0-alpha.7/platform` + the runner image, whose digest both the bundle and the release body name; a second run is refused by name. |
| `J2` Installed-layout smoke | **PASS** | §3.3, run against the published archive rather than a staged one, with all four positive controls. |
| `J4` Provenance | **PASS** | §3.2: `VERSION` names the version, `SUPPORT_REFS` carries every support pin as a 40-hex commit, and the release body names the revision `f4284422…`. |
| §3 *Local first (optional)* | **NOT REACHED** | The guide marks it optional; it needs a local cluster, and the local rows are qualified separately (`VERIF-027`). |
| §4–§7 (bootstrap, deploy, operate, destroy, uninstall) | **NOT REACHED** | They need an authenticated provider account, which is not authorized. |

## 5. Defects this run exposed, and their state

**`BUG-204` — the release workflow could not publish a long body, and could not resume an
interrupted publish.** The first run (`37210258576`) built the binary, pushed
`ghcr.io/loganbnielsen/sol-migration-runner:v0.1.0-alpha.7`, built the archive and passed the
installed-release smoke, then failed at `gh release create`:

```console
HTTP 422: Validation Failed (https://api.github.com/repos/loganbnielsen/sol/releases)
body is too long (maximum is 125000 characters)
```

`--generate-notes` carries one entry per merged pull request since the previous release, and
the real generated changelog was **126890 characters** — over the limit. The second defect is
why the version could not simply be re-cut: the runner step refused an image that already
existed, so any failure after the push burned the version.

Fixed in `.github/workflows/release.yml` (PR #1070, `143bd592`): the body is bounded at a
line boundary with a pointer to the full compare range; the runner publish reuses an existing
digest instead of refusing or overwriting it; a version whose *release* exists is refused; and
a `workflow_dispatch` `version` input resumes a publish from the default branch. The resume
run (`37212693146`) logged
`ghcr.io/loganbnielsen/sol-migration-runner:v0.1.0-alpha.7 is already published; reusing its
digest rather than overwriting it` and
`::warning::the generated changelog is 126890 characters; keeping the first 100000 at a line
boundary`, and published a body of 100324 bytes.

**The tag did not move.** `v0.1.0-alpha.7` still points at the frozen campaign revision
`f4284422`, and the artifact was built from that revision's tree; only the workflow definition
came from the default branch, which is what the `workflow_dispatch` path is for.

## 6. What this run does not establish

- **Nothing provider-side.** No AWS or GCP target was touched; every `C`, `D`, `E`, `F`, `I`
  row that needs an account stays as the campaign records it.
- **Nothing about the local cluster.** The released binary was not driven against `sol local`;
  the local rows are `VERIF-027`'s, on the revision the release was cut from.
- **`dig` is absent on this host**, so §4's DNS-delegation steps could not run here even with
  an account. A clean-user machine following the guide needs it installed.
- The published archive is validated as an artifact (install, layout, provenance, reach-back
  controls, retrievability); it is not evidence that any particular workload deploys, which
  is what the local and live runs are for.
