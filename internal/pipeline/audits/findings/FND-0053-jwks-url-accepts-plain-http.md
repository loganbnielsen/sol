# FND-0053 — A `Jwks_url` with `http://` is fetched in plaintext, and tokens are verified against whatever keys it returns

- **Classification:** `VERIFIED_DEFECT`
- **State:** `OPEN`
- **First identified:** 2026-09-24, correctness audit pass 2
- **Last verified:** 2026-09-24 (`origin/main @ fd5c7e0c`)
- **Derived ticket:** `SEC-009`
- **Invariant:** `framework/ocaml/sol-svc/lib/auth.mli:16-18` — *"`Jwks_url`: HTTPS URL
  of a JWKS endpoint. Fetched over TLS"*
- **Evidence class:** `BEHAVIORAL`

## What is established

Nothing checks the scheme. `fetch_jwks_over_https` calls `Https_eio.request`, whose
`https_for_uri` returns `Ok None`, meaning plain HTTP, for any non-`https` URI
(https-eio `https_eio.ml`). The keys that come back are then trusted to verify
signatures.

Reproduced through `Test_auth_internal.validate` with the real
`fetch_jwks_over_https`, a plain-HTTP server serving the test JWKS, and
`Jwks_url "http://127.0.0.1:18101/jwks.json"`:

```
PROBE http:// JWKS: token VERIFIED with keys fetched over plaintext HTTP
```

## Impact

Medium. It needs a misconfiguration, such as a typo or an internal IdP served over
HTTP. With it, anyone on the network path can substitute the verification keys and
mint tokens the service accepts. Sol's own docs promise that cannot happen, so nothing
warns the author.

## Remedy shape

`Service.Make.run` refuses a route (or `metrics_auth`) whose `Jwks_url` is not an
absolute `https://` URL with a host, returning a `` `Config `` error at startup, like
`PORT` and the API key. Test: an `http://` `Jwks_url` does not start; `https://` does.
