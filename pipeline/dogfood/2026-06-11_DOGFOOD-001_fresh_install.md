# DOGFOOD-001: Fresh Install and Workspace Creation
**Date:** 2026-06-11  
**Tester:** Claude Sonnet 4.6 (automated dogfood pass)  
**Branch:** DOGFOOD-001/fresh-install-workspace

---

## Environment

- OS: Linux 6.6.87.2-microsoft-standard-WSL2 (Ubuntu)
- Sun binary: symlink at `~/.local/bin/sun` → `_build/default/cli/sun/bin/main.exe` (dev install, not release binary)
- SUN_HOME: `/home/lbendtly/Code/sun` (set in shell)

---

## Steps Executed and Timings

| Step | Command | Result | Time |
|------|---------|--------|------|
| Check release binary | `curl -sI .../sun-linux-x86_64` | **404 Not Found** | — |
| Scaffold workspace | `sun new workspace dogfood_acme` | Exit 0, 21 files | 61ms |
| Build workspace | `dune build` in `dogfood_acme/` | Exit 0, clean | 2.1s |
| SUN_HOME="" test | `SUN_HOME="" sun new workspace dogfood_nohome` | Exit 0, NOTE shown | 45ms |

---

## Findings

### F1 — BLOCKER: No release binary published

**URL:** `https://github.com/loganbnielsen/sun/releases/latest/download/sun-linux-x86_64`  
**HTTP:** 404

The GitHub Actions release workflow (`release.yml`) exists and is structurally correct, but no tag has ever been pushed to trigger it. A new user following the README one-liner `curl` install will hit a 404 and have no actionable error message.

**Required action:** Push a `v0.1.0` (or pre-release `v0.1.0-alpha.1`) tag to trigger the first release build.

### F2 — BLOCKER for release-binary users: SUN_HOME auto-detection fails

`infer_sun_home()` walks ancestors of `realpath(/proc/self/exe)`. For a dev install (symlink into `_build/`), this resolves to the Sun checkout root and auto-detection succeeds. For a downloaded release binary at `~/.local/bin/sun`, the ancestor chain is `~/.local/bin/` → `~/.local/` → `~/` → … — none of which contain `framework/sun-svc/lib/dune`. Auto-detection always returns `None`.

The fallback NOTE message is clear and correct. The README does document `SUN_HOME`. But a first-time user will not expect a mandatory second setup step after a one-liner install, and the README buries it after the install command.

**Required action:** Promote the SUN_HOME export to immediately after the `curl` install block in the README, with a clearer explanation that it is required, not optional.

### F3 — Generated workspace README missing SUN_HOME and runtime dep context

The generated `README.md` (from `tpl_readme`) says:

```bash
eval $(opam env)
dune build
```

No mention that:
- `vendor/framework` and `vendor/integrations` must be valid symlinks (set SUN_HOME if missing)
- `librdkafka-dev` and `libpq-dev` are required system packages for `dune build` to succeed

A developer who clones a workspace from a teammate's GitHub will have broken symlinks and no explanation.

**Fixed in this pass:** Updated `tpl_readme` in `sun_cli_cmd_new.ml` to add a "Prerequisites" section.

### F4 — Generated workspace README has confusing duplicate dev workflow

The `tpl_readme` lists `sun dev up` + `sun dev run` in "Run locally" AND `sun dev up` + `sun up` in "CLI commands". This conflates the local-services workflow (`sun dev run`) with the cluster-deploy workflow (`sun up`). The "CLI commands" block should be a reference, not a workflow narrative.

**Fixed in this pass:** Clarified the template.

### F5 — `sun new workspace` post-scaffold message doesn't mention `dune build`

The post-scaffold message jumps straight to `sun dev up`. A user who just wants to verify the scaffold compiles before provisioning a cluster has no prompt to run `dune build` first. This adds a 5-minute cluster wait before they discover a compile error.

**Fixed in this pass:** Added `dune build` as the first step in the post-scaffold message.

---

## What Passed

- `sun new workspace` completes in under 100ms with clean output.
- `dune build` in the generated workspace exits 0 in ~2s with no errors.
- The NOTE message when SUN_HOME is empty is correct and actionable.
- The release workflow is structurally correct (uses `${{ github.repository }}`, correct artifact path).

---

## Required Follow-up Tickets

- **DOGFOOD-007**: Publish first release binary (push `v0.1.0-alpha.1` tag) — human action required.

---

## Acceptance Criteria Status

| Criterion | Status |
|-----------|--------|
| Generated workspace builds from release-installed binary | **BLOCKED** (no release binary) |
| README and tutorial match tested path | **Partial** — F2 addressed in README; F3 fixed in template |
| Manual setup steps are explicit and justified | **Partial** — SUN_HOME step needs more prominence |
