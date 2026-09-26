---
id: INFRA-060
type: feature
severity: medium
title: Establish a qualification-only transport capability for private application services
source: audit finding FND-0020 — DEC-039
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0020-qualification-transport-gap.md`
**Contract:** DEC-039

## Goal

Give live qualification a way to drive a transaction against an application's
private `ClusterIP` service, **without** adding any verb to the production
identities and without the capability becoming part of ordinary customer
infrastructure.

## Acceptance criteria

1. A qualification-only group (`sol:qualifiers`) and IAM principal exist, granting
   **only**: `pods`/`services` `get`/`list` (addressing) and `pods/portforward`
   `create` (transport). No mutating verb, no `pods/exec`, no `pods/log`, no
   `events`, no `secrets`.
2. It is established by `internal/qualification/transport/`, which no
   production Terraform root references and `sol cloud apply` never applies. No
   target field names the qualifier principal.
3. `internal/ci/check_qualification_transport.sh` asserts both directions — the
   production roots never reference the qualifier group, and the manifest carries
   no verb beyond the permitted set — with a mutation case for each, so the guard
   is demonstrably falsifiable.
4. The qualification procedure documents that the record must name the transport
   identity separately from the identities whose contracts are under test.
5. Live: a transaction reaches an application service through this capability, and
   the production identities' permissions are unchanged afterwards (the operator's
   effective surface still excludes `pods/portforward`).

## Out of scope

Any change to provisioner, publisher, deploy or operator; any ingress exposure of
application services to production.
