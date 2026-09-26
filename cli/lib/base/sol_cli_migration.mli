(* AUDIT-069: the migration prerequisite a production deploy verifies. *)

type prerequisite =
  { version : int
  ; name : string
  }

(** The workspace-relative directory holding migration SQL (["db/migrations"]). *)
val default_dir : string

(** The authoritative tracking table [sol migrate] writes for this workspace. *)
val table_name : workspace:string -> string

(** [parse_version "001_create_orders.sql"] is [Some (1, "create_orders")]. *)
val parse_version : string -> (int * string) option

(** Every migration in [dir], ordered by version. [Ok []] when [dir] does not
    exist (the workspace has no migrations, so nothing is required); [Error] on
    a file name that does not carry a numeric version. *)
val required : dir:string -> (prerequisite list, string) result

(** The applied versions in the output of [sol migrate status --json]. *)
val parse_status_json : string -> (int list, string) result

(** [required \ applied]. *)
val unsatisfied : required:prerequisite list -> applied:int list -> prerequisite list

(** [003_add_index] -- the form the operator sees in a failure message. *)
val to_string : prerequisite -> string

(** The [sol migrate status --json] body: one entry per migration with its
    applied flag. *)
val status_json : table:string -> (int * string * string option) list -> string

(** The report printed when the deploy's read-only migration-status Job fails:
    what the container was waiting on (if it never started) and what the Job
    logged (if it ran). Either half may be absent. INFRA-040: the Job is removed
    after the check, so this is what makes the failure diagnosable from the
    deploy's own output. *)
val evidence_report : waiting:(string * string) option -> logs:string -> string
