val render_spec :
  workspace:string ->
  ?env:string ->
  ?image:string ->
  ?secret_backend:Sol_cli_manifest.secret_backend ->
  Sol_cli_deployment_plan.service_spec ->
  (string * string, string) result
(** Render a [(namespace_yaml, workload_yaml)] pair from a resolved
    [service_spec]. [workspace] plus the spec's [domain]/[primitive] populate
    the OBS-008 label taxonomy. Pass [~env] (the resolved deployment
    environment, e.g. ["prod"]) to add the [env] label — omit it for deploys
    with no resolved target (e.g. [sol up]). Returns
    [Ok (ns_yaml, workload_yaml)] on success. Returns [Error msg] when
    [secret_backend = Kubernetes_live] and one or more user-declared secret env
    vars (from [spec.secrets]) are absent from the process environment. All
    deployment identity fields (namespace, k8s name, image, primitive, config,
    secrets, schedule, replicas, cpu, memory) come from the spec. Pass [~image]
    to override [spec.image] - used by [sol up] where the dry-run display image
    ([localhost:5000]) differs from the cluster image. Pass [~secret_backend] to
    control how secret manifests are emitted:
    - [Kubernetes_live] (default): emit a Secret with values read from the
      environment (sol up / direct deploy); fails if any user-declared secret
      key is unset;
    - [Kubernetes_placeholder]: emit a redacted Secret with empty stringData
      (GitOps);
    - [External_secrets _]: emit an ExternalSecret CRD for the External Secrets
      Operator. *)
