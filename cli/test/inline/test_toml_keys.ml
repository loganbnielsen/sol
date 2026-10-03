let load contents =
  let path = Filename.temp_file "sol-toml-keys-" ".toml" in
  let oc = open_out path in
  output_string oc contents;
  close_out oc;
  let result = Sol_cli_toml.load_result path in
  Sys.remove path;
  result
;;

let tpl ~kind rel =
  match Sol_cli_platform_assets.resolve () with
  | Error error ->
    Windtrap.fail
      ("no scaffold templates: " ^ Sol_cli_platform_assets.error_to_string error)
  | Ok assets ->
    (match
       Sol_cli_scaffold_tree.text
         ~root:(Sol_cli_platform_assets.templates_root assets)
         ~kind
         ~rel
     with
     | Ok text -> text
     | Error message -> Windtrap.fail message)
;;

let rejects contents ~names () =
  match load contents with
  | Ok _ -> Windtrap.failf "expected %S to be rejected" contents
  | Error (Sol_cli_toml.Validation { message; _ }) ->
    names
    |> List.iter (fun needle ->
      Windtrap.equal
        Windtrap.bool
        ~msg:("error names " ^ needle)
        true
        (Sol_cli_string.contains ~needle message))
  | Error (Sol_cli_toml.Toml_syntax _) -> Windtrap.fail "expected a validation error"
;;

let accepts contents () =
  match load contents with
  | Ok _ -> ()
  | Error e -> Windtrap.fail (Sol_cli_toml.parse_error_to_string e)
;;

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

let%test "a value that cannot reach a manifest (REFAC-131): NUL in a config value" =
  rejects
    "[infra.env]\nconfig = { NOTE = \"a\\u0000b\" }\n"
    ~names:[ "infra.env.config.NOTE"; "NUL" ]
    ()
;;

let%test "unknown keys are errors: misspelled key" =
  rejects
    "[infra.scale]\nreplica = 3\n"
    ~names:[ "\"replica\""; "[infra.scale]"; "replicas" ]
    ()
;;

let%test "unknown keys are errors: misspelled table" =
  rejects "[infra.sacle]\nreplicas = 3\n" ~names:[ "\"sacle\"" ] ()
;;

let%test "unknown keys are errors: misspelled rollout table" =
  rejects "[infra.rolout]\nstrategy = \"blue-green\"\n" ~names:[ "\"rolout\"" ] ()
;;

let%test "unknown keys are errors: misspelled top-level table" =
  rejects
    "[servce]\nschedule = \"0 3 * * *\"\n"
    ~names:[ "\"servce\""; "the top level" ]
    ()
;;

let%test "unknown keys are errors: misspelled schedule key" =
  rejects "[service]\nschedul = \"0 3 * * *\"\n" ~names:[ "\"schedul\"" ] ()
;;

let%test "unknown keys are errors: unknown volume field" =
  rejects
    "[infra.volumes.data]\nmountpath = \"/d\"\nsize = \"1Gi\"\n"
    ~names:[ "\"mountpath\""; "[infra.volumes.data]" ]
    ()
;;

let%test "unknown keys are errors: unknown canary step key" =
  rejects
    "[infra.rollout]\nstrategy = \"canary\"\nsteps = [{wieght = 10}]\n"
    ~names:[ "\"wieght\"" ]
    ()
;;

let%test "unknown keys are errors: unknown pause key" =
  rejects
    "[infra.rollout]\nstrategy = \"canary\"\nsteps = [{pause = {duraton = 5}}]\n"
    ~names:[ "\"duraton\"" ]
    ()
;;

let%test "documented and generated files still load: every documented key" =
  accepts every_documented_key ()
;;

let%test "documented and generated files still load: empty file" = accepts "" ()

let%test "documented and generated files still load: scaffold sol.toml" =
  accepts (tpl ~kind:"svc" "sol.toml") ()
;;

let%test "documented and generated files still load: scaffold -fn sol.toml" =
  accepts (tpl ~kind:"fn" "sol.toml") ()
;;

let%test "documented and generated files still load: scaffold event sol.toml" =
  accepts
    (Sol_cli_scaffold.subst
       [ "team", "payments"; "name", "charged"; "Mod", "Charged"; "Team", "Payments" ]
       (tpl ~kind:"event" "events/{{team}}/sol.toml"))
    ()
;;

let event_toml body = Printf.sprintf "[[events]]\n%s" body

let%test "declared events: a key outside the schema is rejected" =
  rejects
    (event_toml
       "name = \"Charged\"\n\
        topic = \"t\"\n\
        partitions = 3\n\
        key = \"missing\"\n\
        schema = '{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}}}'\n")
    ~names:[ "\"missing\"" ]
    ()
;;

let%test "declared events: a name that is not a module name is rejected" =
  rejects
    (event_toml
       "name = \"charged\"\n\
        topic = \"t\"\n\
        partitions = 3\n\
        schema = '{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}}}'\n")
    ~names:[ "\"charged\"" ]
    ()
;;

let%test "declared events: a partition count below one is rejected" =
  rejects
    (event_toml
       "name = \"Charged\"\n\
        topic = \"t\"\n\
        partitions = 0\n\
        schema = '{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}}}'\n")
    ~names:[ "partitions" ]
    ()
;;

let%test "declared events: the same name twice is rejected" =
  rejects
    (event_toml
       "name = \"Charged\"\n\
        topic = \"a\"\n\
        partitions = 1\n\
        schema = '{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}}}'\n\n\
        [[events]]\n\
        name = \"Charged\"\n\
        topic = \"b\"\n\
        partitions = 1\n\
        schema = '{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}}}'\n")
    ~names:[ "twice" ]
    ()
;;
