type order_input =
  { order_id : string
  ; item : string
  ; quantity : int
  }

type deps =
  { accept :
      order_id:string
      -> item:string
      -> quantity:int
      -> correlation_id:string
      -> (string, Pg_error.t) result
  ; read : order_id:string -> (Orders.order option, Pg_error.t) result
  }

let generated_correlation_id () =
  Printf.sprintf "%08x" (Random.bits () lxor (Random.bits () lsl 1))
;;

let required_string json name =
  match Yojson.Basic.Util.member name json with
  | `String value when value <> "" -> Ok value
  | `String _ -> Error (name ^ " must not be empty")
  | `Null -> Error (name ^ " is required")
  | _ -> Error (name ^ " must be a string")
;;

let required_int json name =
  match Yojson.Basic.Util.member name json with
  | `Int value -> Ok value
  | `Null -> Error (name ^ " is required")
  | _ -> Error (name ^ " must be an integer")
;;

let decode_order_body body =
  let parsed =
    try Ok (Yojson.Basic.from_string body) with
    | Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)
  in
  match parsed with
  | Error msg -> Error msg
  | Ok json ->
    (match json with
     | `Assoc _ ->
       let open Result.Syntax in
       let* order_id = required_string json "order_id" in
       let* item = required_string json "item" in
       let* quantity = required_int json "quantity" in
       Ok { order_id; item; quantity }
     | _ -> Error "request body must be a JSON object")
;;

let accepted_body order_id status =
  Printf.sprintf
    {|{"order_id":%s,"status":%s}|}
    (Yojson.Safe.to_string (`String order_id))
    (Yojson.Safe.to_string (`String status))
;;

let order_body (order : Orders.order) =
  Printf.sprintf
    {|{"order_id":%s,"item":%s,"quantity":%d,"status":%s}|}
    (Yojson.Safe.to_string (`String order.order_id))
    (Yojson.Safe.to_string (`String order.item))
    order.quantity
    (Yojson.Safe.to_string (`String order.status))
;;

let correlation_id req =
  match Request.header req "x-correlation-id" with
  | Some value when value <> "" -> value
  | _ -> generated_correlation_id ()
;;

let accept_response ~deps ~correlation_id body =
  match decode_order_body body with
  | Error msg -> Response.bad_request msg
  | Ok input ->
    (match
       deps.accept
         ~order_id:input.order_id
         ~item:input.item
         ~quantity:input.quantity
         ~correlation_id
     with
     | Ok status -> Response.json ~status:202 (accepted_body input.order_id status)
     | Error e -> Response.internal_error ("order accept failed: " ^ Pg_error.to_string e))
;;

let handle_accept deps req =
  accept_response ~deps ~correlation_id:(correlation_id req) req.Request.body
;;

let read_response ~deps ~order_id =
  match deps.read ~order_id with
  | Ok None -> Response.not_found
  | Ok (Some order) -> Response.json (order_body order)
  | Error e -> Response.internal_error ("order read failed: " ^ Pg_error.to_string e)
;;

let handle_read deps req =
  read_response ~deps ~order_id:(Request.param_exn req "order_id")
;;

let method_to_string = function
  | `GET -> "GET"
  | `POST -> "POST"
  | `PUT -> "PUT"
  | `PATCH -> "PATCH"
  | `DELETE -> "DELETE"
;;

let with_request_span obs req name f =
  match obs with
  | None -> f ()
  | Some obs ->
    Sol_obs.with_span obs ?parent:req.Request.trace_ctx name (fun span ->
      let response = f () in
      Sol_obs.log
        span
        Sol_obs.Info
        ~fields:
          [ "method", method_to_string req.Request.method_
          ; "path", req.Request.path
          ; "status", string_of_int response.Response.status
          ]
        "request handled";
      response)
;;

let routes ~obs ~deps =
  [ Route.post "/orders" ~auth:`Public (fun req ->
      with_request_span obs req "receive_order" (fun () -> handle_accept deps req))
  ; Route.get "/orders/:order_id" ~auth:`Public (fun req ->
      with_request_span obs req "read_order" (fun () -> handle_read deps req))
  ]
;;
