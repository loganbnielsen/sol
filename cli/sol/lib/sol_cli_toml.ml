(* Parser for sol.toml (otoml-backed, TOML 1.0.0). Unknown keys/sections are
   forward-compatible; malformed TOML raises Parse_error. *)

type rollout_strategy = Recreate | RollingUpdate
type canary_step = Weight of int | Pause of int option

type progressive_delivery =
  | Canary of { steps : canary_step list }
  | Blue_green

type cpu_quantity = Cpu_quantity of string
type memory_quantity = Memory_quantity of string
type hostname = Hostname of string
type ingress_path = Ingress_path of string
type volume_access_mode = ReadWriteOnce | ReadOnlyMany | ReadWriteMany

type volume = {
  name : string;
  mount_path : string;
  size : string;
  access_mode : volume_access_mode;
}

let cpu_quantity_to_string (Cpu_quantity s) = s
let memory_quantity_to_string (Memory_quantity s) = s
let hostname_to_string (Hostname s) = s
let ingress_path_to_string (Ingress_path s) = s

let volume_access_mode_to_string = function
  | ReadWriteOnce -> "ReadWriteOnce"
  | ReadOnlyMany -> "ReadOnlyMany"
  | ReadWriteMany -> "ReadWriteMany"

type t = {
  replicas : int option;
  cpu : cpu_quantity option;
  memory : memory_quantity option;
  env_config : (string * string) list;
  secret_keys : string list;
  volumes : volume list;
  rollout_strategy : rollout_strategy option;
  ingress_host : hostname option;
  ingress_path : ingress_path option;
  extra_labels : (string * string) list;
  progressive_delivery : progressive_delivery option;
  schedule : string option;
  topics : string list;
}

let empty =
  {
    replicas = None;
    cpu = None;
    memory = None;
    env_config = [];
    secret_keys = [];
    volumes = [];
    rollout_strategy = None;
    ingress_host = None;
    ingress_path = None;
    extra_labels = [];
    progressive_delivery = None;
    schedule = None;
    topics = [];
  }

type parse_error =
  | Toml_syntax of { path : string; message : string }
  | Validation of { path : string; message : string }

let parse_error_to_string = function
  | Toml_syntax { path; message } | Validation { path; message } ->
      Printf.sprintf "%s: %s" path message

let validation_error path message = Error (Validation { path; message })
let ( let* ) = Result.bind

(* ── Validation ──────────────────────────────────────────────────────────── *)

let is_digit c = c >= '0' && c <= '9'
let is_lower_alnum c = (c >= 'a' && c <= 'z') || is_digit c

let split_on_dot s =
  let rec loop acc start i =
    if i = String.length s then List.rev (String.sub s start (i - start) :: acc)
    else if s.[i] = '.' then
      loop (String.sub s start (i - start) :: acc) (i + 1) (i + 1)
    else loop acc start (i + 1)
  in
  loop [] 0 0

let has_decimal_digits s =
  let len = String.length s in
  let digits start stop =
    let rec loop i =
      if i = stop then true else if is_digit s.[i] then loop (i + 1) else false
    in
    start < stop && loop start
  in
  match String.index_opt s '.' with
  | None -> digits 0 len
  | Some dot ->
      (digits 0 dot || digits (dot + 1) len)
      &&
      let rec loop i =
        if i = len then true
        else if i = dot || is_digit s.[i] then loop (i + 1)
        else false
      in
      loop 0

let cpu_quantity_of_string s =
  let len = String.length s in
  if len = 0 then Error "sol.toml: [infra.scale] cpu quantity must not be empty"
  else
    let valid =
      if len > 1 && s.[len - 1] = 'm' then
        let millicores = String.sub s 0 (len - 1) in
        has_decimal_digits millicores && not (String.contains millicores '.')
      else has_decimal_digits s
    in
    if valid then Ok (Cpu_quantity s)
    else
      Error
        (Printf.sprintf
           "sol.toml: [infra.scale] cpu quantity %S is invalid — use cores \
            like \"1\" or \"0.5\", or millicores like \"250m\""
           s)

let memory_suffixes =
  [ ""; "Ki"; "Mi"; "Gi"; "Ti"; "Pi"; "Ei"; "k"; "K"; "M"; "G"; "T"; "P"; "E" ]

let memory_quantity_of_string s =
  let len = String.length s in
  if len = 0 then
    Error "sol.toml: [infra.scale] memory quantity must not be empty"
  else
    let suffix =
      List.find_opt
        (fun suffix ->
          let slen = String.length suffix in
          slen <= len && String.sub s (len - slen) slen = suffix)
        (List.sort
           (fun a b -> compare (String.length b) (String.length a))
           memory_suffixes)
    in
    match suffix with
    | None ->
        Error
          (Printf.sprintf
             "sol.toml: [infra.scale] memory quantity %S is invalid — use \
              bytes or memory suffixes like \"128Mi\" or \"1Gi\""
             s)
    | Some suffix ->
        let number = String.sub s 0 (len - String.length suffix) in
        if has_decimal_digits number then Ok (Memory_quantity s)
        else
          Error
            (Printf.sprintf
               "sol.toml: [infra.scale] memory quantity %S is invalid — use \
                bytes or memory suffixes like \"128Mi\" or \"1Gi\""
               s)

let validate_hostname_label label =
  let len = String.length label in
  len > 0 && len <= 63
  && is_lower_alnum label.[0]
  && is_lower_alnum label.[len - 1]
  &&
  let rec loop i =
    if i = len then true
    else
      let c = label.[i] in
      (is_lower_alnum c || c = '-') && loop (i + 1)
  in
  loop 0

let hostname_of_string s =
  let len = String.length s in
  if len = 0 || len > 253 then
    Error "sol.toml: [infra.deploy] ingress_host must be a DNS hostname"
  else if String.contains s '*' then
    Error
      (Printf.sprintf
         "sol.toml: [infra.deploy] ingress_host %S is invalid — wildcard hosts \
          are not supported"
         s)
  else if List.for_all validate_hostname_label (split_on_dot s) then
    Ok (Hostname s)
  else
    Error
      (Printf.sprintf
         "sol.toml: [infra.deploy] ingress_host %S is invalid — use a DNS \
          hostname like \"api.example.com\""
         s)

let ingress_path_of_string s =
  let len = String.length s in
  let rec has_invalid_char i =
    if i = len then false
    else
      match s.[i] with
      | '\000' .. '\032' | '\127' -> true
      | _ -> has_invalid_char (i + 1)
  in
  if len = 0 || s.[0] <> '/' then
    Error
      (Printf.sprintf
         "sol.toml: [infra.deploy] ingress_path %S is invalid — paths must \
          start with \"/\""
         s)
  else if has_invalid_char 0 then
    Error
      (Printf.sprintf
         "sol.toml: [infra.deploy] ingress_path %S is invalid — paths must not \
          contain whitespace or control characters"
         s)
  else Ok (Ingress_path s)

let parse_rollout_strategy path s =
  match s with
  | "Recreate" -> Ok Recreate
  | "RollingUpdate" -> Ok RollingUpdate
  | other ->
      validation_error path
        (Printf.sprintf
           "sol.toml: unsupported rollout_strategy %S — valid values are \
            \"Recreate\" and \"RollingUpdate\""
           other)

let validate_opt path parse = function
  | None -> Ok None
  | Some s ->
      parse s
      |> Result.map (fun v -> Some v)
      |> Result.map_error (fun message -> Validation { path; message })

(* ── [infra.volumes.<name>] ─────────────────────────────────────────────── *)

let parse_volume_access_mode path ~volume_name = function
  | "ReadWriteOnce" -> Ok ReadWriteOnce
  | "ReadOnlyMany" -> Ok ReadOnlyMany
  | "ReadWriteMany" -> Ok ReadWriteMany
  | other ->
      validation_error path
        (Printf.sprintf
           "sol.toml: [infra.volumes.%s] access_mode %S is invalid — valid \
            values are \"ReadWriteOnce\", \"ReadOnlyMany\", and \
            \"ReadWriteMany\""
           volume_name other)

let volume_string_field path ~volume_name ~field fields =
  match List.assoc_opt field fields with
  | None ->
      validation_error path
        (Printf.sprintf "sol.toml: [infra.volumes.%s] missing required %s"
           volume_name field)
  | Some v -> (
      try Ok (Otoml.get_string v)
      with Otoml.Type_error _ ->
        validation_error path
          (Printf.sprintf "sol.toml: [infra.volumes.%s] %s must be a string"
             volume_name field))

let parse_volume path (name, value) =
  let* fields =
    try Otoml.get_table value |> Result.ok
    with Otoml.Type_error _ ->
      validation_error path
        (Printf.sprintf "sol.toml: [infra.volumes.%s] must be a table" name)
  in
  let* mount_path =
    volume_string_field path ~volume_name:name ~field:"mount_path" fields
  in
  let* size = volume_string_field path ~volume_name:name ~field:"size" fields in
  let* access_mode =
    match List.assoc_opt "access_mode" fields with
    | None -> Ok ReadWriteOnce
    | Some v -> (
        try parse_volume_access_mode path ~volume_name:name (Otoml.get_string v)
        with Otoml.Type_error _ ->
          validation_error path
            (Printf.sprintf
               "sol.toml: [infra.volumes.%s] access_mode must be a string" name)
        )
  in
  if not (validate_hostname_label name) then
    validation_error path
      (Printf.sprintf
         "sol.toml: [infra.volumes.%s] name is invalid — use lowercase \
          letters, digits, and hyphens"
         name)
  else if String.length mount_path = 0 || mount_path.[0] <> '/' then
    validation_error path
      (Printf.sprintf
         "sol.toml: [infra.volumes.%s] mount_path must be an absolute path" name)
  else if String.trim size = "" then
    validation_error path
      (Printf.sprintf "sol.toml: [infra.volumes.%s] size must not be empty" name)
  else Ok { name; mount_path; size; access_mode }

let parse_volumes path doc =
  match Otoml.find_opt doc Otoml.get_value [ "infra"; "volumes" ] with
  | None -> Ok []
  | Some v ->
      let* entries =
        try Otoml.get_table v |> Result.ok
        with Otoml.Type_error _ ->
          validation_error path
            "sol.toml: [infra.volumes] must be a table of tables, e.g. \
             [infra.volumes.data]"
      in
      List.fold_left
        (fun acc entry ->
          let* acc = acc in
          let* volume = parse_volume path entry in
          Ok (volume :: acc))
        (Ok []) entries
      |> Result.map List.rev

(* Guard: keys starting with "sol.dev/" are reserved for Sol internals. *)
let validate_extra_label_key k =
  let prefix = "sol.dev/" in
  if String.starts_with ~prefix k then
    Error
      (Printf.sprintf
         "sol.toml: extra_labels key %S is reserved — keys may not start with \
          \"sol.dev/\""
         k)
  else Ok ()

let validate_weight n =
  if n < 0 || n > 100 then
    Error
      (Printf.sprintf
         "sol.toml: [infra.rollout] canary weight %d is invalid — weights must \
          be between 0 and 100"
         n)
  else Ok ()

let validate_duration d =
  if d <= 0 then
    Error
      (Printf.sprintf
         "sol.toml: [infra.rollout] pause duration %d is invalid — durations \
          must be positive seconds"
         d)
  else Ok ()

let validate_canary_step = function
  | Weight n -> validate_weight n
  | Pause None -> Ok ()
  | Pause (Some d) -> validate_duration d

(* ── Canary step parsing ─────────────────────────────────────────────────── *)

(* Parse a single step TOML value (an inline table).
   Accepts: {weight = 10}, {pause = {}}, {pause = {duration = 60}}.
   The weight-only shorthand [10, 40, 100] is handled at the array level below. *)
let parse_canary_step_value path v =
  let* pairs =
    try Otoml.get_table v |> Result.ok
    with Otoml.Type_error _ ->
      validation_error path
        "sol.toml: [infra.rollout] canary step must be an inline table like \
         {weight = 10} or {pause = {}}"
  in
  match List.assoc_opt "weight" pairs with
  | Some wv ->
      let* n =
        try Otoml.get_integer wv |> Result.ok
        with Otoml.Type_error _ ->
          validation_error path
            "sol.toml: [infra.rollout] canary weight must be an integer"
      in
      let step = Weight n in
      let* () =
        validate_canary_step step
        |> Result.map_error (fun message -> Validation { path; message })
      in
      Ok step
  | None -> (
      match List.assoc_opt "pause" pairs with
      | Some pv ->
          let* inner =
            try Otoml.get_table pv |> Result.ok
            with Otoml.Type_error _ ->
              validation_error path
                "sol.toml: [infra.rollout] pause value must be an inline table \
                 like {} or {duration = 60}"
          in
          let* step =
            match List.assoc_opt "duration" inner with
            | Some dv ->
                let* d =
                  try Otoml.get_integer dv |> Result.ok
                  with Otoml.Type_error _ ->
                    validation_error path
                      "sol.toml: [infra.rollout] pause duration must be an \
                       integer"
                in
                Ok (Pause (Some d))
            | None -> Ok (Pause None)
          in
          let* () =
            validate_canary_step step
            |> Result.map_error (fun message -> Validation { path; message })
          in
          Ok step
      | None ->
          validation_error path
            "sol.toml: unsupported [infra.rollout] canary step — expected \
             {weight = N} or {pause = {...}}")

(* Parse the steps array. Supports:
   - Integer shorthand: steps = [10, 40, 100]  (each int → Weight n)
   - Table steps: steps = [{weight = 10}, {pause = {}}, ...]
   Mixed arrays (some ints, some tables) are rejected by the TOML parser. *)
let parse_steps path doc =
  match Otoml.find_opt doc Otoml.get_value [ "infra"; "rollout"; "steps" ] with
  | None -> Ok []
  | Some arr_v ->
      let* items =
        try Otoml.get_array Otoml.get_value arr_v |> Result.ok
        with Otoml.Type_error _ ->
          validation_error path
            "sol.toml: [infra.rollout] steps must be an array"
      in
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | item :: rest -> (
            match item with
            | Otoml.TomlInteger n ->
                let step = Weight n in
                let* () =
                  validate_canary_step step
                  |> Result.map_error (fun message ->
                      Validation { path; message })
                in
                loop (step :: acc) rest
            | _ ->
                let* step = parse_canary_step_value path item in
                loop (step :: acc) rest)
      in
      loop [] items

(* ── Loader ──────────────────────────────────────────────────────────────── *)

let load_result path =
  try
    if not (Sys.file_exists path) then Ok empty
    else begin
      let* doc =
        match Otoml.Parser.from_file_result path with
        | Ok d -> Ok d
        | Error msg ->
            Error
              (Toml_syntax { path; message = Printf.sprintf "sol.toml: %s" msg })
      in

      (* [infra.scale] *)
      let replicas =
        Otoml.Helpers.find_integer_opt doc [ "infra"; "scale"; "replicas" ]
      in
      let* cpu =
        Otoml.Helpers.find_string_opt doc [ "infra"; "scale"; "cpu" ]
        |> validate_opt path cpu_quantity_of_string
      in
      let* memory =
        Otoml.Helpers.find_string_opt doc [ "infra"; "scale"; "memory" ]
        |> validate_opt path memory_quantity_of_string
      in

      (* [infra.env] *)
      let* env_config =
        match
          Otoml.find_opt doc Otoml.get_value [ "infra"; "env"; "config" ]
        with
        | None -> Ok []
        | Some v -> (
            try Otoml.get_table_values Otoml.get_string v |> Result.ok
            with Otoml.Type_error _ ->
              validation_error path
                "sol.toml: [infra.env] config must be an inline table of \
                 string values, e.g. config = { KEY = \"val\" }")
      in
      let* secret_keys =
        match
          Otoml.find_opt doc Otoml.get_value [ "infra"; "env"; "secrets" ]
        with
        | None -> Ok []
        | Some v -> (
            try Otoml.get_array Otoml.get_string v |> Result.ok
            with Otoml.Type_error _ ->
              validation_error path
                "sol.toml: [infra.env] secrets must be an array of strings, \
                 e.g. secrets = [\"KEY1\", \"KEY2\"]")
      in

      (* [infra.volumes.<name>] *)
      let* volumes = parse_volumes path doc in

      (* [infra.deploy] *)
      let* rollout_strategy =
        match
          Otoml.Helpers.find_string_opt doc
            [ "infra"; "deploy"; "rollout_strategy" ]
        with
        | None -> Ok None
        | Some s ->
            let* strategy = parse_rollout_strategy path s in
            Ok (Some strategy)
      in
      let* ingress_host =
        Otoml.Helpers.find_string_opt doc [ "infra"; "deploy"; "ingress_host" ]
        |> validate_opt path hostname_of_string
      in
      let* ingress_path =
        Otoml.Helpers.find_string_opt doc [ "infra"; "deploy"; "ingress_path" ]
        |> validate_opt path ingress_path_of_string
      in

      (* [infra.labels] *)
      let* extra_labels =
        match
          Otoml.find_opt doc Otoml.get_value
            [ "infra"; "labels"; "extra_labels" ]
        with
        | None -> Ok []
        | Some v ->
            let* pairs =
              try Otoml.get_table_values Otoml.get_string v |> Result.ok
              with Otoml.Type_error _ ->
                validation_error path
                  "sol.toml: [infra.labels] extra_labels must be an inline \
                   table of string values, e.g. extra_labels = { key = \"val\" \
                   }"
            in
            let rec validate_keys = function
              | [] -> Ok pairs
              | (k, _) :: rest ->
                  let* () =
                    validate_extra_label_key k
                    |> Result.map_error (fun message ->
                        Validation { path; message })
                  in
                  validate_keys rest
            in
            validate_keys pairs
      in

      (* [infra.rollout] — progressive delivery *)
      let* progressive_delivery =
        match
          Otoml.Helpers.find_string_opt doc [ "infra"; "rollout"; "strategy" ]
        with
        | None -> Ok None
        | Some "canary" ->
            let* steps = parse_steps path doc in
            if steps = [] then
              validation_error path
                "sol.toml: [infra.rollout] strategy \"canary\" requires at \
                 least one step in steps = [...]"
            else Ok (Some (Canary { steps }))
        | Some "blue-green" -> Ok (Some Blue_green)
        | Some other ->
            validation_error path
              (Printf.sprintf
                 "sol.toml: unsupported [infra.rollout] strategy %S — valid \
                  values are \"canary\" and \"blue-green\""
                 other)
      in

      (* [service] *)
      let schedule =
        Otoml.Helpers.find_string_opt doc [ "service"; "schedule" ]
      in
      let* topics =
        match Otoml.find_opt doc Otoml.get_value [ "service"; "topics" ] with
        | None -> Ok []
        | Some v -> (
            try Otoml.get_array Otoml.get_string v |> Result.ok
            with Otoml.Type_error _ ->
              validation_error path
                "sol.toml: [service] topics must be an array of strings, e.g. \
                 topics = [\"my-topic\"]")
      in

      Ok
        {
          replicas;
          cpu;
          memory;
          env_config;
          secret_keys;
          volumes;
          rollout_strategy;
          ingress_host;
          ingress_path;
          extra_labels;
          progressive_delivery;
          schedule;
          topics;
        }
    end
  with Otoml.Type_error message -> Error (Validation { path; message })

let load path =
  match load_result path with
  | Ok t -> t
  | Error err -> failwith (parse_error_to_string err)
