open Cmdliner
open Result.Syntax

(* Per-workspace table name avoids version-number collisions when multiple
   workspaces share one local Postgres instance; --table always overrides it. *)
let default_table_name =
  let cwd_name = Filename.basename (Sys.getcwd ()) in
  let buf = Buffer.create (String.length cwd_name) in
  cwd_name
  |> String.iter (fun c ->
    if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
    then Buffer.add_char buf c
    else if c >= 'A' && c <= 'Z'
    then Buffer.add_char buf (Char.lowercase_ascii c)
    else Buffer.add_char buf '_');
  Printf.sprintf "sol_%s_schema_migrations" (Buffer.contents buf)
;;

let cluster_pg_exists ~ctx () =
  Result.is_ok
    (Sol_cli_kubectl.get
       ~ctx
       ~resource:"svc"
       ~name:"postgresql"
       ~namespace:"postgresql"
       ~output:"name")
;;

(* Start a background port-forward to cluster postgres and return the local URL.
   Registers at_exit cleanup so the forward is killed when the process exits. *)
let auto_forward_pg ~ctx () =
  Printf.printf "Forwarding postgresql (cluster) → localhost:15432 ...\n%!";
  let url = "postgresql://postgres:dev@localhost:15432/dev" in
  match
    Sol_cli_kubectl.temporary_port_forward
      ~ctx
      ~service:"postgresql"
      ~namespace:"postgresql"
      ~local_port:15432
      ~remote_port:5432
  with
  | Ok () -> Ok url
  | Error (Not_started e) ->
    Error ("could not start kubectl port-forward: " ^ Sol_cli_process.error_to_string e)
  | Error Not_ready ->
    Printf.eprintf "warning: port-forward did not become ready in time\n%!";
    Ok url
  | Error (Readiness_check_failed msg) ->
    Printf.eprintf "warning: port-forward readiness check failed: %s\n%!" msg;
    Ok url
;;

let get_postgres_url ~ctx () =
  match Sol_cli_string.env "POSTGRES_URL" with
  | Some u -> Ok u
  | None ->
    if cluster_pg_exists ~ctx ()
    then auto_forward_pg ~ctx ()
    else
      Error
        "POSTGRES_URL not set and no cluster postgres found.\n\
        \  Run 'sol local infra up' first, then retry."
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
      | Error e -> Error ("cannot connect to database: " ^ pg_error_to_string ~url e)
      | Ok pool -> f ~fs:env#fs pool))
;;

(* ── apply ───────────────────────────────────────────────────────────────── *)

(* Print SQL files from [dir] in order without connecting to the database.
   Used by --dry-run to let operators preview migration SQL before applying. *)
let print_pending_sql dir =
  let migration_ext = ".sql" in
  let down_ext = ".down.sql" in
  let* files =
    match Sys.readdir dir with
    | exception Sys_error msg -> Error ("cannot read migrations dir: " ^ msg)
    | arr ->
      Ok
        (Array.to_list arr
         |> List.filter (fun f ->
           Filename.check_suffix f migration_ext && not (Filename.check_suffix f down_ext))
         |> List.sort String.compare)
  in
  (match files with
   | [] -> Printf.printf "(no migration files found in %s)\n" dir
   | files ->
     files
     |> List.iter (fun fname ->
       let path = Filename.concat dir fname in
       let content = In_channel.with_open_text path In_channel.input_all in
       Printf.printf "-- %s\n%s\n\n" fname content));
  Ok ()
;;

let run_apply_local ~ctx dir table dry_run =
  if dry_run
  then print_pending_sql dir
  else
    let* url = get_postgres_url ~ctx () in
    with_pool url (fun ~fs pool ->
      Printf.printf "Applying migrations from %s...\n%!" dir;
      let* () =
        Migration.apply ~table pool ~dir ~fs |> Result.map_error (pg_error_to_string ~url)
      in
      Printf.printf "Done.\n";
      Ok ())
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

(* Same opam-pin/base-image block cli/lib/base/sol_cli_scaffold_templates.ml's
   tpl_dockerfile and the example workspace Dockerfiles use, trimmed to just
   what cli/bin/main.exe itself links (see cli/bin/dune) -- kept in
   sync by hand, same as every other place this block is duplicated. *)
let sol_cli_dockerfile =
  {docker|FROM ocaml/opam:ubuntu-24.04-ocaml-5.4 AS build
RUN sudo apt-get update && sudo apt-get install -y librdkafka-dev libpq-dev libssl-dev libgmp-dev pkg-config
RUN opam repository set-url default https://opam.ocaml.org && opam update
# BUG-059: the support libraries at exactly the revisions this checkout declares,
# pinned by the same script CI and release builds use -- never a branch.
COPY --chown=opam:opam support-refs.txt internal/ci/pin-support-packages.sh /home/opam/pins/
RUN bash /home/opam/pins/pin-support-packages.sh /home/opam/pins/support-refs.txt
COPY --chown=opam:opam sol.opam /home/opam/pins/
RUN cd /home/opam/pins && opam install -y --no-self-upgrade --deps-only ./sol.opam
COPY --chown=opam:opam . /workspace
WORKDIR /workspace
RUN opam exec -- dune build cli/bin/main.exe

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y libpq5 libgmp10 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /workspace/_build/default/cli/bin/main.exe /usr/local/bin/sol
ENTRYPOINT ["/usr/local/bin/sol"]
|docker}
;;

(* REFAC-134: the file is removed by the caller once kubectl or docker has read
   it (Sol_cli_fs.remove_reporting); a failure to write it is an error. *)
let write_temp_file ~suffix content =
  match Filename.temp_file "sol-migrate-" suffix with
  | exception Sys_error message -> Error message
  | path ->
    Sol_cli_fs.write_atomic ~perm:0o600 path content |> Result.map (fun () -> path)
;;

let read_migration_files dir =
  let ext = ".sql" in
  match Sys.readdir dir with
  | exception Sys_error msg -> Error ("cannot read migrations dir: " ^ msg)
  | arr ->
    (* REFAC-131: a file is carried into a ConfigMap, and YAML cannot hold a NUL
       character; refuse the file by name rather than let it be truncated. *)
    let read fname =
      let content =
        In_channel.with_open_text (Filename.concat dir fname) In_channel.input_all
      in
      if String.contains content '\000'
      then
        Error
          (Printf.sprintf
             "migration %s contains a NUL character, which a ConfigMap cannot carry"
             fname)
      else Ok (fname, content)
    in
    Array.to_list arr
    |> List.filter (fun f -> Filename.check_suffix f ext)
    |> List.sort String.compare
    |> List.fold_left
         (fun acc fname ->
            let* files = acc in
            let* file = read fname in
            Ok (file :: files))
         (Ok [])
    |> Result.map List.rev
;;

(* FEAT-063: the context args are prefixed here, so every migration kubectl call
   is scoped by construction. *)
let run_kubectl ~ctx ?(timeout_s = 30.) argv =
  Sol_cli_process.run
    (Sol_cli_process.cmd
       ~timeout_s
       (("kubectl" :: Sol_cli_kube_destination.kubectl_context_args ctx) @ argv))
;;

(* [on_fail] runs before the error is returned -- used to clean up a ConfigMap
   that already applied successfully if the following Job apply then fails, so a
   half-created migration attempt doesn't leave stray cluster objects. *)
let kubectl_apply ~ctx ~what ?(on_fail = fun () -> ()) argv =
  match run_kubectl ~ctx argv with
  | Ok _ -> Ok ()
  | Error (Sol_cli_process.Non_zero r) ->
    on_fail ();
    Error (Printf.sprintf "%s: %s" what r.stderr)
  | Error e ->
    on_fail ();
    Error (Printf.sprintf "%s: %s" what (Sol_cli_process.error_to_string e))
;;

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
  | Ok r ->
    (* The adapter's boundary: kubectl prints blanks for a container that is not
       waiting, and they are decided here, once. *)
    (match String.split_on_char '|' r.stdout with
     | reason :: rest ->
       Sol_cli_string.non_blank reason
       |> Option.map (fun reason ->
         reason, Sol_cli_string.non_blank (String.concat "|" rest))
     | [] -> None)
  | Error _ -> None
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
    | Ok r -> Sol_cli_string.non_blank r.stdout
    | Error (Sol_cli_process.Non_zero r) ->
      Some ("(kubectl logs failed: " ^ Sol_cli_process.failure_message r ^ ")")
    | Error _ -> None
  in
  Sol_cli_migration.evidence_report
    ~waiting:(container_waiting_status ~ctx ~namespace ~job_name ())
    ~logs
;;

let render_configmap ~name ~namespace files =
  Sol_cli_yaml.render [ Sol_cli_manifest.migration_configmap_doc ~name ~namespace files ]
;;

let render_job ~name ~namespace ~image ~args ~configmap_name =
  Sol_cli_yaml.render
    [ Sol_cli_manifest.migration_job_doc ~name ~namespace ~image ~args ~configmap_name ]
;;

(* AUDIT-069: the read-only sibling of the apply Job. It runs `migrate status`
   -- a SELECT against schema_migrations, never an apply -- so the deploy can
   learn the authoritative applied set without a second source of truth and
   without mutating anything. The emitter writes the table name as one quoted
   argument, so it cannot break out of it. *)
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
let reconcile_operator_bindings_warn ~ctx ~workspace ~services =
  Sol_cli_substrate.reconcile_operator_bindings ~ctx ~workspace ~services
  |> Result.iter_error (fun msg ->
    Printf.eprintf
      "warning: could not establish the operator's diagnostic RoleBindings: %s\n\
       The operator identity will not be able to read this workspace's workloads.\n\
       %!"
      msg)
;;

(* REFAC-130: the workspace is read once by the caller ([load_cwd]) and the
   inventory is passed in, rather than re-discovered here. *)
let pick_namespace_and_service ~workspace ~services =
  let by_domain_and_name (a : Sol_cli_manifest.service) (b : Sol_cli_manifest.service) =
    compare (a.domain, a.name) (b.domain, b.name)
  in
  match List.sort by_domain_and_name services with
  | [] ->
    Error
      "no deployed service found in this workspace -- nothing to run the migration Job \
       in, and no ECR repository to push the migration runner image to. Deploy at least \
       one service first."
  | chosen :: _ ->
    let* namespace =
      Sol_cli_deployment_plan.namespace_name ~workspace ~domain:chosen.domain
    in
    let* k8s_name =
      Sol_cli_deployment_plan.k8s_name_result chosen.name
      |> Result.map_error Sol_cli_deployment_plan.plan_error_to_string
    in
    Ok (namespace, k8s_name)
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
       let* dockerfile = write_temp_file ~suffix:".Dockerfile" sol_cli_dockerfile in
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
       Sol_cli_fs.remove_reporting dockerfile;
       result)
;;

let run_apply_in_cluster ~ctx ~target ~dir ~table ~registry_override =
  let* cfg =
    Sol_cli_config.load_for_target ~target
    |> Result.map_error Sol_cli_config.error_to_string
  in
  let target_cfg = cfg.target in
  let registry =
    match registry_override with
    | Some r -> Ok r
    | None ->
      (match target_cfg.registry with
       | Some r -> Ok r
       | None ->
         Error
           "no registry configured for this target -- pass --registry or set \
            target.registry in sol.yml.")
  in
  let* runner = runner_source () in
  let workspace = Filename.basename (Sys.getcwd ()) in
  let* facts = Sol_cli_workspace_model.load_cwd () in
  let services = Sol_cli_workspace_model.services facts in
  let* namespace, k8s_name = pick_namespace_and_service ~workspace ~services in
  (* HARDEN-002 run 2, finding 8: the Job below runs in this namespace and reads
          the runtime Secret, so establish both before submitting it. Doing it here
          is what makes a fresh target's first `sol migrate apply` possible. *)
  let* () = Sol_cli_substrate.ensure ~ctx ~namespaces:[ namespace ] in
  reconcile_operator_bindings_warn ~ctx ~workspace ~services;
  let* files = read_migration_files dir in
  if files = []
  then (
    Printf.printf "(no migration files found in %s -- nothing to do)\n" dir;
    Ok ())
  else
    let* image = obtain_runner_image runner ~registry ~workspace ~k8s_name in
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
    let* configmap_yaml =
      write_temp_file
        ~suffix:".yaml"
        (render_configmap ~name:configmap_name ~namespace files)
    in
    let* job_yaml =
      write_temp_file
        ~suffix:".yaml"
        (render_job
           ~name:job_name
           ~namespace
           ~image
           ~args:[ "migrate"; "apply"; "--dir"; "/migrations"; "--table"; table ]
           ~configmap_name)
    in
    Printf.printf "Submitting migration Job %s in namespace %s...\n%!" job_name namespace;
    let applied =
      let* () =
        kubectl_apply
          ~ctx
          ~what:"kubectl apply (configmap)"
          [ "apply"; "-f"; configmap_yaml ]
      in
      kubectl_apply
        ~ctx
        ~what:"kubectl apply (job)"
        ~on_fail:cleanup
        [ "apply"; "-f"; job_yaml ]
    in
    List.iter Sol_cli_fs.remove_reporting [ configmap_yaml; job_yaml ];
    let* () = applied in
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
      | Ok r -> String.trim r.stdout
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
         match Sol_cli_string.env "POSTGRES_URL" with
         | Some url -> Sol_cli_redaction.connection_error ~url r.stdout
         | None -> r.stdout
       in
       print_string logs
     | Error e ->
       Printf.eprintf
         "warning: could not fetch job logs: %s\n"
         (Sol_cli_process.error_to_string e));
    Printf.printf "--- end logs ---\n\n%!";
    (match outcome with
     | `Timed_out -> Printf.eprintf "error: migration Job did not complete within 300s\n"
     | `Succeeded | `Failed -> ());
    let succeeded = outcome = `Succeeded in
    cleanup ();
    if succeeded
    then (
      Printf.printf "Done.\n";
      Ok ())
    else Error "migration Job failed -- see logs above."
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
(* REFAC-130: [services] is the workspace inventory the caller already read, so
   this does not read the workspace again to pick a namespace. *)
let read_applied_in_cluster ~ctx ~target ~workspace ~dir ~table ~services =
  match Sol_cli_config.load_for_target ~target with
  | Error e -> Error (Sol_cli_config.error_to_string e)
  | Ok cfg ->
    let target_cfg = cfg.target in
    let registry =
      match target_cfg.registry with
      | Some r -> Ok r
      | None ->
        (Error "no registry configured for this target -- set target.registry in sol.yml."
         : (string, string) result)
    in
    (match runner_source () with
     | Error _ as e -> e
     | Ok runner ->
       let* namespace, k8s_name = pick_namespace_and_service ~workspace ~services in
       (* HARDEN-002 run 2, finding 8: the Job below runs in this namespace and reads
          the runtime Secret, so establish both before submitting it. Doing it here
          is what makes a fresh target's first `sol migrate apply` possible. *)
       let* () = Sol_cli_substrate.ensure ~ctx ~namespaces:[ namespace ] in
       (match obtain_runner_image runner ~registry ~workspace ~k8s_name with
        | Error _ as e -> e
        | Ok image ->
          let* files = read_migration_files dir in
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
          let* configmap_yaml =
            write_temp_file
              ~suffix:".yaml"
              (render_configmap ~name:configmap_name ~namespace files)
          in
          let* job_yaml =
            write_temp_file
              ~suffix:".yaml"
              (render_status_job ~name:job_name ~namespace ~image ~table ~configmap_name)
          in
          let applied =
            match run_kubectl ~ctx [ "apply"; "-f"; configmap_yaml ] with
            | Ok _ ->
              (match run_kubectl ~ctx [ "apply"; "-f"; job_yaml ] with
               | Ok _ -> Ok ()
               | Error (Sol_cli_process.Non_zero r) ->
                 Error
                   (Printf.sprintf
                      "kubectl apply (status job) failed: %s"
                      (String.trim r.stderr))
               | Error e ->
                 Error
                   (Printf.sprintf
                      "kubectl apply (status job): %s"
                      (Sol_cli_process.error_to_string e)))
            | Error (Sol_cli_process.Non_zero r) ->
              Error
                (Printf.sprintf
                   "kubectl apply (status configmap) failed: %s"
                   (String.trim r.stderr))
            | Error e ->
              Error
                (Printf.sprintf
                   "kubectl apply (status configmap): %s"
                   (Sol_cli_process.error_to_string e))
          in
          List.iter Sol_cli_fs.remove_reporting [ configmap_yaml; job_yaml ];
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
                | Ok r -> String.trim r.stdout
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
                      (Option.fold detail ~none:"" ~some:(Printf.sprintf " (%s)")))
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
                    let text = String.trim r.stdout in
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
             status_job_evidence ~ctx ~namespace ~job_name ()
             |> Option.iter (Printf.eprintf "\nmigration-status Job evidence:\n%s\n%!");
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
   before any workload mutation. [services] is the workspace inventory the
   deploying command already read (REFAC-130). *)
let verify_migration_prerequisite ~ctx ~target ~workspace ~dir ~services =
  match Sol_cli_migration.required ~dir with
  | Error e -> Unavailable e
  | Ok [] -> No_migrations
  | Ok required ->
    let table = Sol_cli_migration.table_name ~workspace in
    (match read_applied_in_cluster ~ctx ~target ~workspace ~dir ~table ~services with
     | Error e -> Unavailable e
     | Ok applied ->
       (match Sol_cli_migration.unsatisfied ~required ~applied with
        | [] -> Satisfied applied
        | missing -> Unsatisfied missing))
;;

(* BUG-041: every entry point that hands [dir] to the runner validates it with the
   same rule the deploy gate uses first, so a shared version stops here instead of
   being applied once and skipped once. *)
let require_valid_migrations dir = Sol_cli_migration.required ~dir |> Result.map ignore

(* ── status ──────────────────────────────────────────────────────────────── *)

let run_status ~ctx ?(json = false) dir table () =
  let* () = require_valid_migrations dir in
  let* url = get_postgres_url ~ctx () in
  with_pool url (fun ~fs pool ->
    let* rows =
      Migration.status ~table pool ~dir ~fs |> Result.map_error (pg_error_to_string ~url)
    in
    Ok
      (if json
       then
         print_endline
           (Sol_cli_migration.status_json
              ~table
              (rows
               |> List.map (fun (s : Migration.status) -> s.version, s.name, s.applied_at)
              ))
       else (
         Printf.printf "%-6s  %-30s  %s\n" "VER" "NAME" "APPLIED AT";
         Printf.printf "%s\n" (String.make 60 '-');
         rows
         |> List.iter (fun (s : Migration.status) ->
           Printf.printf
             "%-6d  %-30s  %s\n"
             s.version
             s.name
             (Option.value ~default:"(pending)" s.applied_at)))))
;;

(* ── rollback ────────────────────────────────────────────────────────────── *)

let run_rollback ~ctx dir table () =
  let* () = require_valid_migrations dir in
  let* url = get_postgres_url ~ctx () in
  with_pool url (fun ~fs pool ->
    let* () =
      Migration.rollback ~table pool ~dir ~fs
      |> Result.map_error (pg_error_to_string ~url)
    in
    Printf.printf "Rolled back.\n";
    Ok ())
;;

(* ── apply dispatch: local direct-connect vs in-cluster Job ────────────────── *)

let run_apply ~ctx dir table dry_run target registry =
  let* () = require_valid_migrations dir in
  if dry_run
  then print_pending_sql dir
  else (
    match target with
    | None -> run_apply_local ~ctx dir table dry_run
    | Some target ->
      run_apply_in_cluster ~ctx ~target ~dir ~table ~registry_override:registry)
;;

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

(* FEAT-063: a named target supplies the destination; the no-target form is the
   local dev path and uses the literal local cluster. *)
let run_apply_term dir table dry_run target registry =
  Sol_cli_exit.exit_on
    (let* ctx =
       match target with
       | Some _ -> Cmd_destination.remote ~command:"migrate" target
       | None -> Ok Cmd_destination.local
     in
     run_apply ~ctx dir table dry_run target registry |> Sol_cli_exit.of_msg)
;;

let dir_arg =
  Arg.(
    value
    & opt Sol_cli_args.text "db/migrations"
    & info
        [ "dir" ]
        ~docv:"DIR"
        ~doc:"Directory containing migration SQL files (default: db/migrations)")
;;

let table_arg =
  Arg.(
    value
    & opt Sol_cli_args.text default_table_name
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
    & pos 0 (some Sol_cli_args.text) None
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
    & opt (some Sol_cli_args.text) None
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
      const run_apply_term
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
        Sol_cli_exit.exit_on
          (run_status ~ctx:Cmd_destination.local ~json dir table () |> Sol_cli_exit.of_msg))
      $ dir_arg
      $ table_arg
      $ json_flag)
;;

let rollback_cmd =
  Cmd.v
    (Cmd.info "rollback" ~doc:"Roll back the last applied migration")
    Term.(
      const (fun dir table ->
        Sol_cli_exit.exit_on
          (run_rollback ~ctx:Cmd_destination.local dir table () |> Sol_cli_exit.of_msg))
      $ dir_arg
      $ table_arg)
;;

let cmd =
  Cmd.group
    (Cmd.info "migrate" ~doc:"Run database migrations against POSTGRES_URL")
    ~default:
      Term.(
        const run_apply_term
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
        Sol_cli_exit.exit_on
          (run_apply ~ctx:Cmd_destination.local dir table dry_run None registry
           |> Sol_cli_exit.of_msg))
      $ dir_arg
      $ table_arg
      $ dry_run_flag
      $ registry_arg)
;;
