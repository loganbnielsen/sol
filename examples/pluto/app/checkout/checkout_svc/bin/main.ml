let () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let obs =
    Sol_obs.of_env
      ~sw
      ~net:env#net
      ~clock:env#clock
      ~mono_clock:env#mono_clock
      ~service:"pluto-checkout-svc"
      ~context:[ "team", "checkout" ]
      ()
  in
  Service.run Checkout.routes ~env ~ot:obs ()
  |> Result.map_error Service.run_error_to_string
  |> function
  | Ok () -> ()
  | Error e -> failwith e
;;
