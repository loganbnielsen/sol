# Targeted ExternalSecret rotation audit — 2026-09-29

Audited synced `origin/main` `a99a09bd197936ebe8d97991968779c71516bc19`. BUG-093 is a new, independent high-severity finding. No implementation was made.

## Finding: `sol secret set` writes an ExternalSecret-owned target

`Sol_cli_manifest_yaml.external_secret_doc` (`cli/lib/workspace/sol_cli_manifest_yaml.ml:173-207`) names the generated target `<service>-secrets`, sets `creationPolicy: Owner`, and supplies a `refreshInterval` (default `1h` in `cmd_deploy.ml:522`). The GitOps tutorial tells operators that ESO supplies credentials through this path. `Sol_cli_secret.list_workload_secrets` (`cli/lib/deploy/sol_cli_secret.ml:194-206`) selects every Secret with the `-secrets` suffix in a namespace, with no owner check. `read_rotation` includes those objects, and `set` applies the new value to each then restarts all deployments and rollouts (`sol_cli_secret.ml:250-331`). `delete` also patches the same selected objects (`:350-380`). The command does not know which secret backend produced a live object.

Sequence: emit and apply an `ExternalSecret` for a workload; let ESO create its target Secret; run `sol secret set` for a key with a different value from the external store. Sol writes the live target and can report a verified restart. ESO's periodic reconciliation then writes the store value back to that Secret. The next pod start sees the old value; deleting a key is likewise temporary. ESO's [official lifecycle documentation](https://external-secrets.io/latest/guides/ownership-deletion-policy/) defines Owner creation and periodic synchronization of managed keys. This controller behavior is inferred from that documented contract; no live ESO cluster was available for a timed reconciliation reproduction.

This is distinct from backlog BUG-054: that ticket covers `sol deploy` and rollback overwriting values owned by `sol secret set` in the Kubernetes-live backend. Here `sol secret set` writes values owned by an ExternalSecret and falsely reports a durable rotation. The Kubernetes-live Secret is the positive control: it has no ExternalSecret owner and remains eligible for direct rotation.

## Other candidates checked

- `sol secret set` rewriting Kubernetes-live values on a later deploy is already BUG-054; no duplicate filed.
- A verified JWT without `exp` is an explicit `sol-svc` contract and was reviewed in DOCS-021; no ticket filed.
- The TypeScript demo's optional database path resembles the already recorded missing-credential failure in SEC-001 and BUG-054; no independent framework finding established.
