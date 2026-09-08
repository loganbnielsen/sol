---
id: FRIC-014
type: dogfood-finding
severity: low
source: project/dogfood/RUN_2026-09-07_AWS.md (DOGFOOD-011, first real AWS dogfood run) — the same drift class this ticket guards against was found live during that run
branch: FRIC-014/scaffold-example-drift-ci
worktree: ../sun-FRIC-014-scaffold-example-drift-ci
---

**Depends on:** None.

Nothing catches the checked-in example workspaces (`examples/pluto`, `examples/venus`) drifting out of sync with what `sol new`'s scaffold template actually generates — DOGFOOD-011 found a real, live instance of exactly this drift.

**Description:** During DOGFOOD-011, `examples/pluto/app/payments/charge_svc/Dockerfile` (and 3 sibling Dockerfiles across `pluto`/`venus`) failed to build at all: a stale, no-longer-published base image tag (`ocaml/opam:ubuntu-24.04-ocaml-5.4.1`), and — more seriously — no `opam install` step whatsoever, meaning even with a corrected tag the build would still fail with `Command not found 'dune'`. The current `sol new` scaffold template (`cli/sol/lib/sol_cli_scaffold_templates.ml`'s `tpl_dockerfile`) already has both fixes, evidently landed after real iteration (its own comments cite specific past failures: "observed: https-eio needing tls-eio >= 2.1.0", "Library \"jose\" not found"). The example fixtures were simply never re-synced after those fixes were made to the live template.

**Impact:** The example workspaces are the concrete reference every audit skill (`demo-review`, `scaffold-audit`, etc.) and every engineer reads to understand "what does a real Sol app look like." A silently-broken example erodes trust in exactly the artifact meant to build it, and (as this run showed) the breakage is invisible to anyone whose local Docker cache happens to have stale layers from before the drift — it only surfaces on a genuinely fresh build, which is rare enough in normal development that it can sit broken for a long time undetected.

**Remediation:** Add a CI check (or a `scaffold-audit`-style periodic check) that either (a) diffs each example's Dockerfile build-stage content against what the current scaffold template would generate for an equivalent service, flagging drift, or (b) simpler and more direct: actually builds each example's Dockerfiles with `--no-cache` in CI, the same class of check FRIC-009 added for the golden path generally. Option (b) is likely sufficient on its own and is the more direct test of "does this example actually work," not just "does it match the template."
