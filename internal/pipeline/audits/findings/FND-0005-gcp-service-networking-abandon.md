# FND-0005 — GCP service-networking destruction: documented contract vs one live observation

- **Classification:** `QUALIFICATION_GAP`
- **State:** `OPEN` (one live observation; documented contract not aligned, upper bound unestablished)
- **First identified:** 2026-09-19 (GCP qualification Attempts 1–3)
- **Last verified:** 2026-09-19, `main @ 7ea2ef43`
- **Provider:** GCP (Terraform `google` provider)
- **Derived ticket:** none
- **Related invariant:** `INV-DESTROY-3`, `INV-DESTROY-4`
- **Evidence:** `docs/qualification/gcp-bootstrap-inventory.md` §"The
  service-networking destruction failure", §"Attempt 2", §"Attempt 3"

## Sol claim at stake

Sol destroys a GCP target, including the VPC peering created by the Cloud SQL
private-service connection, and verifies the target Absent. The implementation
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
  the peering (list) after destroy (`cmd_cloud_tf.ml:409-506`).
- **Attempt 3.** The destroy completed in 6m14s, exit 0; the connection's
  removal took 0s (abandoned, not deleted); the network was deleted and the API
  independently reported the peering absent.

## Separating the concepts (do not conflate)

| Concept | Status |
|---|---|
| Terraform abandoning management of the connection | happened (ABANDON) |
| The peering existing immediately after abandonment | yes, by documentation |
| Subsequent VPC deletion succeeding | observed once (Attempt 3) |
| Provider-side disappearance of the peering | observed once, by API list |
| Independent verification of `Absent` | yes, `verify_gcp_destroy` |

The finding is **not** "ABANDON deletes the peering". It is: the provider
documents that ABANDON leaves a peering that blocks network deletion, while one
live run observed the network deleted and the peering gone. Both statements are
recorded; the contradiction is unresolved.

## What is established

The lifecycle reached network-absent and peering-absent once, verified by the
provider API rather than by Terraform's exit status. Terraform no longer
confirms the peering is gone, so `verify_gcp_destroy` must — and does.

## What is NOT established

- Whether network deletion removes the peering as a general GCP behaviour, or
  whether Attempt 3 was a path-specific outcome.
- Whether the documented `REMOVE_PEERING` policy would restore Terraform
  lifecycle completeness and is the more appropriate choice for ephemeral
  targets (the provider's own wording recommends it for exactly that case).
- Any upper bound on GCP's producer-reference release behaviour.

## Impact

A destroy that relies on undocumented behaviour (network-delete removes the
peering) may fail on a different project/region/API version and strand billable
resources. The independent verifier fails closed if it does, but only after the
attempt.

## Why no ticket

The behaviour was verified once; changing ABANDON to REMOVE_PEERING is a
provider-mechanism improvement, not a demonstrated defect. Per the ticket policy
it belongs here as a qualification gap and a recommendation, not a ticket. The
GCP agent owns the live re-observation.

## To move to qualified

Repeat the destroy and record network-absent + peering-absent; and decide
ABANDON vs `REMOVE_PEERING` with the provider wording as the primary input.

## Supersession

The externally supplied research packet's ABANDON claim is `SUPERSEDED` by this
finding.
