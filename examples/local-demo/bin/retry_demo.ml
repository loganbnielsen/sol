(** Sol retry-topics demo
    ─────────────────────────────────────────────────────────────────────────
    Scenario:
      5 jobs are produced.  Three are reliable (always succeed).
      Two are "flakey" — they fail on the first attempt, exercising the
      Retry_topics strategy end-to-end:

        1. Main consumer: handler returns Error _ for a flakey job.
           kafka_service intercepts it, publishes the raw bytes to
             sol-demo-jobs-retry
           with headers
             X-Sol-Attempt:  1
             X-Sol-Retry-At: <now + 2 s>
           and commits the original offset immediately.
           The main partition keeps flowing — reliable jobs are never delayed.

        2. Background retry consumer (group "sol-demo-retry-worker-sol-retry")
           subscribes to sol-demo-jobs-retry.
           When the scheduled time arrives it pauses the partition, sleeps,
           resumes, then re-runs the handler.  The second attempt succeeds.

        3. After max_attempts total failures a message would go to
           sol-demo-jobs-dlq.  This demo stays well within the limit.

    Run:
      bash cli/platform/local/scripts/ensure-broker.sh
      KAFKA_BROKERS=localhost:9092 dune exec examples/local-demo/bin/retry_demo.exe
*)

(* ── Job message ────────────────────────────────────────────────────────── *)

module Job = struct
  type t = { id : string; payload : string }

  let topic_name = Kafka_service.topic_name_exn "sol-demo-jobs"

  let schema = {|{
    "type": "object",
    "properties": {
      "id":      { "type": "string" },
      "payload": { "type": "string" }
    },
    "required": ["id", "payload"]
  }|}

  let encode t = `Assoc [("id", `String t.id); ("payload", `String t.payload)]

  let decode = function
    | `Assoc fields ->
      let s k = match List.assoc_opt k fields with
        | Some (`String s) -> Some s | _ -> None
      in
      (match s "id", s "payload" with
       | Some id, Some payload -> Ok { id; payload }
       | _ -> Error "missing fields")
    | _ -> Error "expected object"
end

(* ── Demo configuration ─────────────────────────────────────────────────── *)

let kafka_config : Kafka_service.config =
  let config =
    match Kafka_service.config_of_env () with
    | Ok config -> config
    | Error e   -> failwith ("kafka config: " ^ Kafka_service.error_to_string e)
  in
  { config with linger_ms = 5 }

let sep       = String.make 60 '-'
let say fmt   = Printf.ksprintf (Printf.printf "\n[demo]   %s\n%!") fmt
let stamp ()  = Unix.gettimeofday ()

(* ── Flakey-job table ───────────────────────────────────────────────────── *)
(* Maps job_id → number of times handle has been called.
   Flakey jobs fail on call 0 and succeed on call 1+. *)

let call_count : (string, int) Hashtbl.t = Hashtbl.create 8
let call_mu = Mutex.create ()

let record_call job_id =
  Mutex.protect call_mu (fun () ->
    let n = try Hashtbl.find call_count job_id with Not_found -> 0 in
    Hashtbl.replace call_count job_id (n + 1);
    n)

let flakey_jobs = ["job-A"; "job-C"]
let is_flakey id = List.mem id flakey_jobs

(* ── Main ───────────────────────────────────────────────────────────────── *)

let () =
  let total_jobs    = 5 in
  let completed     = Atomic.make 0 in
  let done_resolved = Atomic.make false in
  let all_done_p, all_done_r = Eio.Promise.create () in
  let t0            = ref (stamp ()) in

  Printf.printf "\n%s\n" sep;
  Printf.printf "  Sol Retry-Topics Demo\n";
  Printf.printf "  strategy: Retry_topics { max_attempts = 3 }\n";
  Printf.printf "  jobs: %d total (%d flakey, fail once then recover)\n"
    total_jobs (List.length flakey_jobs);
  Printf.printf "  flakey jobs: %s\n" (String.concat ", " flakey_jobs);
  Printf.printf "%s\n%!" sep;

  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->

  let svc =
    match Kafka_service.create kafka_config ~sw with
    | Ok s    -> s
    | Error e -> failwith ("kafka_service.create: " ^ Kafka_service.error_to_string e)
  in
  let topic =
    match Kafka_service.register svc ~net:env#net ~clock:env#clock
            (module Job) with
    | Ok t    -> t
    | Error e -> failwith ("kafka_service.register: " ^ Kafka_service.error_to_string e)
  in
  say "topic %S registered." (Kafka_service.topic_name_to_string Job.topic_name);

  (* ── Worker ────────────────────────────────────────────────────────────── *)
  let worker_ready_p, worker_ready_r = Eio.Promise.create () in

  let module W = struct
    module Message = Job
    let group_id = "sol-demo-retry-worker"

    let handle msg ~trace_ctx:_ =
      let call_n = record_call msg.Message.id in
      let ts     = stamp () -. !t0 in
      if is_flakey msg.Message.id && call_n = 0 then begin
        Printf.printf "[worker] t=%.2fs  %-8s  attempt %d → FAIL  (will retry in ~2s)\n%!"
          ts msg.Message.id (call_n + 1);
        Error "transient failure"
      end else begin
        Printf.printf "[worker] t=%.2fs  %-8s  attempt %d → ok\n%!"
          ts msg.Message.id (call_n + 1);
        let n = Atomic.fetch_and_add completed 1 + 1 in
        if n >= total_jobs &&
           Atomic.compare_and_set done_resolved false true then
          Eio.Promise.resolve all_done_r ();
        Ok ()
      end
  end in

  Eio.Fiber.fork_daemon ~sw (fun () ->
    (try
       let module WR = Worker.Make(W) in
       WR.run ~env ~config:kafka_config
         ~retry_strategy:(Worker.Retry_topics { max_attempts = 3 })
         ~on_ready:(fun () ->
           Printf.printf "\n[worker] partition assigned — ready\n%!";
           (try Eio.Promise.resolve worker_ready_r () with _ -> ()))
         ()
       |> Result.map_error Worker.run_error_to_string
       |> function Ok () -> () | Error msg -> failwith msg
     with
     | Failure _  -> ()   (* clean exit via cancellation surfaces as Failure *)
     | _          -> ());
    `Stop_daemon
  );

  (* ── Wait for partition assignment ──────────────────────────────────────── *)
  say "waiting for partition assignment (up to 15s) ...";
  (match Eio.Time.with_timeout env#clock 15.0
           (fun () -> Ok (Eio.Promise.await worker_ready_p)) with
   | Error `Timeout -> failwith "timed out waiting for partition assignment"
   | Ok ()          -> ());

  (* ── Produce jobs ───────────────────────────────────────────────────────── *)
  Printf.printf "\n%s\n" sep;
  t0 := stamp ();
  let jobs = [
    { Job.id = "job-A"; payload = "process invoice #1001" };   (* flakey *)
    { Job.id = "job-B"; payload = "send confirmation email"  };
    { Job.id = "job-C"; payload = "update inventory #42"    };  (* flakey *)
    { Job.id = "job-D"; payload = "charge payment method"   };
    { Job.id = "job-E"; payload = "notify fulfillment team" };
  ] in
  List.iter (fun (j : Job.t) ->
    let tag = if is_flakey j.id then "  ← flakey" else "" in
    Printf.printf "[prod]   %-8s  %s%s\n%!" j.id j.payload tag;
    (match Eio.Promise.await (Kafka_service.publish svc topic j) with
     | Ok ()    -> ()
     | Error ke ->
       Printf.eprintf "[prod]   publish error: %s\n%!" (Kafka.Error.to_string ke))
  ) jobs;
  Printf.printf "%s\n%!" sep;

  (* ── Wait for all jobs to complete ─────────────────────────────────────── *)
  say "waiting for all %d jobs to complete (flakey ones retry after ~2s) ..."
    total_jobs;
  (match Eio.Time.with_timeout env#clock 30.0
           (fun () -> Ok (Eio.Promise.await all_done_p)) with
   | Error `Timeout ->
     Printf.eprintf "\n[demo]   timed out after 30s (%d/%d completed)\n%!"
       (Atomic.get completed) total_jobs
   | Ok () ->
     let elapsed = stamp () -. !t0 in
     Printf.printf "\n%s\n" sep;
     say "all %d/%d jobs completed in %.1fs." (Atomic.get completed) total_jobs elapsed;
     Printf.printf "  reliable jobs: processed immediately on main consumer\n";
     Printf.printf "  flakey  jobs:  acked on main, retried via sol-demo-jobs-retry\n";
     Printf.printf "%s\n%!" sep);

  (* Give the worker a moment to flush its last log line before exit. *)
  Eio.Time.sleep env#clock 0.2
