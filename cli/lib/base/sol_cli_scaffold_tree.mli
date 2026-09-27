(** The scaffold template trees, as trees (REFAC-128).

    `sol new` used to hold every file it generates as an OCaml string. The files
    now live under `platform/shared/templates/<kind>/`, laid out exactly as they
    are generated, and this module is the walk that copies one of them into a
    destination, substituting `{{name}}`-style placeholders in both the paths and
    the content.

    What stays in OCaml is the orchestration: which kind, which destination, and
    which variables each kind carries ([Sol_cli_cmd_new]). What lives in the
    files is what the generated project actually says. *)

(** What to do with one template file.

    [Patch_modules m] appends [m] to an existing `(modules ...)` stanza instead of
    overwriting the file — the one generated file that merges with what an
    author already has (a second event in the same team). *)
type rule =
  | Write
  | Skip_if_exists
  | Patch_modules of string

(** Every kind, in the order `sol assets` reports them. Each is a directory
    under the templates root. *)
val kinds : string list

(** [plan ~root ~kind] is every template of [kind], relative to its kind
    directory, sorted. Reads nothing but the directory listing. *)
val plan : root:string -> kind:string -> (string list, string) result

(** [text ~root ~kind ~rel] is one template's raw content, placeholders intact.
    An error names the file. *)
val text : root:string -> kind:string -> rel:string -> (string, string) result

(** [copy ~root ~kind ~dest ~vars ~rule] writes every template of [kind] into
    [dest], substituting each file's path and content with [vars rel] (its own
    variables, keyed by the template's relative path) and applying [rule rel].

    Returns the destination paths written, in the order written. A missing kind
    directory or an unreadable template is an [Error] naming the path; the
    destination's directories are created as needed. *)
val copy
  :  root:string
  -> kind:string
  -> dest:string
  -> vars:(string -> (string * string) list)
  -> rule:(string -> rule)
  -> (string list, string) result
