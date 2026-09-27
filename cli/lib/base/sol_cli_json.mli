(** Reading JSON that a tool or a stored record produced (REFAC-132, generalising
    REFAC-127's boundary in rollout diagnosis).

    The rule: a read that failed is not an answer. Malformed text, or a document
    without the structure the reader needs, is an [Error] that names what was
    being read -- never [[]], [None] or [false], which would read as "nothing
    there" (FND-0024, DEC-038 §7). Where absence is a real answer (Kubernetes
    omits empty fields), the reader says so with an [option] it asked for.

    Field access below the decode is total: an absent field, or a path through
    something that is not an object, is [`Null], so nothing raises. *)

type t = Yojson.Safe.t

(** [decode ~what text]: [text] parsed, or an error naming [what]. *)
val decode : what:string -> string -> (t, string) result

(** [read_file ~what path]: the file's JSON, or an error naming [what] -- for an
    unreadable file as well as malformed JSON. *)
val read_file : what:string -> string -> (t, string) result

(** [field path j]: the value at [path], or [`Null] when any step is absent or
    is not an object. *)
val field : string list -> t -> t

(** Conversions of one value; [None] when the value is not of that type. *)

val string : t -> string option
val int : t -> int option
val float : t -> float option
val bool : t -> bool option
val list : t -> t list option
val assoc : t -> (string * t) list option

(** [require ~what path convert j]: the value at [path], converted, or an error
    naming [what] and the dotted path when it is absent or of another type. *)
val require : what:string -> string list -> (t -> 'a option) -> t -> ('a, string) result

(** [optional ~what path convert j]: [Ok None] when the value at [path] is
    absent or null (a real "not there"), [Ok (Some v)] when it converts, and an
    error when it is present but of another type. *)
val optional
  :  what:string
  -> string list
  -> (t -> 'a option)
  -> t
  -> ('a option, string) result

(** [items ~what text]: a list response's [items], each an object; an error when
    the text is not JSON or has no [items] list. [Ok []] only when the response
    says the list is empty. *)
val items : what:string -> string -> (t list, string) result
