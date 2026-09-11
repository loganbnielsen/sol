---
id: CODEX_STYLE_AUDIT-028
type: refactor
severity: medium
source: style audit
branch: CODEX_STYLE_AUDIT-028/kafka-service-http-request-record
worktree: /home/lbendtly/Code/sun
---

Replace Kafka service HTTP option pairs with a request record.

**Depends on:** none.

**Problem:** `integrations/kafka/kafka-eio-service/lib/kafka_service_http.ml:55`
passes `~meth ~base_url ~path ~content_type_opt ~body_opt` through the HTTP
client. `content_type_opt` and `body_opt` must move together for POST/PUT, but
the type permits mismatched states.

**Goal:** Model Kafka admin/schema-registry HTTP requests as typed records or
variants.

**Acceptance criteria:**

- Introduce a request type that distinguishes GET without body from methods with
  body and content type.
- Update `http_get`, `http_post`, and `http_put` to construct that type.
- Keep timeout and TLS behavior unchanged.

## Review — automated checks passed
CODEX_STYLE_AUDIT-028 passes review. Kafka_service_http now uses a typed request variant: GET requests carry no body/content type, while POST and PUT requests carry a body_request with both content_type and body together. The existing http_get/http_post/http_put caller APIs remain stable, and timeout plus TLS setup paths are unchanged. Focused kafka service tests and the full suite passed; an initial e2e timing outlier did not reproduce on isolated/full rerun.
