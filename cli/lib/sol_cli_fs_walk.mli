(** Directory traversal that reports rather than swallows.

    The distinction this module exists to make: a path that is [Absent] is
    frequently a legitimate domain fact — no [events/] means no topics, no
    [sol/] means no targets — while a path that exists and cannot be read is
    always a failure, and never the same thing as "nothing there". Callers
    choose which of those they tolerate; the traversal does not decide for them.

    Entries are returned in a deterministic order, so a caller (or a test) that
    depends on traversal order does not inherit [Sys.readdir]'s. *)

type error =
  | Absent of string
  | Unreadable of string * string

(** Human-readable form, for a warning or an error message. *)
val to_string : error -> string

(** Immediate entries of [path], sorted by name, including hidden ones — this
    layer has no opinions about which names matter.

    [Error (Absent path)] when [path] does not exist. [Error (Unreadable
    (path, reason))] when it exists but is not a directory, or cannot be read.
    Note that a path unreadable because of a permission failure on a *parent*
    is reported as [Absent], since that is all [Sys.file_exists] can tell us. *)
val entries : string -> (string list, error) result

(** Immediate subdirectories of [path]. *)
val dirs : string -> (string list, error) result

(** Immediate non-directory entries of [path]. *)
val files : string -> (string list, error) result
