(** SEC-010: a secret must never reach the terraform argument vector.

    Sol records the terraform command line in its run log, so a value passed with
    [--var] (or from the target's own variables) is written to a file. Which
    variables are secrets is the Terraform root's declaration, not Sol's: a root
    marks them [sensitive = true]. This module reads that declaration from the
    root's own [.tf] files and refuses those names on the command line, for every
    provider alike.

    Whether a required secret was supplied at all is Terraform's to enforce (a
    required variable with no default, or a precondition on the resource that uses
    it), so this module does not check for a missing value. *)

(** [declared_in files] is the names of root-module variables declared with
    [sensitive = true] across [files], given as [(filename, contents)]. Sorted,
    without duplicates.

    The reader is tolerant of what a valid root may contain (a trailing comment, a
    one-line block, any whitespace) rather than assuming one layout: answering "no
    secrets" because a root is laid out differently is indistinguishable from a
    root that declares none. When it meets a [sensitive] assignment whose value it
    cannot evaluate, it is [Error] — the fail-closed direction, because skipping
    such a declaration would let the secret reach the logged argument vector.

    A top-level variable block closes with a brace in column 0, which is what
    separates it from a nested validation block. *)
val declared_in : (string * string) list -> (string list, string) result

(** [declared ~root] reads every [*.tf] file directly in [root] and returns
    {!declared_in} of them. [Error] when the directory cannot be read, because a
    root Sol cannot read is not one it can safely run. *)
val declared : root:string -> (string list, string) result

(** [refuse_on_command_line ~sensitive ~vars] is [Ok ()] unless one of [vars]
    (terraform keys and values) sets a variable in [sensitive]; then [Error]
    naming the variable, why it is refused, and the [TF_VAR_<name>] that carries
    it instead. Never inspects or carries the value. *)
val refuse_on_command_line
  :  sensitive:string list
  -> vars:string list
  -> (unit, string) result
