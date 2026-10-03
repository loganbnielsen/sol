let sample_event : Sol_cli_toml.event_decl =
  { name = "Charged"
  ; topic = "payments.charges"
  ; partitions = 6
  ; key_field = Some "id"
  ; schema = {|{"type":"object","properties":{"id":{"type":"string"}}}|}
  }
;;

let contains needle haystack = Sol_cli_string.contains ~needle haystack

let test_render_ocaml_binding () =
  let rendered = Sol_cli_contract_gen.render ~language:Ocaml [ sample_event ] in
  Windtrap.equal
    Windtrap.bool
    ~msg:"module name"
    true
    (contains "module Charged = struct" rendered);
  Windtrap.equal Windtrap.bool ~msg:"topic" true (contains "payments.charges" rendered);
  Windtrap.equal
    Windtrap.bool
    ~msg:"partitions"
    true
    (contains "let partitions = 6" rendered);
  Windtrap.equal
    Windtrap.bool
    ~msg:"key field"
    true
    (contains "let key_field = Some \"id\"" rendered);
  Windtrap.equal
    Windtrap.bool
    ~msg:"format disabled for generated output"
    true
    (contains "[@@@ocamlformat \"disable\"]" rendered)
;;

let test_render_typescript_binding () =
  let rendered = Sol_cli_contract_gen.render ~language:Typescript [ sample_event ] in
  Windtrap.equal
    Windtrap.bool
    ~msg:"the declared event becomes a spec constant"
    true
    (contains "export const ChargedSpec: EventContractSpec" rendered);
  Windtrap.equal
    Windtrap.bool
    ~msg:"topic"
    true
    (contains "name: \"payments.charges\"" rendered);
  Windtrap.equal Windtrap.bool ~msg:"partitions" true (contains "partitions: 6" rendered);
  Windtrap.equal
    Windtrap.bool
    ~msg:"key field"
    true
    (contains "keyField: \"id\"" rendered);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the key is a generated field extractor, not app code"
    true
    (contains "(message as unknown as Record<string, unknown>)[spec.keyField]" rendered)
;;

let test_generated_path () =
  Windtrap.equal
    Windtrap.string
    ~msg:"ocaml team dir"
    "events/payments/payments_contract.ml"
    (Sol_cli_contract_gen.generated_path ~dir:"events/payments" ~language:Ocaml);
  Windtrap.equal
    Windtrap.string
    ~msg:"ocaml top-level dir"
    "events/events_contract.ml"
    (Sol_cli_contract_gen.generated_path ~dir:"events" ~language:Ocaml);
  Windtrap.equal
    Windtrap.string
    ~msg:"typescript lands in the scope's contract package, not beside the declaration"
    "app/demo_ts/contract/src/demo_ts_contract.ts"
    (Sol_cli_contract_gen.generated_path ~dir:"events/demo_ts" ~language:Typescript)
;;

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let mkdir path =
  match Sol_cli_fs.mkdir_p path with
  | Ok () -> ()
  | Error e -> Windtrap.fail ("could not create the fixture workspace: " ^ e)
;;

let manifest ~language =
  Printf.sprintf
    "\n\
     [contract]\n\
     language = %S\n\n\
     [[events]]\n\
     name = \"Charged\"\n\
     topic = \"payments.charges\"\n\
     partitions = 6\n\
     key = \"id\"\n\
     schema = '{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}}}'\n"
    language
;;

let with_workspace ~language ~team f =
  let root = Filename.temp_dir "sol_contract_gen" "" in
  let events_dir = Filename.concat root (Filename.concat "events" team) in
  mkdir events_dir;
  write_file (Filename.concat events_dir "sol.toml") (manifest ~language);
  f root
;;

let test_discover_contracts () =
  with_workspace ~language:"typescript" ~team:"demo_ts" (fun root ->
    match Sol_cli_workspace_scan.discover_contracts ~root () with
    | Ok [ contract ] ->
      Windtrap.equal Windtrap.string ~msg:"contract dir" "events/demo_ts" contract.dir;
      Windtrap.equal
        Windtrap.string
        ~msg:"contract language"
        "typescript"
        (Sol_cli_toml.binding_language_to_string contract.language);
      Windtrap.equal
        (Windtrap.list Windtrap.string)
        ~msg:"contract events"
        [ "Charged" ]
        (List.map (fun (event : Sol_cli_toml.event_decl) -> event.name) contract.events)
    | Ok _ -> Windtrap.fail "expected exactly one declared contract"
    | Error reason ->
      Windtrap.fail
        ("declared contracts failed to load: " ^ Sol_cli_toml.parse_error_to_string reason))
;;

let test_generate_and_check_drift () =
  with_workspace ~language:"ocaml" ~team:"payments" (fun root ->
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
        (contains "payments_contract.ml" reason))
;;

let test_typescript_generate_and_check_drift () =
  with_workspace ~language:"typescript" ~team:"demo_ts" (fun root ->
    let generated = "app/demo_ts/contract/src/demo_ts_contract.ts" in
    (match Sol_cli_contract_gen.generate ~root ~check:false with
     | Ok [ path ] -> Windtrap.equal Windtrap.string ~msg:"generated path" generated path
     | Ok other ->
       Windtrap.fail
         (Printf.sprintf "expected one generated file, got %d" (List.length other))
     | Error reason -> Windtrap.fail ("generate failed: " ^ reason));
    (match Sol_cli_contract_gen.generate ~root ~check:true with
     | Ok [] -> ()
     | Ok _ -> Windtrap.fail "a freshly generated workspace must not drift"
     | Error reason -> Windtrap.fail ("unexpected drift: " ^ reason));
    write_file (Filename.concat root generated) "stale\n";
    match Sol_cli_contract_gen.generate ~root ~check:true with
    | Ok _ -> Windtrap.fail "an edited TypeScript binding must be reported as drift"
    | Error reason ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"the drift names the TypeScript file"
        true
        (contains "demo_ts_contract.ts" reason))
;;

let%test "contract: an OCaml binding renders its declared fields" =
  test_render_ocaml_binding ()
;;

let%test "contract: a TypeScript binding renders its declared fields" =
  test_render_typescript_binding ()
;;

let%test "contract: the generated destination is predictable per language" =
  test_generated_path ()
;;

let%test "contract: declared contracts carry their binding language" =
  test_discover_contracts ()
;;

let%test "contract: drift between an OCaml declaration and its binding is caught" =
  test_generate_and_check_drift ()
;;

let%test "contract: drift between a TypeScript declaration and its binding is caught" =
  test_typescript_generate_and_check_drift ()
;;
