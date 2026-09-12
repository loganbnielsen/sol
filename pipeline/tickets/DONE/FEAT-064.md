---
id: FEAT-064
type: feature
severity: medium
source: FEAT-061 part 1, 2026-09-11 — the vocabulary landed; selection stays loose until this
---

**Depends on:** FEAT-061.

**Related:** FEAT-063 (destination), DEC-018 (rollback), DEC-016.

Strict scope resolution: one resolver over discovery, canonical names, and no positional selector.

## What this is, and what it is not

This is the resolver half of the strict-selection work: a scope resolves once, against discovery, into a neutral result, and `sol check` has exactly one way to name what it works on. The cross-command migration — deleting `filter_path`, wiring `--scope` into the other commands, recording the scope in the plan — is **FEAT-065**, because it is a different kind of change (a migration across 18 files rather than a resolver) and "done" should not mean both.

## What landed

- **One resolver** over discovery's units, taking the neutral `named` shape so neither `service_spec` nor `Sol_cli_manifest.service` becomes the centre of the design. The plan-coupled entry points (`select`, `named_of_spec`) are deleted — they had no consumer.
- **`Selected of named list | Empty`** as the result: the resolver answers *what matched*, and whether zero matches is meaningful is the calling command's policy. `check` accepts an empty workspace explicitly; the mutating commands will not, which is why emptiness is reported rather than judged.
- **Canonical names.** Matching normalises `-` to `_`, so `payments/charge-svc` resolves the same unit as `payments/charge_svc`, and the resolved scope always carries discovery's repository-derived name. Normalisation is an input convenience, not a second identity.
- **Unknown scope fails closed**, naming what exists.
- **The positional `PATH` argument is deleted** from `sol check`, with no rejected-argument shim: cmdliner advertises optional positionals in the usage line (`sol check --help` showed `[PATH]`), so a shim would add invalid grammar to the public surface permanently to produce a nicer error for it.

## Acceptance criteria

- One neutral resolver over discovered `named`.
- `Selected of named list | Empty`.
- Hyphen input normalisation, with repo-derived canonical names.
- Unknown scope fails closed.
- The positional `PATH` argument is gone from `sol check`, and a stray positional fails through the parser.
- The plan-coupled `select` / `named_of_spec` are removed.
- CLI smoke, run against the built binary directly, covers: canonical unit, hyphenated unit, unknown scope, stray positional.

## Verification

Direct binary, in `examples/pluto` (no wrapper: an earlier attempt through `dune exec` reported failures that were the wrapper consuming `--scope`, not the CLI).

| invocation | result |
|---|---|
| `sol check --scope payments/charge_svc` | `sol check: ok`, exit 0 |
| `sol check --scope payments/charge-svc` | `sol check: ok`, exit 0 — normalisation |
| `sol check --scope logistics` | exit 2, `--scope "logistics" matches no workload; domains with units: …` |
| `sol check app/payments/charge_svc` | exit 124 (cmdliner's CLI-error code, not a timeout) — usage, no positional |
| `sol check` | `sol check: ok`, exit 0 — whole workspace |

Unit suites: deployment_scope 12, check 6, config 49, factory 2; full unit suite green through the pre-commit hook.

## Moved to FEAT-065

Deleting `filter_path` everywhere, `--scope` on the remaining commands, the per-command empty policy for mutating commands, recording both the requested scope and the resolved workloads in the plan, and the projection into telemetry addressing. FEAT-065 also carries the invariant that governs them.

## Completion notes

Landed as one PR: the resolver and its first consumer. The narrow scope is deliberate — the cross-command migration is FEAT-065 — so "done" here means the resolver exists, canonicalises, and is used strictly by one command.

**Three things worth recording beyond the criteria.**

1. **The result type earned its place immediately.** Making it `Selected | Empty` produced `partial-match` errors in three tests until emptiness was handled explicitly, which is the compiler asking the design's own question — is zero matches meaningful *here*? `check` answers yes and says so in a comment; `up`, `deploy` and `rollback` answer no in FEAT-065.
2. **Normalisation is input-only, and that was verified end to end rather than only in unit tests.** `payments/charge-svc` resolves, and the resolved scope carries `charge_svc`. Getting this wrong is invisible until two release records disagree about one workload's name.
3. **The verification method matters, because two earlier attempts reported the opposite of the truth.** The CLI cases were run against the built binary directly. An earlier pass through `dune exec` reported parse failures for arguments that are valid — the wrapper had consumed `--scope` — and `rc=124` in a parse failure is cmdliner's CLI-error exit code, not a timeout. Worth knowing before anyone asserts on `124` in a test.
