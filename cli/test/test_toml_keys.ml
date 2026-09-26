(* BUG-042 / FND-0033: a misspelled sol.toml key or table used to load as if it had
   not been written, so the setting silently took its default. Unknown keys and
   tables are now errors that name the key; everything Sol documents still loads. *)

let load contents =
  let path = Filename.temp_file "sol-toml-keys-" ".toml" in
  let oc = open_out path in
  output_string oc contents;
  close_out oc;
  let result = Sol_cli_toml.load_result path in
  Sys.remove path;
  result
;;

let rejects name contents ~names =
  Alcotest.test_case name `Quick (fun () ->
    match load contents with
    | Ok _ -> Alcotest.failf "expected %S to be rejected" contents
    | Error (Sol_cli_toml.Validation { message; _ }) ->
      List.iter
        (fun needle ->
           Alcotest.(check bool)
             ("error names " ^ needle)
             true
             (Sol_cli_string.contains ~needle message))
        names
    | Error (Sol_cli_toml.Toml_syntax _) -> Alcotest.fail "expected a validation error")
;;

let accepts name contents =
  Alcotest.test_case name `Quick (fun () ->
    match load contents with
    | Ok _ -> ()
    | Error e -> Alcotest.fail (Sol_cli_toml.parse_error_to_string e))
;;

(* Every key the docs show (escape-hatches.md, workload-availability.md, sol-fn.md,
   TUTORIAL.md) in one document. *)
let every_documented_key =
  {|[infra.scale]
replicas = 3
availability = "node-failure-tolerant"
cpu = "500m"
memory = "512Mi"

[infra.env]
config = { APP_ENV = "production", ANY_NAME_AT_ALL = "x" }
secrets = ["DB_PASSWORD"]

[infra.volumes.data]
mount_path = "/var/lib/data"
size = "10Gi"
access_mode = "ReadWriteOnce"

[infra.deploy]
rollout_strategy = "Recreate"
ingress_host = "payments.example.com"
ingress_path = "/api"

[infra.labels]
extra_labels = { team = "payments", cost-center = "billing" }

[infra.rollout]
strategy = "canary"
steps = [{weight = 10}, {pause = {duration = 300}}, {weight = 50}, {pause = {}}, {weight = 100}]

[service]
schedule = "0 3 * * *"
scheduled_concurrency = "forbid"
backoff_limit = 3
calls = ["checkout/checkout_svc"]
topics = ["payments-charges"]
|}
;;

let () =
  Alcotest.run
    "toml_keys"
    [ ( "unknown keys are errors"
      , [ rejects
            "misspelled key"
            "[infra.scale]\nreplica = 3\n"
            ~names:[ "\"replica\""; "[infra.scale]"; "replicas" ]
        ; rejects
            "misspelled table"
            "[infra.sacle]\nreplicas = 3\n"
            ~names:[ "\"sacle\"" ]
        ; rejects
            "misspelled rollout table"
            "[infra.rolout]\nstrategy = \"blue-green\"\n"
            ~names:[ "\"rolout\"" ]
        ; rejects
            "misspelled top-level table"
            "[servce]\nschedule = \"0 3 * * *\"\n"
            ~names:[ "\"servce\""; "the top level" ]
        ; rejects
            "misspelled schedule key"
            "[service]\nschedul = \"0 3 * * *\"\n"
            ~names:[ "\"schedul\"" ]
        ; rejects
            "unknown volume field"
            "[infra.volumes.data]\nmountpath = \"/d\"\nsize = \"1Gi\"\n"
            ~names:[ "\"mountpath\""; "[infra.volumes.data]" ]
        ; rejects
            "unknown canary step key"
            "[infra.rollout]\nstrategy = \"canary\"\nsteps = [{wieght = 10}]\n"
            ~names:[ "\"wieght\"" ]
        ; rejects
            "unknown pause key"
            "[infra.rollout]\nstrategy = \"canary\"\nsteps = [{pause = {duraton = 5}}]\n"
            ~names:[ "\"duraton\"" ]
        ] )
    ; ( "documented and generated files still load"
      , [ accepts "every documented key" every_documented_key
        ; accepts "empty file" ""
        ; accepts "scaffold sol.toml" Sol_cli_scaffold_templates.tpl_sol_toml
        ; accepts "scaffold -fn sol.toml" Sol_cli_scaffold_templates.tpl_fn_sol_toml
        ; accepts "scaffold event sol.toml" Sol_cli_scaffold_templates.tpl_event_sol_toml
        ] )
    ]
;;
