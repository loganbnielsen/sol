val positional : doc:string -> string Cmdliner.Term.t
val optional_positional : doc:string -> string option Cmdliner.Term.t
val flag : doc:string -> string option Cmdliner.Term.t
val required_flag : doc:string -> string Cmdliner.Term.t
