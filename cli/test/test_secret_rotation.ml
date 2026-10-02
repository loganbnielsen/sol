let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc
;;

let read_file path =
  try In_channel.with_open_text path In_channel.input_all with
  | Sys_error _ -> ""
;;

let no_resource_type kind =
  Printf.sprintf "error: the server doesn't have a resource type \"%s\"" kind
;;

let stub_script ~log ~manifest =
  String.concat
    "\n"
    [ "#!/bin/sh"
    ; Printf.sprintf "printf '%%s\\n' \"$*\" >> %s" log
    ; "ns=\"\""
    ; "prev=\"\""
    ; "for a in \"$@\"; do"
    ; "  if [ \"$prev\" = \"-n\" ]; then ns=\"$a\"; fi"
    ; "  prev=\"$a\""
    ; "done"
    ; "case \"$*\" in"
    ; "  *externalsecrets*)"
    ; Printf.sprintf "    target=$(grep \"^$ns:\" %s | head -1 | cut -d: -f2)" manifest
    ; "    if [ -n \"$target\" ]; then printf 'eso-%s\\t%s\\n' \"$ns\" \"$target\"; exit \
       0; fi"
    ; Printf.sprintf
        "    echo %s >&2"
        (Filename.quote (no_resource_type "externalsecrets"))
    ; "    exit 1 ;;"
    ; "esac"
    ; "case \"$*\" in"
    ; "  *\"get secrets \"*)"
    ; Printf.sprintf
        "    printf '%%s\\n' \"$(grep \"^$ns:\" %s | head -1 | cut -d: -f3)\""
        manifest
    ; "    exit 0 ;;"
    ; "  *\"get secret \"*)"
    ; "    printf \
       '{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"name\":\"live\",\"namespace\":\"%s\"},\"type\":\"Opaque\",\"data\":{\"API_TOKEN\":\"b2xk\"},\"stringData\":{}}\\n' \
       \"$ns\""
    ; "    exit 0 ;;"
    ; "  *\"get deployment \"*)"
    ; "    printf 'deployment/%s-svc\\n' \"$ns\""
    ; "    exit 0 ;;"
    ; "  *\"get rollout \"*)"
    ; Printf.sprintf "    echo %s >&2" (Filename.quote (no_resource_type "rollout"))
    ; "    exit 1 ;;"
    ; "esac"
    ; "exit 0"
    ; ""
    ]
;;

let with_stub_kubectl ~manifest_lines f =
  let dir = Filename.temp_file "sol-fake-kubectl-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let log = Filename.concat dir "calls.log" in
  let manifest = Filename.concat dir "manifest" in
  write_file manifest (String.concat "\n" manifest_lines ^ "\n");
  let bin = Filename.concat dir "kubectl" in
  write_file bin (stub_script ~log ~manifest);
  Unix.chmod bin 0o755;
  let old_path =
    try Sys.getenv "PATH" with
    | Not_found -> ""
  in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      List.iter
        (fun path ->
           try Sys.remove path with
           | Sys_error _ -> ())
        [ bin; manifest; log ];
      try Unix.rmdir dir with
      | Unix.Unix_error _ -> ())
    (fun () -> f ~calls:(fun () -> read_file log))
;;

let ctx = Sol_cli_kube_destination.local_context
let managed = "payments:payment-svc-secrets:payment-svc-secrets"
let live = "orders::orders-svc-secrets"

let call_lines calls =
  String.split_on_char '\n' calls |> List.filter (fun line -> String.trim line <> "")
;;

let made calls needle =
  List.exists (fun line -> Sol_cli_string.contains ~needle line) (call_lines calls)
;;

let test_mixed_selection_is_refused_before_any_write () =
  with_stub_kubectl ~manifest_lines:[ managed; live ] (fun ~calls ->
    (match
       Sol_cli_secret.set
         ~ctx
         ~workspace:"ws"
         ~namespaces:[ "payments"; "orders" ]
         ~key:"API_TOKEN"
         ~value:"rotated"
     with
     | Ok _ ->
       Alcotest.failf
         "a selection containing an ExternalSecret target was rotated; kubectl calls: %s"
         (calls ())
     | Error message ->
       Alcotest.(check bool)
         "names the managed target"
         true
         (Sol_cli_string.contains ~needle:"payment-svc-secrets" message);
       Alcotest.(check bool)
         "names the namespace"
         true
         (Sol_cli_string.contains ~needle:"payments" message);
       Alcotest.(check bool)
         "names the provider-side path"
         true
         (Sol_cli_string.contains ~needle:"provider store" message));
    Alcotest.(check bool) "no Secret was written" false (made (calls ()) "apply -f");
    Alcotest.(check bool)
      "no workload was restarted"
      false
      (made (calls ()) "rollout restart"))
;;

let test_delete_refuses_the_same_selection () =
  with_stub_kubectl ~manifest_lines:[ managed; live ] (fun ~calls ->
    (match
       Sol_cli_secret.delete
         ~ctx
         ~workspace:"ws"
         ~namespaces:[ "payments" ]
         ~key:"API_TOKEN"
     with
     | Ok _ -> Alcotest.fail "an ExternalSecret-managed target was deleted directly"
     | Error message ->
       Alcotest.(check bool)
         "names the managed target"
         true
         (Sol_cli_string.contains ~needle:"payment-svc-secrets" message));
    Alcotest.(check bool) "no Secret was patched" false (made (calls ()) "patch secret"))
;;

let test_live_selection_still_rotates () =
  with_stub_kubectl ~manifest_lines:[ managed; live ] (fun ~calls ->
    (match
       Sol_cli_secret.set
         ~ctx
         ~workspace:"ws"
         ~namespaces:[ "orders" ]
         ~key:"API_TOKEN"
         ~value:"rotated"
     with
     | Error message -> Alcotest.failf "a Kubernetes-live Secret was refused: %s" message
     | Ok (Sol_cli_secret.Applied namespaces) ->
       Alcotest.(check (list string)) "rotated namespace" [ "orders" ] namespaces
     | Ok _ -> Alcotest.fail "unexpected result");
    Alcotest.(check bool) "the Secret was written" true (made (calls ()) "apply -f");
    Alcotest.(check bool)
      "the workload was restarted"
      true
      (made (calls ()) "rollout restart"))
;;

let () =
  Alcotest.run
    "secret rotation"
    [ ( "external secret ownership"
      , [ Alcotest.test_case
            "a mixed selection is refused before any write"
            `Quick
            test_mixed_selection_is_refused_before_any_write
        ; Alcotest.test_case
            "delete refuses the same selection"
            `Quick
            test_delete_refuses_the_same_selection
        ; Alcotest.test_case
            "a Kubernetes-live Secret still rotates"
            `Quick
            test_live_selection_still_rotates
        ] )
    ]
;;
