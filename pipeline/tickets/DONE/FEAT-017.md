---
id: FEAT-017
type: feature
severity: high
source: DEC-005
branch: FEAT-017/hosted-default-url-custom-domains
worktree: ../sun-FEAT-017-hosted-default-url-custom-domains
---

Add hosted default URLs and custom-domain flow.

**Depends on:** DEC-005, FEAT-010, FEAT-016.

**Problem:** A hosted user must be able to deploy a first HTTP service and open a
working URL immediately. Custom domains are important, but requiring DNS setup
before first value would make onboarding too slow.

**Goal:** Provide instant Sun-managed default URLs for hosted HTTP services and
define the customer-managed DNS flow for custom domains.

**Remediation:**

1. Define the default hosted URL shape for service/environment/workspace identity.
2. Include default URLs in hosted release responses for `-svc` workloads.
3. Define custom-domain ownership verification using customer-managed DNS.
4. Define the DNS records Sun will ask users to create.
5. Define where TLS certificate issuance/renewal is owned.
6. Document default URLs versus custom domains.
7. Add tests for URL generation and service summary output.

**Out of scope:**

- Sun acting as a general-purpose DNS provider.
- Domain registrar integrations.
- Full custom-domain UI.
- Multi-region routing.
- Customer DNS automation.

**Acceptance criteria:**

- A hosted `-svc` release can report a reachable Sun-managed default URL.
- Custom domains use customer-managed DNS with explicit verification records.
- Sun owns TLS issuance/renewal after verification.
- First deploy does not require a custom domain.
- The design does not leak DNS setup into local or customer-cloud paths.
