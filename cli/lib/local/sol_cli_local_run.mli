(** What [`sol local run`] runs, per workload (FEAT-103).

    The loop is language-neutral up to the point where it has to *act*: a
    workload's declared language (FEAT-104) selects the adapter that builds and
    launches it. Nothing here is inferred from a [package.json], a [dune] file or
    a directory name — those are read only once the language is known, as that
    language's own toolchain metadata (DEC-022 §7).

    This module only decides; it runs nothing. A caller (the command) executes
    [builds] in order and then supervises each launch, so the decisions are
    testable without a cluster or a process. *)

type command =
  { argv : string list
  ; cwd : string
    (** Workspace-root relative directory to run in; [""] is the root. A
          TypeScript unit's build runs in its npm project root, which is not its
          own directory. *)
  }

type recipe =
  { label : string (** [domain/name], as the loop prints and prefixes it *)
  ; language : Sol_cli_compat.language
  ; build : command option
    (** The unit's own build, when it has one of its own. An OCaml unit's is
          [None]: every OCaml unit in the selection is built by one merged
          [dune build] in {!plan}, because concurrent [dune] invocations fight
          over the build lock. *)
  ; launch : command
  ; artifact : string
    (** What the launch runs, workspace-root relative: the compiled binary for
          OCaml, the built entry file for TypeScript. *)
  }

type plan =
  { builds : command list (** in order; every OCaml unit's build is merged into one *)
  ; launches : recipe list
  }

(** [plan ~root ~facts services] resolves every selected workload to its
    adapter. Errors are per workload and name it, and a plan with any error is a
    failure: a loop that silently started half a selection would be worse than
    one that refused.

    - an OCaml unit builds [<dir>/bin/main.exe] with one merged [dune build]
      (concurrent [dune] invocations fight over the build lock) and launches the
      compiled binary;
    - a TypeScript unit builds with [npm run build] in the npm project that
      declares it — its own directory, or the nearest ancestor whose
      [package.json] lists the unit's package — and launches the built entry
      directly with [node], never through [npm], because the loop supervises the
      process it starts and must be able to stop it. A declaration that does not
      match the unit's own tree (no [package.json], no [name], no installed
      dependencies) fails naming the unit and the remedy, never by guessing. *)
val plan
  :  root:string
  -> facts:Sol_cli_workspace_model.t
  -> Sol_cli_manifest.service list
  -> (plan, (string * string) list) result

(** [label (domain, name)] is how the loop names a workload in its output. *)
val label : Sol_cli_manifest.service -> string
