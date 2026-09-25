(** One plan-classification and assertion mechanism for destructive applies
    (HARDEN-004 step 3).

    Terraform's own plan is the evidence: {!changes_of_plan_json} reads the
    resource changes (real addresses, actions) from a saved plan, {!violations}
    classifies them against a phase {!policy}, and {!guarded_apply} refuses before
    applying when any change is outside that policy.

    Strictness is the point: a plan that cannot be produced, read or parsed, and
    any action Terraform emits that this module does not recognise, are refused --
    never allowed. *)

type action =
  | Create
  | Update
  | Delete
  | Replace
  | Read
  | No_op
  | Unknown of string list

type change =
  { address : string
  ; resource_type : string
  ; mode : string
  ; action : action
  }

(** How a rule identifies the resources it governs -- identity only, never
    permission (that is the rule's [allows]).

    - [Exact address]: one address exactly as Terraform wrote it.
    - [Resource address]: that resource, any instance of it -- the address
      itself, or it followed by exactly one instance key ([resource[0]],
      [resource["key"]]). This is the matcher for a declared `count`/`for_each`
      mechanism, whose plan address carries an index the declaration does not
      (FND-0058).
    - [Type type]: only for a Terraform-owned mechanism inside a module whose
      internal address is not stable (documented at the rule).

    [Resource] matches one resource: not a longer name, a dotted path, a module
    prefix, or a sibling of the same type. *)
type matcher =
  | Exact of string
  | Resource of string
  | Type of string

type rule =
  { matches : matcher list
  ; allows : action list
  ; reason : string
  }

type policy =
  { phase : string
  ; rules : rule list
  }

val action_to_string : action -> string

(** Parse `terraform show -json <saved plan>`. A document without a
    `resource_changes` array is an error, and the caller refuses. *)
val changes_of_plan_json : string -> (change list, string) result

(** [show_and_record ~run_log ~phase ~show] runs [show] (which returns
    `terraform show -json <saved plan>`), parses it, and appends only the
    classified changes -- one "<action> <address>" line each -- to [phase]'s run
    log. Returns the JSON and its changes. The JSON itself never reaches the run
    log: it carries sensitive values in plain text (SEC-008), so callers must not
    run [show] through {!Sol_cli_run_log.run_phase}. *)
val show_and_record
  :  run_log:Sol_cli_run_log.t
  -> phase:string
  -> show:(unit -> (string, string) result)
  -> (string * change list, string) result

(** Classified changes outside the policy's allowlist. Empty means permitted.
    [no-op] anywhere and a data-source [read] are always permitted. *)
val violations : policy -> change list -> string list

type apply_failure =
  | Plan_failed of string
  | Plan_unreadable of string
  | Refused of string list
  | Apply_failed of string

val apply_failure_to_string : apply_failure -> string
val was_refused : apply_failure -> bool

(** [plan] produces a saved plan and returns its path; [show_plan] reads it;
    [apply_plan] applies that same file. The apply runs only when the plan is
    permitted, so what ran is what was asserted. *)
val guarded_apply
  :  policy:policy
  -> plan:(unit -> (string, string) result)
  -> show_plan:(string -> (string, string) result)
  -> apply_plan:(string -> (unit, string) result)
  -> unit
  -> (unit, apply_failure) result

(** [removed_of_type ~resource_type changes] is the address of every [resource_type]
    that the plan deletes or replaces (INFRA-074). *)
val removed_of_type : resource_type:string -> change list -> string list
