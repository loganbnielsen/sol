type target = {
  name                   : string;
  env                    : string;
  provider               : string;
  region                 : string;
  registry               : string option;
  base_domain            : string option;
  cluster_name           : string option;
  terraform_var_file     : string option;
  observability_backend  : string option;
  provider_fields        : (string * (string * string) list) list;
}

type index = {
  index_name    : string;
  partition_key : string option;
  sort_key      : string option;
}

type resource = {
  name          : string;
  typ           : string option;
  partition_key : string option;
  sort_key      : string option;
  indexes       : index list;
  size          : string option;
  omit          : bool;
}

type service = {
  name      : string;
  typ       : string option;
  path      : string option;
  uses      : string list;
  scale_min : int option;
  scale_max : int option;
  omit      : bool;
}

type t = {
  project   : string option;
  target    : target option;
  resources : resource list;
  services  : service list;
}

type error = { path : string; line : int; message : string }

val error_to_string : error -> string
val load_for_target : target:string -> (t, error) result

(** [target_file target] is the target file path a resolved [target] was
    (or would be) overlaid from: [sol/<env>/<provider>/<region>.yml].
    [load_for_target] itself tolerates this file being absent (a target
    can legitimately rely on [sol.yml] alone) -- callers that mutate real
    infrastructure and need the stronger guarantee that this exact target
    was deliberately declared, not just shaped like one, should check
    [Sys.file_exists] on this path themselves. [sol deploy] always does;
    [sol cloud apply]/[destroy] do for their mutating action only (not
    their [--plan]/[Plan] preview mode); [sol plan] (genuinely read-only)
    doesn't. *)
val target_file : target -> string

val target : t -> target option
val resources : t -> resource list
val services : t -> service list
val format_use_ref : string -> string
val terraform_vars : t -> ((string * string) list, string) result
(** Neutral key/value Terraform variables derived from the target
    (region/cluster_name/base_domain, active provider fields,
    create_rds). Terraform CLI syntax ("key=value", "-var=...") is not
    this module's concern — see {!Sol_cli_terraform.kv_args}. *)
