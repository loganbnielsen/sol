(** Command-line values decoded at the boundary (REFAC-123). *)

(** [text] is Cmdliner's [string] with blank refused at parse time (exit 124):
    for every name, target, path, URL and tag Sol takes, where an empty value
    means nothing and would otherwise have to be re-checked where it is used.
    The value is trimmed. *)
val text : string Cmdliner.Arg.conv
