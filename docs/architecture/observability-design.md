# Observability architecture

Sol makes application telemetry usable in the infrastructure it deploys. The
application contract and first-party framework emit stable workspace, domain,
service, primitive, and release identity; the platform configures collection and
storage for the selected backend. Users retain the operational interface of
that backend.

Sol is responsible for the telemetry wiring needed by a working application and
for validating declared alert-delivery requirements during deployment
preflight. It does not provide routine commands for querying logs, opening
Grafana views, or inspecting service health after deployment. Use Grafana,
Loki, Prometheus, Kubernetes, and provider tooling for those tasks.

## Identity

Workload manifests and runtime configuration share the same bounded application
identity: workspace, environment where applicable, domain, service, primitive,
and release. Collectors may add infrastructure facts such as namespace, pod,
node, or region; they do not replace the application identity.

The release identifies an immutable application state. It is useful for
correlating a deployment with telemetry, but it is not a metrics label, because
that would create an unbounded time-series dimension. Deployment-attempt records
and their consumers are tracked separately; this page does not define or remove
that history contract.

## Platform responsibilities

The platform may install Grafana, Loki, Prometheus, Tempo, alerting rules, and
collectors as declared deployment dependencies. Their APIs and interfaces remain
authoritative for query, visualization, and incident response. Sol verifies the
postconditions of operations it initiates; removing an observation wrapper does
not remove deployment readiness checks, rollout diagnostics, alert declaration
validation, or destructive absence verification.

The supported backend configuration is documented in
[Observability backends](../deployment/observability-backends.md). Alert
ownership and first-response procedures are in
[Production alert runbooks](../deployment/alert-runbooks.md).
