---
id: REFAC-084
type: refactor
severity: low
source: FEAT-062 review 2026-09-11 — --check can report unreachable but not why
---

**Depends on:** None.

Make a failed cluster probe carry its reason, so `sol target show --check` can say *why* a cluster could not be reached instead of only that it could not.

**Related:** FEAT-062, FEAT-063.

## Problem

`Sol_cli_kubectl.probe : args:string list -> bool` answers yes or no. That is enough for a guard — "is it up?" — but not for a diagnosis. FEAT-062's `--check` can therefore print `unreachable` and nothing more, and the message it prints instead names the by-hand equivalent (`kubectl --context … cluster-info`) rather than a cause.

The information already exists: kubectl writes it to stderr, and the adapter discards it. The whole point of distinguishing *configured* from *reachable* is to tell someone whether the plumbing or the cluster is at fault, and a bare "unreachable" answers *whether* without answering *what* — then sends them to run the command by hand, which is the thing the command existed to save them from.

## Scope

**1. Return the result, not just the verdict.** A variant that hands back the process result (exit code, stdout, stderr) — `probe_result`. Either keep `probe` as a thin wrapper over it so existing call sites are untouched, or migrate them; decide alongside FEAT-063, which is reworking these helpers anyway.

**2. Use it in `sol target show --check`**, carrying the first line of stderr into the `unreachable` description.

**3. Mind the masking rule.** FEAT-062 asserts end-to-end that the default output contains no context string, so a reason that embeds the context would break it. Check what kubectl's stderr actually contains before assuming, and keep the context out unless `--verbose`.

**4. Stay honest when there is no reason.** An empty stderr must not become an empty clause, and a probe that cannot run at all (no kubectl on `PATH`) is a different failure from a cluster that refused the connection — say which.

## Acceptance criteria

- An unreachable cluster reports the reason kubectl gave, not just "unreachable".
- The FEAT-062 end-to-end assertion still holds: the default output contains no context string; `--verbose` may name it in the reason.
- A missing kubectl is reported distinctly from a refused connection.
- Existing boolean `probe` call sites keep working.

## Notes

Small, but it is the difference between an inspection command and a command that tells the user to go inspect by hand. It can land with FEAT-063; nothing depends on it.

## Completion notes

**`probe_result` added, `probe` kept.** `probe_result ~args : (int * string, string) result` returns the exit code and the reason a human should see (stderr when present, else stdout); `Error` means kubectl could not be run at all, which is a different failure from running and failing. `probe` is now a thin wrapper, so existing call sites are untouched and the boolean verdict is still there for guards.

**The ticket's step 3 was the right one to insist on, and it changed the design.** kubectl *quotes the context back*: `error: context "prod-us-east-1" does not exist`. So reporting the reason verbatim would have leaked the context into the default output and broken FEAT-062's end-to-end masking assertion — the ticket anticipated this and it was correct. The reason is therefore filtered by the rendering layer (`redact`), and the verified output is:

```
kubernetes    unreachable: error: context "<context>" does not exist
kubernetes    unreachable (no-such-context-xyz): error: context "no-such-context-xyz" does not exist   # --verbose
```

Filtering only the context *field* while printing the reason would have satisfied the rule in appearance and failed it in fact, which is the same shape of mistake this session already made once with a discarded `kubectl apply`.

**Two things checked empirically rather than assumed.** First, what kubectl actually prints (above). Second, whether a probe can hang: a credential prompt appeared when I ran `kubectl` directly, which suggested `--check` could block on a misconfigured target. It cannot — `Sol_cli_process` already spawns children with **stdin on `/dev/null`**, so a prompt returns EOF immediately. The direct-shell experiment inherited my terminal's stdin and was not representative; I did not file the bug it appeared to show. A `timeout_s` of 15s was added anyway, since a network wait is a real hang and bounding it is free.

**Four new assertions, and the cheap one matters.** A unit test covers the redaction (reason present, context absent by default, `--context` placeholder shown, name visible under `--verbose`), and a new end-to-end rule runs the real binary against a context that does not exist: default output must say `unreachable` and must not contain the context; `--verbose` must. The kubectl-dependent assertion is guarded by `command -v kubectl`, so the rule stays meaningful where kubectl exists and harmless where it does not, rather than failing for the wrong reason.

**No demo change, per the convention's escape clause.** This changes the wording of an existing command's output, not a contract an app author writes against — no `sol.toml` field, primitive, CLI command or generated manifest changes.
