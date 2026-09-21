---
id: INFRA-059
type: bug
severity: critical
title: Make `sol status` evidence-backed — an unreadable workload must be UNKNOWN, never HEALTHY
source: audit finding FND-0019 — DEC-038 §7
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0019-status-verdict-unsupported-by-evidence.md`
**Contract:** DEC-038 §7

## Problem

`sol status` prints `healthy` for a workload whose state it could not read. Live:
the same command as an identity with read access prints `DEGRADED` with the pod table
and `notify_worker rollout failed`; as an identity without read access it prints
`healthy`. The cause is in the model, not a branch:

```ocaml
let rollup_domain_status ~ns_exists (diagnoses : string option list) =
  if not ns_exists then Not_deployed
  else if List.exists (fun d -> d <> None) diagnoses then Degraded
  else Healthy
```

`diagnose_service_live`'s `string option` uses `None` for **both** "diagnosed, nothing
wrong" and "could not read", and the rollup reads the second as the first.

## Invariant

`HEALTHY` means *sufficient evidence was obtained and it indicates health*. It must
never mean *my reads produced nothing useful*.

| Verdict | Meaning |
|---|---|
| `HEALTHY` | sufficient evidence obtained; observed state satisfies the health contract |
| `DEGRADED` | sufficient evidence obtained; observed state violates it |
| `UNKNOWN` | required evidence could not be obtained — **reason surfaced** |

Authorization failure, authentication failure, API/read failure, timeout, and
malformed responses must never collapse into `HEALTHY`. They either prevent the
verdict (`UNKNOWN` with its reason) or narrow it to a partial diagnosis that states
what it could not see.

## Acceptance criteria

1. The three-valued verdict is **structural** — represented in the types, not
   special-cased for Kubernetes `Forbidden`.
2. The status path is audited for every other conversion of a failed/unavailable read
   into empty-or-absent data that could produce an unsupported verdict. At minimum
   `ns_exists` (`Error _ -> false`, rendering `NOT DEPLOYED` for an unreadable
   namespace) is in scope and is also fixed.
3. Regression coverage, all offline:
   - readable healthy workload → `HEALTHY`;
   - readable unhealthy workload → `DEGRADED`;
   - unreadable workload → `UNKNOWN`, carrying the reason;
   - zero observed objects after a **successful** read stays distinguishable from a
     failed read;
   - an unreadable namespace does not render as `NOT DEPLOYED`.
4. Each case is mutation-verified: reverting the distinction fails its test.
5. Live: the operator identity, once it can read `pluto-comms`, obtains the same
   degraded evidence the deploy identity obtained.

## Out of scope

Changing what the health contract itself considers healthy for a readable workload.
