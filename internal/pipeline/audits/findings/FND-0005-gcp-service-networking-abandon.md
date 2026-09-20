# FND-0005 — GCP service-networking destruction: documented contract vs live observation

- **Classification:** `QUALIFICATION_GAP`
- **State:** `ACCEPTED` — decided 2026-09-20: keep `ABANDON`, with the provider
  upgrade to `>= 8.1` (or an observed instance of the documented failure) as the
  trigger to revisit. Recorded as **`DEC-035`**
  (`internal/pipeline/tickets/DONE/DEC-035.md`), which also carries the four
  constraints that keep the choice defensible. Observed twice (Attempts 3 and 4);
  the documented contract is still not aligned, and no general upper bound is
  established — that residual is what `ACCEPTED` records.
- **First identified:** 2026-09-19 (GCP qualification Attempts 1–3)
- **Last verified:** 2026-09-19, `main @ 910a59f1` (reconciled after Attempt 4 / #363)
- **Provider:** GCP (Terraform `google` provider)
- **Derived ticket:** none
- **Related invariant:** `INV-DESTROY-3`, `INV-DESTROY-4`
- **Evidence:** `docs/qualification/gcp-bootstrap-inventory.md` §"The
  service-networking destruction failure", §"Attempt 2", §"Attempt 3", §"Attempt 4"

## Sol claim at stake

Sol destroys a GCP target, including the VPC peering created by the Cloud SQL
private-service connection, and verifies the target `Absent`. The implementation
uses `deletion_policy = "ABANDON"` on
`google_service_networking_connection.sql` (`cli/platform/infra/gcp/main.tf:230-235`)
with a comment asserting that what releases the peering is deleting the
*network*, which the same destroy does.

## Verified provider contract

From `terraform-provider-google`, `r/service_networking_connection`:

> "When set to `ABANDON`, the command will remove the resource from Terraform
> management without updating or deleting the resource in the API. The VPC
> peering created by the connection is left in place, which will block deletion
> of the network."
>
> "Setting `deletion_policy` to `"REMOVE_PEERING"` restores Terraform lifecycle
> completeness when a transitively created peering blocks deletion of the
> managed network. … Aim it at teardown of ephemeral networks or projects, not
> routine operations."

— https://raw.githubusercontent.com/hashicorp/terraform-provider-google/main/website/docs/r/service_networking_connection.html.markdown
(renders at https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_networking_connection)

Note: the externally supplied research packet cited
`service_networking_vpc_service_controls` and described ABANDON as "bypassing
VPC deletion locks". Both are wrong: that resource is the VPC-SC configuration
resource, and ABANDON *leaves* the peering rather than bypassing anything.

## What actually happened (observed)

- **Attempt 1.** Destroy could not remove the connection: "Unable to remove
  Service Networking Connection … Producer services … are still using this
  connection." A `time_sleep` was added on the theory that GCP needed a wait.
- **Attempt 2.** The five-minute `time_sleep` expired and the peering *still*
  refused, and still refused after twenty minutes of manual retries. The
  `time_sleep` was withdrawn as the wrong mechanism.
- **Workaround adopted.** `deletion_policy = "ABANDON"`, with
  `verify_gcp_destroy` independently asking the provider for the network **and**
  the peering (list) after destroy.
- **Attempt 3.** The destroy completed in 6m14s, exit 0; the connection's
  removal took 0s (abandoned, not deleted); the network was deleted and the API
  independently reported the peering absent.
- **Attempt 4.** The documented destroy completed the whole teardown, including a
  partially-installed platform, with no emergency cleanup. The inventory records
  "the peering abandonment worked again, and for the second time the peering and
  the network were confirmed absent through the provider's API rather than
  Terraform's exit status."

Attempt 4 also exposed a defect in the *verifier*, not in the abandonment: the
destroy removed everything and then reported failure because the absence check
recognised `NOT_FOUND`/`was not found` while gcloud answers `code=404 … Not found:`
and `HTTPError 404: … does not exist`. That is now fixed (`gcp_absence_message`
matches the provider's own wording, case-insensitively, and anything else stays a
verification failure), with the harness stub corrected to answer with gcloud's
real wording and mutation-tested. The fix matters here because it is what lets a
successful abandonment be *verified* as `Absent` rather than reported as a
failure.

## Separating the concepts (do not conflate)

| Concept | Status |
|---|---|
| Terraform abandoning management of the connection | happened (ABANDON), Attempts 3 and 4 |
| The peering existing immediately after abandonment | yes, by documentation |
| Subsequent VPC deletion succeeding | observed twice (Attempts 3, 4) |
| Provider-side disappearance of the peering | observed twice, by API list |
| Independent verification of `Absent` | yes — `verify_gcp_destroy`, whose absence recognition was repaired after Attempt 4 |

The finding is **not** "ABANDON deletes the peering". It is: the provider
documents that ABANDON leaves a peering that blocks network deletion, while two
live runs observed the network deleted and the peering gone. Both statements are
recorded; the contradiction is unresolved, and no general bound is established.

## What is established

The lifecycle reached network-absent and peering-absent on two independent runs,
verified by the provider API rather than by Terraform's exit status. Terraform no
longer confirms the peering is gone, so `verify_gcp_destroy` must — and does, now
recognising the wording gcloud actually emits.

## What is NOT established

- Whether network deletion removes the peering as a general GCP behaviour, or
  whether Attempts 3/4 were path-specific outcomes.
- Whether the documented `REMOVE_PEERING` policy would restore Terraform
  lifecycle completeness and is the more appropriate choice for ephemeral
  targets (the provider's own wording recommends it for exactly that case).
- Any upper bound on GCP's producer-reference release behaviour.

## Impact

A destroy that relies on under-documented behaviour (network-delete removes the
peering) may fail on a different project/region/API version and strand billable
resources. The independent verifier fails closed if it does, but only after the
attempt.

## Why no ticket

The behaviour has now been observed twice; changing ABANDON to `REMOVE_PEERING`
is a provider-mechanism improvement, not a demonstrated defect. Per the ticket
policy it belongs here as a qualification gap and a recommendation, not a ticket.

## To move to qualified

**Done, 2026-09-20.** The decision was taken with the provider wording and the
provider version as the primary inputs; `ABANDON` is kept and the residual
uncertainty is recorded as an accepted design choice rather than an open
qualification row. See `DEC-035` for the decision and its four constraints.

## Decision input (2026-09-20): the provider version gate

The open question above — "whether the documented `REMOVE_PEERING` policy … is the
more appropriate choice" — now has a decisive constraint. From
`terraform-provider-google`'s own CHANGELOG:

> ## 8.1.0 (September 1, 2026)
> * servicenetworking: added `REMOVE_PEERING` value to `deletion_policy` on
>   `google_service_networking_connection`, which removes the VPC peering when the
>   connection cannot be deleted because service producer resources still use it
>   ([#29036](https://github.com/hashicorp/terraform-provider-google/pull/29036))

Sol pins the provider at `google = { version = "~> 5.25" }`
(`cli/platform/infra/gcp/main.tf:20-24`), so `REMOVE_PEERING` **cannot be used at
the pinned version**. Adopting it is a 5.x → 8.x major upgrade of the Google
provider, which re-opens every other GCP resource in the root to re-verification —
a separate, larger change with its own qualification, not something to fold into a
destruction-behaviour decision.

The full documented semantics, verified from the resource page (same source as
above):

| Value | Documented effect |
|---|---|
| `DELETE` (default) | Deleting the resource is allowed. |
| `PREVENT` | `terraform destroy`/`apply` fails when it would delete the resource. |
| `ABANDON` | Removes the resource from Terraform management "without updating or deleting the resource in the API"; the VPC peering is left in place, "which will block deletion of the network". |
| `REMOVE_PEERING` | "The connection is deleted, and if the API refuses because service producer resources still use it, the VPC peering is removed from the network so that the network can be deleted." An "escape hatch, not equivalent to a fully successful `deleteConnection`. Aim it at teardown of ephemeral networks or projects, not routine operations." |

### Decision (ratified 2026-09-20): keep `ABANDON`, with the provider upgrade as the trigger

Ratified by the repository owner and recorded as `DEC-035`; the reasoning below is
the recommendation that was accepted.

1. `REMOVE_PEERING` is documented as the more complete mechanism and costs a major
   provider upgrade (above). It is not available to this code today.
2. What Sol does is not bare abandonment. The connection is abandoned, the network
   is deleted in the same destroy, and `verify_gcp_destroy` then asks the provider
   for the network **and** the peering. That compensation is what makes the choice
   defensible: the abandonment is checked by something that can see the abandoned
   object, and the documented failure ("will block deletion of the network") fails
   closed instead of stranding a billable resource silently.
3. `REMOVE_PEERING`'s documented precondition would be satisfiable later: the Cloud
   SQL instance `depends_on` the connection (`cli/platform/infra/gcp/main.tf:191`),
   so a destroy removes the instance before the connection — the doc's "only once
   every service instance reachable through the connection has already been
   deleted".

So record `ABANDON` as an **accepted design choice with a named trigger**, not an
open qualification row. Revisit it when the Google provider is upgraded to `>= 8.1`,
and revisit it immediately if any run observes the documented failure — the network
still present after the connection was abandoned, with the peering still listed.

Two things must not change while `ABANDON` stands: the post-destroy provider query
for the peering (it *is* the compensation), and the fail-closed absence recognition
(#363's `gcp_absence_message`), without which the compensation is blind.

## Supersession

The externally supplied research packet's ABANDON claim is `SUPERSEDED` by this
finding. The "one live observation" wording of the first version of this finding
is `SUPERSEDED` by the Attempt-4 evidence.
