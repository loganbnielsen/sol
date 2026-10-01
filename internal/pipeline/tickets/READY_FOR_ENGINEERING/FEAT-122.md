---
id: FEAT-122
type: feature
severity: high
title: Hand the operator the durable root's identity contracts, so an installation completes without a checkout or Terraform knowledge
source: DOCS-026 reconnaissance (2026-10-01), with AUDIT-072 and docs/DEVELOPER_EXPERIENCE.md §4.1
---

**Depends on:** None.

**Related:** `AUDIT-072` (the IAM policy contract is Sol's; the role lifecycle is
deliberately the operator's — reaffirmed here, not revisited), `INFRA-096` (the
installation stage and its inspectable resolved configuration), `FEAT-106` (the inline
first run this makes completable), `DOCS-026` (the on-ramp page this unblocks),
`DEC-057` §1/§4, `DEC-030` (the deploy-identity question, still open), and
`platform/cloud/{aws,gcp}/bootstrap/outputs.tf`.

## What this is

The durable installation has four identity prerequisites — provisioning,
cluster-access, deploy, operator — and Sol deliberately does not create the roles:
it generates the **policy contract** and the operator creates the role from it
(`AUDIT-072`; `docs/deployment/production-bootstrap.md` §2). Today Sol keeps that
contract to itself. It exists only as a Terraform output of the durable root
(`provisioner_policy_json`, `cluster_access_policy_json`, `deploy_policy_json`,
`operator_policy_json`), and nothing in the CLI surfaces it: the installation report
says `Unmet: An error occurred (NoSuchEntity) …` and stops there.

That is the step an operator who does not already know the machinery cannot take. It
was found while preparing the first-deploy guide (`DOCS-026`), whose audience is a
capable backend developer with *no Terraform knowledge and no source checkout*: the
guide can reach neither the contract nor a supported way to create the role. The
release bundle does ship the durable root
(`share/sol/<version>/platform/cloud/aws/bootstrap`), so no checkout is required —
but reading a Terraform root's outputs and creating roles from them is exactly the
Terraform knowledge the on-ramp is supposed to remove.

**Evidence (2026-10-01, `origin/main` `438267c9`).** The contracts are declared as
outputs and never consumed by the CLI:

```text
$ rg -n 'policy_json' cli/
(no matches)

$ rg -n 'provisioner_policy_json|cluster_access_policy_json|deploy_policy_json|operator_policy_json' \
    platform/cloud/aws/bootstrap/outputs.tf
33:output "provisioner_policy_json" {
39:output "cluster_access_policy_json" {
45:output "deploy_policy_json" {
56:output "operator_policy_json" {
```

The declaration the other half of the contract depends on is already resolved: the
role *name* Sol will look for comes from the declared ARN
(`Sol_cli_provider_capabilities.aws` derives it), and the identifier the operator must
declare back is that ARN. So Sol has both halves — the contract and the exact name —
and prints neither.

## Remediation

- **Surface the contracts where the operator is already looking.** When an identity
  prerequisite is reported not `Established`, the installation report names, per
  identity: the role name Sol reads from the declaration, the ARN field the operator
  must set, and the generated policy contract — written to a file whose path is
  printed, rather than only described (the contracts are multi-statement policy
  documents, not one-line facts).
- **Get them from the owner of the contract.** The contracts are read from the
  durable root's own Terraform outputs, not re-derived in OCaml, so there is exactly
  one definition of each policy. `INFRA-096`'s `install`/`reconcile` path already runs
  the root and reads its outputs, so this adds no new Terraform invocation and no new
  provider privilege.
- **Say when they are not available yet.** The state backend is the one prerequisite
  that must exist before the root can run, so a report against an unapplied root
  cannot have the contracts: say that plainly, name the command that produces them
  (`sol cloud bootstrap <target> --apply`), and never present an unavailable contract
  as an empty or absent one.
- **Do not invent authority.** This surfaces a contract; it does not create, attach or
  verify a role (`AUDIT-072`), and it must not derive an authority grant or an
  accountability declaration from anything Sol inferred.
- **Provider-symmetric.** The contract set is per-provider data behind
  `Sol_cli_provider_capabilities` (GCP's durable root declares no identities, so its
  set is empty and the installation report says the same thing it does today), rather
  than an AWS shape copied over.
- **Reach the operator in both places.** The explicit administrative path
  (`sol cloud bootstrap <target>`) and the inline first run (`FEAT-106`) must show the
  same thing; a user who reaches production through `sol deploy` must not have to
  discover a second command to find out which policy to attach.

## Non-goals

- Not creating, attaching, rotating or deleting roles. `AUDIT-072` stands: Sol owns
  the policy contract, the operator owns the role lifecycle.
- Not changing where the identities live or what they may do.
- Not resolving `DEC-030` (fresh-machine authentication for operating an
  environment).
- Not a hosted secrets or identity service.

## Acceptance criteria

- For a target whose identities are not established, the installation report names,
  per identity, the role name Sol resolves from the declaration, the ARN field the
  operator declares, and the path of the generated policy contract.
- The contracts are read from the durable root's outputs, and a test fails if the CLI
  ever derives a policy document itself.
- A report against a root that has not been applied says the contracts are not
  available yet and names the command that produces them — never an empty or silently
  missing contract.
- The same output appears on the explicit path (`sol cloud bootstrap <target>`) and on
  the inline first run (`sol deploy <target>`).
- A provider with no durable identities (GCP) reports no contract section rather than
  an empty one.
- No role is created, attached or modified by this change.

**Demo/example coverage:** the first-run flow is the on-ramp, so
`examples/pluto/README.md`'s installation section and `docs/DEVELOPER_EXPERIENCE.md`
§4.1/§4.2 must show the contracts step, and `DOCS-026` documents it as the page's one
cloud-account action.

**TypeScript parity:** No language-parity impact — this is an operator-facing
installation surface, and no application-facing contract changes.

## Notes

- Filed from the `DOCS-026` reconnaissance, which found that the guide could not be
  written for its stated audience while the contracts stayed inside Terraform. The
  preference order the ticket keeps: make the product's own step do the work before
  documenting around it.
- If the contracts are surfaced but creating the roles still requires provider
  knowledge the audience does not have, that is a second finding about the identity
  step itself, not a reason to widen this one.
