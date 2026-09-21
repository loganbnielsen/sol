# FND-0019 — `sol status` reports an unsupported verdict: an unreadable workload is called healthy

**Classification:** `VERIFIED_DEFECT` · **State:** `QUALIFIED` (2026-09-21) · **Severity:** critical
**Ticket:** `INFRA-059` · **Contract:** DEC-038 §7 (clarified 2026-09-21)
**Derived from:** FND-0017's first live verification · **Evidence:** `BEHAVIORAL`

## The defect

`sol status` prints **`healthy`** for a workload whose state it could not read at
all. Live, against the preserved Run 8 target, the same command under two
identities:

| Identity | Can read `pluto-comms`? | `sol status comms/notify_worker` |
|---|---|---|
| deploy | **yes** | **`DEGRADED`** + the pod table + `notify_worker rollout failed` |
| operator | **no** | **`healthy`** — no pod table, no rollout line |

The operator's own authorizer agrees it cannot look:

```
kubectl --context sol-qual5-operator auth can-i list pods -n pluto-comms  ->  no
```

The facts were available and unambiguous to the identity that could see them:
the Deployment reports `2 desired / 1 ready`, one replica is `0/1 Running`, and
Sol's own diagnostic path rendered `notify_worker rollout failed`.

## The model-level cause

This is not a bad branch in the Kubernetes path. The status model conflates
**absence** with **inability to observe**, and the conflation is in the type:

```ocaml
type domain_status = Healthy | Degraded | Not_deployed

let rollup_domain_status ~ns_exists (diagnoses : string option list) =
  if not ns_exists then Not_deployed
  else if List.exists (fun d -> d <> None) diagnoses then Degraded
  else Healthy
```

`diagnose_service_live` returns `string option`, and `None` carries **both**
meanings: "diagnosed, nothing wrong" and "could not read the workload". The rollup
then reads the second as the first, so an unreadable workload becomes `Healthy`.
A documented "healthy" must mean *evidence obtained and it indicates health*, not
*my reads returned nothing useful*.

## The audit this prompted

The same collapse has now been found twice — `events: Forbidden → []` (FND-0017,
fixed) and an unreadable workload → `healthy` (here). Two is not a coincidence; it
is the model. Auditing the status path for other failed-read-to-verdict
conversions found one more:

- **`ns_exists`** returns `false` on `Error _`, so a namespace that exists but
  cannot be read — a permissions failure, an API error — renders as
  **`NOT DEPLOYED`**. Same class, same unsupported verdict.

## The invariant (DEC-038 §7)

```
HEALTHY   sufficient evidence obtained, and observed state satisfies the contract
DEGRADED  sufficient evidence obtained, and observed state violates the contract
UNKNOWN   required evidence could not be obtained -- reason surfaced
```

An authorization failure, authentication failure, API/read failure, timeout or
malformed response must never collapse into `HEALTHY`. Depending on which evidence
is missing they either prevent the verdict (`UNKNOWN`, with the reason) or narrow
the diagnosis to a partial one that says what it could not see. A successful read
that returns zero objects stays distinguishable from a read that failed — the
FND-0017 rule, now applied to the verdict itself.

**Why this is the highest-severity item in the chain:** `healthy` is the verdict an
operator acts on. Every other issue here degrades or delays a diagnosis; this one
actively asserts safety it did not verify, and it does so precisely in the failure
conditions — degraded authorization, an API hiccup — where an operator most needs
the truth.

## What would make it qualified

Regression coverage for each row of the model — readable-healthy → `HEALTHY`,
readable-unhealthy → `DEGRADED`, unreadable → `UNKNOWN` with its reason, and
zero-objects-after-a-successful-read distinct from a failed read — plus live
evidence that the operator identity, once it can read the namespace, obtains the
same degraded evidence the deploy identity did.

## Resolution (2026-09-21)

The verdict is now `Healthy | Unhealthy of string | Undetermined of string`, every
fetch carries its reason, and the rollup takes an observed namespace presence rather
than a boolean. The audit's other instances are fixed in the same change:
`format_cronjob_diagnosis`'s `Unavailable -> None` (a failed read was health — and a
*test* asserted it), `ns_exists`'s `Error _ -> false` (an unreadable namespace was
NOT DEPLOYED), and a `filter_map` that let an unresolvable service vanish from the
rollup.

Live: the operator identity, which previously produced `healthy` from an unreadable
namespace, now produces the same `DEGRADED` verdict the correctly authenticated
identity produced — with the events on top.

The regression that matters is mutation-verified: restoring the collapse (an
`Undetermined` verdict rolling up to `Healthy`) fails
`an unreadable workload is Unknown, never Healthy`.

The invariant this finding asked for is now structural rather than defensive:
`HEALTHY` cannot be produced by a read that did not happen, because the type no
longer has a value that means both.

### Process deviation (recorded, 2026-09-21)

The audit's own instruction was *artifacts, then regression tests, then the product
change*. The artifacts came first, but the code changes for this finding and for
FND-0018 were made before their tests. The deviation is recorded rather than
remediated: the coverage is present and mutation-verified (the collapse restored fails
`an unreadable workload is Unknown, never Healthy`), so what is missing is ordering
discipline, not evidence. It is worth recording because the one guard test that *was*
written first found a real gap in the guard itself — a substring match that let a
renamed call pass — which is the argument for the ordering.
