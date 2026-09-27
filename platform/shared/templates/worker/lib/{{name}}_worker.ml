(* Replace Message with your event module, e.g.:
     module Message = My_team_events.My_event *)
module Message = struct
  type t = { id : string }
  let topic_name = Kafka_service.topic_name_exn "{{domain}}-{{name}}-events"
  let schema = {|{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}|}
  let encode t = `Assoc [("id", `String t.id)]
  let required_string fields name =
    match List.assoc_opt name fields with
    | Some (`String value) -> Ok value
    | Some _              -> Error (name ^ " must be a string")
    | None                -> Error (name ^ " is required")
  open Result.Syntax
  let decode = function
    | `Assoc fields ->
      let* id = required_string fields "id" in
      Ok { id }
    | _ -> Error "expected object"
end

let group_id = "{{domain}}-{{name}}-worker"

let handle (msg : Message.t) ~trace_ctx:_ =
  Printf.printf "[{{name}}-worker] received id=%s\n%!" msg.id;
  (* Add side effects here, then return Worker.Ack. The worker acknowledges
     (commits the offset) for you, only after this returns Worker.Ack — there is
     no ack to call.
     This is an Ack-only worker: it has no retry capability, so a failed side
     effect here has nowhere to go but a raised exception. If you need retry
     or dead-letter handling, change Message.t's module to implement
     Worker.RETRYABLE_WORKER (handle returning Worker.outcome, i.e.
     Worker.Ack | Worker.Retry _ | Worker.Dead_letter _) and run it with
     Worker.Make_with_retry, which requires an explicit ~retry_strategy. *)
  Worker.Ack
