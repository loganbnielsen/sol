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
