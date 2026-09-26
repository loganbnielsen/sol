# FND-0028 — No lifecycle phase owns durable account prerequisites

- **Classification:** `DESIGN_GAP`
- **State:** `OPEN` — decision-gated by `DEC-043`; deliberately **not** implemented under
  `HARDEN-004`, whose scope is qualifying the GCP contract rather than changing it
- **First identified:** 2026-09-22 (HARDEN-004, Attempt 5 preparation)
- **Last verified:** 2026-09-22, `main @ b950b567`
- **Provider:** both — GCP has no implementation at all; AWS has one the operator must
  know about
- **Derived ticket:** none — `DEC-043` decides the stage that owns these prerequisites
- **Related:** `HARDEN-004`, `DEC-042`, `ADR 0002` (Sol owns the cloud-target
  lifecycle), `ADR 0003` (phases determine authority and desired-state policy),
  `cli/platform/infra/bootstrap/`, `internal/qualification/gcp/gcp-bootstrap-inventory.md`

## The gap

`sol cloud apply` cannot take a cloud from zero to usable, although the user-facing
contract reads as though it can: credentials + a target in, a usable cloud out.

Three observations, established while building the GCP attempt harness:

1. **`apply` refuses to run without a Terraform backend the operator must supply.**
   Verified: `sol cloud apply` exits with *"target must declare state_bucket before
   `sol cloud` can use durable state"*. The target has a `state_bucket` field, so the
   operator is expected to have one — and the repository provides no GCP path to
   create it.
2. **This is structural, not policy.** A Terraform root cannot create the backend that
   stores its own state, so *something* must always precede `apply`. The defect is not
   that a bootstrap step exists; it is that the step has no name and no
   provider-symmetric implementation.
3. **The durable/disposable boundary is therefore enforced by prose.** The one durable
   prerequisite Sol *does* create — the Cloud DNS zone for `qual-gcp.sol-fab.dev` — is
   created by the cloud root that otherwise owns only disposable infrastructure, which
   is why `DEC-042` had to argue explicitly that it must survive teardown. The state
   backend does not have that choice available to it: it necessarily preexists the root
   that stores into it.

## Evidence

| Observation | How it was established |
|---|---|
| `apply` requires `state_bucket` and fails closed without it | a `PLAN_ONLY` run of the GCP harness against the real CLI; the refusal is explicit and names the field |
| The repository has no GCP backend path | `cli/platform/infra/bootstrap/` is AWS-only: `provider "aws"`, `aws_s3_bucket`, `aws_dynamodb_table` |
| AWS's equivalent is an operator-known out-of-band root | the same directory, and `internal/qualification/aws/run8-aws-target.example.yml`, which instructs the operator to apply it by hand and then record the bucket in the untracked target |
| The prerequisite knowledge is not reproducible from the tree | attempts 1–4 evidently created the GCP state bucket outside the repository; nothing tracked creates or names it |
| Money-relevant checks were performed by hand, into a document | the GCP inventory's quota correction now carries the commands for billing, enabled APIs, quota limits and usage — knowledge in prose, which nothing executes and nothing verifies |
| A qualification target needs ~15 fields before Sol will plan | `internal/qualification/aws/run8-aws-target.example.yml` |

## What is established

- A durable-prerequisite stage is required in every provider, and its first member is
  the Terraform state backend.
- The provider asymmetry is real: one contract, one implementation.
- The lifetime distinction is not expressed anywhere in the lifecycle: durable
  prerequisites and disposable target infrastructure are currently owned by the same
  root in the one case where Sol creates both.
- The checks an operator must perform before spending money are a *document*, not a
  command.

## What is NOT established

- Whether `bootstrap` (and `preflight`) should be Sol lifecycle phases rather than
  provider-specific Terraform roots — that is `DEC-043`'s question, and it is a
  contract decision about what `apply` and `destroy` mean.
- Whether any provider needs prerequisites beyond the backend at bootstrap time
  (provider enablement, account-level IAM) or whether those belong to the target's
  apply.
- That a `decommission`-style operation is needed at all. Deliberately out of scope:
  no evidence establishes the requirement, and such a command would have to contend
  with state it cannot clean up — the registrar NS records behind a delegation — and
  possibly the only copy of the state that describes everything else.

## Impact

Every fresh project pays it: a new qualification project, and every customer
onboarding, requires an operator who already knows an undocumented step. A
qualification attempt cannot be reproduced from repository artefacts alone, and the
durable/disposable boundary is enforced by whoever happens to be operating rather than
by the lifecycle.

## To move to `FIXED_QUALIFIED`

`DEC-043` decides which stage owns which prerequisite; the chosen shape is implemented
for every provider with the durable-lifetime constraint honoured (a target `destroy`
provably cannot remove a durable prerequisite, with a test); and a fresh project plus
supplied credentials and identity can reach a planned target using **tracked
repository artefacts only**.

## Supersession

None.
