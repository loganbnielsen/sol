/**
 * Sol's metric naming/shape vocabulary. This module owns names and label
 * *values*, not measurement -- wire these into whatever Prometheus client
 * (prom-client or otherwise) the consumer already uses.
 *
 * Every constant here mirrors a specific OCaml source site exactly, so an
 * OCaml sol-worker/sol-svc and a TypeScript one land in the same Grafana
 * panel without disagreeing on label vocabulary:
 *   - framework/sol-worker/lib/worker.ml:84-89 (sol_worker_messages_total /
 *     sol_worker_message_duration_seconds, status labels at lines 99,150,
 *     144,and the retry path)
 *   - framework/kafka-eio-service/lib/kafka_service_intf.ml:96-102
 *     (sol_worker_decode_errors_total -- zero labels, a separate counter,
 *     not a "status" value on sol_worker_messages_total)
 *   - framework/sol-svc/lib/service.ml:216-227,256,274 (sol_svc_requests_total /
 *     sol_svc_request_duration_seconds, the "unmatched" route default at
 *     service.ml:113-114,256)
 */

// ---------------------------------------------------------------------------
// sol-worker

export const SOL_WORKER_MESSAGES_TOTAL = "sol_worker_messages_total";
export const SOL_WORKER_MESSAGE_DURATION_SECONDS = "sol_worker_message_duration_seconds";

/**
 * The full, exact status vocabulary for sol_worker_messages_total{status}.
 * Decode/validation failures are deliberately NOT a member of this type --
 * they never reach the handler and are never counted here at all (see
 * SOL_WORKER_DECODE_ERRORS_TOTAL below). FEAT-033's first draft invented
 * "decode_error"/"db_error" status values here; both were wrong for
 * different reasons -- decode errors belong on the separate counter, and a
 * downstream DB failure is exactly what the "retry" status is for.
 */
export type WorkerMessageStatus = "ok" | "error" | "retry" | "ack_failed";

export const SOL_WORKER_DECODE_ERRORS_TOTAL = "sol_worker_decode_errors_total";

// ---------------------------------------------------------------------------
// sol-svc

export const SOL_SVC_REQUESTS_TOTAL = "sol_svc_requests_total";
export const SOL_SVC_REQUEST_DURATION_SECONDS = "sol_svc_request_duration_seconds";

export type HttpMethod = "GET" | "POST" | "PUT" | "PATCH" | "DELETE" | "OTHER";

/** The fixed route label used for any request that never matched a route. */
export const UNMATCHED_ROUTE = "unmatched";

/**
 * Derive the method label exactly as service.ml does: the five named verbs,
 * or "OTHER" for anything else (service.ml:266-268).
 */
export function httpMethodLabel(method: string): HttpMethod {
  switch (method.toUpperCase()) {
    case "GET":
    case "POST":
    case "PUT":
    case "PATCH":
    case "DELETE":
      return method.toUpperCase() as HttpMethod;
    default:
      return "OTHER";
  }
}

/**
 * Derive the status_class label exactly as service.ml:274 does:
 * `string_of_int (status / 100) ^ "xx"` -- e.g. 200 -> "2xx", 404 -> "4xx".
 */
export function statusClassOf(statusCode: number): string {
  return `${Math.floor(statusCode / 100)}xx`;
}

/**
 * Derive the route label exactly as service.ml:113-114,256 does: the
 * matched route *pattern* (e.g. "/orders/:id"), or the fixed UNMATCHED_ROUTE
 * constant when no route matched. FEAT-033's first draft passed the raw,
 * caller-controlled request path here instead of a route pattern -- an
 * unbounded-cardinality bug in the Prometheus label set (every distinct URL
 * path, including ones an attacker can freely vary, becomes its own time
 * series). Never pass `req.path`/`req.url` to this function; only a
 * statically-known route pattern, or undefined/omitted for "no route
 * matched."
 */
export function routeLabel(matchedRoutePattern: string | undefined): string {
  return matchedRoutePattern ?? UNMATCHED_ROUTE;
}
