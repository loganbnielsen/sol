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

(** A resolved configuration: sol.yml, then the environment, then the target
    (DEC-047). It always has its target (REFAC-109). *)
type t =
  { project : string option
  ; target : target
  ; resources : resource list
  ; services : service list
  }

type error =
  { path : string
  ; line : int
  ; message : string
  }

val error_to_string : error -> string

(** [sol_yml_services_of_string ~path text] is {!sol_yml_services} for text in
    hand rather than a file: the services [sol.yml] declares, with the language
    each one declares (FEAT-104: the manifest editor re-parses what it is about
    to write, and refuses rather than write a file that would not say what it
    intended). *)
val sol_yml_services_of_string : path:string -> string -> (service list, error) result

val load_for_target : target:string -> (t, error) result

(** The part of a configuration a deployment *plan* reads (BUG-056): what
    [sol.yml] declares — services, with the language, scale range and resource
    uses they declare, and the resources themselves — plus the profile the
    resolved target selects (only a target file may set one, DEC-026).

    It is split out from {!t} because these are the same facts in every
    deployment mode, while a resolved configuration always carries a target:
    [sol deploy] has one, and [sol up] is local-only — there is no local
    [provider] to put in a {!target} — so it supplies these facts from the
    manifest alone with {!load_declared}. Before this existed [sol up] passed
    nothing, and a local workspace was rendered from less information than the
    same workspace deployed to a target. *)
type declared =
  { services : service list
  ; resources : resource list
  ; profile : Sol_cli_profile.t option
  }

(** What a resolved configuration declares. *)
val declared_of_config : t -> declared

(** What [sol.yml] declares on its own — no environment or target layer, so no
    profile. This is what [sol up] plans from. *)
val load_declared : root:string -> (declared, error) result

(** [parse_target address] is the bare target an [<env>/<provider>/<region>]
    address names, with no settings, or the address error (REFAC-109). *)
val parse_target : string -> (target, error) result

(** [target_declared target] is [true] when [sol/environments.yml] (or the local
    file) declares this target under its environment's [targets:] (FEAT-100).
    [load_for_target] itself tolerates an undeclared target (one can rely on
    [sol.yml] and its environment alone) -- callers that mutate real
    infrastructure and need the stronger guarantee that this exact target was
    deliberately declared check this. [sol deploy] always does; [sol cloud
    apply]/[destroy] do for their mutating action only; [sol plan] doesn't. *)
val target_declared : target -> bool

(** Where a target is (or would be) declared, for messages:
    [<root>/sol/environments.yml (<env>.targets.<provider>/<region>)]. *)
val target_source : target -> string

(** Every declared target, as [<env>/<provider>/<region>], sorted. [~root]
    names the workspace to read; without it the root is resolved from the
    current directory. *)
val discover_target_paths : ?root:string -> unit -> (string list, error) result

val resources : t -> resource list
val services : t -> service list
val format_use_ref : string -> string

(** The services [sol.yml] itself declares, read without resolving an
    environment or a target, together with the language each one declares
    (FEAT-088). This is what [Sol_cli_workspace_model] uses to attach a
    declared language to each discovered workload; a malformed [sol.yml] is an
    error naming it. *)
val sol_yml_services : root:string -> (service list, error) result

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
