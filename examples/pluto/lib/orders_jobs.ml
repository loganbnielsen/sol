module Def = struct
  type t =
    | Send_confirmation of { order_id : string }
    | Release_inventory of { order_id : string }

  let workspace = "pluto.orders"

  let kind = function
    | Send_confirmation _ -> "send_confirmation"
    | Release_inventory _ -> "release_inventory"
  ;;

  let kinds = [ "send_confirmation"; "release_inventory" ]

  let encode = function
    | Send_confirmation { order_id } ->
      Printf.sprintf
        {|{"kind":"send_confirmation","order_id":%s}|}
        (Yojson.Safe.to_string (`String order_id))
    | Release_inventory { order_id } ->
      Printf.sprintf
        {|{"kind":"release_inventory","order_id":%s}|}
        (Yojson.Safe.to_string (`String order_id))
  ;;

  let decode payload =
    match
      try Ok (Yojson.Safe.from_string payload) with
      | Yojson.Json_error msg -> Error msg
    with
    | Error msg -> Error msg
    | Ok (`Assoc fields) ->
      (match List.assoc_opt "kind" fields, List.assoc_opt "order_id" fields with
       | Some (`String "send_confirmation"), Some (`String order_id) ->
         Ok (Send_confirmation { order_id })
       | Some (`String "release_inventory"), Some (`String order_id) ->
         Ok (Release_inventory { order_id })
       | _ -> Error ("invalid job payload: " ^ payload))
    | Ok _ -> Error ("invalid job payload: " ^ payload)
  ;;
end

include Def

module type POOL = sig
  val pool : Pg_db.pool
end

module Make (Config : POOL) = struct
  include Def

  let handle = function
    | Send_confirmation { order_id } ->
      (match Pg_db.transaction Config.pool (fun tx -> Orders.confirm tx ~order_id) with
       | Ok () -> Ok ()
       | Error e -> Error (Pg_error.to_string e))
    | Release_inventory { order_id } ->
      (match
         Pg_db.transaction Config.pool (fun tx -> Orders.mark_fulfilled tx ~order_id)
       with
       | Ok () -> Ok ()
       | Error e -> Error (Pg_error.to_string e))
  ;;
end
