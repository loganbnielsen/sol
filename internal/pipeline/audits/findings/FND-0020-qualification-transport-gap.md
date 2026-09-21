# FND-0020 — the qualification procedure assumes a transport capability no identity provides

**Classification:** `QUALIFICATION_GAP` · **State:** `OPEN` · **Severity:** medium
**Ticket:** `INFRA-060` · **Contract:** DEC-039 · **Evidence:** `BEHAVIORAL`

## The gap

Run 8 §B B3 drives a transaction against an application's private `ClusterIP`
service. Measured live, no principal can reach one:

- `cluster-access` is cluster-admin **inside platform namespaces** (`*.* [*]` in
  `redpanda`/`monitoring`) and has **no access at all** in application namespaces;
- `deploy` and `operator` hold read-only grants there, with no `pods/portforward`
  and no `pods/exec`;
- the provisioner has no EKS access entry at all;
- the cluster administrator (SSO) is `Unauthorized` on the cluster, so it cannot
  stand in.

The application services are `ClusterIP` with no ingress path.

## Why it is a gap in the procedure rather than a product defect

The platform's refusal is **correct and deliberate**: no production identity should
be able to tunnel into arbitrary application pods, and DEC-038 §4 excludes
port-forward from the operator on exactly that reasoning. The defect is that B3 —
and by extension any row that needs to drive a private service — does not say how
the harness obtains connectivity, so the procedure's assumptions and the platform's
identity model disagree in a way that only shows up at execution time.

The wrong resolutions, recorded so they are not adopted later:

- granting `pods/portforward` to `operator` or `deploy`;
- adding a qualifier ARN to the target schema, which would put qualification
  scaffolding into the customer-facing contract;
- a `ClusterRoleBinding` in a production root.

## Resolution

DEC-039: a qualification-only capability (`sol:qualifiers`), granting only the
addressing reads and `pods/portforward`, established by the harness and never by
`sol cloud apply`; plus the evidence rule that the record names the transport
identity separately from the identities under qualification.

## What would make it qualified

The transport established out-of-band, B3 executed through it, and the run record
showing the identity split explicitly. Also worth checking at that point: whether
B3's own text should require the documented downstream effect rather than broker
progress (DEC-039 §5).
