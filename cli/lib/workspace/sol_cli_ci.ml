module Tree = Sol_cli_scaffold_tree
module Assets = Sol_cli_platform_assets
open Result.Syntax

let workflow = ".github/workflows/sol-ci.yml"
let target_rel = ".github/workflows/sol-ci.yml"
let template_kind = "workspace"

type outcome =
  { written : bool
  ; path : string
  }

let substitute vars text =
  List.fold_left
    (fun text (key, value) ->
       let needle = "{{" ^ key ^ "}}" in
       let nlen = String.length needle in
       let buf = Buffer.create (String.length text) in
       let rec loop i =
         if i >= String.length text
         then ()
         else if i + nlen <= String.length text && String.sub text i nlen = needle
         then (
           Buffer.add_string buf value;
           loop (i + nlen))
         else (
           Buffer.add_char buf text.[i];
           loop (i + 1))
       in
       loop 0;
       Buffer.contents buf)
    text
    vars
;;

let workspace_name workspace_root =
  Filename.basename workspace_root |> Sol_cli_scaffold.normalize
;;

let render ~root ~workspace_root =
  let name = workspace_name workspace_root in
  let vars =
    [ "name", name; "Name", Sol_cli_scaffold.capitalize_name name; "basename", name ]
  in
  let* text = Tree.text ~root ~kind:template_kind ~rel:workflow in
  Ok (substitute vars text)
;;

let init_github ~force ~cwd =
  let* assets = Assets.resolve () |> Result.map_error Assets.error_to_string in
  let root = Assets.templates_root assets in
  let workspace_root = Option.value (Sol_cli_workspace.find_root ~dir:cwd) ~default:cwd in
  let* rendered = render ~root ~workspace_root in
  let path = Filename.concat workspace_root target_rel in
  match Sol_cli_fs.read_file_opt path with
  | Some existing when String.equal existing rendered -> Ok { written = false; path }
  | Some _ when not force ->
    Error
      (Printf.sprintf
         "%s already exists and differs from the supported workflow; re-run with --force \
          to overwrite it, or reconcile the differences by hand"
         target_rel)
  | _ ->
    let* () = Sol_cli_fs.mkdir_p (Filename.dirname path) in
    let* () = Sol_cli_fs.write_atomic path rendered in
    Ok { written = true; path }
;;
