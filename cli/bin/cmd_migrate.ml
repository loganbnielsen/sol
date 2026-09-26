open Cmdliner

(* Per-workspace table name avoids version-number collisions when multiple
   workspaces share one local Postgres instance; --table always overrides it. *)
let default_table_name =
  let cwd_name = Filename.basename (Sys.getcwd ()) in
  let buf = Buffer.create (String.length cwd_name) in
  String.iter
    (fun c ->
       if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
       then Buffer.add_char buf c
       else if c >= 'A' && c <= 'Z'
       then Buffer.add_char buf (Char.lowercase_ascii c)
       else Buffer.add_char buf '_')
    cwd_name;
  Printf.sprintf "sol_%s_schema_migrations" (Buffer.contents buf)
;;

let cluster_pg_exists ~ctx () =
  match
    Sol_cli_kubectl.get
      ~ctx
      ~resource:"svc"
      ~name:"postgresql"
      ~namespace:"postgresql"
      ~output:"name"
  with
  | Ok r -> r.Sol_cli_process.exit_code = 0
  | Error _ -> false
;;

(* Start a background port-forward to cluster postgres and return the local URL.
   Registers at_exit cleanup so the forward is killed when the process exits. *)
let auto_forward_pg ~ctx () =
  Printf.printf "Forwarding postgresql (cluster) → localhost:15432 ...\n%!";
  let devnull_w = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
  let context_name = ctx.Sol_cli_kube_destination.destination.context in
  (* FEAT-063: scoped like every other invocation -- [--context] in the argv and
     the destination's [KUBECONFIG] in the child env. *)
  let pid =
    try
      Unix.create_process_env
        "kubectl"
        [| "kubectl"
         ; "--context"
         ; context_name
         ; "port-forward"
         ; "svc/postgresql"
         ; "-n"
         ; "postgresql"
         ; "15432:5432"
        |]
        (Sol_cli_kube_destination.child_environment ctx)
        Unix.stdin
        devnull_w
        devnull_w
    with
    | Unix.Unix_error (e, fn, _) ->
      Unix.close devnull_w;
      Printf.eprintf
        "error: could not start kubectl port-forward: %s: %s\n"
        fn
        (Unix.error_message e);
      exit 1
  in
  Unix.close devnull_w;
  at_exit (fun () ->
    (try Unix.kill pid Sys.sigterm with
     | _ -> ());
    try ignore (Unix.waitpid [ Unix.WNOHANG ] pid) with
    | _ -> ());
  (* Poll until localhost:15432 accepts a TCP connection, up to 5 s. Only
     the connect-failure codes that genuinely mean "nothing is listening
     yet" are treated as expected and retried silently; anything else
     (fd exhaustion, permission issues, ...) is a real problem that ten
     silent retries would otherwise mask behind a generic "did not become
     ready in time" — surfaced immediately instead, without wasting the
     remaining attempts on a failure that retrying can't fix. *)
  let is_not_listening_yet = function
    | Unix.ECONNREFUSED
    | Unix.ETIMEDOUT
    | Unix.ENETUNREACH
    | Unix.EHOSTUNREACH
    | Unix.ECONNRESET -> true
    | _ -> false
  in
  let check_connect () =
    match Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 with
    | exception Unix.Unix_error (e, fn, _) ->
      `Failed (Printf.sprintf "%s: %s" fn (Unix.error_message e))
    | s ->
      let addr = Unix.ADDR_INET (Unix.inet_addr_loopback, 15432) in
      (match Unix.connect s addr with
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
    if n = 0
    then Printf.eprintf "warning: port-forward did not become ready in time\n%!"
    else (
      match check_connect () with
      | `Ready -> ()
      | `Not_listening_yet ->
        Unix.sleepf 0.5;
        wait (n - 1)
      | `Failed msg ->
        Printf.eprintf "warning: port-forward readiness check failed: %s\n%!" msg)
  in
  wait max_attempts;
  "postgresql://postgres:dev@localhost:15432/dev"
;;

let get_postgres_url ~ctx () =
  match Sys.getenv_opt "POSTGRES_URL" with
  | Some u -> u
  | None ->
    if cluster_pg_exists ~ctx ()
    then auto_forward_pg ~ctx ()
    else (
      Printf.eprintf "error: POSTGRES_URL not set and no cluster postgres found.\n";
      Printf.eprintf "  Run 'sol local infra up' first, then retry.\n";
      exit 1)
;;

(* INFRA-044: Pg/caqti errors may reproduce their connection URI verbatim.
   Rendering through this boundary inside the migration runner is essential:
   scrubbing only the parent CLI's copy would leave the credential in the
   Kubernetes Job's own logs and in every sink that collects them. *)
let pg_error_to_string ~url error =
  Sol_cli_redaction.connection_error ~url (Pg_error.to_string error)
;;

let with_pool url f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      match Pg_db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) () with
      | Error e ->
        Printf.eprintf
          "error: cannot connect to database: %s\n"
          (pg_error_to_string ~url e);
        exit 1
      | Ok pool -> f ~fs:env#fs pool))
;;

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
        Filename.check_suffix f migration_ext && not (Filename.check_suffix f down_ext))
      |> List.sort String.compare
  in
  if files = []
  then Printf.printf "(no migration files found in %s)\n" dir
  else
    List.iter
      (fun fname ->
         let path = Filename.concat dir fname in
         let content = In_channel.with_open_text path In_channel.input_all in
         Printf.printf "-- %s\n%s\n\n" fname content)
      files
;;

let run_apply_local ~ctx dir table dry_run =
  if dry_run
  then print_pending_sql dir
  else (
    let url = get_postgres_url ~ctx () in
    with_pool url (fun ~fs pool ->
      Printf.printf "Applying migrations from %s...\n%!" dir;
      match Migration.apply ~table pool ~dir ~fs with
      | Ok () -> Printf.printf "Done.\n"
      | Error e ->
        Printf.eprintf "error: %s\n" (pg_error_to_string ~url e);
        exit 1))
;;

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
;;

let fatal_p fmt = Printf.ksprintf fatal fmt

(* Same opam-pin/base-image block cli/lib/base/sol_cli_scaffold_templates.ml's
   tpl_dockerfile and the example workspace Dockerfiles use, trimmed to just
   what cli/bin/main.exe itself links (see cli/bin/dune) -- kept in
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
RUN opam exec -- dune build cli/bin/main.exe

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y libpq5 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /workspace/_build/default/cli/bin/main.exe /usr/local/bin/sol
ENTRYPOINT ["/usr/local/bin/sol"]
|docker}
;;

let write_temp_file ~suffix content =
  let path = Filename.temp_file "sol-migrate-" suffix in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  path
;;

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
        In_channel.with_open_text (Filename.concat dir fname) In_channel.input_all
      in
      fname, content)
;;

(* FEAT-063: the context args are prefixed here, so every migration kubectl call
   is scoped by construction. *)
let run_kubectl ~ctx ?(timeout_s = 30.) argv =
  Sol_cli_process.run
    (Sol_cli_process.cmd
       ~timeout_s
       (("kubectl" :: Sol_cli_kube_destination.kubectl_context_args ctx) @ argv))
;;

(* [on_fail] runs before erroring out -- used to clean up a ConfigMap that
   already applied successfully if the following Job apply then fails, so a
   half-created migration attempt doesn't leave stray cluster objects. *)
let kubectl_apply_or_fatal ~ctx ~what ?(on_fail = fun () -> ()) argv =
  match run_kubectl ~ctx argv with
  | Ok r when r.Sol_cli_process.exit_code = 0 -> ()
  | Ok r ->
    on_fail ();
    fatal_p "%s: %s" what r.Sol_cli_process.stderr
  | Error e ->
    on_fail ();
    fatal_p "%s: %s" what (Sol_cli_process.error_to_string e)
;;

(* Matches Sol_cli_secret's own yaml_quote exactly (that module can't be
   reused directly here -- private to its own file -- but the escaping
   rules for a YAML double-quoted scalar are the same regardless of what's
   being embedded). Migration file *contents* are arbitrary SQL, not a
   controlled value, so every C0 control character needs an escape, not
   just the three most obvious ones -- an unescaped \r silently gets
   YAML-folded into a space by the double-quoted-scalar line-folding rule,
   corrupting CRLF-terminated SQL without so much as a parse error. *)
(* INFRA-040: a Job whose container cannot start has already failed. Waiting the
   full timeout for an outcome that cannot come describes the symptom and hides the
   cause: Attempt 6 spent its entire migration gate on "did not complete within
   120s" while the Pod had been reporting
   `CreateContainerConfigError: secret "sol-secrets" not found` from the start.

   The reason and the message are read together, because the reason names the class
   and the message names the thing -- which Secret, which image. *)
let container_waiting_status ~ctx ~namespace ~job_name () =
  let jsonpath =
    "jsonpath={range \
     .items[*]}{.status.containerStatuses[*].state.waiting.reason}\"|\"{.status.containerStatuses[*].state.waiting.message}{\"\\n\"}{end}"
  in
  match
    run_kubectl
      ~ctx
      ~timeout_s:15.
      [ "get"; "pods"; "-n"; namespace; "-l"; "job-name=" ^ job_name; "-o"; jsonpath ]
  with
  | Ok r when r.Sol_cli_process.exit_code = 0 ->
    (match String.split_on_char '|' (String.trim r.Sol_cli_process.stdout) with
     | reason :: rest when String.trim reason <> "" ->
       Some (String.trim reason, String.trim (String.concat "|" rest))
     | _ -> None)
  | _ -> None
;;

(* Reasons that mean the container will never run without a change: waiting longer
   cannot help, so the operation should fail now and say why. *)
let terminal_waiting_reasons =
  [ "CreateContainerConfigError"
  ; "CreateContainerError"
  ; "InvalidImageName"
  ; "ErrImagePull"
  ; "ImagePullBackOff"
  ; "RunContainerError"
  ; "CrashLoopBackOff"
  ]
;;

(* INFRA-040: read the failing Job's evidence out before anything removes it. The
   message this replaced said "see the Job logs" and then deleted the Job, so the
   cause had to be rediscovered with a different command. Both observations are
   gathered because a Job fails in either direction: a container that cannot
   start has a waiting reason and no logs, while a Job that ran and failed has
   logs and no waiting reason. *)
let status_job_evidence ~ctx ~namespace ~job_name () =
  let logs =
    match
      run_kubectl
        ~ctx
        ~timeout_s:20.
        [ "logs"; Printf.sprintf "job/%s" job_name; "-n"; namespace; "--tail=200" ]
    with
    | Ok r when r.Sol_cli_process.exit_code = 0 -> String.trim r.Sol_cli_process.stdout
    | Ok r ->
      (match String.trim r.Sol_cli_process.stderr with
       | "" -> ""
       | e -> "(kubectl logs failed: " ^ e ^ ")")
    | Error _ -> ""
  in
  Sol_cli_migration.evidence_report
    ~waiting:(container_waiting_status ~ctx ~namespace ~job_name ())
    ~logs
;;

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
;;

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
    name
    namespace
    entries
;;

(* Args are rendered as a JSON list, so a value with a comma or quote cannot
   change the argument structure. *)
let render_job_args args = "[" ^ String.concat ", " (List.map yaml_dq args) ^ "]"

let render_job ~name ~namespace ~image ~args ~configmap_name =
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
          args: %s
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
    name
    namespace
    image
    (render_job_args args)
    Sol_cli_manifest.runtime_secret_name
    configmap_name
;;

(* AUDIT-069: the read-only sibling of the apply Job. It runs `migrate status`
   -- a SELECT against schema_migrations, never an apply -- so the deploy can
   learn the authoritative applied set without a second source of truth and
   without mutating anything. [yaml_dq] already quotes/escapes the value, and
   the args list is JSON, so the table name cannot break out of the arg. *)
let render_status_job ~name ~namespace ~image ~table ~configmap_name =
  render_job
    ~name
    ~namespace
    ~image
    ~args:[ "migrate"; "status"; "--json"; "--dir"; "/migrations"; "--table"; table ]
    ~configmap_name
;;

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

(* DEC-038 §6 / INFRA-058: the operator's diagnostic grant follows the workload,
   not this command's scope, so reconcile it across every namespace that holds a
   Sol-managed workload. RBAC only -- it writes RoleBindings and nothing else.

   A failure here is a warning, not fatal: a deployment must not be blocked by a
   read-only grant. But it is never silent -- the warning names what could not be
   established and what it costs, because a diagnostic capability that quietly
   did not appear is the failure mode this whole line of work exists to remove. *)
let reconcile_operator_bindings_warn ~ctx ~workspace =
  match Sol_cli_substrate.reconcile_operator_bindings ~ctx ~workspace with
  | Ok () -> ()
  | Error msg ->
    Printf.eprintf
      "warning: could not establish the operator's diagnostic RoleBindings: %s\n\
       The operator identity will not be able to read this workspace's workloads.\n\
       %!"
      msg
;;

let pick_namespace_and_service ~workspace =
  match Sol_cli_manifest.discover_services () with
  | [] ->
    fatal
      "no deployed service found in this workspace -- nothing to run the migration Job \
       in, and no ECR repository to push the migration runner image to. Deploy at least \
       one service first."
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
        Sol_cli_deployment_plan.namespace_result
          ~workspace
          ~domain:chosen.Sol_cli_manifest.domain
      with
      | Ok ns -> Sol_cli_deployment_plan.namespace_to_string ns
      | Error e -> fatal (Sol_cli_deployment_plan.plan_error_to_string e)
    in
    let k8s_name =
      match Sol_cli_deployment_plan.k8s_name_result chosen.Sol_cli_manifest.name with
      | Ok n -> n
      | Error e -> fatal (Sol_cli_deployment_plan.plan_error_to_string e)
    in
    namespace, k8s_name
;;

let runner_source () =
  match Sol_cli_platform_assets.resolve () with
  | Error e -> Error (Sol_cli_platform_assets.error_to_string e)
  | Ok assets -> Sol_cli_platform_assets.migration_runner assets
;;

(* The migration runner image is the Sol CLI itself, which carries `sol migrate`.
   The apply path and the deploy's read-only status check obtain it the same way,
   so the status Job runs exactly the code that would apply migrations; the
   deploy path fails closed on [Error] rather than skipping the check.
   DEC-049: a checkout builds its runner from itself and pushes it to the
   target's registry; an installed release runs the runner published with it,
   by digest, and needs no build and no registry. *)
let obtain_runner_image runner ~registry ~workspace ~k8s_name =
  match (runner : Sol_cli_platform_assets.migration_runner) with
  | Published image ->
    Printf.printf "Using migration runner %s\n%!" image;
    Ok image
  | Build_from_source { context } ->
    (match registry with
     | Error _ as e -> e
     | Ok registry ->
       let image =
         Sol_cli_deployment_plan.image_ref
           ~registry
           ~workspace
           ~k8s_name
           ~tag:"sol-cli-migrate"
       in
       Printf.printf "Building migration runner image %s...\n%!" image;
       let dockerfile = write_temp_file ~suffix:".Dockerfile" sol_cli_dockerfile in
       let result =
         match Sol_cli_docker.build ~tag:image ~dockerfile ~context with
         | Error e ->
           Error (Printf.sprintf "docker build: %s" (Sol_cli_process.error_to_string e))
         | Ok () ->
           Printf.printf "Pushing %s...\n%!" image;
           (match Sol_cli_docker.push ~image_ref:image with
            | Error e ->
              Error (Printf.sprintf "docker push: %s" (Sol_cli_process.error_to_string e))
            | Ok () -> Ok image)
       in
       (try Sys.remove dockerfile with
        | _ -> ());
       result)
;;

let run_apply_in_cluster ~ctx ~target ~dir ~table ~registry_override =
  match Sol_cli_config.load_for_target ~target with
  | Error e -> fatal (Sol_cli_config.error_to_string e)
  | Ok cfg ->
    let target_cfg = cfg.Sol_cli_config.target in
    let registry =
      match registry_override with
      | Some r -> Ok r
      | None ->
        (match target_cfg.Sol_cli_config.registry with
         | Some r -> Ok r
         | None ->
           Error
             "no registry configured for this target -- pass --registry or set \
              target.registry in sol.yml.")
    in
    let runner =
      match runner_source () with
      | Ok runner -> runner
      | Error msg -> fatal msg
    in
    let workspace = Filename.basename (Sys.getcwd ()) in
    let namespace, k8s_name = pick_namespace_and_service ~workspace in
    (* HARDEN-002 run 2, finding 8: the Job below runs in this namespace and reads
          the runtime Secret, so establish both before submitting it. Doing it here
          is what makes a fresh target's first `sol migrate apply` possible. *)
    (match Sol_cli_substrate.ensure ~ctx ~namespaces:[ namespace ] with
     | Ok () -> ()
     | Error msg -> fatal msg);
    reconcile_operator_bindings_warn ~ctx ~workspace;
    let files = read_migration_files dir in
    if files = []
    then Printf.printf "(no migration files found in %s -- nothing to do)\n" dir
    else (
      let image =
        match obtain_runner_image runner ~registry ~workspace ~k8s_name with
        | Ok image -> image
        | Error msg -> fatal msg
      in
      let run_id = Printf.sprintf "%.0f" (Unix.gettimeofday () *. 1000.) in
      let job_name = Printf.sprintf "sol-migrate-%s" run_id in
      let configmap_name = Printf.sprintf "sol-migrate-files-%s" run_id in
      let cleanup () =
        ignore
          (run_kubectl
             ~ctx
             [ "delete"
             ; "job"
             ; job_name
             ; "-n"
             ; namespace
             ; "--ignore-not-found"
             ; "--wait=false"
             ]);
        ignore
          (run_kubectl
             ~ctx
             [ "delete"
             ; "configmap"
             ; configmap_name
             ; "-n"
             ; namespace
             ; "--ignore-not-found"
             ])
      in
      let configmap_yaml =
        write_temp_file
          ~suffix:".yaml"
          (render_configmap ~name:configmap_name ~namespace files)
      in
      let job_yaml =
        write_temp_file
          ~suffix:".yaml"
          (render_job
             ~name:job_name
             ~namespace
             ~image
             ~args:[ "migrate"; "apply"; "--dir"; "/migrations"; "--table"; table ]
             ~configmap_name)
      in
      Printf.printf
        "Submitting migration Job %s in namespace %s...\n%!"
        job_name
        namespace;
      kubectl_apply_or_fatal
        ~ctx
        ~what:"kubectl apply (configmap)"
        [ "apply"; "-f"; configmap_yaml ];
      kubectl_apply_or_fatal
        ~ctx
        ~what:"kubectl apply (job)"
        ~on_fail:cleanup
        [ "apply"; "-f"; job_yaml ];
      (try Sys.remove configmap_yaml with
       | _ -> ());
      (try Sys.remove job_yaml with
       | _ -> ());
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
          run_kubectl
            ~ctx
            ~timeout_s:15.
            [ "get"
            ; "job"
            ; job_name
            ; "-n"
            ; namespace
            ; "-o"
            ; Printf.sprintf "jsonpath={.status.%s}" field
            ]
        with
        | Ok r -> String.trim r.Sol_cli_process.stdout
        | Error _ -> ""
      in
      let job_status () =
        ( job_field "succeeded" = "1"
        , match job_field "failed" with
          | "" | "0" -> false
          | _ -> true )
      in
      let rec wait_for_completion n =
        if n = 0
        then `Timed_out
        else (
          match job_status () with
          | true, _ -> `Succeeded
          | _, true -> `Failed
          | false, false ->
            Unix.sleepf 2.;
            wait_for_completion (n - 1))
      in
      let outcome =
        wait_for_completion 150
        (* ~300s at 2s/poll *)
      in
      Printf.printf "\n--- migration Job logs (%s) ---\n%!" job_name;
      (match
         run_kubectl
           ~ctx
           ~timeout_s:30.
           [ "logs"; Printf.sprintf "job/%s" job_name; "-n"; namespace ]
       with
       | Ok r ->
         let logs =
           match Sys.getenv_opt "POSTGRES_URL" with
           | Some url -> Sol_cli_redaction.connection_error ~url r.Sol_cli_process.stdout
           | None -> r.Sol_cli_process.stdout
         in
         print_string logs
       | Error e ->
         Printf.eprintf
           "warning: could not fetch job logs: %s\n"
           (Sol_cli_process.error_to_string e));
      Printf.printf "--- end logs ---\n\n%!";
      (match outcome with
       | `Timed_out ->
         Printf.eprintf "error: migration Job did not complete within 300s\n"
       | `Succeeded | `Failed -> ());
      let succeeded = outcome = `Succeeded in
      cleanup ();
      if succeeded
      then Printf.printf "Done.\n"
      else (
        Printf.eprintf "error: migration Job failed -- see logs above.\n";
        exit 1))
;;

(* ── AUDIT-069: the deploy's read-only migration prerequisite ─────────────── *)

(* The result of the live prerequisite check. [Unavailable] and [Unsatisfied]
   both stop the deploy before workload mutation; [Unavailable] is the
   fail-closed answer when the check itself could not be performed. *)
type migration_verification =
  | No_migrations
  | Satisfied of int list
  | Unsatisfied of Sol_cli_migration.prerequisite list
  | Unavailable of string

(* Read the authoritative applied set from the target cluster with a
   short-lived, read-only Job. The Job runs `migrate status --json`, which only
   reads schema_migrations. Any failure to run the Job or read the table is an
   [Error] the caller treats as [Unavailable] -- never a reason to assume the
   schema is compatible. *)
let read_applied_in_cluster ~ctx ~target ~workspace ~dir ~table =
  match Sol_cli_config.load_for_target ~target with
  | Error e -> Error (Sol_cli_config.error_to_string e)
  | Ok cfg ->
    let target_cfg = cfg.Sol_cli_config.target in
    let registry =
      match target_cfg.Sol_cli_config.registry with
      | Some r -> Ok r
      | None ->
        (Error "no registry configured for this target -- set target.registry in sol.yml."
         : (string, string) result)
    in
    (match runner_source () with
     | Error _ as e -> e
     | Ok runner ->
       let namespace, k8s_name = pick_namespace_and_service ~workspace in
       (* HARDEN-002 run 2, finding 8: the Job below runs in this namespace and reads
          the runtime Secret, so establish both before submitting it. Doing it here
          is what makes a fresh target's first `sol migrate apply` possible. *)
       (match Sol_cli_substrate.ensure ~ctx ~namespaces:[ namespace ] with
        | Ok () -> ()
        | Error msg -> fatal msg);
       (match obtain_runner_image runner ~registry ~workspace ~k8s_name with
        | Error _ as e -> e
        | Ok image ->
          let files = read_migration_files dir in
          let run_id = Printf.sprintf "%.0f" (Unix.gettimeofday () *. 1000.) in
          let job_name = Printf.sprintf "sol-migrate-status-%s" run_id in
          let configmap_name = Printf.sprintf "sol-migrate-status-files-%s" run_id in
          (* Read-only and short-lived: the Job and its ConfigMap are removed
                whether the check succeeds or fails, so a deploy never leaves
                cluster objects behind for a check that only reads. *)
          let cleanup () =
            ignore
              (run_kubectl
                 ~ctx
                 [ "delete"
                 ; "job"
                 ; job_name
                 ; "-n"
                 ; namespace
                 ; "--ignore-not-found"
                 ; "--wait=false"
                 ]);
            ignore
              (run_kubectl
                 ~ctx
                 [ "delete"
                 ; "configmap"
                 ; configmap_name
                 ; "-n"
                 ; namespace
                 ; "--ignore-not-found"
                 ])
          in
          let configmap_yaml =
            write_temp_file
              ~suffix:".yaml"
              (render_configmap ~name:configmap_name ~namespace files)
          in
          let job_yaml =
            write_temp_file
              ~suffix:".yaml"
              (render_status_job ~name:job_name ~namespace ~image ~table ~configmap_name)
          in
          let applied =
            match run_kubectl ~ctx [ "apply"; "-f"; configmap_yaml ] with
            | Ok r when r.Sol_cli_process.exit_code = 0 ->
              (match run_kubectl ~ctx [ "apply"; "-f"; job_yaml ] with
               | Ok r when r.Sol_cli_process.exit_code = 0 -> Ok ()
               | Ok r ->
                 Error
                   (Printf.sprintf
                      "kubectl apply (status job) failed: %s"
                      (String.trim r.Sol_cli_process.stderr))
               | Error e ->
                 Error
                   (Printf.sprintf
                      "kubectl apply (status job): %s"
                      (Sol_cli_process.error_to_string e)))
            | Ok r ->
              Error
                (Printf.sprintf
                   "kubectl apply (status configmap) failed: %s"
                   (String.trim r.Sol_cli_process.stderr))
            | Error e ->
              Error
                (Printf.sprintf
                   "kubectl apply (status configmap): %s"
                   (Sol_cli_process.error_to_string e))
          in
          (try Sys.remove configmap_yaml with
           | _ -> ());
          (try Sys.remove job_yaml with
           | _ -> ());
          let result =
            match applied with
            | Error _ as e -> e
            | Ok () ->
              (* Same bounded poll as the apply path: `kubectl wait` does not
                    return on a failed Job, so the status fields are polled
                    directly. *)
              let job_field field =
                match
                  run_kubectl
                    ~ctx
                    ~timeout_s:15.
                    [ "get"
                    ; "job"
                    ; job_name
                    ; "-n"
                    ; namespace
                    ; "-o"
                    ; Printf.sprintf "jsonpath={.status.%s}" field
                    ]
                with
                | Ok r -> String.trim r.Sol_cli_process.stdout
                | Error _ -> ""
              in
              let rec wait n =
                if n = 0
                then `Timed_out
                else if job_field "succeeded" = "1"
                then `Succeeded
                else if
                  match job_field "failed" with
                  | "" | "0" -> false
                  | _ -> true
                then `Failed
                else (
                  (* INFRA-040: fail on a container that cannot start rather than waiting
                        out a timeout that cannot resolve. This is what turned a one-line
                        Secret-name mismatch into an hour of diagnosis. *)
                  match container_waiting_status ~ctx ~namespace ~job_name () with
                  | Some (reason, detail) when List.mem reason terminal_waiting_reasons ->
                    `Unstartable (reason, detail)
                  | _ ->
                    Unix.sleepf 2.;
                    wait (n - 1))
              in
              (match wait 60 with
               | `Unstartable (reason, detail) ->
                 Error
                   (Printf.sprintf
                      "migration-status Job cannot start: %s%s"
                      reason
                      (if detail = "" then "" else Printf.sprintf " (%s)" detail))
               | `Timed_out -> Error "migration-status Job did not complete within 120s"
               | `Failed -> Error "migration-status Job failed -- see the Job logs"
               | `Succeeded ->
                 (match
                    run_kubectl
                      ~ctx
                      ~timeout_s:30.
                      [ "logs"; Printf.sprintf "job/%s" job_name; "-n"; namespace ]
                  with
                  | Error e ->
                    Error
                      (Printf.sprintf
                         "could not read migration-status Job logs: %s"
                         (Sol_cli_process.error_to_string e))
                  | Ok r ->
                    (* The Job prints only the JSON body, but take the first
                          `{`..last `}` so a stray log line cannot break the
                          parse of an otherwise valid report. *)
                    let text = String.trim r.Sol_cli_process.stdout in
                    let text =
                      match String.index_opt text '{', String.rindex_opt text '}' with
                      | Some i, Some j when j > i -> String.sub text i (j - i + 1)
                      | _ -> text
                    in
                    Sol_cli_migration.parse_status_json text))
          in
          (* INFRA-040: this check is read-only, so a success still tidies up
                after itself. A failure must not delete the only record of why it
                failed: the evidence goes into the deploy's own output, and the
                Job is kept so it can still be read afterwards. *)
          (match result with
           | Ok _ -> cleanup ()
           | Error _ ->
             let evidence = status_job_evidence ~ctx ~namespace ~job_name () in
             if String.trim evidence <> ""
             then Printf.eprintf "\nmigration-status Job evidence:\n%s\n%!" evidence;
             Printf.eprintf
               "\n\
                The failing Job is kept for inspection:\n\
               \  kubectl logs job/%s -n %s\n\
               \  kubectl delete job/%s configmap/%s -n %s\n\
                %!"
               job_name
               namespace
               job_name
               configmap_name
               namespace);
          result))
;;

(* The prerequisite check the deploy path runs after the static preflight and
   before any workload mutation. *)
let verify_migration_prerequisite ~ctx ~target ~workspace ~dir =
  match Sol_cli_migration.required ~dir with
  | Error e -> Unavailable e
  | Ok [] -> No_migrations
  | Ok required ->
    let table = Sol_cli_migration.table_name ~workspace in
    (match read_applied_in_cluster ~ctx ~target ~workspace ~dir ~table with
     | Error e -> Unavailable e
     | Ok applied ->
       (match Sol_cli_migration.unsatisfied ~required ~applied with
        | [] -> Satisfied applied
        | missing -> Unsatisfied missing))
;;

(* BUG-041: every entry point that hands [dir] to the runner validates it with the
   same rule the deploy gate uses first, so a shared version stops here instead of
   being applied once and skipped once. *)
let require_valid_migrations dir =
  match Sol_cli_migration.required ~dir with
  | Ok _ -> ()
  | Error message ->
    Printf.eprintf "error: %s\n" message;
    exit 1
;;

(* ── status ──────────────────────────────────────────────────────────────── *)

let run_status ~ctx ?(json = false) dir table () =
  require_valid_migrations dir;
  let url = get_postgres_url ~ctx () in
  with_pool url (fun ~fs pool ->
    match Migration.status ~table pool ~dir ~fs with
    | Error e ->
      Printf.eprintf "error: %s\n" (pg_error_to_string ~url e);
      exit 1
    | Ok rows ->
      if json
      then
        print_endline
          (Sol_cli_migration.status_json
             ~table
             (List.map
                (fun (s : Migration.status) -> s.version, s.name, s.applied_at)
                rows))
      else (
        Printf.printf "%-6s  %-30s  %s\n" "VER" "NAME" "APPLIED AT";
        Printf.printf "%s\n" (String.make 60 '-');
        List.iter
          (fun (s : Migration.status) ->
             Printf.printf
               "%-6d  %-30s  %s\n"
               s.version
               s.name
               (Option.value ~default:"(pending)" s.applied_at))
          rows))
;;

(* ── rollback ────────────────────────────────────────────────────────────── *)

let run_rollback ~ctx dir table () =
  require_valid_migrations dir;
  let url = get_postgres_url ~ctx () in
  with_pool url (fun ~fs pool ->
    match Migration.rollback ~table pool ~dir ~fs with
    | Ok () -> Printf.printf "Rolled back.\n"
    | Error e ->
      Printf.eprintf "error: %s\n" (pg_error_to_string ~url e);
      exit 1)
;;

(* ── apply dispatch: local direct-connect vs in-cluster Job ────────────────── *)

let run_apply ~ctx dir table dry_run target registry =
  require_valid_migrations dir;
  if dry_run
  then print_pending_sql dir
  else (
    match target with
    | None -> run_apply_local ~ctx dir table dry_run
    | Some target ->
      run_apply_in_cluster ~ctx ~target ~dir ~table ~registry_override:registry)
;;

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let dir_arg =
  Arg.(
    value
    & opt string "db/migrations"
    & info
        [ "dir" ]
        ~docv:"DIR"
        ~doc:"Directory containing migration SQL files (default: db/migrations)")
;;

let table_arg =
  Arg.(
    value
    & opt string default_table_name
    & info
        [ "table" ]
        ~docv:"TABLE"
        ~doc:
          "Migration tracking table name (default: sol_<workspace>_schema_migrations; \
           override with this flag to share a table across workspaces)")
;;

let dry_run_flag =
  Arg.(
    value
    & flag
    & info [ "dry-run" ] ~doc:"Print pending migration SQL to stdout without applying")
;;

let target_arg =
  Arg.(
    value
    & pos 0 (some string) None
    & info
        []
        ~docv:"TARGET"
        ~doc:
          "Deployment target path: <env>/<provider>/<region>. When given, migrations run \
           from a one-shot Kubernetes Job inside the target's cluster instead of \
           connecting directly from this machine — required for any real deployment \
           whose database (e.g. RDS) isn't reachable from outside its network by design \
           (FRIC-012). Omit for the local dev cluster, which remains directly reachable \
           via kubectl port-forward.")
;;

let registry_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "registry" ]
        ~docv:"URL"
        ~doc:
          "Container registry to push the migration runner image to. Omit to fall back \
           to the resolved target's own registry. Only meaningful together with TARGET.")
;;

let apply_cmd =
  Cmd.v
    (Cmd.info "apply" ~doc:"Apply all pending migrations (default subcommand)")
    Term.(
      const (fun dir table dry_run target registry ->
        (* FEAT-063: a named target supplies the destination; the no-target
              form is the local dev path and uses the literal local cluster. *)
        let ctx =
          match target with
          | Some t -> Cmd_destination.top ~command:"migrate" t
          | None -> Cmd_destination.local
        in
        run_apply ~ctx dir table dry_run target registry)
      $ dir_arg
      $ table_arg
      $ dry_run_flag
      $ target_arg
      $ registry_arg)
;;

let json_flag =
  Arg.(
    value
    & flag
    & info
        [ "json" ]
        ~doc:
          "Emit the status as JSON (the machine-readable form the deploy path's \
           read-only prerequisite check consumes)")
;;

let status_cmd =
  Cmd.v
    (Cmd.info "status" ~doc:"Show per-file applied/pending status")
    Term.(
      const (fun dir table json ->
        run_status ~ctx:Cmd_destination.local ~json dir table ())
      $ dir_arg
      $ table_arg
      $ json_flag)
;;

let rollback_cmd =
  Cmd.v
    (Cmd.info "rollback" ~doc:"Roll back the last applied migration")
    Term.(
      const (fun dir table -> run_rollback ~ctx:Cmd_destination.local dir table ())
      $ dir_arg
      $ table_arg)
;;

let cmd =
  Cmd.group
    (Cmd.info "migrate" ~doc:"Run database migrations against POSTGRES_URL")
    ~default:
      Term.(
        const (fun dir table dry_run target registry ->
          let ctx =
            match target with
            | Some t -> Cmd_destination.top ~command:"migrate" t
            | None -> Cmd_destination.local
          in
          run_apply ~ctx dir table dry_run target registry)
        $ dir_arg
        $ table_arg
        $ dry_run_flag
        $ target_arg
        $ registry_arg)
    [ apply_cmd; status_cmd; rollback_cmd ]
;;

(* FEAT-063: the local form -- migrations against Sol's own cluster. *)
let local_cmd =
  Cmd.v
    (Cmd.info "migrate" ~doc:"Apply migrations against the local cluster's Postgres")
    Term.(
      const (fun dir table dry_run registry ->
        run_apply ~ctx:Cmd_destination.local dir table dry_run None registry)
      $ dir_arg
      $ table_arg
      $ dry_run_flag
      $ registry_arg)
;;
