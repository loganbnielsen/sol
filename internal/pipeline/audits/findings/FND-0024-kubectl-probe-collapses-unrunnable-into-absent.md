# FND-0024 — `Sol_cli_kubectl.probe` reports an unreadable cluster as `false`, so `sol logs`/`sol fn run` say "not deployed"

- **Classification:** `VERIFIED_DEFECT`
- **State:** `FIXED_UNQUALIFIED` — fixed by `INFRA-063` (2026-09-22): `probe`'s bool is
  replaced by a three-state `presence` (`Present | Absent reason | Uncheckable why`),
  and the two callers (`sol logs`, `sol fn run`) report "could not check" with the
  reason instead of asserting the workload is not deployed. Verified by a hermetic
  unit test; a real unreachable cluster is what would make it `QUALIFIED`.
- **First identified:** 2026-09-21, fail-open audit (`2026-09-21_fail-open-audit.md`)
- **Last verified:** 2026-09-21 (`main` @ `4ae985f3`)
- **Derived ticket:** `INFRA-063`
- **Evidence class:** `STATIC` (code paths); the unit reproduction named below would
  make it `MECHANISM`.

## What is established

`Sol_cli_kubectl` exposes two probes:

- `probe_result` (`sol_cli_kubectl.ml:115-123`) keeps the distinction — `Error`
  means kubectl could not be run at all, `Ok (exit_code, reason)` means it ran;
- `probe` (`sol_cli_kubectl.ml:126-131`) collapses both into a `bool`:

  ```ocaml
  let probe ~ctx ~args =
    match probe_result ~ctx ~args with
    | Ok (0, _) -> true
    | Ok _ | Error _ -> false
  ```

  So `false` means *either* "kubectl ran and said no" *or* "kubectl could not be
  run" (no kubeconfig, context unreachable, binary absent).

Two callers read that `false` as a definite negative:

- `cmd_fn.ml:97-102` — `if not (probe ...) then` prints
  `-fn <domain>/<name> is not deployed in namespace <ns>` and exits 1.
- `cmd_logs.ml:44-50` — `workload_exists` returns `probe ...`, and the caller
  reports the workload as not found.

`cmd_target.ml:55,77` already uses `probe_result` and comments on exactly this
distinction ("keeps what kubectl said, so the reason is …"), so the fix shape is
present in the tree.

## Why it is the fail-open class

A cluster that cannot be reached is reported to the operator as a definite "not
deployed". The command fails (exit 1), so this is not a false success — it is the
**indeterminate-collapsed-to-negative** half of the class, the same shape as
FND-0017 ("a denied read is shown as no events"): the operator is told a fact
about the world that was never established.

## Impact

Misleading diagnosis on the two commands an operator reaches for when something
is wrong. An operator debugging a deploy on a machine with the wrong kubeconfig
is told the workload does not exist, and pointed at `sol status` — which will
report `UNKNOWN` for the same reason. Low severity (the command stops), but it is
the exact diagnostic path FND-0017 exists to harden.

## Not established

- Not observed live; no run has been recorded hitting this path.
- Whether every other `probe` caller in the tree (only the two above are
  production callers) has the same reading — the tree-wide grep is in the audit
  report.

## Reproduction (unit-level, for the ticket)

Call `Sol_cli_kubectl.probe ~ctx` with a destination whose `kubectl` invocation
cannot run (the existing test doubles already model a runner) and assert the
result is not distinguishable from a genuine non-zero exit — i.e. that today's
`probe` cannot express the third state.

## Related

`INFRA-056` / FND-0017 (diagnosis and the operator identity); DEC-040 (the
tri-state pattern this should adopt); `sol_cli_status.ml:36-63` (`ns_presence`,
the fix shape already landed for status).
