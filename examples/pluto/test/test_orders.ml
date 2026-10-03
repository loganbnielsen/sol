let deps ?(status = "accepted") ?(order = None) ?accept_error () : Orders_handler.deps =
  { accept =
      (fun ~order_id:_ ~item:_ ~quantity:_ ~correlation_id:_ ->
        match accept_error with
        | Some error -> Error error
        | None -> Ok status)
  ; read = (fun ~order_id:_ -> Ok order)
  }
;;

let () =
  let decoded : Orders_handler.order_input =
    { order_id = "o1"; item = "widget"; quantity = 3 }
  in
  assert (
    Orders_handler.decode_order_body {|{"order_id":"o1","item":"widget","quantity":3}|}
    = Ok decoded);
  assert (Result.is_error (Orders_handler.decode_order_body "{}"));
  assert (Result.is_error (Orders_handler.decode_order_body "{"));
  let accepted =
    Orders_handler.accept_response
      ~deps:(deps ())
      ~correlation_id:"c1"
      {|{"order_id":"o1","item":"widget","quantity":3}|}
  in
  assert (accepted.Response.status = 202);
  assert (accepted.Response.body = {|{"order_id":"o1","status":"accepted"}|});
  let duplicate =
    Orders_handler.accept_response
      ~deps:(deps ~status:"confirmed" ())
      ~correlation_id:"c2"
      {|{"order_id":"o1","item":"widget","quantity":3}|}
  in
  assert (duplicate.Response.body = {|{"order_id":"o1","status":"confirmed"}|});
  let rejected =
    Orders_handler.accept_response
      ~deps:(deps ~accept_error:(Pg_error.Query_error "nope") ())
      ~correlation_id:"c3"
      {|{"order_id":"o1","item":"widget","quantity":3}|}
  in
  assert (rejected.Response.status = 500);
  assert (
    (Orders_handler.read_response ~deps:(deps ()) ~order_id:"o1").Response.status = 404);
  let found =
    Orders_handler.read_response
      ~deps:
        (deps
           ~order:
             (Some
                { Orders.order_id = "o1"
                ; item = "widget"
                ; quantity = 3
                ; status = "fulfilled"
                })
           ())
      ~order_id:"o1"
  in
  assert (found.Response.status = 200);
  assert (
    found.Response.body
    = {|{"order_id":"o1","item":"widget","quantity":3,"status":"fulfilled"}|});
  let round_trip job =
    match Orders_jobs.decode (Orders_jobs.encode job) with
    | Ok decoded -> assert (Orders_jobs.kind decoded = Orders_jobs.kind job)
    | Error msg -> failwith msg
  in
  round_trip (Orders_jobs.Send_confirmation { order_id = "o1" });
  round_trip (Orders_jobs.Release_inventory { order_id = "o1" });
  assert (Result.is_error (Orders_jobs.decode "not json"));
  assert (Result.is_error (Orders_jobs.decode {|{"kind":"bogus","order_id":"o1"}|}))
;;
