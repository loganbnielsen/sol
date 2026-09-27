(* REFAC-139, part A: running the migration runner in the target cluster.

   `sol migrate apply` and the deploy's read-only prerequisite check both run
   the runner as a Job over a ConfigMap of the migration files, wait for it, read
   its logs and clean up. They did so with two ~200-line copies in
   `cmd_migrate.ml` that had drifted: only the check failed fast on a container
   that cannot start (INFRA-040), so `apply` waited its full 300s on, for one,
   a missing runtime Secret. This module is that Job, once; the command decides
   what an outcome means for it and renders it. *)

open Result.Syntax

type job =
  { namespace : string
  ; job_name : string
  ; configmap_name : string
  }

type outcome =
  | Succeeded
  | Failed
  | Unstartable of
      { reason : string
      ; detail : string option
      }
  | Timed_out of float

let kubectl ~ctx ?(timeout_s = 30.) args = Sol_cli_kubectl.run ~timeout_s ~ctx args

(* The runner image is the Sol CLI itself, which carries `sol migrate`. *)
let runner_dockerfile =
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

(* REFAC-130: the caller read the workspace once and passes the inventory. The
   Job runs in the first service's namespace (by domain, then name), and a
   source-built runner is pushed to that service's repository: ECR needs the
   repository to exist, and there is one per service. *)
let namespace_and_repository ~workspace ~(services : Sol_cli_manifest.service list) =
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

(* DEC-049: a checkout builds its runner from itself and pushes it to the target's
   registry; an installed release runs the runner published with it, by digest,
   and needs no build and no registry. The apply path and the deploy's check
   obtain it the same way, so the check runs exactly the code that would apply. *)
let runner_source () =
  let* assets =
    Sol_cli_platform_assets.resolve ()
    |> Result.map_error Sol_cli_platform_assets.error_to_string
  in
  Sol_cli_platform_assets.migration_runner assets
;;

let runner_image ~registry ~workspace ~k8s_name =
  let* runner = runner_source () in
  match (runner : Sol_cli_platform_assets.migration_runner) with
  | Published image ->
    Sol_cli_report.app "Using migration runner %s" image;
    Ok image
  | Build_from_source { context } ->
    let* registry = registry in
    let image =
      Sol_cli_deployment_plan.image_ref
        ~registry
        ~workspace
        ~k8s_name
        ~tag:"sol-cli-migrate"
    in
    Sol_cli_report.app "Building migration runner image %s..." image;
    let built =
      Sol_cli_fs.with_temp_file
        ~prefix:"sol-migrate-"
        ~suffix:".Dockerfile"
        runner_dockerfile
        (fun dockerfile ->
           Sol_cli_docker.build ~tag:image ~dockerfile ~context
           |> Result.map_error (fun e ->
             "docker build: " ^ Sol_cli_process.error_to_string e))
      |> Result.join
    in
    let* () = built in
    Sol_cli_report.app "Pushing %s..." image;
    let* () =
      Sol_cli_docker.push ~image_ref:image
      |> Result.map_error (fun e -> "docker push: " ^ Sol_cli_process.error_to_string e)
    in
    Ok image
;;

let apply_doc ~ctx ~what doc =
  Sol_cli_fs.with_temp_file
    ~prefix:"sol-migrate-"
    ~suffix:".yaml"
    (Sol_cli_yaml.render [ doc ])
    (fun file ->
       Sol_cli_kubectl.apply ~ctx ~file
       |> Result.map_error (fun e ->
         Printf.sprintf "kubectl apply (%s): %s" what (Sol_cli_process.error_to_string e)))
  |> Result.join
;;

(* Removes the Job and its ConfigMap. Absent is fine; any other failure is
   reported, because a stray Job is something the operator should know about. *)
let cleanup ~ctx job =
  [ [ "delete"
    ; "job"
    ; job.job_name
    ; "-n"
    ; job.namespace
    ; "--ignore-not-found"
    ; "--wait=false"
    ]
  ; [ "delete"
    ; "configmap"
    ; job.configmap_name
    ; "-n"
    ; job.namespace
    ; "--ignore-not-found"
    ]
  ]
  |> List.iter (fun args ->
    kubectl ~ctx args
    |> Result.iter_error (fun e ->
      Sol_cli_report.warn
        "warning: could not clean up after the migration Job: %s"
        (Sol_cli_process.error_to_string e)))
;;

(* The Job and its ConfigMap, named [<prefix>-<id>] and [<prefix>-files-<id>]. A
   ConfigMap whose Job then fails to apply is removed, so a half-created attempt
   leaves nothing behind. *)
let submit ~ctx ~namespace ~name_prefix ~label ~image ~args ~files =
  let run_id = Printf.sprintf "%.0f" (Unix.gettimeofday () *. 1000.) in
  let job =
    { namespace
    ; job_name = Printf.sprintf "%s-%s" name_prefix run_id
    ; configmap_name = Printf.sprintf "%s-files-%s" name_prefix run_id
    }
  in
  let* () =
    apply_doc
      ~ctx
      ~what:(label ^ "configmap")
      (Sol_cli_manifest.migration_configmap_doc ~name:job.configmap_name ~namespace files)
  in
  match
    apply_doc
      ~ctx
      ~what:(label ^ "job")
      (Sol_cli_manifest.migration_job_doc
         ~name:job.job_name
         ~namespace
         ~image
         ~args
         ~configmap_name:job.configmap_name)
  with
  | Ok () -> Ok job
  | Error _ as e ->
    cleanup ~ctx job;
    e
;;

(* INFRA-040: a Job whose container cannot start has already failed. Waiting the
   full timeout for an outcome that cannot come describes the symptom and hides the
   cause: Attempt 6 spent its entire migration gate on "did not complete within
   120s" while the Pod had been reporting
   `CreateContainerConfigError: secret "sol-secrets" not found` from the start.

   The reason and the message are read together, because the reason names the class
   and the message names the thing -- which Secret, which image. *)
let waiting_status ~ctx job =
  let jsonpath =
    "jsonpath={range \
     .items[*]}{.status.containerStatuses[*].state.waiting.reason}\"|\"{.status.containerStatuses[*].state.waiting.message}{\"\\n\"}{end}"
  in
  match
    kubectl
      ~ctx
      ~timeout_s:15.
      [ "get"
      ; "pods"
      ; "-n"
      ; job.namespace
      ; "-l"
      ; "job-name=" ^ job.job_name
      ; "-o"
      ; jsonpath
      ]
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

(* kubectl wait's own --for=condition=complete never returns on a failed Job, so
   the status fields are polled. JobStatus's succeeded/failed are `omitempty`, so
   each is read on its own: an absent field is then just blank. A read that fails
   reads as "not finished yet"; the poll's bound is what ends it. *)
let job_field ~ctx job field =
  match
    kubectl
      ~ctx
      ~timeout_s:15.
      [ "get"
      ; "job"
      ; job.job_name
      ; "-n"
      ; job.namespace
      ; "-o"
      ; Printf.sprintf "jsonpath={.status.%s}" field
      ]
  with
  | Ok r -> String.trim r.stdout
  | Error _ -> ""
;;

let wait ~ctx ~interval_s ~attempts job =
  let failed () =
    match job_field ~ctx job "failed" with
    | "" | "0" -> false
    | _ -> true
  in
  let rec poll n =
    if n = 0
    then Timed_out (interval_s *. float_of_int attempts)
    else if job_field ~ctx job "succeeded" = "1"
    then Succeeded
    else if failed ()
    then Failed
    else (
      match waiting_status ~ctx job with
      | Some (reason, detail) when List.mem reason terminal_waiting_reasons ->
        Unstartable { reason; detail }
      | _ ->
        Unix.sleepf interval_s;
        poll (n - 1))
  in
  poll attempts
;;

let logs ~ctx job =
  kubectl ~ctx [ "logs"; "job/" ^ job.job_name; "-n"; job.namespace ]
  |> Result.map (fun (r : Sol_cli_process.output) -> r.stdout)
  |> Result.map_error Sol_cli_process.error_to_string
;;

(* INFRA-040: read the failing Job's evidence out before anything removes it.
   Both observations are gathered because a Job fails in either direction: a
   container that cannot start has a waiting reason and no logs, while a Job that
   ran and failed has logs and no waiting reason. *)
let evidence ~ctx job =
  let logs =
    match
      kubectl
        ~ctx
        ~timeout_s:20.
        [ "logs"; "job/" ^ job.job_name; "-n"; job.namespace; "--tail=200" ]
    with
    | Ok r -> Sol_cli_string.non_blank r.stdout
    | Error (Sol_cli_process.Non_zero r) ->
      Some ("(kubectl logs failed: " ^ Sol_cli_process.failure_message r ^ ")")
    | Error _ -> None
  in
  Sol_cli_migration.evidence_report ~waiting:(waiting_status ~ctx job) ~logs
;;
