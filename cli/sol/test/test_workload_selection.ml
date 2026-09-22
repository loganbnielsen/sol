(* DEC-041: what a target's `omit` declarations do to a resolved selection.

   The rule being pinned is the one the DEC was about: `omit` means "not in this
   target's default set", so a bare `--scope <domain>` and a whole-workspace run
   exclude an omitted unit, while `--scope <domain>/<name>` is explicit intent
   about that unit and may include it back — reporting that it did. Pure, so no
   workspace or cluster is involved. *)

let svc domain name =
  { Sol_cli_manifest.domain; name; primitive = Sol_cli_manifest.Svc; dir = "" }
;;

let charge = svc "payments" "charge_svc"
let checkout = svc "checkout" "checkout_svc"
let invoices = svc "payments" "invoice_svc"
let all = [ charge; checkout; invoices ]

(* The target omits one unit in one domain. *)
let omit_charge (s : Sol_cli_manifest.service) = String.equal s.name "charge_svc"

let resolve scope services =
  match Sol_cli_workload_selection.resolve scope services with
  | Ok resolved -> resolved
  | Error msg -> Alcotest.fail ("unexpected resolution error: " ^ msg)
;;

let apply ?(is_omitted = omit_charge) scope =
  Sol_cli_workload_selection.apply_omission ~is_omitted (resolve scope all)
;;

let names (services : Sol_cli_manifest.service list) =
  List.map (fun (s : Sol_cli_manifest.service) -> s.name) services
  |> List.sort String.compare
;;

(* A unit-level scope names the unit, so it is deployed even though the target
   omits it -- and the caller is told, because this is the escape hatch. *)
let test_unit_scope_names_it_back_in () =
  let o = apply (Some "payments/charge_svc") in
  Alcotest.(check (list string)) "it is deployed" [ "charge_svc" ] (names o.selected);
  Alcotest.(check (list string))
    "reported as included"
    [ "charge_svc" ]
    (names o.included);
  Alcotest.(check (list string)) "nothing dropped" [] (names o.excluded)
;;

(* A domain-level scope names a domain, not a unit: the omitted unit is excluded
   from the expansion rather than swept back in as collateral. *)
let test_domain_scope_excludes_it () =
  let o = apply (Some "payments") in
  Alcotest.(check (list string))
    "the rest of the domain still goes"
    [ "invoice_svc" ]
    (names o.selected);
  Alcotest.(check (list string))
    "reported as excluded"
    [ "charge_svc" ]
    (names o.excluded);
  Alcotest.(check (list string)) "not quietly re-included" [] (names o.included)
;;

(* No scope at all is still not naming a unit. *)
let test_whole_workspace_excludes_it () =
  let o = apply None in
  Alcotest.(check (list string))
    "the other units are unaffected"
    [ "checkout_svc"; "invoice_svc" ]
    (names o.selected);
  Alcotest.(check (list string))
    "reported as excluded"
    [ "charge_svc" ]
    (names o.excluded);
  Alcotest.(check (list string)) "not quietly re-included" [] (names o.included)
;;

(* A target that omits nothing must behave exactly as before. *)
let test_untouched_when_nothing_is_omitted () =
  let o = apply ~is_omitted:(fun _ -> false) (Some "payments") in
  Alcotest.(check (list string))
    "the whole domain"
    [ "charge_svc"; "invoice_svc" ]
    (names o.selected);
  Alcotest.(check (list string)) "nothing excluded" [] (names o.excluded);
  Alcotest.(check (list string)) "nothing specially included" [] (names o.included)
;;

(* `selected` and `excluded` must partition the resolved selection: a unit that is
   neither deployed nor reported as excluded is a silent drop, which is the shape
   this DEC exists to prevent. `included` is not part of that partition — it
   names units already in `selected` — so it is asserted as a subset instead. *)
let test_selected_and_excluded_partition_the_selection () =
  List.iter
    (fun scope ->
       let resolved = resolve scope all in
       let o =
         Sol_cli_workload_selection.apply_omission ~is_omitted:omit_charge resolved
       in
       Alcotest.(check (list string))
         "every resolved unit is deployed or reported excluded, exactly once"
         (names resolved.services)
         (names (o.selected @ o.excluded));
       let selected_names = names o.selected in
       List.iter
         (fun name ->
            Alcotest.(check bool)
              (Printf.sprintf "included %s is also selected" name)
              true
              (List.mem name selected_names))
         (names o.included))
    [ None; Some "payments"; Some "payments/charge_svc" ]
;;

(* The predicate sees the whole service, so a target can key by domain as well as
   by name. That matters because the config declares `omit` on a service *name*
   while discovery keys a unit by (domain, name), so a name alone can be ambiguous
   — which is why the deploy passes a predicate over services rather than a name
   list. Compared as domain/name here, since two units share a name. *)
let test_the_predicate_sees_domain_and_name () =
  let billing_invoices = svc "billing" "invoice_svc" in
  let services = all @ [ billing_invoices ] in
  let o =
    Sol_cli_workload_selection.apply_omission
      ~is_omitted:(fun (s : Sol_cli_manifest.service) ->
        String.equal s.domain "payments" && String.equal s.name "invoice_svc")
      (resolve None services)
  in
  let ids (services : Sol_cli_manifest.service list) =
    List.map (fun (s : Sol_cli_manifest.service) -> s.domain ^ "/" ^ s.name) services
    |> List.sort String.compare
  in
  Alcotest.(check (list string))
    "the payments one is excluded; the billing unit of the same name is not"
    [ "billing/invoice_svc"; "checkout/checkout_svc"; "payments/charge_svc" ]
    (ids o.selected);
  Alcotest.(check (list string))
    "reported as excluded"
    [ "payments/invoice_svc" ]
    (ids o.excluded)
;;

let () =
  Alcotest.run
    "workload_selection"
    [ ( "omit authority (DEC-041)"
      , [ Alcotest.test_case
            "unit scope names it back in"
            `Quick
            test_unit_scope_names_it_back_in
        ; Alcotest.test_case
            "domain scope excludes it"
            `Quick
            test_domain_scope_excludes_it
        ; Alcotest.test_case
            "whole workspace excludes it"
            `Quick
            test_whole_workspace_excludes_it
        ; Alcotest.test_case
            "untouched when nothing is omitted"
            `Quick
            test_untouched_when_nothing_is_omitted
        ; Alcotest.test_case
            "selected and excluded partition the selection"
            `Quick
            test_selected_and_excluded_partition_the_selection
        ; Alcotest.test_case
            "the predicate sees domain and name"
            `Quick
            test_the_predicate_sees_domain_and_name
        ] )
    ]
;;
