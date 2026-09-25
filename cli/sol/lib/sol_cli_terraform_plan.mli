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

(** [Exact address] for a stable root-level address; [Type type] only for a
    Terraform-owned mechanism inside a module whose internal address is not
    stable (documented at the rule). *)
type matcher =
  | Exact of string
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

(** The second reading of the same document (FND-0055 / B2): what the
    configuration *declares*, from `planned_values` -- the planned post-apply
    state, child modules and indexed instances included. Deliberately not
    [resource_changes]: a no-op resource is declared without appearing as a
    change, and a resource being removed is a change but not a declaration.

    A document this cannot read is an error, which the caller treats as UNKNOWN --
    never as an empty declared set. *)
type declared =
  { address : string
  ; resource_type : string
  ; mode : string (** "managed" or "data"; only managed resources are owned *)
  ; values : Yojson.Safe.t
  }

val declared_of_plan_json : string -> (declared list, string) result

(** The value a provider block was configured with, as the plan document records
    it: a literal, or a reference to a root variable whose resolved value the same
    document carries. [None] when it cannot be read -- never a default. *)
val provider_value : json:string -> provider:string -> key:string -> string option

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

(** The same, recorded as the declared universe (FND-0055 / B2). Not expressible
    through [show_and_record]: that one requires `resource_changes`, which a plan
    with nothing to change may not carry, and a declaration is not a change. *)
val show_declared_and_record
  :  run_log:Sol_cli_run_log.t
  -> phase:string
  -> show:(unit -> (string, string) result)
  -> (string * declared list, string) result

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
