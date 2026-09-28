# GCP qualification Attempt 19 (2026-09-28) — the TLS path, end to end

## Summary

| | |
|---|---|
| revision | `352fd870` (`DEC-055`'s DNS-01 path, with per-provider literal ClusterIssuers) |
| target | fresh `qual19/gcp/us-central1`, cluster `sol-qual-gcp-19`, 4 × e2-standard-4, **`cluster_issuer: letsencrypt-staging`** declared |
| result | **the whole TLS path works**: Cloud DNS DNS-01 → challenges validated → platform certificates `Ready` → the ingress serves a hostname-matching certificate |
| platform apply | `ok (180.5s)`, lifecycle **`Ready`**, 80 pods `Running`, none `Pending` |
| identity | Workload Identity verified live: the pod impersonates a new GSA through a zone-scoped least-privilege role |
| finding | `FND-0067` → **`QUALIFIED`** (GCP half) |
| teardown | supported destroy from `Ready`, independently verified |
| bundle | `/tmp/sol-gcp-qual-19` (harness manifest plus a `ready-state/` capture) |

## 1. Identity and step log

| Field | Value |
|---|---|
| revision | `352fd870` (`harness.log` line 1) |
| target | `qual19/gcp/us-central1`, `sol-qual-gcp-19`, `cluster_issuer: letsencrypt-staging` — **the driver accepted it**, which the pre-`DEC-055` refusal would have prevented |
| preflight | clean: no clusters, no SQL instances, `SSD_TOTAL_GB 0/1000`, both durable prerequisites present |
| run credentials | poll 47: `RUNNING / credentials-established` (`05:32:37Z`) |
| cloud root | `terraform-apply ok (767.4s)` |
| platform prerequisites | `ok (45.6s)` |
| **platform apply** | **`ok (180.5s)`** |
| authority bracket | `provisioner-bootstrap-access-remove ok (6.3s)` |
| lifecycle | **`Ready`** |
| delegation | observed `05:43:05Z` |
| API readiness | 68 samples; every one after credential establishment carries the configured endpoint |

## 2. The TLS path, observed

**The issuers carry the provider-native solver**, with the project the GCP root owns:

```text
letsencrypt-prod	[{"dns01":{"cloudDNS":{"project":"sol-qualification"}}}]
letsencrypt-staging	[{"dns01":{"cloudDNS":{"project":"sol-qualification"}}}]
```

**The pod carries the identity**, which is what makes the solver able to write the zone:

```text
kubectl get sa -n cert-manager cert-manager -o jsonpath='{.metadata.annotations}'
{"iam.gke.io/gcp-service-account":"sol-qual-gcp-19-cert-manager@sol-qualification.iam.gserviceaccount.com", …}
```

**The challenges validated and the platform's certificates issued:**

```text
NAMESPACE    NAME                                      READY   SECRET        AGE
argocd       certificate.cert-manager.io/argocd-tls    True    argocd-tls    3m18s
monitoring   certificate.cert-manager.io/grafana-tls   True    grafana-tls   3m18s

NAMESPACE    NAME                                                 STATE   AGE
argocd       order.acme.cert-manager.io/argocd-tls-1-4259780645   valid   3m18s
monitoring   order.acme.cert-manager.io/grafana-tls-1-158463743   valid   3m18s
```

**And the ingress serves it** — verified independently, not inferred from `READY=True`: a TLS connection
with SNI set to each hostname, against the LoadBalancer's IP, returns a certificate whose subject and SAN
are that hostname, issued by the ACME **staging** CA, and the service answers over it.

```text
--- argocd.qual-gcp.sol-fab.dev
    subject=CN = argocd.qual-gcp.sol-fab.dev
    issuer=C = US, O = Let's Encrypt, CN = (STAGING) Dastardly Durum YR1
    X509v3 Subject Alternative Name: DNS:argocd.qual-gcp.sol-fab.dev
    HTTP: 307
--- grafana.qual-gcp.sol-fab.dev
    subject=CN = grafana.qual-gcp.sol-fab.dev
    issuer=C = US, O = Let's Encrypt, CN = (STAGING) Ersatz Emmer YR2
    X509v3 Subject Alternative Name: DNS:grafana.qual-gcp.sol-fab.dev
    HTTP: 302
```

## 3. The identity and permission model, as provisioned

The permissions were designed to be the minimum an ACME DNS-01 challenge needs, and the observed run is
the evidence that they are sufficient — nothing had to be widened:

```text
sol_sol_qual_gcp_19_cert_manager_dns_records       dns.changes.create;dns.changes.get;dns.changes.list;
                                                   dns.resourceRecordSets.create;dns.resourceRecordSets.delete;
                                                   dns.resourceRecordSets.get;dns.resourceRecordSets.list;
                                                   dns.resourceRecordSets.update
sol_sol_qual_gcp_19_cert_manager_dns_discovery     dns.managedZones.get;dns.managedZones.list
```

- the record role is bound **on the managed zone** `qual-gcp-sol-fab-dev`, not project-wide;
- the discovery role is bound at project level, because listing zones cannot be scoped to one;
- the service account's only other grant is `roles/iam.workloadIdentityUser` for
  `serviceAccount:sol-qualification.svc.id.goog[cert-manager/cert-manager]`.

## 4. Two observations, recorded not acted on

1. **Neither provider publishes the platform's ingress records.** No `google_dns_record_set` and no
   `aws_route53_record` exists in either root, so `argocd.<domain>` and `grafana.<domain>` have no A
   record unless an operator (or external-dns) creates one. What this run establishes is the *TLS* half —
   the certificate exists and the ingress serves it for that hostname — reached by connecting to the
   LoadBalancer IP with SNI. Name-to-address publication is a separate concern that Sol does not currently
   own, and it is not a defect discovered here: it is the *absence* of a feature, visible statically in
   both roots.
2. **This machine cannot resolve public DNS** (`dig @8.8.8.8 google.com` returns nothing), so DNSSEC-free
   name resolution could not be exercised from the run's own environment. The verification above was
   therefore done by SNI against the IP, which is the stronger of the two for the certificate claim and
   says nothing about resolution. Any future DNS-dependent row should either run where resolution works or
   say which half it checked.

## 5. Teardown

A supported `sol cloud destroy qual19/gcp/us-central1` from the `Ready` platform, with the authority
bracket used exactly once each way, and independent verification afterwards — cluster, SQL, network,
subnet, router, NAT, addresses, disks, Artifact Registry, service accounts, roles and bindings all absent,
quota back to zero, both durable prerequisites standing, no manual or emergency action.

## 6. Ledger

| Finding / row | Before | After |
|---|---|---|
| `FND-0067` | `FIXED_UNQUALIFIED` | **`QUALIFIED`** (GCP half) — the path is observed, and the DNS-01 challenge is what carried it |
| `INV-SUBSTRATE-1`'s ingress realization | unqualified | **qualified on GCP** by this run's evidence |
| `FND-0068` / `DEC-056` (`Ready` vs certificate state) | open | unchanged: this run's `Ready` again preceded the certificates by minutes, which is the same observation from the other side |
| application rows (`sol deploy`) | `NOT REACHED` | `NOT REACHED` — the next objective |
