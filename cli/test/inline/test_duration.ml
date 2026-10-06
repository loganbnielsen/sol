let name = "SOL_TEST_DURATION_OVERRIDE"

let with_value value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some previous -> Unix.putenv name previous
      | None -> Unix.putenv name "")
    f
;;

let parse ?(default = 900.) value =
  with_value value (fun () -> Sol_cli_duration.env_seconds ~name ~default)
;;

let result = Windtrap.result (Windtrap.float 0.) Windtrap.string

let test_omitted_uses_the_default () =
  Windtrap.equal result ~msg:"blank follows the unset policy" (Ok 900.) (parse "")
;;

let test_valid_values_are_kept () =
  Windtrap.equal result ~msg:"zero is a supported value" (Ok 0.) (parse "0");
  Windtrap.equal result ~msg:"a finite value is kept" (Ok 12.5) (parse "12.5");
  Windtrap.equal result ~msg:"the default is the caller's" (Ok 3.) (parse ~default:3. "3")
;;

let test_invalid_values_are_refused () =
  List.iter
    (fun raw ->
       match parse raw with
       | Ok seconds ->
         Windtrap.fail (Printf.sprintf "%S was accepted as %f seconds" raw seconds)
       | Error message ->
         Windtrap.equal
           Windtrap.bool
           ~msg:(Printf.sprintf "%S refusal names the setting" raw)
           true
           (Sol_cli_string.contains ~needle:name message))
    [ "abc"; "-1"; "nan"; "inf"; "infinity" ]
;;

let%test "duration override: omitted uses the default" = test_omitted_uses_the_default ()
let%test "duration override: valid values are kept" = test_valid_values_are_kept ()

let%test "duration override: invalid values are refused" =
  test_invalid_values_are_refused ()
;;
