---
id: REFAC-083
type: refactor
severity: low
source: naming discussion 2026-09-11, after FEAT-059 merged
---

**Depends on:** None.

Rename `sol dev up` to `sol local up`, and reserve `local` as a name no environment may use.

**Related:** DEC-016, FEAT-059.

## Problem

`sol dev up` brings up the **local substrate** — the k3d cluster plus Redpanda, Postgres, Grafana, Loki, Tempo, Prometheus and their port-forwards. But `dev` is also a very common **environment** name: a target lives at `sol/<env>/<provider>/<region>.yml` and carries `env: dev`. So `sol dev up` reads as "bring up the dev environment", which is a different thing — potentially a real cloud cluster that other people are using.

FEAT-059 already settled the vocabulary on the destination side: `Sol_cli_kube_destination.local`, context `k3d-sol-local`, and `local` as the one carve-out that may be named literally because Sol owns that cluster. The command should use the same word the rest of the system uses for the same thing.

One thing to record so nobody "fixes" this the wrong way later: **there is no `--env` flag and none should be added** (DEC-016). The environment is a property of the resolved target, and the target is the selector. So this is a collision between a *command namespace* and a possible *target name* — not a flag conflict, and not solvable by adjusting a flag.

## Scope

**1. Rename the command namespace.** `sol dev up` → `sol local up`, and the sibling subcommands under `dev` (e.g. `sol dev run`) → `local`. Prefer removing the old name outright rather than aliasing it: the project is pre-1.0, and a permanent alias preserves the confusion this ticket exists to remove.

**2. Reserve `local`.** Config validation must reject `local` as a target's env name, with a message that explains the reason and points at what to do instead: `local` is Sol's ephemeral substrate, not an environment; a cluster you run yourself is still a cluster, so name the target for it (`dev`, `staging`, …). Without this reservation the rename merely moves which word can collide — onto a word that must never be a valid environment.

**3. Update the callers and the docs.** The golden-path smoke invokes the command (`.github/workflows/ci.yml`), and the tutorial and `docs/dogfood/DOGFOOD.md` reference it. Rename them in the same change — the smoke is the reason this cannot be done piecemeal.

**4. DEC-016's vocabulary is already amended** — the rule that `local` is not an environment, is reserved, and that no `--env` flag is to be added, is recorded there as of 2026-09-11, along with the note that this ticket renames `sol dev up`. Nothing further is needed on that front; this ticket is the rename and the guard.

## Acceptance criteria

- `sol local up` does everything `sol dev up` did, including the port-forwards and the summary output.
- `sol dev up` no longer exists (or fails with a message naming its replacement — decide during implementation and record which).
- A target whose env is `local` fails config validation, with a message that explains why and says what to name it instead.
- No documentation calls `sol local up` an environment, or implies `local` can be selected like `prod`.
- `.github/workflows/ci.yml`'s golden-path smoke and `DOGFOOD.md` use the new name; the full unit suite passes.

## Notes

Small, but coordinated: the smoke and the docs reference the command, so the rename lands in one commit. Worth checking whether any example or fixture already uses `local` as an env name — if one does, it is exactly the confusion this ticket is about, and it gets renamed rather than exempted.
