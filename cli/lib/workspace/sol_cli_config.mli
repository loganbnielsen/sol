type target =
  { name : string
  ; env : string
  ; provider : Sol_cli_provider.t
  ; region : string
  ; registry : string option
  ; base_domain : string option
  ; cluster_issuer : string option
  ; letsencrypt_email : string option
  ; cluster_name : string option
  ; kube_context : string option
  ; kubeconfig : string option
  ; terraform_var_file : string option
  ; observability_backend : string option
    (* DEC-033: what `sol cloud destroy` deliberately keeps. Absent means the
     production default (retain the final snapshot); a disposable qualification
     target sets `destroy_retention: none`. *)
  ; destroy_retention : string option
  ; alert_receiver_type : string option
  ; alert_receiver_url : string option
  ; alert_owner : string option
  ; alert_runbook_url : string option
  ; state_bucket : string option
    (** AUDIT-072: the encrypted, versioned remote Terraform state bucket. Sol
        provisions a conformant one by default (platform/cloud/aws/bootstrap);
        an operator may bring their own by declaring it here. *)
  ; cluster_endpoint_cidr : string option
    (** The single CIDR allowed to reach the public Kubernetes API endpoint. A
        production profile requires an explicit, non-world-reachable value. *)
  ; node_failure_headroom_nodes : int option
  ; profile : Sol_cli_profile.t option
    (** The production profile this target explicitly selects (DEC-026). Only a
        target file may set it; an environment name never implies one. *)
  ; provider_fields : (string * (string * string) list) list
  }

(** Where this target deploys — the mechanism Sol uses to reach the cluster, not
    its identity (DEC-020). Returns [Error] when the target names no context, so
    no caller can fall back to the ambient one. *)
val destination_of_target : target -> (Sol_cli_kube_destination.t, string) result

type index =
  { index_name : string
  ; partition_key : string option
  ; sort_key : string option
  }

type resource =
  { name : string
  ; typ : string option
  ; partition_key : string option
  ; sort_key : string option
  ; indexes : index list
  ; size : string option
  ; omit : bool
  }

type service =
  { name : string
  ; typ : string option
  ; path : string option
  ; uses : string list
  ; scale_min : int option
  ; scale_max : int option
  ; language : Sol_cli_compat.language option
    (** FEAT-088: the declared framework language for this workload. The
          production profile qualifies only OCaml. *)
  ; omit : bool
  }

type t =
  { project : string option
  ; target : target option
  ; resources : resource list
  ; services : service list
  }

type error =
  { path : string
  ; line : int
  ; message : string
  }

val error_to_string : error -> string
val load_for_target : target:string -> (t, error) result

(** [target_file target] is the target file path a resolved [target] was (or
    would be) overlaid from, resolved against the workspace root (DEC-024):
    [<root>/sol/<env>/<provider>/<region>.yml].
    [load_for_target] itself tolerates this file being absent (a target can
    legitimately rely on [sol.yml] alone) -- callers that mutate real
    infrastructure and need the stronger guarantee that this exact target was
    deliberately declared, not just shaped like one, should check
    [Sys.file_exists] on this path themselves. [sol deploy] always does;
    [sol cloud apply]/[destroy] do for their mutating action only (not their
    [--plan]/[Plan] preview mode); [sol plan] (genuinely read-only) doesn't. *)
val target_file : target -> string

val target : t -> target option
val resources : t -> resource list
val services : t -> service list
val format_use_ref : string -> string

(** [is_omitted_service cfg ~name] is [true] when this target declares a service
    with that name and [omit: true] (DEC-041).

    The raw declaration is what matters here: [services] above is already filtered,
    so it cannot answer "was this unit omitted?" for a unit the caller reached by
    another route — which is exactly the question the deploy selection asks when it
    decides whether an omitted unit may be named back in. Discovery keys a unit by
    (domain, name) while the config keys a service by name alone, so the lookup is
    by name. *)
val is_omitted_service : t -> name:string -> bool

(** REFAC-098: a value from the target's own provider block ([aws:] / [gcp:]),
    where provider-native configuration lives: the AWS state-locking table and the
    AUDIT-072 / DEC-034 role ARNs, and the GCP provisioner impersonator. *)
val provider_field : target -> string -> string option

(** The workspace's ECR repositories as a Terraform list literal, derived from
    every service under [app/]; ["[]"] when the workspace has no [app/]. A
    discovery failure is an error, never "no repositories" (INFRA-074). *)
val ecr_repositories_var : unit -> (string, string) result

(** Merges a target's profile-derived Terraform vars (e.g. [rds_multi_az],
    [rds_deletion_protection]) with the caller's own `-var`/var-file values,
    in the order the two lists must be handed to Terraform.

    Terraform resolves a key assigned more than once by taking the *last*
    occurrence, so order is the entire enforcement mechanism: when
    [has_profile] is true, [config_vars] goes last so a profile's claims
    cannot be weakened by a caller-supplied value for the same key; when
    false, [cli_vars] goes last so an ordinary (non-profile) target keeps
    full operator control. *)
val vars_with_profile_precedence
  :  has_profile:bool
  -> cli_vars:string list
  -> config_vars:string list
  -> string list

(** [local_infra ~root] is the local infrastructure a workspace needs (REFAC-107):
    Kafka and Postgres when [sol.yml] declares a [kafka] / [postgres] resource, and
    the observability stack always. Decided from the declaration, never inferred
    from build files, so it is the same for OCaml and TypeScript units. *)
val local_infra : root:string -> (Sol_cli_workspace.infra_requirements, error) result
