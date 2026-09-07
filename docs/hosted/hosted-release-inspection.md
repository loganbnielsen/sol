# Hosted Release Inspection and Diagnostics

Sol-hosted release inspection is a Sol-native view over a hosted release. It
shows application-level facts first and keeps infrastructure details behind a
read-only diagnostics surface.

This is intentionally not an Argo CD or Kubernetes API. Hosted users should be
able to answer "what changed?", "what is rolling out?", and "why did it fail?"
without operating the hosted control plane.

## Default Release View

The default view is `Sol_cli_release_inspection.release_summary`. It contains:

- release id
- environment id and name
- release status
- submitted deployment-plan summary
- immutable image refs supplied by CI
- affected services
- rollout status per service
- health status per service
- optional failure reason per service

The deployment-plan summary is intentionally compact: workspace, environment,
mode, image tag, service count, topic count, and migration count. It is enough
to compare releases without exposing every rendered manifest by default.

Secret values are not part of release inspection. Plans and inspection summaries
carry secret keys and references only.

## Advanced Diagnostics

The advanced diagnostics view is
`Sol_cli_release_inspection.diagnostics`. It can include:

- rendered manifests
- reconciliation events
- rollout resource names
- Kubernetes event summaries
- raw failure details

Diagnostics are read-only facts. They are suitable for debugging and support,
but they do not expose direct Argo CD access, Kubernetes credentials, or write
operations.

## Hosted Executor Integration

`Sol_cli_hosted_executor.submit_mock` now returns a release with an embedded
inspection summary. The mock still performs no network I/O and does not deploy
anything. It validates the hosted request, confirms image refs for every
service, and returns release-shaped data that can be inspected by a future
hosted API.

## Customer-Cloud Path

Customer-cloud users can still inspect generated manifests through GitOps emit
paths. `Sol_cli_release_inspection.rendered_manifests_of_plan` provides the same
read-only manifest facts from a deployment plan, so customer-cloud tooling can
show what Sol emitted without requiring hosted control-plane concepts.

## Non-Goals

- Direct Argo CD access for hosted users.
- Direct Kubernetes write access for hosted users.
- A web UI.
- Long-term release analytics.
