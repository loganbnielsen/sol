# Hosted Account and Environment Model

This model is the experimental ownership boundary for Sol-hosted deployment. It
exists so hosted releases, secrets, diagnostics, and early billing all point at
the same customer-scoped runtime identity.

## Hierarchy

```
account/customer
  project/workspace
    environment
      single-tenant runtime substrate
```

The first hosted runtime is single-tenant per customer. Multi-tenant scheduling,
team membership, RBAC, hosted control-plane persistence, and real substrate
provisioning are intentionally outside this model.

## Objects

| Object | Purpose |
|---|---|
| `account` | Customer ownership and early billing readiness. |
| `project` | Hosted product record for a Sol workspace. |
| `environment` | Named deploy target such as `production` or `staging`. |
| `runtime_substrate` | Customer-scoped runtime target, initially Kubernetes. |
| `secret_scope` | Environment-scoped target for secret keys and values. |
| `release_target` | Account/project/environment/runtime context for a deployment plan. |
| `spend_guardrail` | Current account spend posture against cap and approval threshold. |
| `cost_attribution` | Provider resource cost record tied to account/project/environment/runtime. |
| `early_cost_plus_billing_record` | Billing-period cost-plus summary for early hosted adopters. |

## Early Billing Guardrails

Hosted environment creation requires an account with billing marked ready and a
spend cap. The model rejects creation when the account needs a payment method,
is billing-suspended, or has no spend cap. The environment record carries the
owning account id so later release, secret, resource, and cost records cannot be
attributed only by project name.

Accounts can also carry an approval threshold. Evaluating current spend produces
one of three statuses:

- `within_cap` continues with alerting only.
- `approval_required` requires manual approval before additional spend-heavy
  hosted changes.
- `cap_reached` blocks new hosted resources.

These statuses define product/control-plane behavior only. They do not contact a
payment processor or cloud billing API.

## Cost Attribution

The minimum reconciliation record is `cost_attribution`. Each record includes:

- account, project, environment, and runtime ids
- billing period
- provider and provider resource id
- resource kind
- observed provider cost in cents and currency
- small metadata pairs such as region or manual reconciliation source

This is enough to connect manually reconciled provider cost to a hosted
environment without implementing fine-grained per-service metering.

## Early Cost-Plus Billing

For private early adopters, Sol can aggregate provider costs for a billing
period and create an `early_cost_plus_billing_record`. The record stores provider
cost, markup in basis points, computed charge amount, currency, and review
status.

This is explicitly an early-adopter cost-plus model, not final Sol pricing. It
keeps early hosted billing understandable while real cost drivers are learned.
Polished invoices, automatic provider-cost ingestion, tiered pricing, and
payment-provider integration remain deferred.

## Deployment Plans

Hosted release submission should attach a `Sol_cli_deployment_plan.t` to a
`release_target`. The target check enforces:

- project workspace equals the deployment plan workspace
- hosted environment name equals the deployment plan environment name
- plan mode is `sol_hosted`
- account, project, environment, and runtime links are internally consistent

Deployment plans still contain application intent. The hosted model contains
ownership and runtime context.

## Hosted Executor Spike

`Sol_cli_hosted_executor` is an experimental boundary for future Sol-hosted
release submission. It accepts a hosted `release_target`, the deployment plan,
the serialized deployment-plan JSON artifact, and immutable image refs supplied
by customer CI.

The current implementation is a mock submission path only. It validates that
the plan is `sol_hosted`, that the serialized plan matches the request plan,
and that each service has an image ref. It returns Sol release-shaped data:
release id, environment id/name, mock status, service summaries, and a
read-only release inspection summary. See `docs/hosted/hosted-release-inspection.md`
for the release and diagnostics model.

This is not a supported production deploy mode. There is no hosted control
plane, account authentication, billing enforcement, managed runtime
provisioning, secret-value management, domain/TLS automation, or deployment
execution behind this spike.

## Deferred

- authentication and authorization
- account/team membership
- billing-provider integration
- automatic cloud-cost ingestion
- cloud resource provisioning
- hosted database/control-plane persistence
- polished invoices
- multi-tenant runtime placement
