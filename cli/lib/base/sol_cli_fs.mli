(** Filesystem chores, done once and without a shell (REFAC-134).

    Every function returns a result naming the path; nothing raises and nothing
    swallows. "Already absent" is success where absence is the goal
    ({!remove_if_present}, {!remove_tree}), and any other failure -- a
    permission error, a directory where a file was expected -- is an error, not
    something a catch-all hides. *)

(** [remove_if_present path]: [path] (a file or symlink) is gone. Absent is [Ok]. *)
val remove_if_present : string -> (unit, string) result

(** [remove_reporting path]: {!remove_if_present}, for a cleanup that has nothing
    to return to -- a failure is reported as a warning instead of swallowed. *)
val remove_reporting : string -> unit

(** [remove_tree path]: [path] and everything under it are gone, like `rm -rf`
    without following symlinks. Absent is [Ok]. *)
val remove_tree : string -> (unit, string) result

(** [mkdir_p ?perm dir]: [dir] and its parents exist as directories (a symlink
    to a directory counts). A dangling symlink or a file in the way is an error. *)
val mkdir_p : ?perm:int -> string -> (unit, string) result

(** [write_atomic ?perm path content]: [path] holds [content], written to a
    temporary file beside it and renamed, so a reader never sees half of it.
    With [~perm], the file has exactly that mode, whatever the umask. *)
val write_atomic : ?perm:int -> string -> string -> (unit, string) result

(** [with_temp_file ~prefix ~suffix content f]: [f path] with [content] written to
    a fresh temporary file, which is removed afterwards whatever [f] did. A
    removal that fails is reported as a warning (the result of [f] stands). *)
val with_temp_file
  :  prefix:string
  -> suffix:string
  -> string
  -> (string -> 'a)
  -> ('a, string) result

(** [copy_tree ~exclude ~src ~dst]: a copy of [src] at [dst], following symlinks
    (like `rsync -a --copy-links`), skipping any entry whose name is in
    [exclude], and keeping each file's permission bits. [dst] must not exist. *)
val copy_tree : exclude:string list -> src:string -> dst:string -> (unit, string) result
