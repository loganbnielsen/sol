open Cmdliner

(* Per-workspace table name avoids version-number collisions when multiple
   workspaces share one local Postgres instance; --table always overrides it. *)
let default_table_name =
  let cwd_name = Filename.basename (Sys.getcwd ()) in
  let buf = Buffer.create (String.length cwd_name) in
  String.iter (fun c ->
    if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') then Buffer.add_char buf c
    else if c >= 'A' && c <= 'Z' then Buffer.add_char buf (Char.lowercase_ascii c)
    else Buffer.add_char buf '_'
  ) cwd_name;
  Printf.sprintf "sol_%s_schema_migrations" (Buffer.contents buf)

let cluster_pg_exists () =
  match Sol_cli_kubectl.get ~resource:"svc" ~name:"postgresql"
          ~namespace:"postgresql" ~output:"name" with
  | Ok r -> r.Sol_cli_process.exit_code = 0
  | Error _ -> false

(* Start a background port-forward to cluster postgres and return the local URL.
   Registers at_exit cleanup so the forward is killed when the process exits. *)
let auto_forward_pg () =
  Printf.printf "Forwarding postgresql (cluster) → localhost:15432 ...\n%!";
  let devnull_w = Unix.openfile "/dev/null" [Unix.O_WRONLY] 0 in
  let pid =
    try
      Unix.create_process "kubectl"
        [|"kubectl"; "port-forward"; "svc/postgresql";
          "-n"; "postgresql"; "15432:5432"|]
        Unix.stdin devnull_w devnull_w
    with Unix.Unix_error (e, fn, _) ->
      Unix.close devnull_w;
      Printf.eprintf "error: could not start kubectl port-forward: %s: %s\n"
        fn (Unix.error_message e);
      exit 1
  in
  Unix.close devnull_w;
  at_exit (fun () ->
    (try Unix.kill pid Sys.sigterm with _ -> ());
    (try ignore (Unix.waitpid [Unix.WNOHANG] pid) with _ -> ()));
  (* Poll until localhost:15432 accepts a TCP connection, up to 5 s. Only
     the connect-failure codes that genuinely mean "nothing is listening
     yet" are treated as expected and retried silently; anything else
     (fd exhaustion, permission issues, ...) is a real problem that ten
     silent retries would otherwise mask behind a generic "did not become
     ready in time" — surfaced immediately instead, without wasting the
     remaining attempts on a failure that retrying can't fix. *)
  let is_not_listening_yet = function
    | Unix.ECONNREFUSED | Unix.ETIMEDOUT | Unix.ENETUNREACH
    | Unix.EHOSTUNREACH | Unix.ECONNRESET -> true
    | _ -> false
  in
  let check_connect () =
    match Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 with
    | exception Unix.Unix_error (e, fn, _) -> `Failed (Printf.sprintf "%s: %s" fn (Unix.error_message e))
    | s ->
      let addr = Unix.ADDR_INET (Unix.inet_addr_loopback, 15432) in
      (match Unix.connect s addr with
       | () -> Unix.close s; `Ready
       | exception Unix.Unix_error (e, _, _) when is_not_listening_yet e ->
         Unix.close s; `Not_listening_yet
       | exception Unix.Unix_error (e, fn, _) ->
         Unix.close s; `Failed (Printf.sprintf "%s: %s" fn (Unix.error_message e))
       | exception exn ->
         Unix.close s; `Failed (Printexc.to_string exn))
  in
  let max_attempts = 10 in
  let rec wait n =
    if n = 0 then
      Printf.eprintf "warning: port-forward did not become ready in time\n%!"
    else
      match check_connect () with
      | `Ready -> ()
      | `Not_listening_yet -> Unix.sleepf 0.5; wait (n - 1)
      | `Failed msg -> Printf.eprintf "warning: port-forward readiness check failed: %s\n%!" msg
  in
  wait max_attempts;
  "postgresql://postgres:dev@localhost:15432/dev"

let get_postgres_url () =
  match Sys.getenv_opt "POSTGRES_URL" with
  | Some u -> u
  | None ->
    if cluster_pg_exists () then
      auto_forward_pg ()
    else begin
      Printf.eprintf "error: POSTGRES_URL not set and no cluster postgres found.\n";
      Printf.eprintf "  Run 'sol dev up' first, then retry.\n";
      exit 1
    end

let with_pool url f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      match Pg_db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) () with
      | Error e ->
        Printf.eprintf "error: cannot connect to database: %s\n" (Pg_error.to_string e);
        exit 1
      | Ok pool -> f ~fs:env#fs pool
    )
  )

(* ── apply ───────────────────────────────────────────────────────────────── *)

(* Print SQL files from [dir] in order without connecting to the database.
   Used by --dry-run to let operators preview migration SQL before applying. *)
let print_pending_sql dir =
  let migration_ext = ".sql" in
  let down_ext = ".down.sql" in
  let files =
    match Sys.readdir dir with
    | exception Sys_error msg ->
      Printf.eprintf "error: cannot read migrations dir: %s\n" msg; exit 1
    | arr ->
      Array.to_list arr
      |> List.filter (fun f ->
           Filename.check_suffix f migration_ext &&
           not (Filename.check_suffix f down_ext))
      |> List.sort String.compare
  in
  if files = [] then Printf.printf "(no migration files found in %s)\n" dir
  else
    List.iter (fun fname ->
      let path = Filename.concat dir fname in
      let content =
        In_channel.with_open_text path In_channel.input_all
      in
      Printf.printf "-- %s\n%s\n\n" fname content
    ) files

let run_apply dir table dry_run =
  if dry_run then
    print_pending_sql dir
  else begin
    let url = get_postgres_url () in
    with_pool url (fun ~fs pool ->
      Printf.printf "Applying migrations from %s...\n%!" dir;
      match Migration.apply ~table pool ~dir ~fs with
      | Ok () -> Printf.printf "Done.\n"
      | Error e ->
        Printf.eprintf "error: %s\n" (Pg_error.to_string e);
        exit 1
    )
  end

(* ── status ──────────────────────────────────────────────────────────────── *)

let run_status dir table () =
  let url = get_postgres_url () in
  with_pool url (fun ~fs pool ->
    match Migration.status ~table pool ~dir ~fs with
    | Error e ->
      Printf.eprintf "error: %s\n" (Pg_error.to_string e);
      exit 1
    | Ok rows ->
      Printf.printf "%-6s  %-30s  %s\n" "VER" "NAME" "APPLIED AT";
      Printf.printf "%s\n" (String.make 60 '-');
      List.iter (fun (s : Migration.status) ->
        Printf.printf "%-6d  %-30s  %s\n" s.version s.name
          (Option.value ~default:"(pending)" s.applied_at)
      ) rows
  )

(* ── rollback ────────────────────────────────────────────────────────────── *)

let run_rollback dir table () =
  let url = get_postgres_url () in
  with_pool url (fun ~fs pool ->
    match Migration.rollback ~table pool ~dir ~fs with
    | Ok () -> Printf.printf "Rolled back.\n"
    | Error e ->
      Printf.eprintf "error: %s\n" (Pg_error.to_string e);
      exit 1
  )

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let dir_arg =
  Arg.(value & opt string "db/migrations" &
       info ["dir"] ~docv:"DIR"
         ~doc:"Directory containing migration SQL files (default: db/migrations)")

let table_arg =
  Arg.(value & opt string default_table_name &
       info ["table"] ~docv:"TABLE"
         ~doc:"Migration tracking table name \
               (default: sol_<workspace>_schema_migrations; \
               override with this flag to share a table across workspaces)")

let dry_run_flag =
  Arg.(value & flag &
       info ["dry-run"]
         ~doc:"Print pending migration SQL to stdout without applying")

let apply_cmd =
  Cmd.v
    (Cmd.info "apply" ~doc:"Apply all pending migrations (default subcommand)")
    Term.(const run_apply $ dir_arg $ table_arg $ dry_run_flag)

let status_cmd =
  Cmd.v
    (Cmd.info "status" ~doc:"Show per-file applied/pending status")
    Term.(const run_status $ dir_arg $ table_arg $ const ())

let rollback_cmd =
  Cmd.v
    (Cmd.info "rollback" ~doc:"Roll back the last applied migration")
    Term.(const run_rollback $ dir_arg $ table_arg $ const ())

let cmd =
  Cmd.group
    (Cmd.info "migrate"
       ~doc:"Run database migrations against POSTGRES_URL")
    ~default:Term.(const run_apply $ dir_arg $ table_arg $ dry_run_flag)
    [ apply_cmd; status_cmd; rollback_cmd ]
