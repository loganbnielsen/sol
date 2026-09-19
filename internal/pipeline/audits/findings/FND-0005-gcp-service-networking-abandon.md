# FND-0005 — GCP service-networking destruction: documented contract vs live observation

- **Classification:** `QUALIFICATION_GAP`
- **State:** `OPEN` (observed twice — Attempts 3 and 4; the documented contract is
  not aligned, and no general upper bound is established)
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

Decide ABANDON vs `REMOVE_PEERING` with the provider wording as the primary
input. If ABANDON is kept, record the two observations and the residual
uncertainty as an accepted design choice rather than an open qualification row.

## Supersession

The externally supplied research packet's ABANDON claim is `SUPERSEDED` by this
finding. The "one live observation" wording of the first version of this finding
is `SUPERSEDED` by the Attempt-4 evidence.
