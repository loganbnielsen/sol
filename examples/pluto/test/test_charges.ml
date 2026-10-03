let input : Handler.charge_input =
  { customer_id = "cus_1"; amount_cents = 4200; currency = "USD" }
;;

let () =
  assert (
    Handler.decode_charge_body
      {|{"customer_id":"cus_1","amount_cents":4200,"currency":"USD"}|}
    = Ok input);
  assert (Handler.decode_charge_body "{}" = Error "customer_id is required");
  assert (
    Handler.decode_charge_body {|{"customer_id":"cus_1","amount_cents":"4200"}|}
    = Error "amount_cents must be an integer");
  assert (Result.is_error (Handler.decode_charge_body "{"));
  List.iter
    (fun root ->
       match Handler.decode_charge_body root with
       | Error message -> assert (message = "request body must be a JSON object")
       | Ok _ -> failwith ("non-object root accepted: " ^ root))
    [ "[]"; "null"; "42"; "3.5"; "\"text\""; "true" ];
  let inserted = ref None in
  let insert ~charge_id ~customer_id ~amount_cents ~currency =
    inserted := Some (charge_id, customer_id, amount_cents, currency);
    Ok (Some charge_id)
  in
  let accepted = Handler.create_charge ~insert input |> Result.get_ok in
  assert (
    !inserted
    = Some (accepted.charge_id, input.customer_id, input.amount_cents, input.currency));
  let failure = `Unavailable in
  let insert ~charge_id:_ ~customer_id:_ ~amount_cents:_ ~currency:_ = Error failure in
  assert (Handler.create_charge ~insert input = Error failure)
;;
