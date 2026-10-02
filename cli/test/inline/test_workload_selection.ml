let svc domain name =
  { Sol_cli_manifest.domain; name; primitive = Sol_cli_manifest.Svc; dir = "" }
;;

let charge = svc "payments" "charge_svc"
let checkout = svc "checkout" "checkout_svc"
let invoices = svc "payments" "invoice_svc"
let all = [ charge; checkout; invoices ]
let omit_charge (s : Sol_cli_manifest.service) = String.equal s.name "charge_svc"

let resolve scope services =
  match Sol_cli_workload_selection.resolve scope services with
  | Ok resolved -> resolved
  | Error msg -> Windtrap.fail ("unexpected resolution error: " ^ msg)
;;

let apply ?(is_omitted = omit_charge) scope =
  Sol_cli_workload_selection.apply_omission ~is_omitted (resolve scope all)
;;

let names (services : Sol_cli_manifest.service list) =
  List.map (fun (s : Sol_cli_manifest.service) -> s.name) services
  |> List.sort String.compare
;;

let test_unit_scope_names_it_back_in () =
  let o = apply (Some "payments/charge_svc") in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"it is deployed"
    [ "charge_svc" ]
    (names o.selected);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"reported as included"
    [ "charge_svc" ]
    (names o.included);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"nothing dropped"
    []
    (names o.excluded)
;;

let test_domain_scope_excludes_it () =
  let o = apply (Some "payments") in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"the rest of the domain still goes"
    [ "invoice_svc" ]
    (names o.selected);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"reported as excluded"
    [ "charge_svc" ]
    (names o.excluded);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"not quietly re-included"
    []
    (names o.included)
;;

let test_whole_workspace_excludes_it () =
  let o = apply None in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"the other units are unaffected"
    [ "checkout_svc"; "invoice_svc" ]
    (names o.selected);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"reported as excluded"
    [ "charge_svc" ]
    (names o.excluded);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"not quietly re-included"
    []
    (names o.included)
;;

let test_untouched_when_nothing_is_omitted () =
  let o = apply ~is_omitted:(fun _ -> false) (Some "payments") in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"the whole domain"
    [ "charge_svc"; "invoice_svc" ]
    (names o.selected);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"nothing excluded"
    []
    (names o.excluded);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"nothing specially included"
    []
    (names o.included)
;;

let test_selected_and_excluded_partition_the_selection () =
  List.iter
    (fun scope ->
       let resolved = resolve scope all in
       let o =
         Sol_cli_workload_selection.apply_omission ~is_omitted:omit_charge resolved
       in
       Windtrap.equal
         (Windtrap.list Windtrap.string)
         ~msg:"every resolved unit is deployed or reported excluded, exactly once"
         (names resolved.services)
         (names (o.selected @ o.excluded));
       let selected_names = names o.selected in
       names o.included
       |> List.iter (fun name ->
         Windtrap.equal
           Windtrap.bool
           ~msg:(Printf.sprintf "included %s is also selected" name)
           true
           (List.mem name selected_names)))
    [ None; Some "payments"; Some "payments/charge_svc" ]
;;

let test_the_predicate_sees_domain_and_name () =
  let billing_invoices = svc "billing" "invoice_svc" in
  let services = all @ [ billing_invoices ] in
  let o =
    Sol_cli_workload_selection.apply_omission
      ~is_omitted:(fun s ->
        String.equal s.domain "payments" && String.equal s.name "invoice_svc")
      (resolve None services)
  in
  let ids (services : Sol_cli_manifest.service list) =
    List.map (fun (s : Sol_cli_manifest.service) -> s.domain ^ "/" ^ s.name) services
    |> List.sort String.compare
  in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"the payments one is excluded; the billing unit of the same name is not"
    [ "billing/invoice_svc"; "checkout/checkout_svc"; "payments/charge_svc" ]
    (ids o.selected);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"reported as excluded"
    [ "payments/invoice_svc" ]
    (ids o.excluded)
;;

let%test "omit authority (DEC-041): unit scope names it back in" =
  test_unit_scope_names_it_back_in ()
;;

let%test "omit authority (DEC-041): domain scope excludes it" =
  test_domain_scope_excludes_it ()
;;

let%test "omit authority (DEC-041): whole workspace excludes it" =
  test_whole_workspace_excludes_it ()
;;

let%test "omit authority (DEC-041): untouched when nothing is omitted" =
  test_untouched_when_nothing_is_omitted ()
;;

let%test "omit authority (DEC-041): selected and excluded partition the selection" =
  test_selected_and_excluded_partition_the_selection ()
;;

let%test "omit authority (DEC-041): the predicate sees domain and name" =
  test_the_predicate_sees_domain_and_name ()
;;
