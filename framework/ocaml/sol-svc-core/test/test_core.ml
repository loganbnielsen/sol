let test_lifecycle_rejects_after_drain () =
  let lifecycle = Lifecycle.create () in
  let request = Option.get (Lifecycle.begin_request lifecycle) in
  Lifecycle.begin_draining lifecycle;
  Windtrap.equal
    Windtrap.bool
    ~msg:"draining"
    true
    (Option.is_none (Lifecycle.begin_request lifecycle));
  Lifecycle.finish_request request;
  Windtrap.equal
    Windtrap.int
    ~msg:"in-flight requests drained"
    0
    (Lifecycle.in_flight lifecycle)
;;

let test_observation_keeps_boundary_separate_from_principal () =
  match
    Observation.request_finished
      ~method_:"GET"
      ~path:"/account"
      ~boundary:Observation.External
      ~status:200
      ~duration_s:0.01
      ()
  with
  | Observation.Request_finished request ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"external boundary"
      true
      (request.Observation.boundary = Observation.External);
    Windtrap.equal
      (Windtrap.option (Windtrap.pair Windtrap.string Windtrap.string))
      ~msg:"no Sol principal"
      None
      request.Observation.workload_principal
;;

let test_projected_callers_ignore_malformed_entries () =
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
    ~msg:"valid entries only, represented as service account to caller unit"
    [ "ns-a:charge", "payments/charge"; "ns-b:checkout", "checkout/checkout" ]
    (Auth.callers_of_projection
       "payments/charge=ns-a:charge,malformed,checkout/checkout=ns-b:checkout, \
        =ns-c:no-unit")
;;

let () =
  Windtrap.run
    "sol-svc-core"
    [ Windtrap.test
        "lifecycle rejects work after drain"
        test_lifecycle_rejects_after_drain
    ; Windtrap.test
        "external observation does not imply a Sol principal"
        test_observation_keeps_boundary_separate_from_principal
    ; Windtrap.test
        "projected caller policy parsing fails closed"
        test_projected_callers_ignore_malformed_entries
    ]
;;
