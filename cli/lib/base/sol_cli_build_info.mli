(** The release this binary belongs to (FEAT-101, DEC-049).

    [Some v] exactly when the binary was built by a release build, with
    [SOL_RELEASE_VERSION=v]; [None] for every development build. It names the
    installed bundle ([<prefix>/share/sol/<v>/]) whose assets this binary uses. *)
val release_version : string option
