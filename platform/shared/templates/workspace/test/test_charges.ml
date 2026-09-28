let input : Handler.charge_input =
  { customer_id = "cus_1"; amount_cents = 4200; currency = "USD" }

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
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let obs =
            Sol_obs.of_env ~sw ~net:env#net ~clock:env#clock
              ~mono_clock:env#mono_clock ~service:"charge-test" ()
          in
          let published = ref None in
          let publish_charged event =
            published := Some event;
            Ok ()
          in
          let accepted =
            Handler.create_charge ~publish_charged ~obs ~parent:None
              ~correlation_id:(Some "cor_1") input
            |> Result.get_ok
          in
          let event : Charged.t = Option.get !published in
          assert (event.id = accepted.charge_id);
          assert (event.customer_id = input.customer_id);
          assert (event.amount_cents = input.amount_cents);
          assert (event.currency = input.currency);
          assert (event.correlation_id = "cor_1");
          let accepted =
            Handler.create_charge ~publish_charged ~obs ~parent:None
              ~correlation_id:None input
            |> Result.get_ok
          in
          let event : Charged.t = Option.get !published in
          assert (event.correlation_id = accepted.charge_id);
          let publish_charged _ = Error "broker unavailable" in
          assert (
            Handler.create_charge ~publish_charged ~obs ~parent:None
              ~correlation_id:None input
            = Error "broker unavailable")))
