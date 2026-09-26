(** What `sol cloud apply` prints of a root's Terraform outputs (REFAC-118).

    Only outputs Terraform marks non-sensitive are shown; an output without a
    [sensitive] field counts as sensitive. Deciding what to show is pure and
    separate from printing it. *)

type value =
  | Text of string
  | Texts of string list (** The string items of a list output. *)
  | Null

(** [displayable json] is the [(name, value)] pairs to show from
    [terraform output -json], in order; an [Error] says why the JSON could not
    be read. Outputs that are sensitive, of another type, or lists with no
    string items are omitted. *)
val displayable : string -> ((string * value) list, string) result

(** One line, as `sol cloud apply` prints it. *)
val line : string * value -> string
