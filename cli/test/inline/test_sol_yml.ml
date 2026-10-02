let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual
let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual
let read_file path = In_channel.with_open_bin path In_channel.input_all

let write_file path text =
  let oc = open_out_bin path in
  output_string oc text;
  close_out oc
;;

let lines text = String.split_on_char '\n' text

let check_original_preserved ~label ~original ~edited =
  let rec go original edited =
    match original, edited with
    | [], _ -> true
    | line :: rest, [] -> String.equal line "" && go rest []
    | line :: rest, candidate :: more ->
      if String.equal line candidate then go rest more else go original more
  in
  check_bool
    (Printf.sprintf "%s: every original line survives in order" label)
    true
    (go (lines original) (lines edited))
;;

let with_workspace sol_yml f =
  let dir = Filename.temp_file "sol-sol-yml-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let path = Filename.concat dir "sol.yml" in
  write_file path sol_yml;
  Fun.protect
    ~finally:(fun () ->
      (try Unix.chmod dir 0o755 with
       | _ -> ());
      ignore (Sol_cli_fs.remove_tree dir))
    (fun () -> f dir path)
;;

let register ~root ~name ~dir =
  Result.bind
    (Sol_cli_sol_yml.plan ~root ~name ~dir ~language:Sol_cli_compat.Ocaml)
    Sol_cli_sol_yml.commit
;;

let declared ~root =
  match Sol_cli_config.sol_yml_services ~root with
  | Ok services -> services
  | Error e ->
    Windtrap.fail
      ("sol.yml did not parse after the edit: " ^ Sol_cli_config.error_to_string e)
;;

let language_of ~root name =
  declared ~root
  |> List.find_opt (fun (s : Sol_cli_config.service) -> String.equal s.name name)
  |> Option.map (fun (s : Sol_cli_config.service) -> s.language)
;;

let scaffold_sol_yml =
  {|# Sol workspace manifest.
#
# A directory containing this file is a Sol workspace.

resources:
  app_db:
    type: postgres
  events:
    type: kafka
|}
;;

let test_adds_a_section_when_there_is_none () =
  with_workspace scaffold_sol_yml
  @@ fun root path ->
  let dir = "app/payments/charge_svc" in
  (match register ~root ~name:"charge_svc" ~dir with
   | Ok Sol_cli_sol_yml.Declared -> ()
   | Ok _ -> Windtrap.fail "expected a new declaration"
   | Error e -> Windtrap.fail e);
  let edited = read_file path in
  check_original_preserved ~label:"added section" ~original:scaffold_sol_yml ~edited;
  check_bool
    "declares the service"
    true
    (String.length edited > String.length scaffold_sol_yml);
  Windtrap.equal
    (Windtrap.option (Windtrap.option Windtrap.string))
    ~msg:"parsed language"
    (Some (Some "ocaml"))
    (language_of ~root "charge_svc" |> Option.map (Option.map Sol_cli_compat.to_string))
;;

let sol_yml_with_an_entry_and_comments =
  {|project: pluto

resources:
  app_db:
    type: postgres

services:
  # The ledger worker is hand-maintained, with its own settings.
  ledger_worker:
    type: worker
    path: app/comms/ledger_worker
    language: ocaml
    scale:
      min: 2
|}
;;

let test_adds_an_entry_to_an_existing_section () =
  with_workspace sol_yml_with_an_entry_and_comments
  @@ fun root path ->
  (match register ~root ~name:"charge_svc" ~dir:"app/payments/charge_svc" with
   | Ok Sol_cli_sol_yml.Declared -> ()
   | Ok _ -> Windtrap.fail "expected a new declaration"
   | Error e -> Windtrap.fail e);
  let edited = read_file path in
  check_original_preserved
    ~label:"added entry"
    ~original:sol_yml_with_an_entry_and_comments
    ~edited;
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"both services"
    [ "charge_svc"; "ledger_worker" ]
    (List.map (fun (s : Sol_cli_config.service) -> s.name) (declared ~root)
     |> List.sort String.compare);
  Windtrap.equal
    (Windtrap.option Windtrap.int)
    ~msg:"the hand-written scale survives"
    (Some 2)
    (declared ~root
     |> List.find (fun (s : Sol_cli_config.service) ->
       String.equal s.name "ledger_worker")
     |> fun (s : Sol_cli_config.service) -> s.scale_min)
;;

let test_completes_an_entry_that_declares_no_language () =
  let sol_yml =
    {|services:
  charge_svc:
    type: http
    path: app/payments/charge_svc
|}
  in
  with_workspace sol_yml
  @@ fun root path ->
  (match register ~root ~name:"charge_svc" ~dir:"app/payments/charge_svc" with
   | Ok Sol_cli_sol_yml.Language_added -> ()
   | Ok _ -> Windtrap.fail "expected the language to be added to an existing entry"
   | Error e -> Windtrap.fail e);
  let edited = read_file path in
  check_original_preserved ~label:"completed entry" ~original:sol_yml ~edited;
  Windtrap.equal
    (Windtrap.option (Windtrap.option Windtrap.string))
    ~msg:"parsed language"
    (Some (Some "ocaml"))
    (language_of ~root "charge_svc" |> Option.map (Option.map Sol_cli_compat.to_string));
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"the declared path survives"
    (Some "app/payments/charge_svc")
    (declared ~root
     |> List.find (fun (s : Sol_cli_config.service) -> String.equal s.name "charge_svc")
     |> fun (s : Sol_cli_config.service) -> s.path)
;;

let test_registering_twice_writes_nothing () =
  with_workspace scaffold_sol_yml
  @@ fun root path ->
  ignore (register ~root ~name:"charge_svc" ~dir:"app/payments/charge_svc");
  let after_first = read_file path in
  (match register ~root ~name:"charge_svc" ~dir:"app/payments/charge_svc" with
   | Ok Sol_cli_sol_yml.Already_declared -> ()
   | Ok _ -> Windtrap.fail "expected the second registration to be a no-op"
   | Error e -> Windtrap.fail e);
  check_string "the file is untouched" after_first (read_file path)
;;

let test_a_file_without_a_trailing_newline_keeps_its_ending () =
  let sol_yml = "services:\n  ledger_worker:\n    language: ocaml" in
  with_workspace sol_yml
  @@ fun root path ->
  (match register ~root ~name:"charge_svc" ~dir:"app/payments/charge_svc" with
   | Ok _ -> ()
   | Error e -> Windtrap.fail e);
  let edited = read_file path in
  check_original_preserved ~label:"no trailing newline" ~original:sol_yml ~edited;
  check_bool
    "still ends without a newline"
    false
    (String.length edited > 0 && edited.[String.length edited - 1] = '\n')
;;

let test_a_name_that_needs_quoting_is_quoted () =
  with_workspace scaffold_sol_yml
  @@ fun root path ->
  (match register ~root ~name:"true" ~dir:"app/orders/true_svc" with
   | Ok _ -> ()
   | Error e -> Windtrap.fail e);
  let edited = read_file path in
  check_bool "the key is quoted" true (Sol_cli_string.contains ~needle:{|"true":|} edited);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"the name round-trips"
    [ "true" ]
    (List.map (fun (s : Sol_cli_config.service) -> s.name) (declared ~root))
;;

let test_refuses_a_name_declared_at_another_path () =
  let sol_yml =
    "services:\n  charge_svc:\n    path: app/billing/charge_svc\n    language: ocaml\n"
  in
  with_workspace sol_yml
  @@ fun root path ->
  let before = read_file path in
  (match register ~root ~name:"charge_svc" ~dir:"app/payments/charge_svc" with
   | Ok _ -> Windtrap.fail "expected a refusal"
   | Error e ->
     check_bool
       "names the path it is already declared at"
       true
       (Sol_cli_string.contains ~needle:"app/billing/charge_svc" e);
     check_bool "names the file" true (Sol_cli_string.contains ~needle:"sol.yml" e));
  check_string "nothing was written" before (read_file path)
;;

let test_refuses_a_conflicting_language () =
  let sol_yml = "services:\n  charge_svc:\n    language: typescript\n" in
  with_workspace sol_yml
  @@ fun root path ->
  let before = read_file path in
  (match register ~root ~name:"charge_svc" ~dir:"app/payments/charge_svc" with
   | Ok _ -> Windtrap.fail "expected a refusal"
   | Error e ->
     check_bool
       "names the declared language"
       true
       (Sol_cli_string.contains ~needle:"typescript" e));
  check_string "nothing was written" before (read_file path)
;;

let test_refuses_a_sol_yml_it_cannot_parse () =
  let sol_yml = "services:\n  charge_svc:\n    language: rust\n" in
  with_workspace sol_yml
  @@ fun root path ->
  let before = read_file path in
  (match register ~root ~name:"ledger_worker" ~dir:"app/comms/ledger_worker" with
   | Ok _ -> Windtrap.fail "expected a refusal"
   | Error e ->
     check_bool "names the file" true (Sol_cli_string.contains ~needle:"sol.yml" e));
  check_string "nothing was written" before (read_file path)
;;

let test_refuses_a_shape_it_cannot_patch () =
  let sol_yml = "services: { ledger_worker: { language: ocaml } }\n" in
  with_workspace sol_yml
  @@ fun root path ->
  let before = read_file path in
  (match register ~root ~name:"charge_svc" ~dir:"app/payments/charge_svc" with
   | Ok _ -> Windtrap.fail "expected a refusal"
   | Error e ->
     check_bool
       "says what to do instead"
       true
       (Sol_cli_string.contains ~needle:"by hand" e));
  check_string "nothing was written" before (read_file path)
;;

let test_commit_reports_an_unwritable_manifest () =
  with_workspace scaffold_sol_yml
  @@ fun root path ->
  ignore (Unix.chmod path 0o444);
  ignore (Unix.chmod root 0o555);
  Fun.protect
    ~finally:(fun () ->
      ignore (Unix.chmod root 0o755);
      ignore (Unix.chmod path 0o644))
    (fun () ->
       match register ~root ~name:"charge_svc" ~dir:"app/payments/charge_svc" with
       | Ok _ -> Windtrap.fail "expected the write to fail"
       | Error e ->
         check_bool
           "names the manifest"
           true
           (Sol_cli_string.contains ~needle:"sol.yml" e));
  check_string "the original manifest is intact" scaffold_sol_yml (read_file path)
;;

let%test "edits: adds a section when there is none" =
  test_adds_a_section_when_there_is_none ()
;;

let%test "edits: adds an entry to an existing section" =
  test_adds_an_entry_to_an_existing_section ()
;;

let%test "edits: completes an entry that declares no language" =
  test_completes_an_entry_that_declares_no_language ()
;;

let%test "edits: registering twice writes nothing" =
  test_registering_twice_writes_nothing ()
;;

let%test "edits: a file without a trailing newline keeps its ending" =
  test_a_file_without_a_trailing_newline_keeps_its_ending ()
;;

let%test "edits: a name that needs quoting is quoted" =
  test_a_name_that_needs_quoting_is_quoted ()
;;

let%test "refusals: a name declared at another path" =
  test_refuses_a_name_declared_at_another_path ()
;;

let%test "refusals: a conflicting language" = test_refuses_a_conflicting_language ()
let%test "refusals: a sol.yml it cannot parse" = test_refuses_a_sol_yml_it_cannot_parse ()
let%test "refusals: a shape it cannot patch" = test_refuses_a_shape_it_cannot_patch ()

let%test "refusals: an unwritable manifest" =
  test_commit_reports_an_unwritable_manifest ()
;;
