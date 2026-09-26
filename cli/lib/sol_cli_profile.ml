type t = Production_single_region

let version Production_single_region = 1
let selection_name Production_single_region = "production-single-region"
let to_string t = Printf.sprintf "%s/v%d" (selection_name t) (version t)
let all = [ Production_single_region ]

let known_selections () =
  all |> List.map selection_name |> List.map (Printf.sprintf "%S") |> String.concat ", "
;;

let of_selection s =
  match List.find_opt (fun t -> selection_name t = s) all with
  | Some t -> Ok t
  | None ->
    Error
      (Printf.sprintf "unknown profile %S (known profiles: %s)" s (known_selections ()))
;;

let of_string s =
  match List.find_opt (fun t -> to_string t = s) all with
  | Some t -> Ok t
  | None -> Error (Printf.sprintf "unknown profile identity %S" s)
;;

type capability =
  | Qualified_substrate
  | Qualified_versions
  | Direct_apply_authority
  | Remote_state
  | Scoped_operator_identities
  | Alert_delivery
  | Immutable_artifacts
  | Credential_posture
  | Platform_capacity
  | Workload_availability
  | Postgres_durability
  | Kafka_durability

let capability_to_string = function
  | Qualified_substrate -> "qualified_substrate"
  | Qualified_versions -> "qualified_versions"
  | Direct_apply_authority -> "direct_apply_authority"
  | Remote_state -> "remote_state"
  | Scoped_operator_identities -> "scoped_operator_identities"
  | Alert_delivery -> "alert_delivery"
  | Immutable_artifacts -> "immutable_artifacts"
  | Credential_posture -> "credential_posture"
  | Platform_capacity -> "platform_capacity"
  | Workload_availability -> "workload_availability"
  | Postgres_durability -> "postgres_durability"
  | Kafka_durability -> "kafka_durability"
;;

let capability_description = function
  | Qualified_substrate -> "qualified provider/substrate"
  | Qualified_versions -> "qualified version set"
  | Direct_apply_authority -> "direct apply reconciliation authority"
  | Remote_state -> "recoverable remote infrastructure state"
  | Scoped_operator_identities -> "scoped operator identity"
  | Alert_delivery -> "alert delivery to an owner"
  | Immutable_artifacts -> "immutable artifact identity"
  | Credential_posture -> "workload credential posture"
  | Platform_capacity -> "capacity for the production platform's own components"
  | Workload_availability -> "workload availability"
  | Postgres_durability -> "Postgres durability"
  | Kafka_durability -> "Kafka durability"
;;

type workload_capability =
  | Long_running
  | Postgres
  | Kafka

let guarantee_of_use = function
  | Long_running -> Workload_availability
  | Postgres -> Postgres_durability
  | Kafka -> Kafka_durability
;;

(* INFRA-030 / HARDEN-002 Run 5 attempt 1: this profile claims its target can
   host the production platform, so which node shape the Terraform module happens
   to default to cannot be the thing that decides whether that claim holds.
   Attempt 1 provisioned 3 x m6i.large (6 vCPU) and then could not install the
   platform at all: the platform's own RF>=3 Redpanda requests 2 vCPU x 3 brokers
   = 6 vCPU by itself, so `helm_release.redpanda` and `helm_release.loki` both
   died with "context deadline exceeded" behind `0/3 nodes are available: 3
   Insufficient cpu`.

   The contract is deliberately *capacity*, not an instance type: production
   means "enough resources to satisfy the platform's declared resource envelope",
   and {!recommended_node_shape} is one configuration that does. A larger
   Terraform default would repair that one manifestation while leaving any target
   free to set the shape back to 2-vCPU nodes and still claim this profile.

   This is not a Kubernetes scheduler simulator and does not pretend to be:
   aggregate request summation is a lower bound, and DaemonSets, kubelet/system
   reservations, affinity and topology constraints all sit between it and real
   schedulability. It encodes conservative, checkable rules instead:

   - a *per-node* floor, because capacity-per-node decides whether the platform's
     largest indivisible pod can land anywhere at all. This is why a 2-vCPU node
     cannot host a 2-vCPU pod: allocatable sits below capacity once system pods
     take their share, so the floor states the requirement *including* that
     margin;
   - a *cluster* floor measured after {!node_failure_headroom_nodes}. Production
     promises a lost node's replicas can be restored, so the question is not "does
     the platform fit on N nodes" but "does it still fit on N - headroom" — which
     attempt 1 would have failed twice over. *)
type capacity_envelope =
  { largest_pod_vcpu : int
  ; min_vcpu_per_node : int
  ; min_memory_gib_per_node : int
  ; platform_vcpu : int
  ; platform_memory_gib : int
  }

type node_shape =
  { instance_type : string
  ; vcpu_per_node : int
  ; memory_gib_per_node : int
  ; nodes : int
  }

(* Derived from the platform charts' own declared requests
   (platform/cloud/modules/platform/variables.tf):

   - Redpanda is the largest indivisible unit, at `redpanda_cpu_cores = 2` and
     `redpanda_memory = 4Gi` per broker, and RF>=3 means three of them;
   - the rest of the platform (cert-manager, ingress-nginx, Argo CD, Redpanda
     console, Loki and its caches, Grafana, Prometheus, Alloy) is carried as one
     conservative allowance rather than a per-chart sum, because the point is to
     reject a structurally undersized target, not to predict a schedule.

   If a platform component's declared requests grow, this envelope has to grow
   with it: the offline test that pins {!recommended_node_shape} against this
   envelope fails the build rather than letting the two drift apart silently. *)
let platform_capacity_envelope =
  { largest_pod_vcpu = 2
  ; min_vcpu_per_node = 4
  ; min_memory_gib_per_node = 8
  ; platform_vcpu = 10
  ; platform_memory_gib = 20
  }
;;

(* The recommended shape, kept *separate* from the contract above: it satisfies
   the envelope comfortably rather than barely, so the platform still fits after
   the node-failure headroom is spent. *)
let recommended_node_shape =
  { instance_type = "m6i.xlarge"; vcpu_per_node = 4; memory_gib_per_node = 16; nodes = 4 }
;;

let capacity_shortfall ~envelope ~shape ~headroom_nodes =
  let headroom_nodes = max 0 headroom_nodes in
  let schedulable_nodes = shape.nodes - headroom_nodes in
  let per_node =
    if
      shape.vcpu_per_node >= envelope.min_vcpu_per_node
      && shape.memory_gib_per_node >= envelope.min_memory_gib_per_node
    then []
    else
      [ Printf.sprintf
          "each node must offer at least %d vCPU / %d GiB so the platform's largest pod \
           (%d vCPU) still fits on one node after system reservations, but this shape \
           offers %d vCPU / %d GiB"
          envelope.min_vcpu_per_node
          envelope.min_memory_gib_per_node
          envelope.largest_pod_vcpu
          shape.vcpu_per_node
          shape.memory_gib_per_node
      ]
  in
  let cluster =
    if schedulable_nodes < 1
    then
      [ Printf.sprintf
          "%d node(s) with %d reserved for node-failure headroom leaves no schedulable \
           capacity at all"
          shape.nodes
          headroom_nodes
      ]
    else (
      let vcpu = schedulable_nodes * shape.vcpu_per_node in
      let memory = schedulable_nodes * shape.memory_gib_per_node in
      let check value needed unit =
        if value < needed
        then
          [ Printf.sprintf
              "%d %s left after node-failure headroom but the platform needs %d"
              value
              unit
              needed
          ]
        else []
      in
      check vcpu envelope.platform_vcpu "vCPU"
      @ check memory envelope.platform_memory_gib "GiB")
  in
  per_node @ cluster
;;

let satisfies_capacity ~envelope ~shape ~headroom_nodes =
  match capacity_shortfall ~envelope ~shape ~headroom_nodes with
  | [] -> Ok ()
  | shortfalls ->
    Error
      (Printf.sprintf
         "%d x %s (%d vCPU / %d GiB each) cannot host the production platform: %s"
         shape.nodes
         shape.instance_type
         shape.vcpu_per_node
         shape.memory_gib_per_node
         (String.concat "; " shortfalls))
;;

(* The provider variables that select the shape. A profile target contributes
   these through the profile-precedence path
   ([Sol_cli_terraform_vars.of_config] -> [vars_with_profile_precedence]), so the
   shape cannot be weakened by a target field, a var-file or a --var — the same
   mechanism that already protects [rds_multi_az] and [rds_deletion_protection].
   [node_min_size] leaves room for exactly the reserved headroom, so the cluster
   may shrink by one node without Terraform fighting the contract. *)
let node_shape_vars shape =
  [ "node_instance_types", Printf.sprintf "[%S]" shape.instance_type
  ; "node_desired_size", string_of_int shape.nodes
  ; "node_min_size", string_of_int (max 1 (shape.nodes - 1))
  ; "node_max_size", "10"
  ]
;;

let requirements Production_single_region uses =
  [ Qualified_substrate
  ; Qualified_versions
  ; Direct_apply_authority
  ; Remote_state
  ; Scoped_operator_identities
  ; Alert_delivery
  ; Immutable_artifacts
  ; Credential_posture
  ; Platform_capacity
  ]
  @ List.map guarantee_of_use (List.sort_uniq compare uses)
;;
