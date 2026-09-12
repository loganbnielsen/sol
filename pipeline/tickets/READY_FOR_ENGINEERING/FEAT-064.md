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

**4. Delete the positional argument outright — no rejection shim, no teaching branch.** `sol check charge_svc` fails through cmdliner as an unexpected positional, and the teaching happens in the grammar the command already publishes: cmdliner prints its usage line on a parse error, so `--scope DOMAIN[/UNIT]` with a clear `docv` and a "Workload selection" man section is where a user learns the valid form.

**Checked rather than assumed**, because the choice hinged on it: cmdliner exposes no `hidden` option for arguments, and an optional positional *is* advertised in usage — `sol check --help` already shows `[PATH]` today. There is also no `Cmd.eval`-style variant that hands back the parse error to reword. So a rejection shim would not be invisible: it would put a permanent `[ARG]` in the command's public usage line, i.e. it would *add* invalid grammar to the surface in order to produce a nicer sentence for it.

The principle, since this is the second time it has come up: **teach through errors when the invalid input belongs to a real, supported grammar; do not add invalid grammar solely to produce a teaching error.** A removed positional is not part of Sol's grammar any more, and nothing documented or deployed depends on it, so there is no migration story that would justify the shim — "one release" was a period measured against users who do not exist.

**5. `--scope` on every command that can meaningfully operate on a subset** — not on every command for uniformity's sake. `check`, `up`, `deploy`, `status`, `logs` and `rollback` qualify; omission means workspace-wide where that is today's behaviour. `sol status` selects everything unconditionally (`filter_path:None`), so it needs this as much as the others.

**6. `logs` needs the projection this ticket's earlier draft dropped.** `sol logs` (and `sol open`) address telemetry through `Sol_cli_open.scope` — `Workspace | Domain | Service of (domain, service) | Resource of (type, name)` — a different vocabulary, keyed by namespace segments, with **no worker or function case** because telemetry naming collapses them. So `logs --scope payments/settle_worker` resolves a *deployment* unit that the telemetry side cannot address directly. That projection has to exist explicitly (worker and function → their `domain/service` naming), in one place, with a test — otherwise the two vocabularies drift and the failure looks like missing logs rather than a naming mismatch. `sol open` keeps its own argument; the projection is what the command uses internally.

**7. After selection, commands never see a selector again.** From `named` onward, `check`, the plan, the apply and the diagnostics take the same input, so no two commands can disagree about what a name means.

**8. Record both the requested scope and the resolved set in the emitted plan** (FEAT-061's criterion 3, moved here). The resolved `named` list answers "what was deployed"; the requested scope answers "what was *asked* for" — and it is the requested scope that defines the boundary of a release, which is what DEC-018 needs to restore one. Recording only the resolved set would leave rollback inferring the boundary from a service list.

**9. Omitted scope in a mutating command is not a silent no-op.** `sol up` with no scope on a workspace that discovers nothing must fail ("no workloads discovered"), for the same reason the loose filter had to go: a selector that matches nothing must not look like success. Read-only commands can report an empty workspace and exit 0.

**10. Demo and docs follow**, per the repo's convention: the TUTORIAL's local sections, the CI smoke, and `sol check --help`.

## Acceptance criteria

- `--scope payments` resolves a domain; `--scope payments/charge_svc` and `--scope payments/charge-svc` resolve the **same** workload, with discovery's repo-derived `charge_svc` remaining the **canonical** internal name — normalisation is an input convenience, not two equal names to carry around.
- Unknown domain and unknown unit each fail closed with a typed selection error naming what exists.
- A positional workload argument fails with a message naming `--scope`, asserted by a test rather than by reading the shim.
- No `filter_path` remains in `sol_cli_manifest`, `sol_cli_check` or any command, and no positional workload selector remains functional.
- Every scope-aware command uses the same resolver — asserted by a test, not by inspection.
- A bad selector fails before check or deploy logic runs, so no command can report a downstream cause for it.
- A worker or function scope projects onto the telemetry addressing `logs` uses, tested, rather than being assumed to line up.
- `sol check` with no `--scope` still covers the whole workspace; a mutating command with no scope on an empty workspace fails rather than reporting success.
- The emitted plan carries both the requested scope and the resolved workloads.
- FEAT-061's independence tests with the destination (its criterion 2) are written once FEAT-063 threads it.

## Notes

Sequencing: this is the strict-selection half of the scope work. FEAT-061 landed the vocabulary and its first consumer with the escape hatch still present; this ticket removes the rest, and the argument for doing it now is the whole ticket — once something depends on the positional forms, deleting them becomes a compatibility negotiation instead of a cleanup.

## The invariant, and what follows from it

> **Sol has one workload-selection language. Commands may project that selection into their own addressing model, but may not reinterpret it.**

Three consequences, each of which came up as a question during design:

- **Selection is neutral about emptiness.** The resolver answers `Selected of named list | Empty`; whether zero matches is *meaningful* is a command policy — `status` and `check` accept an empty workspace, `up`, `deploy` and `rollback` do not. Encoding that policy inside the selection type would make the selector know what its caller intends to do with the answer.
- **A command receives `--scope` only when every accepted scope projects into that command's addressing model without changing its meaning.** If `payments/settle_worker` resolves as a deployment unit but Loki can only address `payments`, then `logs --scope payments/settle_worker` must not ship implying unit granularity: either write the projection that preserves the intended granularity, or defer `--scope` for that command and say so here. `scope resolution != command addressing`.
- **The plan carries both facts.** The requested scope (`Domain "payments"`) and the concrete resolved set (`charge_svc`, `refund_svc`, `settle_worker`) are different pieces of information: intent, and reproducibility. A service added to `payments` next week does not retroactively change what the boundary of *that* release was, and rollback needs both.
