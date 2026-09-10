let routes =
  [ Route.get "/quote" ~auth:`Api_key (fun req ->
      let trace =
        match req.Request.trace_ctx with
        | None -> `Null
        | Some ctx -> `String (Sol_obs.trace_id_string ctx)
      in
      Response.json
        (Yojson.Basic.to_string
           (`Assoc
               [ "shipping_cents", `Int 799
               ; "currency", `String "USD"
               ; "trace_id", trace
               ])))
  ]
;;
