type infra_requirements = {
  kafka      : bool;
  postgres   : bool;
  loki       : bool;
  prometheus : bool;
  tempo      : bool;
}


let read_file path = In_channel.with_open_text path In_channel.input_all

let has_app_dir dir =
  let app_dir = Filename.concat dir "app" in
  Sys.file_exists app_dir && Sys.is_directory app_dir

let find_root ~dir =
  let rec go dir =
    if has_app_dir dir then Some dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then None else go parent
  in
  go dir

(** Count .sql files in [dir]/db/migrations.  Returns 0 if the directory does
    not exist.  Used by [sol up] to warn users about unapplied migrations. *)
let pending_migration_count ~dir =
  let mig_dir = Filename.concat dir "db/migrations" in
  if Sys.file_exists mig_dir && Sys.is_directory mig_dir then
    Array.fold_left
      (fun acc f ->
        if Filename.check_suffix f ".sql" && not (Filename.check_suffix f ".down.sql")
        then acc + 1 else acc)
      0
      (Sys.readdir mig_dir)
  else
    0

let scan ~dir =
  let kafka      = ref false in
  let postgres   = ref false in
  let loki       = ref false in
  let prometheus = ref false in
  let tempo      = ref false in
  let rec collect d =
    (try
      Array.iter (fun entry ->
        if entry.[0] <> '.' then begin
          let path = Filename.concat d entry in
          if entry = "dune" then begin
            (try
              let content = read_file path in
              if Sol_cli_port_forward.string_contains ~needle:"kafka_eio_service"  content then kafka      := true;
              if Sol_cli_port_forward.string_contains ~needle:"pg-eio"             content then postgres   := true;
              if Sol_cli_port_forward.string_contains ~needle:"obs-loki-eio"       content then loki       := true;
              if Sol_cli_port_forward.string_contains ~needle:"obs-prometheus-eio" content then prometheus := true;
              if Sol_cli_port_forward.string_contains ~needle:"obs-tempo-eio"      content then tempo      := true;
            with _ -> ())
          end else if Sys.is_directory path then
            collect path
        end
      ) (Sys.readdir d)
    with _ -> ())
  in
  collect dir;
  { kafka = !kafka; postgres = !postgres; loki = !loki; prometheus = !prometheus; tempo = !tempo }
