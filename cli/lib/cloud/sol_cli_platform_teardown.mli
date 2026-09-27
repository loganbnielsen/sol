(** The platform root's teardown, including INFRA-042's recovery for a
    partially installed platform (REFAC-139, part D). *)

(** [kinds_of_api_resources text]: the kinds in the output of
    [kubectl api-resources --no-headers], sorted and deduplicated. *)
val kinds_of_api_resources : string -> string list

(** [unserved_of_show_json ~served text]: the [kubernetes_manifest] resources in
    a [terraform show -json] whose kind is not in [served], as
    [(address, kind)]. Only [kubernetes_manifest] is considered: its stored
    manifest states its kind verbatim, where a native resource's kind would have
    to be guessed from its Terraform type. *)
val unserved_of_show_json
  :  served:string list
  -> string
  -> ((string * string) list, string) result

(** [absent env]: none of the platform's namespaces exists. *)
val absent : (string * string) list -> bool

(** [destroy ~run_log ~env ~chdir ~vars]: destroy the platform root in [chdir]
    (already initialized), then verify the platform is absent. If Terraform's
    destroy fails, the resources whose kind the cluster provably does not serve
    are forgotten, each named, and the destroy is retried once; otherwise the
    original failure stands. *)
val destroy
  :  run_log:Sol_cli_run_log.t
  -> env:(string * string) list
  -> chdir:string
  -> vars:string list
  -> (unit, string) result
