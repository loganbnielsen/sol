# Hosted Default URLs and Custom Domains

## Overview

Every hosted Sol `-svc` service gets a Sol-managed default URL immediately after the first successful deploy. No DNS configuration is required before the first deploy.

Custom domains are also supported. After deploying with a default URL, a user can point any domain they control to the same service by adding two DNS records and waiting for Sol to issue a TLS certificate.

This document describes:

- The default URL scheme and when it applies
- How to add a custom domain
- What DNS records to create
- Where TLS issuance is owned

---

## Default URLs

### Shape

```
<service>.<workspace>.<environment>.apps.<base_domain>
```

Each component is normalised to a DNS-safe label (lowercase, underscores → hyphens, other non-alphanumeric characters stripped).

**Examples:**

| Service | Workspace | Environment | Default URL |
|---------|-----------|-------------|-------------|
| `charge-svc` | `pluto` | `production` | `charge-svc.pluto.production.apps.sol.dev` |
| `notify_svc` | `My_Workspace` | `staging` | `notify-svc.my-workspace.staging.apps.sol.dev` |

### When it applies

Default URLs are generated for **`-svc` workloads only**. `-worker` and `-fn` primitives do not have default URLs because they do not serve HTTP traffic.

The URL is included in the hosted release response:

```json
{
  "services": [
    {
      "service_name": "charge-svc",
      "primitive": "svc",
      "default_url": "charge-svc.pluto.production.apps.sol.dev",
      ...
    },
    {
      "service_name": "notify-worker",
      "primitive": "worker"
    }
  ]
}
```

### TLS

Sol manages a wildcard TLS certificate for `*.apps.<base_domain>` via cert-manager and Let's Encrypt. Default URLs are HTTPS immediately after deploy.

---

## Custom Domains

A custom domain allows users to serve traffic through a domain they control (e.g. `api.acme.com`) rather than the Sol-managed default URL.

### Flow

1. Deploy your service. Note the default URL from the release response.
2. Create two DNS records (see below) at your DNS provider.
3. Sol detects the TXT verification record and issues a TLS certificate for your domain via cert-manager + Let's Encrypt.
4. Traffic to your custom domain is routed to the service.

Steps 2–4 are configuration; no `sol` CLI command is required to initiate the process.

### DNS records to create

Create both records at your DNS provider:

| Record | Name | Value | TTL |
|--------|------|-------|-----|
| CNAME  | `<your-domain>` | `<default_url>` | 300 |
| TXT    | `_sol-verify.<your-domain>` | `sol-verify=<verification_token>` | 300 |

**Example** (custom domain `api.acme.com`, service default URL `charge-svc.pluto.production.apps.sol.dev`):

| Record | Name | Value |
|--------|------|-------|
| CNAME  | `api.acme.com` | `charge-svc.pluto.production.apps.sol.dev` |
| TXT    | `_sol-verify.api.acme.com` | `sol-verify=<token-from-control-plane>` |

The verification token is issued by the Sol control plane and tied to your account + domain. It proves you control both the domain and the Sol account.

### TLS for custom domains

Sol owns TLS issuance and renewal for custom domains after ownership verification. The certificate is issued via Let's Encrypt DNS-01 challenge using the TXT record above. Sol renews it automatically before expiration.

Users must keep the TXT verification record in place for as long as they want Sol to renew the certificate. Removing the TXT record will cause renewal to fail.

---

## What does not leak between paths

The default URL and custom domain model applies **only to hosted deploys** (`sol cloud deploy`). The local dev path (`sol local up` / `sol up`) and the customer-cloud path (`sol deploy`) are unaffected:

- `sol up` against a local k3d cluster uses NodePort services and `kubectl port-forward` for local access.
- `sol deploy` for customer-cloud produces Kubernetes manifests that the customer controls; they manage DNS, TLS, and ingress themselves.

No DNS setup is required or expected in local or customer-cloud paths.

---

## Out of scope

- Sol acting as a general-purpose DNS provider (Sol does not manage DNS zones for customer domains)
- Domain registrar integrations
- Multi-region routing for custom domains
- Customer DNS automation
- A full custom-domain management UI (beyond reading the TXT/CNAME records to add)
