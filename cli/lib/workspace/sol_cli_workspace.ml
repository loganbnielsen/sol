type infra_requirements =
  { kafka : bool
  ; postgres : bool
  ; loki : bool
  ; prometheus : bool
  ; tempo : bool
  }

(* ── Workspace identity (DEC-024) ────────────────────────────────────────── *)

(** The manifest whose *presence* establishes a workspace boundary. Its
    contents define optional workspace configuration; existence alone is what
    makes the directory a Sol workspace. *)
let workspace_file = "sol.yml"

type workspace_error =
  | Not_in_workspace
  | Nested_workspace of
      { outer : string
      ; inner : string
      }

let workspace_error_to_string = function
  | Not_in_workspace ->
    "not inside a Sol workspace (no sol.yml found)\n\n\
     A Sol workspace is identified by sol.yml.\n\
     Run this command from an existing Sol workspace, or create one with\n\
     `sol new workspace <name>`."
  | Nested_workspace { outer; inner } ->
    Printf.sprintf
      "nested Sol workspace is not supported\n\n\
       workspace:        %s\n\
       nested workspace: %s\n\n\
       Use sibling workspaces instead."
      outer
      inner
;;

let has_workspace_file dir =
  let path = Filename.concat dir workspace_file in
  Sys.file_exists path && not (Sys.is_directory path)
;;

(* Cheap, deterministic upward walk: the first ancestor whose sol.yml is the
   workspace root. No ecosystem marker is consulted -- not dune-project, not
   package.json, not .git (DEC-024 clause 5). *)
let find_root ~dir =
  let rec go dir =
    if has_workspace_file dir
    then Some dir
    else (
      let parent = Filename.dirname dir in
      if parent = dir then None else go parent)
  in
  go dir
;;

let resolve ~dir =
  match find_root ~dir with
  | Some root -> Ok root
  | None -> Error Not_in_workspace
;;

(* Join a workspace-root-relative path to the resolved workspace root, so a
   command that did not chdir (e.g. `sol deploy`, which must keep the
   invocation cwd for `--emit-to` paths) still reads workspace files from the
   same place regardless of where it was invoked. Falls back to the path as
   given when there is no workspace: callers either fail closed first or are
   operating on explicitly supplied paths (e.g. tests under _build). *)
let at_root path =
  match find_root ~dir:(Sys.getcwd ()) with
  | Some root -> Filename.concat root path
  | None -> path
;;

let workspace_name ~root = Filename.basename root

(* The workspace name for the process cwd. Commands that key deployments by
   workspace use this instead of [Filename.basename (Sys.getcwd ())], so a
   command run in a descendant directory names the same workspace as one run
   from the root (DEC-024 clause 4). When there is no workspace at all this
   falls back to the cwd basename; commands that must fail closed do so through
   [resolve]/[load_for_target] before the name matters. *)
let current_name () =
  match find_root ~dir:(Sys.getcwd ()) with
  | Some root -> workspace_name ~root
  | None -> Filename.basename (Sys.getcwd ())
;;

(* Directories that are never part of the workspace's own application tree.
   Skipping [vendor] avoids walking a vendored copy of another project whose
   own sol.yml would be a false nested-boundary report. *)
let ignored_dir name =
  name = "_build" || name = "node_modules" || name = "vendor" || name = "dist"
;;

let is_symlink path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_LNK; _ } -> true
  | _ -> false
  | exception Unix.Unix_error _ -> false
;;

(* Nested-boundary validation (DEC-024 clause 2): walk *down* from the root and
   refuse a second sol.yml below it, because a command run inside the inner
   workspace would otherwise bind to it silently. Deliberately separate from
   [find_root], which walks *up* from the current directory to the nearest sol.yml
   (cheap, like git finding .git): only discovery and the command boundary pay for
   this recursive scan, where the invariant must hold.

   Symlinks are never followed. A symlinked checkout inside the workspace -- say
   `vendor/sol -> ~/Code/sol` -- contains sol.yml files of its own (Sol's
   examples/pluto/sol.yml) that would read as nested workspaces, and a symlink
   that points back up the tree would make this walk recurse forever.
   Reports both boundaries rather than silently shadowing. *)
let validate ~root =
  let rec go dir =
    let entries =
      try Sys.readdir dir with
      | Sys_error _ -> [||]
    in
    Array.find_map
      (fun entry ->
         if entry = "" || entry.[0] = '.' || ignored_dir entry
         then None
         else (
           let path = Filename.concat dir entry in
           if is_symlink path
           then None
           else if has_workspace_file path
           then Some path
           else if Sys.is_directory path
           then go path
           else None))
      entries
  in
  match go root with
  | None -> Ok ()
  | Some inner -> Error (Nested_workspace { outer = root; inner })
;;

let resolve_validated ~dir =
  match resolve ~dir with
  | Error _ as e -> e
  | Ok root ->
    (match validate ~root with
     | Ok () -> Ok root
     | Error _ as e -> e)
;;

(* Resolve the workspace and make it the process cwd, so every relative path
   inside the workspace (discovery, sol.toml, the build context) is workspace
   root relative no matter which descendant directory the command started in.
   [sol up]/[sol check]/[sol logs] run from any descendant and act on the
   workspace, per DEC-024 clause 4. *)
let enter ~dir =
  match resolve_validated ~dir with
  | Error _ as e -> e
  | Ok root ->
    Sys.chdir root;
    Ok root
;;

(* REFAC-108: the one way a command establishes its workspace. Every command that
   acts on the workspace calls this at its edge, so the boundary is always
   validated (DEC-024 clause 2), absence always fails closed, and the cwd is the
   root for the rest of the command. The root is returned for callers that need
   it by name; a caller that only needs the cwd to be the root may ignore it. *)
type t =
  { root : string
  ; name : string
  }

let enter_or_exit () =
  match enter ~dir:(Sys.getcwd ()) with
  | Ok root -> { root; name = workspace_name ~root }
  | Error e ->
    Printf.eprintf "sol: %s\n" (workspace_error_to_string e);
    exit 1
;;

(** Count .sql files in [dir]/db/migrations. Returns 0 if the directory does not
    exist. Used by [sol up] to warn users about unapplied migrations. *)
let pending_migration_count ~dir =
  let mig_dir = Filename.concat dir "db/migrations" in
  if Sys.file_exists mig_dir && Sys.is_directory mig_dir
  then
    Array.fold_left
      (fun acc f ->
         if Filename.check_suffix f ".sql" && not (Filename.check_suffix f ".down.sql")
         then acc + 1
         else acc)
      0
      (Sys.readdir mig_dir)
  else 0
;;
