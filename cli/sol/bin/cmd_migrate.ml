open Cmdliner

(* Per-workspace table name avoids version-number collisions when multiple
   workspaces share one local Postgres instance; --table always overrides it. *)
let default_table_name =
  let cwd_name = Filename.basename (Sys.getcwd ()) in
  let buf = Buffer.create (String.length cwd_name) in
  String.iter
    (fun c ->
      if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') then
        Buffer.add_char buf c
      else if c >= 'A' && c <= 'Z' then
        Buffer.add_char buf (Char.lowercase_ascii c)
      else Buffer.add_char buf '_')
    cwd_name;
  Printf.sprintf "sol_%s_schema_migrations" (Buffer.contents buf)

let cluster_pg_exists () =
  match
    Sol_cli_kubectl.get ~resource:"svc" ~name:"postgresql"
      ~namespace:"postgresql" ~output:"name"
  with
  | Ok r -> r.Sol_cli_process.exit_code = 0
  | Error _ -> false

(* Start a background port-forward to cluster postgres and return the local URL.
   Registers at_exit cleanup so the forward is killed when the process exits. *)
let auto_forward_pg () =
  Printf.printf "Forwarding postgresql (cluster) → localhost:15432 ...\n%!";
  let devnull_w = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
  let pid =
    try
      Unix.create_process "kubectl"
        [|
          "kubectl";
          "port-forward";
          "svc/postgresql";
          "-n";
          "postgresql";
          "15432:5432";
        |]
        Unix.stdin devnull_w devnull_w
    with Unix.Unix_error (e, fn, _) ->
      Unix.close devnull_w;
      Printf.eprintf "error: could not start kubectl port-forward: %s: %s\n" fn
        (Unix.error_message e);
      exit 1
  in
  Unix.close devnull_w;
  at_exit (fun () ->
      (try Unix.kill pid Sys.sigterm with _ -> ());
      try ignore (Unix.waitpid [ Unix.WNOHANG ] pid) with _ -> ());
  (* Poll until localhost:15432 accepts a TCP connection, up to 5 s. Only
     the connect-failure codes that genuinely mean "nothing is listening
     yet" are treated as expected and retried silently; anything else
     (fd exhaustion, permission issues, ...) is a real problem that ten
     silent retries would otherwise mask behind a generic "did not become
     ready in time" — surfaced immediately instead, without wasting the
     remaining attempts on a failure that retrying can't fix. *)
  let is_not_listening_yet = function
    | Unix.ECONNREFUSED | Unix.ETIMEDOUT | Unix.ENETUNREACH | Unix.EHOSTUNREACH
    | Unix.ECONNRESET ->
        true
    | _ -> false
  in
  let check_connect () =
    match Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 with
    | exception Unix.Unix_error (e, fn, _) ->
        `Failed (Printf.sprintf "%s: %s" fn (Unix.error_message e))
    | s -> (
        let addr = Unix.ADDR_INET (Unix.inet_addr_loopback, 15432) in
        match Unix.connect s addr with
        | () ->
            Unix.close s;
            `Ready
        | exception Unix.Unix_error (e, _, _) when is_not_listening_yet e ->
            Unix.close s;
            `Not_listening_yet
        | exception Unix.Unix_error (e, fn, _) ->
            Unix.close s;
            `Failed (Printf.sprintf "%s: %s" fn (Unix.error_message e))
        | exception exn ->
            Unix.close s;
            `Failed (Printexc.to_string exn))
  in
  let max_attempts = 10 in
  let rec wait n =
    if n = 0 then
      Printf.eprintf "warning: port-forward did not become ready in time\n%!"
    else
      match check_connect () with
      | `Ready -> ()
      | `Not_listening_yet ->
          Unix.sleepf 0.5;
          wait (n - 1)
      | `Failed msg ->
          Printf.eprintf "warning: port-forward readiness check failed: %s\n%!"
            msg
  in
  wait max_attempts;
  "postgresql://postgres:dev@localhost:15432/dev"

let get_postgres_url () =
  match Sys.getenv_opt "POSTGRES_URL" with
  | Some u -> u
  | None ->
      if cluster_pg_exists () then auto_forward_pg ()
      else begin
        Printf.eprintf
          "error: POSTGRES_URL not set and no cluster postgres found.\n";
        Printf.eprintf "  Run 'sol dev up' first, then retry.\n";
        exit 1
      end

let with_pool url f =
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          match
            Pg_db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) ()
          with
          | Error e ->
              Printf.eprintf "error: cannot connect to database: %s\n"
                (Pg_error.to_string e);
              exit 1
          | Ok pool -> f ~fs:env#fs pool))

(* ── apply ───────────────────────────────────────────────────────────────── *)

(* Print SQL files from [dir] in order without connecting to the database.
   Used by --dry-run to let operators preview migration SQL before applying. *)
let print_pending_sql dir =
  let migration_ext = ".sql" in
  let down_ext = ".down.sql" in
  let files =
    match Sys.readdir dir with
    | exception Sys_error msg ->
        Printf.eprintf "error: cannot read migrations dir: %s\n" msg;
        exit 1
    | arr ->
        Array.to_list arr
        |> List.filter (fun f ->
            Filename.check_suffix f migration_ext
            && not (Filename.check_suffix f down_ext))
        |> List.sort String.compare
  in
  if files = [] then Printf.printf "(no migration files found in %s)\n" dir
  else
    List.iter
      (fun fname ->
        let path = Filename.concat dir fname in
        let content = In_channel.with_open_text path In_channel.input_all in
        Printf.printf "-- %s\n%s\n\n" fname content)
      files

let run_apply_local dir table dry_run =
  if dry_run then print_pending_sql dir
  else begin
    let url = get_postgres_url () in
    with_pool url (fun ~fs pool ->
        Printf.printf "Applying migrations from %s...\n%!" dir;
        match Migration.apply ~table pool ~dir ~fs with
        | Ok () -> Printf.printf "Done.\n"
        | Error e ->
            Printf.eprintf "error: %s\n" (Pg_error.to_string e);
            exit 1)
  end

(* ── in-cluster migration Job (FRIC-012) ────────────────────────────────────
   A real deployment's Postgres (RDS, etc.) is correctly not reachable from
   outside the VPC -- confirmed live during DOGFOOD-011 (a 2-minute
   Connection timed out running sol migrate from an operator's laptop, with
   no network path at all, not a misconfiguration). Rather than punching a
   hole in that security posture or requiring every operator/CI runner to
   set up their own bastion/VPN, run the exact same Migration.apply logic
   from a one-shot Kubernetes Job inside the cluster, where the security
   group already allows access. This reuses infrastructure Sol already
   owns (the cluster, the workspace's runtime secret) instead of adding a
   new standing component, and generalizes to CI for free -- a GitHub
   Actions runner has the same external-network problem a laptop does, and
   can't hold an SSM session open the way an interactive operator could. *)

let fatal msg =
  Printf.eprintf "error: %s\n" msg;
  exit 1

let fatal_p fmt = Printf.ksprintf fatal fmt

(* Same opam-pin/base-image block cli/sol/lib/sol_cli_scaffold_templates.ml's
   tpl_dockerfile and the example workspace Dockerfiles use, trimmed to just
   what cli/sol/bin/main.exe itself links (see cli/sol/bin/dune) -- kept in
   sync by hand, same as every other place this block is duplicated. *)
let sol_cli_dockerfile =
  {docker|FROM ocaml/opam:ubuntu-24.04-ocaml-5.4 AS build
RUN sudo apt-get update && sudo apt-get install -y librdkafka-dev libpq-dev libssl-dev
RUN opam repository set-url default https://opam.ocaml.org && \
    opam update && \
    opam pin add obs-eio https://github.com/loganbnielsen/obs-eio.git#main -y && \
    opam pin add obs-loki-eio https://github.com/loganbnielsen/obs-loki-eio.git#main -y && \
    opam pin add pg-eio https://github.com/loganbnielsen/pg-eio.git#main -y
RUN opam install -y --no-self-upgrade \
    eio eio_main cmdliner yojson otoml ptime \
    caqti-eio caqti-driver-postgresql
COPY --chown=opam:opam . /workspace
WORKDIR /workspace
RUN opam exec -- dune build cli/sol/bin/main.exe

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y libpq5 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /workspace/_build/default/cli/sol/bin/main.exe /usr/local/bin/sol
ENTRYPOINT ["/usr/local/bin/sol"]
|docker}

let write_temp_file ~suffix content =
  let path = Filename.temp_file "sol-migrate-" suffix in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  path

let read_migration_files dir =
  let ext = ".sql" in
  match Sys.readdir dir with
  | exception Sys_error msg -> fatal_p "cannot read migrations dir: %s" msg
  | arr ->
      Array.to_list arr
      |> List.filter (fun f -> Filename.check_suffix f ext)
      |> List.sort String.compare
      |> List.map (fun fname ->
          let content =
            In_channel.with_open_text
              (Filename.concat dir fname)
              In_channel.input_all
          in
          (fname, content))

let run_kubectl ?(timeout_s = 30.) argv =
  Sol_cli_process.run (Sol_cli_process.cmd ~timeout_s ("kubectl" :: argv))

(* [on_fail] runs before erroring out -- used to clean up a ConfigMap that
   already applied successfully if the following Job apply then fails, so a
   half-created migration attempt doesn't leave stray cluster objects. *)
let kubectl_apply_or_fatal ~what ?(on_fail = fun () -> ()) argv =
  match run_kubectl argv with
  | Ok r when r.Sol_cli_process.exit_code = 0 -> ()
  | Ok r ->
      on_fail ();
      fatal_p "%s: %s" what r.Sol_cli_process.stderr
  | Error e ->
      on_fail ();
      fatal_p "%s: %s" what (Sol_cli_process.error_to_string e)

(* Matches Sol_cli_secret's own yaml_quote exactly (that module can't be
   reused directly here -- private to its own file -- but the escaping
   rules for a YAML double-quoted scalar are the same regardless of what's
   being embedded). Migration file *contents* are arbitrary SQL, not a
   controlled value, so every C0 control character needs an escape, not
   just the three most obvious ones -- an unescaped \r silently gets
   YAML-folded into a space by the double-quoted-scalar line-folding rule,
   corrupting CRLF-terminated SQL without so much as a parse error. *)
let yaml_dq s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (function
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | c when Char.code c < 0x20 ->
          Buffer.add_string b (Printf.sprintf "\\x%02X" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

(* ponytail: a ConfigMap has a 1MiB total size cap -- fine for typical
   migration sets, but a workspace with unusually large SQL files could
   exceed it. Move to a projected volume backed by multiple ConfigMaps (or
   an init-container that fetches files another way) if that ever bites. *)
let render_configmap ~name ~namespace files =
  let entries =
    files
    |> List.map (fun (fname, content) ->
        Printf.sprintf "  %s: %s" (yaml_dq fname) (yaml_dq content))
    |> String.concat "\n"
  in
  Printf.sprintf
    {|apiVersion: v1
kind: ConfigMap
metadata:
  name: %s
  namespace: %s
data:
%s
|}
    name namespace entries

let render_job ~name ~namespace ~image ~table ~configmap_name =
  Printf.sprintf
    {|apiVersion: batch/v1
kind: Job
metadata:
  name: %s
  namespace: %s
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: %s
          args: ["migrate", "apply", "--dir", "/migrations", "--table", %s]
          envFrom:
            - secretRef:
                name: %s
          volumeMounts:
            - name: migrations
              mountPath: /migrations
      volumes:
        - name: migrations
          configMap:
            name: %s
|}
    name namespace image (yaml_dq table) Sol_cli_manifest.runtime_secret_name
    configmap_name

(* Migrations aren't domain-scoped, so any already-deployed domain's
   namespace works -- RDS network reachability is enforced at the
   VPC/security-group level (main.tf), not per-namespace. Sorted so the
   choice is deterministic across runs rather than dependent on
   Sys.readdir's unspecified order. *)
(* Also returns a k8s_name to push the migration runner image under: ECR
   (unlike Docker Hub) requires a repository to already exist before a
   push succeeds, and FRIC-011 provisions exactly one ECR repo per
   discovered app service -- there is no "sol-cli" repo to push a
   standalone tool image to. Reusing this same service's repo path with a
   distinct tag (not a version tag) avoids needing a new, otherwise-empty
   repository just for this one-off image. *)
let pick_namespace_and_service ~workspace =
  match Sol_cli_manifest.discover_services ~filter_path:None with
  | [] ->
      fatal
        "no deployed service found in this workspace -- nothing to run the \
         migration Job in, and no ECR repository to push the migration runner \
         image to. Deploy at least one service first."
  | services ->
      let chosen =
        services
        |> List.sort (fun (a : Sol_cli_manifest.service) b ->
            compare
              (a.Sol_cli_manifest.domain, a.Sol_cli_manifest.name)
              (b.Sol_cli_manifest.domain, b.Sol_cli_manifest.name))
        |> List.hd
      in
      let namespace =
        match
          Sol_cli_deployment_plan.namespace_result ~workspace
            ~domain:chosen.Sol_cli_manifest.domain
        with
        | Ok ns -> Sol_cli_deployment_plan.namespace_to_string ns
        | Error e -> fatal (Sol_cli_deployment_plan.plan_error_to_string e)
      in
      let k8s_name =
        match
          Sol_cli_deployment_plan.k8s_name_result chosen.Sol_cli_manifest.name
        with
        | Ok n -> n
        | Error e -> fatal (Sol_cli_deployment_plan.plan_error_to_string e)
      in
      (namespace, k8s_name)

let run_apply_in_cluster ~target ~dir ~table ~registry_override =
  match Sol_cli_config.load_for_target ~target with
  | Error e -> fatal (Sol_cli_config.error_to_string e)
  | Ok cfg -> (
      match Sol_cli_config.target cfg with
      | None -> fatal_p "target %S not found" target
      | Some target_cfg ->
          let registry =
            match registry_override with
            | Some r -> r
            | None -> (
                match target_cfg.Sol_cli_config.registry with
                | Some r -> r
                | None ->
                    fatal
                      "no registry configured for this target -- pass \
                       --registry or set target.registry in sol.yml.")
          in
          let sol_home =
            match Sol_cli_cmd_new.infer_sol_home () with
            | Some dir -> dir
            | None ->
                fatal
                  "cannot locate the Sol checkout to build the migration \
                   runner image -- set SOL_HOME."
          in
          let workspace = Filename.basename (Sys.getcwd ()) in
          let namespace, k8s_name = pick_namespace_and_service ~workspace in
          let files = read_migration_files dir in
          if files = [] then
            Printf.printf "(no migration files found in %s -- nothing to do)\n"
              dir
          else begin
            let image =
              Sol_cli_deployment_plan.image_ref ~registry ~workspace ~k8s_name
                ~tag:"sol-cli-migrate"
            in
            Printf.printf "Building migration runner image %s...\n%!" image;
            let dockerfile =
              write_temp_file ~suffix:".Dockerfile" sol_cli_dockerfile
            in
            (match
               Sol_cli_docker.build ~tag:image ~dockerfile ~context:sol_home
             with
            | Error e ->
                fatal_p "docker build: %s" (Sol_cli_process.error_to_string e)
            | Ok () -> ());
            (try Sys.remove dockerfile with _ -> ());
            Printf.printf "Pushing %s...\n%!" image;
            (match Sol_cli_docker.push ~image_ref:image with
            | Error e ->
                fatal_p "docker push: %s" (Sol_cli_process.error_to_string e)
            | Ok () -> ());

            let run_id =
              Printf.sprintf "%.0f" (Unix.gettimeofday () *. 1000.)
            in
            let job_name = Printf.sprintf "sol-migrate-%s" run_id in
            let configmap_name = Printf.sprintf "sol-migrate-files-%s" run_id in

            let cleanup () =
              ignore
                (run_kubectl
                   [
                     "delete";
                     "job";
                     job_name;
                     "-n";
                     namespace;
                     "--ignore-not-found";
                     "--wait=false";
                   ]);
              ignore
                (run_kubectl
                   [
                     "delete";
                     "configmap";
                     configmap_name;
                     "-n";
                     namespace;
                     "--ignore-not-found";
                   ])
            in

            let configmap_yaml =
              write_temp_file ~suffix:".yaml"
                (render_configmap ~name:configmap_name ~namespace files)
            in
            let job_yaml =
              write_temp_file ~suffix:".yaml"
                (render_job ~name:job_name ~namespace ~image ~table
                   ~configmap_name)
            in

            Printf.printf "Submitting migration Job %s in namespace %s...\n%!"
              job_name namespace;
            kubectl_apply_or_fatal ~what:"kubectl apply (configmap)"
              [ "apply"; "-f"; configmap_yaml ];
            kubectl_apply_or_fatal ~what:"kubectl apply (job)" ~on_fail:cleanup
              [ "apply"; "-f"; job_yaml ];
            (try Sys.remove configmap_yaml with _ -> ());
            (try Sys.remove job_yaml with _ -> ());

            (* kubectl wait's own --for=condition=complete never returns on a
           failed (not completed) Job -- it would sit out the full timeout
           on every failure. Poll the status fields directly instead, same
           bounded-retry shape .github/workflows/ci.yml's own health check
           already uses.

           JobStatus's succeeded/failed fields are `omitempty`: a Job that
           completed one way has only ONE of them present at all, so a
           single "{.status.succeeded} {.status.failed}" jsonpath query
           produces "1 " or " 1" -- and Sol_cli_process.run already trims
           stdout before this code ever sees it, collapsing that down to a
           single token that can't match a 2-element split. Query each
           field with its own jsonpath instead, so an absent field just
           trims to "" rather than corrupting the other field's parse. *)
            let job_field field =
              match
                run_kubectl ~timeout_s:15.
                  [
                    "get";
                    "job";
                    job_name;
                    "-n";
                    namespace;
                    "-o";
                    Printf.sprintf "jsonpath={.status.%s}" field;
                  ]
              with
              | Ok r -> String.trim r.Sol_cli_process.stdout
              | Error _ -> ""
            in
            let job_status () =
              ( job_field "succeeded" = "1",
                match job_field "failed" with "" | "0" -> false | _ -> true )
            in
            let rec wait_for_completion n =
              if n = 0 then `Timed_out
              else
                match job_status () with
                | true, _ -> `Succeeded
                | _, true -> `Failed
                | false, false ->
                    Unix.sleepf 2.;
                    wait_for_completion (n - 1)
            in
            let outcome =
              wait_for_completion 150
              (* ~300s at 2s/poll *)
            in
            Printf.printf "\n--- migration Job logs (%s) ---\n%!" job_name;
            (match
               run_kubectl ~timeout_s:30.
                 [ "logs"; Printf.sprintf "job/%s" job_name; "-n"; namespace ]
             with
            | Ok r -> print_string r.Sol_cli_process.stdout
            | Error e ->
                Printf.eprintf "warning: could not fetch job logs: %s\n"
                  (Sol_cli_process.error_to_string e));
            Printf.printf "--- end logs ---\n\n%!";
            (match outcome with
            | `Timed_out ->
                Printf.eprintf
                  "error: migration Job did not complete within 300s\n"
            | `Succeeded | `Failed -> ());
            let succeeded = outcome = `Succeeded in
            cleanup ();
            if succeeded then Printf.printf "Done.\n"
            else begin
              Printf.eprintf "error: migration Job failed -- see logs above.\n";
              exit 1
            end
          end)

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
          List.iter
            (fun (s : Migration.status) ->
              Printf.printf "%-6d  %-30s  %s\n" s.version s.name
                (Option.value ~default:"(pending)" s.applied_at))
            rows)

(* ── rollback ────────────────────────────────────────────────────────────── *)

let run_rollback dir table () =
  let url = get_postgres_url () in
  with_pool url (fun ~fs pool ->
      match Migration.rollback ~table pool ~dir ~fs with
      | Ok () -> Printf.printf "Rolled back.\n"
      | Error e ->
          Printf.eprintf "error: %s\n" (Pg_error.to_string e);
          exit 1)

(* ── apply dispatch: local direct-connect vs in-cluster Job ────────────────── *)

let run_apply dir table dry_run target registry =
  if dry_run then print_pending_sql dir
  else
    match target with
    | None -> run_apply_local dir table dry_run
    | Some target ->
        run_apply_in_cluster ~target ~dir ~table ~registry_override:registry

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let dir_arg =
  Arg.(
    value & opt string "db/migrations"
    & info [ "dir" ] ~docv:"DIR"
        ~doc:"Directory containing migration SQL files (default: db/migrations)")

let table_arg =
  Arg.(
    value
    & opt string default_table_name
    & info [ "table" ] ~docv:"TABLE"
        ~doc:
          "Migration tracking table name (default: \
           sol_<workspace>_schema_migrations; override with this flag to share \
           a table across workspaces)")

let dry_run_flag =
  Arg.(
    value & flag
    & info [ "dry-run" ]
        ~doc:"Print pending migration SQL to stdout without applying")

let target_arg =
  Arg.(
    value
    & pos 0 (some string) None
    & info [] ~docv:"TARGET"
        ~doc:
          "Deployment target path: <env>/<provider>/<region>. When given, \
           migrations run from a one-shot Kubernetes Job inside the target's \
           cluster instead of connecting directly from this machine — required \
           for any real deployment whose database (e.g. RDS) isn't reachable \
           from outside its network by design (FRIC-012). Omit for the local \
           dev cluster, which remains directly reachable via kubectl \
           port-forward.")

let registry_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "registry" ] ~docv:"URL"
        ~doc:
          "Container registry to push the migration runner image to. Omit to \
           fall back to the resolved target's own registry. Only meaningful \
           together with TARGET.")

let apply_cmd =
  Cmd.v
    (Cmd.info "apply" ~doc:"Apply all pending migrations (default subcommand)")
    Term.(
      const run_apply $ dir_arg $ table_arg $ dry_run_flag $ target_arg
      $ registry_arg)

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
    (Cmd.info "migrate" ~doc:"Run database migrations against POSTGRES_URL")
    ~default:
      Term.(
        const run_apply $ dir_arg $ table_arg $ dry_run_flag $ target_arg
        $ registry_arg)
    [ apply_cmd; status_cmd; rollback_cmd ]
