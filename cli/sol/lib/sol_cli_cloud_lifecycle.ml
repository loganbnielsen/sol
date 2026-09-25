(* Remote state for one root. A backend's *type* is part of a Terraform root's own
   configuration -- `-backend-config` sets attributes, never the type -- so each
   provider's roots declare their own backend and this supplies the attributes
   that root expects. The two are therefore not the same shape:

     * S3 addresses an object by `key` and needs a separate lock resource
       (`dynamodb_table`), because S3 has no native locking.
     * GCS addresses an object by `prefix` and locks natively, so there is no lock
       resource to name. A GCP target that declares a `state_lock_table` is not
       wrong -- the field is simply not what serializes applies there.

   What Sol actually requires of a target is the same for both, and is the one
   declaration checked here: the durable, encrypted, versioned bucket. *)
let backend_config (target : Sol_cli_config.target) ~root =
  let layer =
    match root with
    | `Cloud -> "cloud"
    | `Platform -> "platform"
  in
  let object_key = Printf.sprintf "sol/%s/%s.tfstate" target.name layer in
  match target.state_bucket with
  | Some bucket when String.trim bucket <> "" ->
    (Sol_cli_provider_capabilities.capabilities_of target.provider).backend_config
      target
      ~bucket:(String.trim bucket)
      ~object_key
  | _ -> Error "target must declare state_bucket before `sol cloud` can use durable state"
;;

(* The provider-neutral facts a cloud lifecycle operation needs from a target,
   plus the backend config each provider's roots expect. Provider-specific
   *identity* is deliberately absent: an AWS target names a role ARN because that
   is how an AWS caller assumes the provisioner, while a GCP target names nothing
   because the caller impersonates a service account through short-lived
   credentials instead. Making both carry a role-shaped field would invent a
   concept GCP does not have. *)
type cloud_target =
  { target : Sol_cli_config.target
  ; cloud_backend : string list
  ; platform_backend : string list
  ; base_domain : string
  ; letsencrypt_email : string
  ; cluster_access_role_arn : string option
  }

let required name = function
  | Some value when String.trim value <> "" -> Ok (String.trim value)
  | _ -> Error ("the cloud lifecycle requires target." ^ name)
;;

let cloud_target target =
  let ( let* ) = Result.bind in
  let* cloud_backend = backend_config target ~root:`Cloud in
  let* platform_backend = backend_config target ~root:`Platform in
  let* base_domain = required "base_domain" target.Sol_cli_config.base_domain in
  let* letsencrypt_email = required "letsencrypt_email" target.letsencrypt_email in
  let* cluster_access_role_arn =
    (Sol_cli_provider_capabilities.capabilities_of target.provider)
      .cluster_access_role_arn
      target
  in
  Ok
    { target
    ; cloud_backend
    ; platform_backend
    ; base_domain
    ; letsencrypt_email
    ; cluster_access_role_arn
    }
;;

(* The platform root, relative to the Sol home. The platform *definition* is
   shared (`cli/platform/infra/base`); the root differs per provider because a
   Terraform root's backend type is part of its own configuration -- so `base`
   declares the S3 backend and is AWS's root, while `base-gcp` declares the GCS
   backend and uses `base` as the shared definition. *)
let platform_root provider =
  (Sol_cli_provider_capabilities.capabilities_of provider).platform_root
;;

(* A resource address inside the platform root. A provider whose root reaches the
   shared definition through a module addresses its resources through it, so the
   provider prefix lives next to [platform_root] rather than at each `-target`. *)
let platform_address provider address =
  (Sol_cli_provider_capabilities.capabilities_of provider).platform_address address
;;

let target config = config.target
let cloud_backend config = config.cloud_backend
let platform_backend config = config.platform_backend

type platform_inputs =
  { base_domain : string
  ; letsencrypt_email : string
  ; region : string
  ; cluster_issuer : string option
  ; observability_backend : string option
  ; alert_receiver_type : string option
  ; alert_receiver_url : string option
  ; alert_owner : string option
  ; alert_runbook_url : string option
  ; cluster : Sol_cli_cluster.t
  }

let platform_inputs (target : cloud_target) (cluster : Sol_cli_cluster.t) =
  (* The cloud root reports the identity the platform root will act as; the
     target's declaration is what authorized it, so the cluster checks one against
     the other. Providers without a role-shaped identity have nothing to compare. *)
  match
    cluster.check_identity ~cluster_access_role_arn:target.cluster_access_role_arn
  with
  | Error _ as refused -> refused
  | Ok () ->
    Ok
      { base_domain = target.base_domain
      ; letsencrypt_email = target.letsencrypt_email
      ; region = target.target.region
      ; cluster_issuer = target.target.cluster_issuer
      ; observability_backend = target.target.observability_backend
      ; alert_receiver_type = target.target.alert_receiver_type
      ; alert_receiver_url = target.target.alert_receiver_url
      ; alert_owner = target.target.alert_owner
      ; alert_runbook_url = target.target.alert_runbook_url
      ; cluster
      }
;;

(* The platform definition's variables for one provider's target. Fallible,
   because a target can ask for a capability the provider's root cannot wire yet,
   and the honest answer there is a refusal naming the gap rather than a variable
   set that silently omits it.

   What is shared is genuinely shared -- the domain, the ACME contact, and the
   fact that a cloud database means no in-cluster Postgres. What differs is the
   provider's own inputs: AWS passes the region and the IRSA roles and buckets its
   definition branch reads, GCP passes its GCS buckets and Workload Identity
   service accounts. Neither set is emitted for the other provider, because a
   variable a provider's root does not declare is an error rather than a no-op. *)
(* Whether these variables are being computed to INSTALL the platform or to REMOVE
   it. It matters because some of what this function checks is a capability guarantee
   for installation -- "if you ask for this, the platform must be able to deliver it"
   -- and a destruction is not an installation.

   FND-0029: evaluating an install-time guarantee while destroying a target that was
   already created made the only supported destruction path refuse a target that
   `apply` had accepted, which stranded billable infrastructure until the declaration
   was edited by hand. ADR 0003 invariant 6 makes destruction an abort edge available
   from every phase; a creation-time requirement must not be what closes that edge.
   Install-time validation stays exactly as strict. *)
(* Whether these variables are being computed to INSTALL the platform or to REMOVE
   it. It matters because some of what this function checks is a capability guarantee
   for installation -- "if you ask for this, the platform must be able to deliver it"
   -- and a destruction is not an installation.

   FND-0029: evaluating an install-time guarantee while destroying a target that was
   already created made the only supported destruction path refuse a target that
   `apply` had accepted, which stranded billable infrastructure until the declaration
   was edited by hand. ADR 0003 invariant 6 makes destruction an abort edge available
   from every phase; a creation-time requirement must not be what closes that edge.
   Install-time validation stays exactly as strict. *)
(* What happens to destruction when a preparation fails.

   A preparation is not one kind of thing. Most of it is best-effort: it lowers a deletion
   guard or reconciles a setting so that destruction can proceed, and if it fails the honest
   response is to say so and attempt the destruction anyway, because destruction is an abort
   edge available from every phase (ADR 0003 invariant 6) and the destroy's own error is the
   accurate signal.

   Some of it is a destruction precondition. An AWS target that declares
   `destroy_retention: final-snapshot` is promised that its recovery data survives the
   destroy; if the preparation that sets that up fails, proceeding would silently discard
   the data the target asked to keep (DEC-033). That must block.

   The preparation declares which it is, so the destruction path carries no list of
   provider-and-feature exceptions that grows every time a new guarantee appears. That is
   also the honest reading of the invariant: destruction remains available from a half-built
   target UNLESS proceeding would violate an explicit destruction-time safety guarantee that
   the target itself declared. *)
type failure_policy =
  | Continue_to_destroy
  | Block_destroy

(* [Prepared] carries whatever the caller needs from a successful preparation -- the AWS
   final-snapshot identifier, [()] where there is nothing to carry. *)
type 'a preparation_outcome =
  | Nothing_to_prepare
  | Prepared of 'a
  | Preparation_failed of
      { reason : string
      ; policy : failure_policy
      }

(* The reason to report, for a failure of either policy: a failure that permits destruction
   must still be visible in the result rather than swallowed by it. *)
let preparation_failure = function
  | Nothing_to_prepare | Prepared _ -> None
  | Preparation_failed { reason; _ } -> Some reason
;;

(* [Some reason] only when destruction must not proceed. Nothing else blocks. *)
let destruction_blocked = function
  | Nothing_to_prepare | Prepared _ -> None
  | Preparation_failed { policy = Continue_to_destroy; _ } -> None
  | Preparation_failed { reason; policy = Block_destroy } -> Some reason
;;

(* Which resources a DESTRUCTIVE preparation may target.

   The preparation lowers deletion guards so that destruction can proceed, and it does so
   with `terraform apply -target=<address>`. Terraform's targeted apply *creates* a target
   that is in the configuration but absent from state -- so preparing a resource the target
   does not have makes the destroy path the thing that creates it, which is the opposite of
   its purpose. Attempt 6 hit exactly that: the cluster existed in the provider, was absent
   from state, and the preparation failed with `409 Already exists` while trying to create
   the cluster it had been asked to remove (FND-0030).

   So eligibility is `configuration INTERSECT state`. A resource absent from state is not a
   resource to prepare, and for a half-built target the eligible set is empty.

   What this does NOT do, on its own: bound what Terraform plans. `-target` includes
   everything the target depends on, so a targeted apply can still plan to create an
   unrepresented network or private-IP range; and a targeted apply reconciles the WHOLE
   resource against configuration, so drift on a ForceNew attribute plans a replacement,
   which creates on the destroy path. The intersection bounds what may be targeted; the
   guarantee that nothing is created has to be asserted on the plan itself, before applying
   it (FND-0030). *)
let preparations_eligible ~state ~desired =
  List.filter (fun address -> List.mem address state) desired
;;

(* The addresses the target's configuration declares and its state does not hold. These are
   the ones a destroy cannot reach: Terraform destroys what its state knows about, so a
   resource in this set may still exist in the provider after a successful destroy -- and
   still be billable. Reporting them is the minimum: staying quiet turns a loud failure into
   a quiet one (FND-0030). *)
let preparations_unrepresented ~state ~desired =
  List.filter (fun address -> not (List.mem address state)) desired
;;

type platform_vars_context = Sol_cli_cluster.platform_vars_context =
  | Install
  | Destruction

let platform_terraform_vars ?(context = Install) inputs =
  let add_opt key value vars =
    match value with
    | None -> vars
    | Some value -> (key ^ "=" ^ value) :: vars
  in
  let optional vars =
    vars
    |> add_opt "cluster_issuer" inputs.cluster_issuer
    |> add_opt "observability_backend" inputs.observability_backend
    |> add_opt "alert_receiver_type" inputs.alert_receiver_type
    |> add_opt "alert_receiver_url" inputs.alert_receiver_url
    |> add_opt "alert_owner" inputs.alert_owner
    |> add_opt "alert_runbook_url" inputs.alert_runbook_url
  in
  let shared =
    [ "base_domain=" ^ inputs.base_domain
    ; "letsencrypt_email=" ^ inputs.letsencrypt_email
    ; "install_postgresql=false"
    ]
  in
  Result.map
    (fun { Sol_cli_cluster.fixed; optional = provider_optional } ->
       List.fold_left
         (fun vars (key, value) -> add_opt key value vars)
         (optional (shared @ fixed))
         provider_optional)
    (inputs.cluster.platform_vars
       context
       ~cluster_issuer:inputs.cluster_issuer
       ~region:inputs.region)
;;

type plan_phase =
  | Plannable
  | Deferred of string

(* [rbac_established] is a plan-only prerequisite: establishing the provisioner's
   steady-state RBAC requires an apply, and plan must not mutate to unlock its own
   later phases, so a cluster without it defers both platform phases (ADR 0002).
   [crds_established] only matters once RBAC makes the prerequisites plannable. *)
let platform_plan_phases ~cluster_exists ~rbac_established ~crds_established =
  let requires_cloud = "requires cloud substrate to exist" in
  let requires_rbac =
    "requires provisioner platform RBAC established by an earlier apply"
  in
  if not cluster_exists
  then Deferred requires_cloud, Deferred requires_cloud
  else if not rbac_established
  then Deferred requires_rbac, Deferred requires_rbac
  else if not crds_established
  then Plannable, Deferred "requires cert-manager CRDs to be Established"
  else Plannable, Plannable
;;

type authorization =
  | Required
  | Forbidden

let provisioner_authorization_checks =
  [ Required, [ "create"; "deployments.apps"; "-n"; "monitoring" ]
  ; Required, [ "create"; "services"; "-n"; "ingress-nginx" ]
  ; Required, [ "create"; "customresourcedefinitions.apiextensions.k8s.io" ]
  ; Required, [ "create"; "storageclasses.storage.k8s.io" ]
  ; Required, [ "create"; "clusterissuers.cert-manager.io" ]
  ; Required, [ "create"; "namespaces" ]
  ; Forbidden, [ "create"; "deployments.apps"; "-n"; "default" ]
  ; Forbidden, [ "create"; "services"; "-n"; "default" ]
  ; Forbidden, [ "create"; "jobs.batch"; "-n"; "default" ]
  ; Forbidden, [ "create"; "secrets"; "-n"; "default" ]
  ; Forbidden, [ "bind"; "clusterroles.rbac.authorization.k8s.io" ]
  ; Forbidden, [ "escalate"; "clusterroles.rbac.authorization.k8s.io" ]
  ]
;;

let provisioner_authorization_established ~can_i =
  List.for_all
    (fun (expected, args) ->
       match expected with
       | Required -> can_i args
       | Forbidden -> not (can_i args))
    provisioner_authorization_checks
;;

type readiness =
  | Established
  | Unmet of string

(* Readiness: is the platform converged? ------------------------------------
   [Ready] is what licenses `PlatformInstalling -> Ready` (ADR 0003), so it
   asserts that the platform reached its defined operational state according to
   authoritative Kubernetes state. Two things it deliberately does NOT do, both
   learned from a real target:

   * It does not probe the platform across the network. The five checks that read
     service endpoints through the API server's `/proxy/` path needed a route this
     platform never creates — the EKS module admits the control plane to nodes
     only on the admission-webhook ports — so a fully converged platform reported
     `Unmet`. Whether a capability *works* is HARDEN's question, and HARDEN
     answers it with behaviour (a known log reaches Loki and can be queried), not
     with a route.
   * It does not require an external ACME round trip. A ClusterIssuer's only
     condition is `Ready`, and for an ACME issuer cert-manager sets it only after
     registering with the external CA, so an unreachable Let's Encrypt would make
     a converged platform "not ready". Real issuance is qualified in HARDEN.

   What is left is convergence: Kubernetes' own statement about its own objects.
   Workloads are read per kind because kinds differ in what they declare — a
   DaemonSet's desired count is derived from the node set, so zero means nothing
   matched, while a StatefulSet's replicas are declared by its owner. *)
type readiness_check =
  { name : string
  ; reason : string
  ; accept : string -> bool
  ; argv : string list
  }

let check ?(accept = fun _ -> true) name reason argv = { name; reason; accept; argv }

(* Deployments state their own availability through their own condition. *)
let available_deployments namespace =
  [ "wait"
  ; "--for=condition=Available"
  ; "deployment"
  ; "--all"
  ; "-n"
  ; namespace
  ; "--timeout=5s"
  ]
;;

(* DaemonSets and StatefulSets have no condition [kubectl wait] understands, so
   convergence comes from status, as ready/desired pairs. *)
let converged_workload ~kind ~namespace ~ready_field ~desired_field =
  [ "get"
  ; kind
  ; "-n"
  ; namespace
  ; "-o"
  ; Printf.sprintf
      "jsonpath={range .items[*]}{.%s}/{.%s}{' '}{end}"
      ready_field
      desired_field
  ]
;;

let converged_daemonsets namespace =
  converged_workload
    ~kind:"daemonset"
    ~namespace
    ~ready_field:"status.numberReady"
    ~desired_field:"status.desiredNumberScheduled"
;;

let converged_statefulsets namespace =
  converged_workload
    ~kind:"statefulset"
    ~namespace
    ~ready_field:"status.readyReplicas"
    ~desired_field:"status.replicas"
;;

let bound_pvcs namespace =
  [ "get"
  ; "pvc"
  ; "-n"
  ; namespace
  ; "-o"
  ; "jsonpath={range .items[*]}{.status.phase}{' '}{end}"
  ]
;;

let ready_nodes =
  [ "get"
  ; "nodes"
  ; "-o"
  ; "jsonpath={range .items[*]}{.status.conditions[?(@.type==\"Ready\")].status}{' \
     '}{end}"
  ]
;;

(* Every workload reports as many ready replicas as it declares. An empty result
   is never "converged": it means there was nothing to look at, so a query that
   matched nothing would otherwise pass silently. [require_desired] additionally
   rejects a desired count of zero — right for DaemonSets, where zero means the
   node set matched nothing, and wrong for StatefulSets, where a declared zero is
   its owner's choice. *)
let replicas_converged ?(require_desired = true) output =
  let pairs =
    String.split_on_char ' ' (String.trim output) |> List.filter (fun part -> part <> "")
  in
  pairs <> []
  && List.for_all
       (fun pair ->
          match String.split_on_char '/' pair with
          | [ ready; desired ] ->
            (match int_of_string_opt ready, int_of_string_opt desired with
             | Some ready, Some desired ->
               ready = desired && (desired > 0 || not require_desired)
             | None, _ | _, None -> false)
          | _ -> false)
       pairs
;;

let daemonsets_converged output = replicas_converged output
let statefulsets_converged output = replicas_converged ~require_desired:false output

(* Every volume is Bound, and there is at least one to look at. *)
let all_pvcs_bound output =
  let phases =
    String.split_on_char ' ' (String.trim output) |> List.filter (fun part -> part <> "")
  in
  phases <> [] && List.for_all (fun phase -> phase = "Bound") phases
;;

let all_nodes_ready output =
  let states =
    String.split_on_char ' ' (String.trim output) |> List.filter (fun part -> part <> "")
  in
  states <> [] && List.for_all (fun state -> state = "True") states
;;

(* ── The target's Kubernetes storage contract ────────────────────────────────

   The platform's durable components -- Redpanda's log, Loki's chunks, the
   Prometheus TSDB, Tempo's blocks -- bind PersistentVolumeClaims against the
   cluster's *default* StorageClass, because that is what an unqualified claim
   resolves to. The platform therefore depends on two facts that are the cloud
   provider's, not Sol's: which block-storage CSI driver backs the cluster, and
   which class is the one default.

   They differ in kind between providers, and the difference is real rather than
   cosmetic: EKS ships no default StorageClass at all, so Sol creates one (`gp3`,
   `ebs.csi.aws.com`); GKE ships `standard-rwo` (`pd.csi.storage.gke.io`) already
   annotated as the default, so Sol *adopts* it -- creating a second default class
   would leave the cluster with two, which Kubernetes accepts with a warning and
   then resolves arbitrarily.

   What is provider-neutral is the assertion, so it is expressed once against
   this table: the provider's class exists, is the *only* default, and is
   provided by the provider's block-storage CSI driver. Naming the class in the
   table keeps the assertion as strong as it was when it was spelled out for AWS:
   a cluster whose default is some unrelated class backed by the same driver
   still fails, because the platform's volumes are then not on the class Sol
   established. *)
type platform_storage = Sol_cli_provider_capabilities.platform_storage =
  { storage_class : string
  ; csi_driver : string
  }

let platform_storage provider =
  (Sol_cli_provider_capabilities.capabilities_of provider).platform_storage
;;

(* `name|provisioner|is-default` per StorageClass, then space-separated. A CSI
   StorageClass's `provisioner` is the driver's registered name -- that is the
   contract, not a naming convention -- so one field of the table covers both.

   Assembled rather than written as one literal so the jsonpath is on one logical
   line: a `\`-newline inside a string literal is elided by the lexer, which makes
   the printed argv depend on where the formatter chose to wrap. *)
let storage_class_entries =
  let jsonpath =
    "jsonpath={range .items[*]}"
    ^ "{.metadata.name}{'|'}{.provisioner}{'|'}"
    ^ "{.metadata.annotations.storageclass\\.kubernetes\\.io/is-default-class}"
    ^ "{' '}{end}"
  in
  [ "get"; "storageclass"; "-o"; jsonpath ]
;;

let sole_default_storage_class ~storage_class ~csi_driver output =
  let fields entry = String.split_on_char '|' entry in
  let is_default entry =
    match fields entry with
    | [ _; _; "true" ] -> true
    | _ -> false
  in
  match String.split_on_char ' ' (String.trim output) |> List.filter is_default with
  | [ entry ] ->
    (match fields entry with
     | [ name; provisioner; _ ] -> name = storage_class && provisioner = csi_driver
     | _ -> false)
  | [] | _ :: _ :: _ -> false
;;

let storage_checks provider =
  let { storage_class; csi_driver } = platform_storage provider in
  [ check
      ~accept:(sole_default_storage_class ~storage_class ~csi_driver)
      "default StorageClass"
      (Printf.sprintf
         "%s is absent, is not the only default StorageClass, or is not provided by %s"
         storage_class
         csi_driver)
      storage_class_entries
  ; check
      "block-storage CSI driver"
      (Printf.sprintf "the %s block-storage CSI driver is not registered" csi_driver)
      [ "get"; "csidriver/" ^ csi_driver ]
  ]
;;

(* Parameterised by provider only: the checks still depend on neither the
   observability backend nor the configured issuer. Those were once
   backend-shaped distinctions inside a gate whose only job is to state "the
   platform converged", and the namespace-wide workload checks hold for whatever
   a backend installed. *)
let readiness_checks ~provider =
  let before_storage =
    [ check
        "cert-manager CRDs"
        "required cert-manager CRDs are not Established"
        [ "wait"
        ; "--for=condition=Established"
        ; "crd/certificates.cert-manager.io"
        ; "crd/clusterissuers.cert-manager.io"
        ; "--timeout=5s"
        ]
    ; check
        "cert-manager controllers"
        "cert-manager controller, webhook, or cainjector is unavailable"
        (available_deployments "cert-manager")
    ; check ~accept:all_nodes_ready "nodes" "a cluster node is not Ready" ready_nodes
    ]
  in
  before_storage
  @ storage_checks provider
  @ [ (* Monitoring is checked namespace-wide: the assertion is "everything
       installed here has converged", which holds for whatever the configured
       observability backend installs and needs no per-chart list to drift. *)
      check
        "monitoring deployments"
        "a monitoring deployment is not available"
        (available_deployments "monitoring")
    ; check
        ~accept:statefulsets_converged
        "monitoring statefulsets"
        "a monitoring statefulset does not have every declared replica ready"
        (converged_statefulsets "monitoring")
    ; check
        ~accept:daemonsets_converged
        "monitoring daemonsets"
        "a monitoring daemonset does not have every scheduled pod ready"
        (converged_daemonsets "monitoring")
    ; check
        ~accept:all_pvcs_bound
        "monitoring PVCs"
        "a monitoring PersistentVolumeClaim is not Bound"
        (bound_pvcs "monitoring")
    ; (* The one behavioural check kept in [Ready]. Redpanda is the platform's own
       broker, so this is the platform's own health API rather than a third
       party's, it needs no route beyond the API server -> kubelet path that
       `kubectl exec` already uses, and "the brokers agree they are healthy" is
       what makes the data plane operable rather than merely scheduled. *)
      check
        "Redpanda"
        "Redpanda broker-native cluster health is not healthy"
        [ "exec"
        ; "-n"
        ; "redpanda"
        ; "statefulset/redpanda"
        ; "--"
        ; "rpk"
        ; "cluster"
        ; "health"
        ; "--exit-when-healthy"
        ; "--watch=false"
        ]
    ; check
        ~accept:statefulsets_converged
        "Redpanda statefulset"
        "the Redpanda statefulset does not have every declared replica ready"
        (converged_statefulsets "redpanda")
    ; check
        ~accept:all_pvcs_bound
        "Redpanda PVCs"
        "a Redpanda PersistentVolumeClaim is not Bound"
        (bound_pvcs "redpanda")
    ; check
        "ingress-nginx"
        "ingress-nginx controller is unavailable"
        (available_deployments "ingress-nginx")
    ; check
        ~accept:(fun output -> output <> "")
        "ingress endpoint"
        "ingress-nginx LoadBalancer has no assigned endpoint"
        [ "get"
        ; "service/ingress-nginx-controller"
        ; "-n"
        ; "ingress-nginx"
        ; "-o"
        ; "jsonpath={.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}"
        ]
    ; check
        "Argo CD"
        "an Argo CD controller is unavailable"
        (available_deployments "argocd")
    ]
;;

(* Run every readiness check and report the ones that are not established. A check
   is established only when its invocation succeeds *and* its output satisfies
   [accept]: a command that exits zero while saying nothing useful is not
   evidence. *)
let readiness ~provider ~run =
  List.map
    (fun check ->
       ( check.name
       , match run check.argv with
         | Some output when check.accept (String.trim output) -> Established
         | _ -> Unmet check.reason ))
    (readiness_checks ~provider)
;;

(* The kubectl invocations the checks above run, exposed so CI can validate them
   against a real kubectl. Nothing calls this in production — it exists because
   the invocations are otherwise only reachable through [readiness], which needs
   a live cluster, so an argv kubectl rejects could ship unnoticed.

   Per provider, because the storage assertion is provider-specific: CI
   validates every provider's set, so a new one cannot ship an invocation nobody
   checked. *)
let readiness_invocations ~provider =
  List.map (fun check -> check.name, check.argv) (readiness_checks ~provider)
;;

let readiness_summary checks =
  match
    List.filter_map
      (fun (name, result) ->
         match result with
         | Established -> None
         | Unmet reason -> Some (name ^ ": " ^ reason))
      checks
  with
  | [] -> "Ready"
  | unmet -> "Unmet — " ^ String.concat "; " unmet
;;

(* ── Lifecycle phases: authority and desired-state policy (ADR 0003) ──────────

   HARDEN-002 run 4 (findings 13, 14, 15) showed that the lifecycle needs an
   explicit notion of *which operation Sol is performing*, because that decides
   both the authority it may use and which desired-state policy applies. Two
   individually-correct rules contradicted each other only because no phase said
   which one was in force:

     BUG-039      production-single-region/v1 -> RDS deletion protection = true
     INFRA-023    PrepareDestroy              -> RDS deletion protection = false

   A [phase] is NOT infrastructure truth: Terraform state remains authoritative
   for managed resources and AWS/Kubernetes provide observed reality. It names
   the operation/transition, and therefore the authority and policy, Sol is
   applying right now; it is derived from the command and its verified
   preparation, never persisted as a second state database. *)

type phase =
  | Absent
  | Cloud_bootstrap
  | Platform_installing
  | Ready
  | Platform_updating
  | Preparing_destroy
  | Destroying

(* The desired-state policy a phase applies. [Installation] and [Production]
   differ in authority even where their substitution vars coincide today. *)
type phase_policy =
  | Bootstrap
  | Installation
  | Production
  | Destroy

let policy_of_phase = function
  | Absent | Cloud_bootstrap -> Bootstrap
  | Platform_installing | Platform_updating -> Installation
  | Ready -> Production
  | Preparing_destroy | Destroying -> Destroy
;;

(* The forward lifecycle relation: the edges of ADR 0003's diagram. Anything not
   listed is illegal; the operations in cmd_cloud_tf.ml perform only listed
   transitions, and the tests assert the illegal ones are rejected.

   This is deliberately NOT the whole story about how a phase can be entered. It
   describes *progressive establishment* -- each edge moves the target further
   along the diagram, so reversing one is illegal (invariant 5). Teardown is a
   different class of move and is described separately by [destruction_available];
   keeping the two apart is what lets this relation keep saying exactly what the
   diagram says. *)
let transition_allowed ~from ~to_ =
  match from, to_ with
  | Absent, Cloud_bootstrap -> true
  | Cloud_bootstrap, Platform_installing -> true
  | Platform_installing, Ready -> true
  | Ready, Platform_updating -> true
  | Platform_updating, Ready -> true
  | Ready, Preparing_destroy -> true
  | Preparing_destroy, Destroying -> true
  | Destroying, Absent -> true
  | _ -> false
;;

(* The abort edge (ADR 0003 invariant 6).

   Destruction is not a forward lifecycle transition, so it is not in the relation
   above -- which is why `Platform_installing -> Preparing_destroy` is correctly
   *rejected* there. It is nonetheless available from every phase that can hold
   infrastructure, including a half-built one, because lifecycle enforcement must
   never strand infrastructure: a run that fails midway (a partial install, an
   interrupted privileged update, a destroy that died before finishing) has to
   remain destructible through Sol's public lifecycle, or the only way out is
   manual console surgery on live cloud resources.

   [Absent] is the post-destroy state and has nothing to tear down. *)
let destruction_available = function
  | Absent -> false
  | Cloud_bootstrap
  | Platform_installing
  | Ready
  | Platform_updating
  | Preparing_destroy
  | Destroying -> true
;;

(* The phase a destroy operation proceeds in. Total by construction: destroying an
   already-absent target yields [Absent], the post-destroy state itself, which is
   why destroy is idempotent rather than an error.

   Note what this does *not* need: the answer is [Preparing_destroy] for every
   phase except [Absent], so a destroy has to decide only Absent-ness -- which is
   observable from the substrate Sol is about to tear down. It deliberately does
   not probe the platform: a probe that can fail must never be able to block
   teardown, and would strand exactly the half-built target this exists to
   protect. *)
let enter_destruction ~from =
  if destruction_available from then Preparing_destroy else Absent
;;

(* Ready-state invariants apply only in [Ready]. Once [Preparing_destroy] has
   succeeded no later reconciliation may re-apply them (finding 15) -- BUG-039
   stays exactly correct throughout [Ready] and is deliberately left behind when
   the target leaves it. *)
let ready_policy_applies phase = policy_of_phase phase = Production

(* The desired-state overrides a phase imposes. Callers append these AFTER their
   own variables so the phase policy wins. [Destroy] deliberately contradicts the
   Production invariant for RDS deletion protection. *)
(* The Destroy policy is provider-shaped, because the levers are: AWS lifts RDS
   deletion protection and names the final snapshot it will take, while GCP lifts
   Cloud SQL's and the GKE cluster's. What is provider-neutral is that a Destroy
   policy exists, that the phase names it, and that it is what decides whether a
   target can reach [Absent].

   This is not a cosmetic split. `-var` for a variable a root does not declare is
   an error, not a no-op, so handing the GCP cloud root AWS's three would fail the
   first GCP destroy with "Value for undeclared variable" instead of lifting
   anything -- the failure would arrive as a destroy that cannot start.

   Three things are deliberately kept separate here, because two of them had already
   been conflated:

   - *deletion protection* is a safety guard on a resource that exists. Lifting it is
     what makes the target destructible, and it says nothing about what survives.
   - *retention* (DEC-033) is what a destroy deliberately keeps. AWS expresses it
     with the final snapshot; GCP cannot express it at all yet, which is why
     [prepare_destruction] refuses a GCP target whose retention is the default rather
     than discarding its recovery data quietly.
   - *preparation* is the applied-and-verified semantic transition that makes the
     destruction legal under both of the above.

   Both providers' guards have to be *forwarded to every apply from [Preparing_destroy]
   on*, not only to the destroy itself: each root's default is protection-on, so any
   apply in that window which omits the override silently turns protection back on and
   the teardown then fails on something the target still owns. Live attempt 1 was
   exactly that shape, one guard deeper than expected -- Cloud SQL's was lifted and the
   GKE cluster's, a provider default the root never mentioned, was not, so a target Sol
   had provisioned could not be deleted. *)
(* DEC-033: what a destroy deliberately keeps, and the fact that it is a choice.

   Two postconditions were being conflated. A production destroy means "nothing
   running, with recovery explicitly retained"; a disposable qualification
   target's means "Absent, with nothing billable left behind". Both are legitimate;
   neither is the default for the other. The default here stays [Retain_final_snapshot]
   -- a qualification run retaining nothing must not quietly become "Sol destroys
   every recovery artifact".

   Retention is named by the target (see [Sol_cli_config.destroy_retention]) and
   reported by the destroy that performed it, so an operator never has to infer
   what survived. *)
type destroy_retention =
  | Retain_final_snapshot
  | Retain_nothing

let default_destroy_retention = Retain_final_snapshot

let destroy_retention_to_string = function
  | Retain_final_snapshot -> "final-snapshot"
  | Retain_nothing -> "none"
;;

let destroy_retention_of_string = function
  | "final-snapshot" -> Ok Retain_final_snapshot
  | "none" -> Ok Retain_nothing
  | other ->
    Error
      (Printf.sprintf
         "unknown destroy_retention %S (expected \"final-snapshot\" or \"none\")"
         other)
;;

(* HARDEN-004 step 5: there is deliberately no [retention_report] here any more.
   It rendered the retention *policy* -- "final snapshot X", or "destroyed to
   Absent with no residual billable artifacts" -- with nothing observing whether
   either was true (FND-0046 / INFRA-072). Retention is now reported from
   evidence, by [Sol_cli_destroy_verification], so the sentence an operator reads
   is the one a provider query supports. *)

let policy_vars ~provider ~phase ~destroy_snapshot_id ~retention =
  match policy_of_phase phase with
  | Bootstrap | Installation | Production -> []
  | Destroy ->
    (Sol_cli_provider_capabilities.capabilities_of provider).destroy_guard_vars
      ~final_snapshot:
        (match retention with
         | Retain_final_snapshot -> Some destroy_snapshot_id
         | Retain_nothing -> None)
;;

(* The operator-facing name of a phase (ADR 0003's own spelling). Kept here so a
   report, an error message and a test label cannot drift from the model. *)
let phase_to_string = function
  | Absent -> "Absent"
  | Cloud_bootstrap -> "CloudBootstrap"
  | Platform_installing -> "PlatformInstalling"
  | Ready -> "Ready"
  | Platform_updating -> "PlatformUpdating"
  | Preparing_destroy -> "PreparingDestroy"
  | Destroying -> "Destroying"
;;

(* The phase a target is actually in, recomputed from observation on every run --
   the phase is never persisted and is never infrastructure truth (ADR 0003).
   [cloud_exists] is what Terraform reports for the substrate. [platform_installed]
   is a cheap, privilege-independent observation that an *earlier* run completed
   the platform install (the cert-manager CRDs are cluster objects, so unlike a
   `kubectl auth can-i` probe they are unaffected by the bootstrap-admin
   escalation the current run performs itself). An installed-but-not-fully-Ready
   target observes as [Ready] here because the operation it admits is the same
   privileged re-establishment; the transition is still verified to [Ready] before
   the run may leave it. *)
let observed_phase ~cloud_exists ~platform_installed =
  if not cloud_exists
  then Absent
  else if platform_installed
  then Ready
  else Platform_installing
;;

(* The only way an operation may move between phases. A call site cannot express
   an edge the relation does not admit (ADR 0003 invariant 5), so
   `Preparing_destroy -> Ready` and `Ready -> Platform_installing` are refused
   here rather than by an operator or a call site remembering to check. Remaining
   in the same phase is not a transition and is deliberately not routed through
   this. *)
(* DEC-040 / FND-0021: a control-plane acknowledgement is not evidence that an
   authorization boundary has moved.

   Live, an EKS access-policy disassociation was accepted and `describe-access-entry`
   reported no access policies, while the cluster's authorizer went on granting
   cluster-admin for over five minutes -- established by reading an application's
   Secrets from a principal confirmed at the time of the read. Deleting the access
   *entry* propagated in under 45 seconds; the policy disassociation did not.

   So de-escalation is decided from the *effective* authorization surface: the
   capabilities only the bootstrap authority held, asked of the component that
   enforces the boundary. [Deescalated] is the only verdict that permits `Ready`. *)
(** Which principal answered the probe. The probe must be run as the principal whose
    elevation is being removed; a different principal answering proves nothing about
    that one, which is why it is [Unexpected] rather than a pass. *)
type deescalation_principal =
  | Principal_confirmed of string
  (** The intended principal answered, so its refusals are evidence. *)
  | Principal_refused_by_cluster of string
  (** The intended principal reached the cluster and the cluster's own authorizer
          refused it -- the expected result of removing its access. The elevated
          capability needs authentication, so its absence is its revocation. *)
  | Principal_probe_failed of string
  (** The probe obtained no evidence -- credentials, token generation, network, API, or
          any error that is not the cluster refusing an identified principal. A
          measurement failure must never read as de-escalation. *)
  | Principal_unexpected of string
  (** Some other principal answered. The probe establishes nothing. *)

type deescalation_verdict =
  | Deescalated
  | Still_elevated of string list
  (** Capabilities the de-escalated principal is still permitted. *)
  | Undetermined of string
  (** The surface could not be established -- never treated as de-escalated. *)

(* DEC-040 / FND-0021: a `kubectl auth can-i` answer is three-valued, not a bool.

   [false] used to mean "denied", but the same non-zero exit is what an unreachable
   API, a token that could not be minted, or a transient failure produce. Folding
   those into "denied" made every capability read as removed, the principal read as
   confirmed, and the verdict read as [Deescalated] -- absence of evidence turned
   into evidence of removal in the one verdict that has to mean something. So the
   probe's answer is named, and only an explicit `no` is a denial. *)
type capability_answer =
  | Permitted
  | Denied
  | Indeterminate of string
  (** The probe obtained no usable answer: a transport, token or process failure, or
      an answer the caller could not classify. Never treated as [Denied]. *)

(* The first whitespace-delimited token of the first non-empty line. `kubectl auth
   can-i` prints `yes`/`no` as that token, and newer versions append a reason after a
   denial (`no - no RBAC policy matched`), so matching the whole line would read every
   real denial as indeterminate and make the verification unusable. *)
let first_token text =
  let text = String.trim text in
  let line_end =
    match String.index_opt text '\n' with
    | Some i -> i
    | None -> String.length text
  in
  let rec scan i =
    if i >= line_end
    then i
    else (
      match text.[i] with
      | ' ' | '\t' | '\r' -> i
      | _ -> scan (i + 1))
  in
  String.sub text 0 (scan 0)
;;

(* Classify a `kubectl auth can-i` result. Pure on purpose: this is the decision that
   turns a probe into evidence, it has cases a shell stub cannot produce by hand, and it
   is where FND-0021's fail-open lived. The token and the exit code must agree --
   `yes`/0 and `no`/1 -- because a mismatch means the process is not answering the
   question that was asked, which is [Indeterminate] rather than an answer. *)
let capability_answer_of_can_i_output ~exit_code ~stdout ~stderr =
  let describe () =
    let text = String.trim (stderr ^ " " ^ stdout) in
    if String.equal text ""
    then Printf.sprintf "kubectl exited %d with no output" exit_code
    else Printf.sprintf "kubectl exited %d (%s)" exit_code text
  in
  match first_token stdout with
  | "yes" when exit_code = 0 -> Permitted
  | "no" when exit_code = 1 -> Denied
  | "yes" | "no" ->
    Indeterminate
      (Printf.sprintf
         "kubectl answered %S but exited %d; a mismatch is not an answer"
         (first_token stdout)
         exit_code)
  | _ -> Indeterminate (describe ())
;;

type capability =
  { verb : string
  ; resource : string
  }

let capability_label { verb; resource } = Printf.sprintf "%s %s" verb resource

let answer_is_permitted = function
  | Permitted -> true
  | Denied | Indeterminate _ -> false
;;

let indeterminate_reason (capability, answer) =
  match answer with
  | Indeterminate why -> Some (capability_label capability, why)
  | Permitted | Denied -> None
;;

let permitted_capabilities probes =
  List.filter_map
    (fun (capability, answer) ->
       if answer_is_permitted answer then Some capability else None)
    probes
;;

let still_permitted probes = List.map capability_label (permitted_capabilities probes)

let deescalation_verdict
      ~(principal : deescalation_principal)
      (probes : (capability * capability_answer) list)
  : deescalation_verdict
  =
  match principal with
  | Principal_unexpected who ->
    Undetermined
      (Printf.sprintf
         "the probe answered as %s, not the principal whose elevation was removed"
         who)
  | Principal_probe_failed why -> Undetermined why
  | Principal_refused_by_cluster _why -> Deescalated
  | Principal_confirmed _ ->
    (* A capability that is definitely permitted is hard evidence of elevation and is
       more actionable than another capability's indeterminate probe, so it wins. *)
    let still = still_permitted probes in
    if still <> []
    then Still_elevated still
    else (
      match List.find_map indeterminate_reason probes with
      | Some (capability, why) ->
        Undetermined
          (Printf.sprintf
             "the capability probe for %s obtained no usable answer (%s), so the \
              effective surface is not established"
             capability
             why)
      | None ->
        if probes = []
        then Undetermined "no capability probe produced an answer"
        else Deescalated)
;;

(* DEC-040's positive control. A final denial is not evidence of a transition: a
   credential that never worked, a principal that was never the elevated one, or a
   capability that was never granted all produce the same "denied" afterwards. What the
   security claim needs is the same principal and the same capabilities, observed
   *permitted* inside the bootstrap window and *denied* after it. Anything less is
   [Undetermined], which is not a licence to announce Ready. *)
let deescalation_transition
      ~(before : (capability * capability_answer) list)
      ~after_principal
      ~(after : (capability * capability_answer) list)
  =
  match after_principal with
  | Principal_unexpected who ->
    Undetermined
      (Printf.sprintf
         "the principal answering after de-escalation was %s, not the one observed \
          during the window; the transition is not established"
         who)
  | Principal_probe_failed why ->
    Undetermined ("the post-de-escalation probe obtained no evidence: " ^ why)
  | Principal_refused_by_cluster _ -> Deescalated
  | Principal_confirmed _ ->
    (* A capability that is definitely permitted after de-escalation is hard evidence
       that the surface is still elevated -- more actionable than an indeterminate probe
       elsewhere -- so it is decided first. *)
    let still = still_permitted after in
    if still <> []
    then Still_elevated still
    else (
      match List.find_map indeterminate_reason after with
      | Some (capability, why) ->
        Undetermined
          (Printf.sprintf
             "the capability probe for %s obtained no usable answer after de-escalation \
              (%s), so removal is not established"
             capability
             why)
      | None ->
        let before_permitted = permitted_capabilities before in
        let uncovered =
          List.filter
            (fun capability -> not (List.mem_assoc capability after))
            before_permitted
        in
        (* A capability observed permitted in the window must still be *covered* by the
           after-probe. Its absence from the after list is not its removal. *)
        if uncovered <> []
        then
          Undetermined
            (Printf.sprintf
               "the post-de-escalation probe did not cover %s, so its removal is not \
                established"
               (String.concat ", " (List.map capability_label uncovered)))
        else (
          match List.find_map indeterminate_reason before with
          | Some (capability, why) ->
            Undetermined
              (Printf.sprintf
                 "the bootstrap window probe for %s obtained no usable answer (%s), so \
                  its later removal cannot be demonstrated"
                 capability
                 why)
          | None ->
            if before_permitted = []
            then
              Undetermined
                "the bootstrap-only capabilities were never observed permitted, so no \
                 removal can be demonstrated"
            else Deescalated))
;;

let deescalation_verdict_to_string = function
  | Deescalated ->
    "de-escalated: the effective surface no longer permits bootstrap capabilities"
  | Still_elevated capabilities ->
    Printf.sprintf
      "still elevated: the de-escalated identity is still permitted %s"
      (String.concat ", " capabilities)
  | Undetermined why -> Printf.sprintf "undetermined: %s" why
;;

let enter ~from ~to_ =
  if transition_allowed ~from ~to_
  then Ok to_
  else
    Error
      (Printf.sprintf
         "illegal lifecycle transition %s -> %s"
         (phase_to_string from)
         (phase_to_string to_))
;;
