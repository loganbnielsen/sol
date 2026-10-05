let contains ~needle haystack =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with
  | Not_found -> false
;;

let declared_account_id_suffixes text =
  let marker = "\"${var.cluster_name}" in
  text
  |> String.split_on_char '\n'
  |> List.filter (fun line -> contains ~needle:"account_id" line)
  |> List.filter_map (fun line ->
    match Str.search_forward (Str.regexp_string marker) line 0 with
    | exception Not_found -> None
    | index ->
      let start = index + String.length marker in
      let stop =
        try String.index_from line start '"' with
        | Not_found -> String.length line
      in
      Some (String.sub line start (stop - start)))
;;

let longest suffixes =
  List.fold_left
    (fun longest suffix ->
       if String.length suffix > String.length longest then suffix else longest)
    ""
    suffixes
;;

let test_validate_cluster_name_boundary () =
  let seventeen = String.make 17 'a' in
  let nineteen = String.make 19 'a' in
  (match Sol_cli_gcp_cluster.validate_cluster_name seventeen with
   | Ok () -> ()
   | Error message ->
     Windtrap.failf
       "a 17-character cluster name must validate every derived id: %s"
       message);
  match Sol_cli_gcp_cluster.validate_cluster_name nineteen with
  | Ok () -> Windtrap.fail "a 19-character cluster name overflows a derived account id"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"the error names the derived account id"
      true
      (contains ~needle:(nineteen ^ "-cert-manager") message);
    Windtrap.equal
      Windtrap.bool
      ~msg:"the error names the 30-character cap"
      true
      (contains ~needle:"6-30" message);
    Windtrap.equal
      Windtrap.bool
      ~msg:"the error names the allowable cluster-name length"
      true
      (contains ~needle:"at most 17" message)
;;

let test_cli_suffixes_match_terraform () =
  let root = Source_root.find () in
  let main_tf = Filename.concat root "platform/cloud/gcp/cluster/main.tf" in
  let text = In_channel.with_open_bin main_tf In_channel.input_all in
  let declared = declared_account_id_suffixes text in
  Windtrap.equal
    Windtrap.bool
    ~msg:"the GCP cluster root declares cluster-name-derived account ids"
    true
    (declared <> []);
  List.iter
    (fun suffix ->
       Windtrap.equal
         Windtrap.bool
         ~msg:(Printf.sprintf "the CLI validates the declared suffix %s" suffix)
         true
         (List.mem suffix Sol_cli_gcp_cluster.account_id_suffixes))
    declared;
  Windtrap.equal
    Windtrap.string
    ~msg:"the CLI's longest suffix is the root's longest, so the bound cannot drift"
    (longest declared)
    Sol_cli_gcp_cluster.longest_account_id_suffix
;;

let%test "gcp: a cluster name at the derived-id boundary validates (BUG-208)" =
  test_validate_cluster_name_boundary ()
;;

let%test "gcp: the CLI account-id suffixes match the Terraform root (BUG-208)" =
  test_cli_suffixes_match_terraform ()
;;
