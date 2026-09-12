---
id: FEAT-064
type: feature
severity: medium
source: FEAT-061 part 1, 2026-09-11 — the vocabulary landed; selection stays loose until this
---

**Depends on:** FEAT-061.

One workload-selection model across Sol: `--scope`. Remove `filter_path` and every loose positional workload alias, resolve a scope once into discovery's neutral `named`, fail closed at that boundary, and let each command adapt from there.

**Supersedes:** this ticket's earlier framing ("wire the vocabulary into a command, keep the path argument as an escape hatch"). Checking found the escape hatch redundant for selection, so it is deleted rather than documented as legacy compatibility.

**Related:** FEAT-063 (destination), DEC-018 (rollback), DEC-016.

## Why delete rather than keep both cleanly

`app/payments/charge_svc`, `charge_svc` and `--scope payments/charge_svc` all identify the same discovered workload, and the positional forms add no capability:

- `included_by_filter` matches an exact directory, a basename, or a name — **never a subtree** — so `app/payments` selects nothing today.
- A directory discovery did not recognise cannot be reached by any filter either (it lands in the scanner's `unexpected`), so workspace-wide `sol check` is the tool for that case.
- Nothing documented depends on the positional forms: the only same-shaped invocations in CI, README, TUTORIAL and DOGFOOD are `sol deploy <target>`, which is `--target`.

So they buy compatibility with undocumented behaviour, in exchange for an argument meaning "maybe a name, maybe a normalised name, maybe a directory". That is the overload this project has spent its time removing elsewhere, and now is when it is cheapest to remove.

## Scope

**1. One resolver, returning a typed selection error.**

```ocaml
resolve
  :  ?what:string
  -> request
  -> Sol_cli_manifest.service list
  -> (named list, selection_error) result
```

with `named = { domain; name; primitive; dir }` from discovery. Two failures, both raised *before* any command logic runs:

```
scope "payments/foo" matches no workload
  available in payments: charge_svc, refund_worker

"app/payments/foo" is not a discovered Sol workload directory
```

The second only matters if any path form survives (see 4). Today's `no Sol workloads found with a Dockerfile` is a *check finding* (`sol_cli_check.ml:84`); it becomes unreachable once selection cannot be reached with a bad selector.

**2. Delete `filter_path`.** It is not a `sol check` detail: `cmd_up.ml` threads it into `discover_services` (:235) and the factory (:247), and `check_contract` (:54) passes it onward. `discover_services` should stop taking a user-supplied string at all — a scope resolves to workloads, and commands receive those.

**3. Move `-` → `_` normalisation into the resolver.** `normalize_filter` does it in the *filter* today, which is why `charge-svc` works positionally and fails under `--scope`. The logical selector is where it belongs: the hyphenated spelling is what a user sees in the cluster, while the canonical internal form is the repository name.

**4. No positional workload selector.** `sol check charge_svc` becomes an unknown argument. Decide during implementation whether a stray positional gets cmdliner's generic error or a rejected-argument message pointing at `--scope` — the latter teaches, but keeps a vestigial argument alive for one release.

**5. `--scope` on every command that can meaningfully operate on a subset** — not on every command for uniformity's sake. `check`, `up`, `deploy`, `status`, `logs` and `rollback` qualify; omission means workspace-wide where that is today's behaviour. `sol status` selects everything unconditionally (`filter_path:None`), so it needs this as much as the others.

**6. After selection, commands never see a selector again.** From `named` onward, `check`, the plan, the apply and the diagnostics take the same input, so no two commands can disagree about what a name means.

**7. Record the resolved scope in the emitted plan**, so "what was deployed" survives the command (FEAT-061's criterion 3, moved here).

**8. Demo and docs follow**, per the repo's convention: the TUTORIAL's local sections, the CI smoke, and `sol check --help`.

## Acceptance criteria

- `--scope payments` resolves a domain; `--scope payments/charge_svc` resolves a unit; `--scope payments/charge-svc` resolves the same unit.
- Unknown domain and unknown unit each fail closed with a typed selection error naming what exists.
- No `filter_path` remains in `sol_cli_manifest`, `sol_cli_check` or any command, and no positional workload selector remains.
- Every scope-aware command uses the same resolver — asserted by a test, not by inspection.
- A bad selector fails before check or deploy logic runs, so no command can report a downstream cause for it.
- `sol check` with no `--scope` still covers the whole workspace.
- FEAT-061's independence tests with the destination (its criterion 2) are written once FEAT-063 threads it.

## Notes

Sequencing: this is the strict-selection half of the scope work. FEAT-061 landed the vocabulary and its first consumer with the escape hatch still present; this ticket removes the rest, and the argument for doing it now is the whole ticket — once something depends on the positional forms, deleting them becomes a compatibility negotiation instead of a cleanup.
