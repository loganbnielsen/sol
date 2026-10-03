let sample_event : Sol_cli_toml.event_decl =
  { name = "Charged"
  ; topic = "payments.charges"
  ; partitions = 6
  ; key_field = Some "id"
  ; schema = {|{"type":"object","properties":{"id":{"type":"string"}}}|}
  }
;;

let test_render_binding () =
  let rendered = Sol_cli_contract_gen.render [ sample_event ] in
  Windtrap.equal
    Windtrap.bool
    ~msg:"module name"
    true
    (Sol_cli_string.contains ~needle:"module Charged = struct" rendered);
  Windtrap.equal
    Windtrap.bool
    ~msg:"topic"
    true
    (Sol_cli_string.contains ~needle:"payments.charges" rendered);
  Windtrap.equal
    Windtrap.bool
    ~msg:"partitions"
    true
    (Sol_cli_string.contains ~needle:"let partitions = 6" rendered);
  Windtrap.equal
    Windtrap.bool
    ~msg:"key field"
    true
    (Sol_cli_string.contains ~needle:"let key_field = Some \"id\"" rendered);
  Windtrap.equal
    Windtrap.bool
    ~msg:"format disabled for generated output"
    true
    (Sol_cli_string.contains ~needle:"[@@@ocamlformat \"disable\"]" rendered)
;;

let test_generated_path () =
  Windtrap.equal
    Windtrap.string
    ~msg:"team dir"
    "events/payments/payments_contract.ml"
    (Sol_cli_contract_gen.generated_path ~dir:"events/payments");
  Windtrap.equal
    Windtrap.string
    ~msg:"top-level dir"
    "events/events_contract.ml"
    (Sol_cli_contract_gen.generated_path ~dir:"events")
;;

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let with_workspace f =
  let root = Filename.temp_dir "sol_contract_gen" "" in
  let events_dir = Filename.concat root "events/payments" in
  (match Sol_cli_fs.mkdir_p events_dir with
   | Ok () -> ()
   | Error e -> Windtrap.fail ("could not create the fixture workspace: " ^ e));
  write_file
    (Filename.concat events_dir "sol.toml")
    {|
[[events]]
name = "Charged"
topic = "payments.charges"
partitions = 6
key = "id"
schema = '{"type":"object","properties":{"id":{"type":"string"}}}'
|};
  f root
;;

let test_discover_events () =
  with_workspace (fun root ->
    match Sol_cli_workspace_scan.discover_events ~root () with
    | Ok [ (dir, event) ] ->
      Windtrap.equal Windtrap.string ~msg:"event dir" "events/payments" dir;
      Windtrap.equal Windtrap.string ~msg:"event name" "Charged" event.name;
      Windtrap.equal Windtrap.string ~msg:"event topic" "payments.charges" event.topic;
      Windtrap.equal Windtrap.int ~msg:"event partitions" 6 event.partitions;
      Windtrap.equal
        (Windtrap.option Windtrap.string)
        ~msg:"event key"
        (Some "id")
        event.key_field
    | Ok _ -> Windtrap.fail "expected exactly one declared event"
    | Error reason ->
      Windtrap.fail
        ("declared events failed to load: " ^ Sol_cli_toml.parse_error_to_string reason))
;;

let test_generate_and_check_drift () =
  with_workspace (fun root ->
    (match Sol_cli_contract_gen.generate ~root ~check:false with
     | Ok [ "events/payments/payments_contract.ml" ] -> ()
     | Ok other ->
       Windtrap.fail
         (Printf.sprintf "expected one generated file, got %d" (List.length other))
     | Error reason -> Windtrap.fail ("generate failed: " ^ reason));
    (match Sol_cli_contract_gen.generate ~root ~check:true with
     | Ok [] -> ()
     | Ok _ -> Windtrap.fail "a freshly generated workspace must not drift"
     | Error reason -> Windtrap.fail ("unexpected drift: " ^ reason));
    write_file (Filename.concat root "events/payments/payments_contract.ml") "stale\n";
    match Sol_cli_contract_gen.generate ~root ~check:true with
    | Ok _ -> Windtrap.fail "an edited generated file must be reported as drift"
    | Error reason ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"the drift names the file"
        true
        (Sol_cli_string.contains ~needle:"payments_contract.ml" reason))
;;

let%test "contract: a binding renders its declared fields" = test_render_binding ()
let%test "contract: the generated destination is predictable" = test_generated_path ()
let%test "contract: declared events are discovered" = test_discover_events ()

let%test "contract: drift between the declaration and the checked-in binding is caught" =
  test_generate_and_check_drift ()
;;
