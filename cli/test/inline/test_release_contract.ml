let matches_regex re s =
  try
    ignore (Str.search_forward re s 0);
    true
  with
  | Not_found -> false
;;

let with_fake_kubectl script f =
  let dir = Filename.temp_file "sol-release-contract-kubectl" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let bin = Filename.concat dir "kubectl" in
  let oc = open_out bin in
  output_string oc script;
  close_out oc;
  Unix.chmod bin 0o755;
  let old_path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      (try Sys.remove bin with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    f
;;

let deployed_contract ~workspace =
  Sol_cli_release_store.deployed_contract
    ~ctx:Sol_cli_kube_destination.local_context
    ~workspace
;;

let test_absent_pointer_is_an_empty_baseline () =
  with_fake_kubectl
    "#!/bin/sh\n\
     printf 'Error from server (NotFound): configmaps \"sol-release-current-myapp\" not \
     found\n\
     ' >&2\n\
     exit 1\n"
    (fun () ->
       match deployed_contract ~workspace:"myapp" with
       | Ok contract ->
         Windtrap.equal
           Windtrap.int
           ~msg:"a genuinely absent current pointer is a first deployment"
           0
           (List.length contract)
       | Error msg -> Windtrap.fail ("an absent pointer must not fail: " ^ msg))
;;

let test_unreadable_pointer_fails_closed () =
  with_fake_kubectl
    "#!/bin/sh\n\
     printf 'Error from server (Forbidden): configmaps \"sol-release-current-myapp\" is \
     forbidden\\n' >&2\n\
     exit 1\n"
    (fun () ->
       match deployed_contract ~workspace:"myapp" with
       | Error msg -> assert (matches_regex (Str.regexp_string "Forbidden") msg)
       | Ok _ -> Windtrap.fail "an unreadable pointer must not report an empty baseline")
;;

let test_unreadable_record_fails_closed () =
  with_fake_kubectl
    "#!/bin/sh\n\
     case \"$*\" in\n\
    \  *jsonpath*) printf 'r-0123456789abcdef' ;;\n\
    \  *) printf 'Error from server (Forbidden): configmaps \
     \"sol-release-r-0123456789abcdef\" is forbidden\\n' >&2; exit 1 ;;\n\
     esac\n"
    (fun () ->
       match deployed_contract ~workspace:"myapp" with
       | Error msg ->
         assert (matches_regex (Str.regexp_string "r-0123456789abcdef") msg);
         assert (matches_regex (Str.regexp_string "Forbidden") msg)
       | Ok _ -> Windtrap.fail "a dangling pointer must not report an empty baseline")
;;

let test_malformed_record_fails_closed () =
  with_fake_kubectl
    "#!/bin/sh\n\
     case \"$*\" in\n\
    \  *jsonpath*) printf 'r-0123456789abcdef' ;;\n\
    \  *) printf '{\"data\":{\"record\":\"not-json\",\"record_digest\":\"deadbeef\"}}' ;;\n\
     esac\n"
    (fun () ->
       match deployed_contract ~workspace:"myapp" with
       | Error _ -> ()
       | Ok _ ->
         Windtrap.fail "a malformed stored record must not report an empty baseline")
;;

let%test "release_contract: absent pointer is a valid first deployment" =
  test_absent_pointer_is_an_empty_baseline ()
;;

let%test "release_contract: unreadable pointer refuses" =
  test_unreadable_pointer_fails_closed ()
;;

let%test "release_contract: unreadable current release refuses" =
  test_unreadable_record_fails_closed ()
;;

let%test "release_contract: malformed current release refuses" =
  test_malformed_record_fails_closed ()
;;
