(* REFAC-096: the AWS cluster behind [Sol_cli_cluster.t].

   The AWS cloud root's outputs, their parsing, and everything that reaches the
   EKS cluster with them live here, private to the provider: the ephemeral
   provisioner kubeconfig (`aws eks update-kubeconfig --role-arn`), the substrate
   readiness check, and DEC-040's bootstrap window -- the whoami shape gate, the
   window control, and the de-escalation probes, which exist because Sol grants
   and revokes that window itself on AWS. Moved verbatim from `cmd_cloud_tf.ml`
   and `Sol_cli_cloud_lifecycle`; the lifecycle sees only the record [cluster]
   builds. *)

type aws_outputs =
  { cluster_name : string
  ; cluster_access_role_arn : string
  ; cert_manager_irsa_role_arn : string
  ; loki_s3_bucket : string option
  ; loki_irsa_role_arn : string option
  ; thanos_s3_bucket : string option
  ; thanos_irsa_role_arn : string option
  ; grafana_irsa_role_arn : string option
  ; managed_resource_dashboards : Yojson.Safe.t
  }

let aws_outputs_of_json text =
  try
    let value, string, optional_string =
      Sol_cli_cluster.outputs_reader ~provider:"AWS" text
    in
    let ( let* ) = Result.bind in
    let* cluster_name = string "cluster_name" in
    let* cluster_access_role_arn = string "cluster_access_role_arn" in
    let* cert_manager_irsa_role_arn = string "cert_manager_irsa_arn" in
    let* loki_s3_bucket = optional_string "loki_s3_bucket" in
    let* loki_irsa_role_arn = optional_string "loki_irsa_arn" in
    let* thanos_s3_bucket = optional_string "thanos_s3_bucket" in
    let* thanos_irsa_role_arn = optional_string "thanos_irsa_arn" in
    let* grafana_irsa_role_arn = optional_string "grafana_irsa_arn" in
    let managed_resource_dashboards = value "managed_resource_dashboards" in
    match managed_resource_dashboards with
    | `Assoc _ ->
      Ok
        { cluster_name
        ; cluster_access_role_arn
        ; cert_manager_irsa_role_arn
        ; loki_s3_bucket
        ; loki_irsa_role_arn
        ; thanos_s3_bucket
        ; thanos_irsa_role_arn
        ; grafana_irsa_role_arn
        ; managed_resource_dashboards
        }
    | _ -> Error "AWS Terraform output \"managed_resource_dashboards\" is not an object"
  with
  | Yojson.Json_error message -> Error ("invalid AWS Terraform output JSON: " ^ message)
  | Yojson.Safe.Util.Type_error (message, _) ->
    Error ("invalid AWS Terraform outputs: " ^ message)
;;

let cluster_access_role_arn (outputs : aws_outputs) = outputs.cluster_access_role_arn

let provisioner_kubeconfig ?role_arn ~region outputs f =
  let path = Filename.temp_file "sol-platform-provisioner-" ".kubeconfig" in
  let cleanup () =
    try Sys.remove path with
    | Sys_error _ -> ()
  in
  (* A run can still end through [exit] while this is held -- an interrupt, or a
     command edge -- which does not unwind the stack, so [Fun.protect]'s finalizer
     alone could leak this privileged kubeconfig. Register the same cleanup with
     [at_exit] as well; it is idempotent. *)
  at_exit cleanup;
  Fun.protect ~finally:cleanup (fun () ->
    Printf.printf "  cluster access identity: %s\n%!" (cluster_access_role_arn outputs);
    (* Finding 12: the base providers resolve the kubeconfig from
       KUBE_CONFIG_PATH/KUBE_CONFIG_PATHS, not KUBECONFIG. *)
    let env = Sol_cli_cluster.provisioner_kube_env path in
    match
      Sol_cli_process.run
        (Sol_cli_process.cmd
           ~env
           [ "aws"
           ; "eks"
           ; "update-kubeconfig"
           ; "--region"
           ; region
           ; "--name"
           ; outputs.cluster_name
           ; "--alias"
           ; outputs.cluster_name
           ; "--role-arn"
           ; (match role_arn with
              | Some arn -> arn
              | None -> cluster_access_role_arn outputs)
           ; "--kubeconfig"
           ; path
           ])
    with
    | Ok result when result.exit_code = 0 -> Ok (f env)
    | _ -> Error "could not establish ephemeral provisioner cluster access")
;;

(* DEC-040 / FND-0021: de-escalation is not complete because a control plane said so.

   Live, an EKS access-policy disassociation was accepted, `describe-access-entry`
   reported no access policies, and the authorizer went on granting cluster-admin for
   over five minutes.

   Two things make this evidence rather than ceremony. The probe runs as **the principal
   whose bootstrap elevation this phase removes** -- the provisioner, not the
   steady-state cluster-access identity, whose refusals would say nothing about the
   provisioner's authority. And it establishes *which* principal answered before
   believing any answer: a probe that quietly authenticated as somebody else would
   "prove" exactly the thing FND-0021 showed can be false. *)
let bootstrap_only_capabilities =
  List.map
    (fun (verb, resource) -> { Sol_cli_cloud_lifecycle.verb; resource })
    [ "create", "clusterroles"
    ; "create", "clusterrolebindings"
    ; "escalate", "clusterroles"
    ]
;;

(* Run `kubectl auth can-i` and classify its result. The classification itself is a lib
   function so it can be unit tested; this only performs the call. *)
let capability_answer_of_can_i ~env { Sol_cli_cloud_lifecycle.verb; resource } =
  match
    Sol_cli_process.run
      (Sol_cli_process.cmd ~env [ "kubectl"; "auth"; "can-i"; verb; resource ])
  with
  | Ok r ->
    Sol_cli_cloud_lifecycle.capability_answer_of_can_i_output
      ~exit_code:r.Sol_cli_process.exit_code
      ~stdout:r.Sol_cli_process.stdout
      ~stderr:r.Sol_cli_process.stderr
  | Error e -> Sol_cli_cloud_lifecycle.Indeterminate (Sol_cli_process.error_to_string e)
;;

(* One definition of the retry interval, so the shape gate, the bootstrap-window
   control and the post-de-escalation loop cannot drift apart. Production uses the
   default; a harness overrides it to exercise the retry without sleeping through it.
   A negative or non-finite override is ignored rather than slept on -- a NaN reaches
   [Unix.sleepf] as an exception, and a negative would spend the whole retry budget in
   one pass. *)
let whoami_retry_interval_s () =
  match Sys.getenv_opt "SOL_WHOAMI_RETRY_INTERVAL_S" with
  | None -> 10.
  | Some raw ->
    (match float_of_string_opt raw with
     | Some seconds when Float.is_finite seconds && seconds >= 0. -> seconds
     | _ -> 10.)
;;

(* Bounds for the retry loops, named so they cannot drift apart silently. The shape
   gate and the window control both wait out a fresh endpoint's propagation; the
   post-removal await is longer, because FND-0021 saw an access-policy disassociation
   take over five minutes to propagate while a deletion took under 45 s. *)
let cluster_propagation_attempts = 10
let deescalation_attempts = 18

(* A refusal from the cluster, as opposed to a failure to reach it. Shared because the
   de-escalation probe treats it as evidence of de-escalation while the shape gate treats it
   as a reason to stop immediately: retrying cannot change an identity. *)
let cluster_refused detail =
  List.exists
    (fun needle -> Sol_cli_string.contains ~needle detail)
    [ "Unauthorized"
    ; "You must be logged in"
    ; "the server has asked for the client to provide credentials"
    ; "is forbidden"
    ]
;;

(* AUDIT-POST-001: AWS-native identity, moved here from [Sol_cli_cloud_lifecycle].

   `kubectl auth whoami -o json` answers with a SelfSubjectReview, and on EKS the AWS
   authenticator reports it under `status.userInfo.extra` with every value an *array of
   strings* -- including `arn` and `canonicalArn`. Nothing about that shape is a Sol
   semantic: GCP's window is closed by applying the platform root, so it has no Sol-side
   identity to compare and needs none of this. It belongs with the provider that produces
   it, and the generic lifecycle keeps only the provider-neutral verdict types
   ([deescalation_principal], [deescalation_verdict], [deescalation_transition]). *)

(* DEC-040 / FND-0021: identify the principal the authorizer resolved, from the JSON
   that kubectl auth whoami -o json emits.

   That response is a SelfSubjectReview. On EKS the AWS authenticator puts identity
   details under status.userInfo.extra, where every value is an *array of strings* --
   including arn and canonicalArn. So the arn is not a plain field of userInfo, and an
   earlier version that looked only for a string there would have failed closed on every
   real install. The flat string form is still accepted, because other authenticators and
   test stubs emit it, but the array form is the one EKS actually produces.

   canonicalArn is preferred for identity: arn for an assumed role carries a session name
   that differs between the before and after probes, so comparing raw arns would report a
   false mismatch. *)
type whoami_identity =
  { arn : string option
  ; canonical_arn : string option
  ; username : string option
  ; source : string
    (** Which field the identity was taken from: extra.canonicalArn, extra.arn,
          userInfo.canonicalArn, userInfo.arn, or username. The de-escalation comparison
          depends on canonicalArn being present, so a caller that cares must be able to see
          which field it got. *)
  }

(* Strict: a value that is a list must have exactly one element.

   The AWS authenticator reports identity values as one-element arrays, so a two-element
   array names more than one principal -- and taking the first element is a default in
   disguise, which is how an ambiguous response could otherwise be read as a definite one.
   Absent is [Ok None]; present-but-ambiguous is [Error]. *)
let single_string_of_json ~what = function
  | `String v -> Ok (Some v)
  | `List [ `String v ] -> Ok (Some v)
  | `List [] -> Error (Printf.sprintf "a %s value was an empty array" what)
  | `List (_ :: _ :: _) ->
    Error (Printf.sprintf "a %s value was an array of more than one element" what)
  | `Null -> Ok None
  | _ ->
    Error (Printf.sprintf "a %s value was neither a string nor an array of strings" what)
;;

let whoami_identity_of_json json : (whoami_identity, string) result =
  match Yojson.Safe.from_string json with
  | exception _ -> Error "the whoami response was not JSON"
  | json ->
    (* Non-raising on purpose: Yojson's member raises when its parent is null, and a
       response with no `extra` at all (any non-EKS authenticator, or a stub) would then
       crash the probe instead of degrading to a stated reason. The fixtures caught
       exactly that. *)
    let member_opt key = function
      | `Assoc fields -> List.assoc_opt key fields
      | _ -> None
    in
    let sub key j =
      match member_opt key j with
      | Some v -> v
      | None -> `Null
    in
    let status = sub "status" json in
    let user = sub "userInfo" status in
    let extra = sub "extra" user in
    let source = ref "none" in
    (* A present-but-ambiguous value is an error, not a first element. *)
    let field name = single_string_of_json ~what:name (sub name user) in
    let extra_field name = single_string_of_json ~what:name (sub name extra) in
    Result.bind (extra_field "arn") (fun extra_arn ->
      Result.bind (field "arn") (fun user_arn ->
        Result.bind (extra_field "canonicalArn") (fun extra_canonical ->
          Result.bind (field "canonicalArn") (fun user_canonical ->
            Result.bind (field "username") (fun username ->
              let arn, arn_source =
                match extra_arn with
                | Some _ as v -> v, "extra.arn"
                | None -> user_arn, "userInfo.arn"
              in
              let canonical_arn, canonical_source =
                match extra_canonical with
                | Some _ as v -> v, "extra.canonicalArn"
                | None -> user_canonical, "userInfo.canonicalArn"
              in
              (* The field the identity is *taken from*: canonicalArn is the one the
                 comparison depends on, so it is named rather than left implicit. *)
              (source
               := match canonical_arn, arn, username with
                  | Some _, _, _ -> canonical_source
                  | None, Some _, _ -> arn_source
                  | None, None, Some _ -> "username"
                  | None, None, None -> "none");
              let identity = { arn; canonical_arn; username; source = !source } in
              match arn, canonical_arn, username with
              | None, None, None ->
                Error
                  "the whoami response carried no arn and no username (is \
                   SelfSubjectReview supported by this cluster and kubectl?)"
              | _ -> Ok identity)))))
;;

(* The role name inside an ARN, whichever form it takes. An assumed-role ARN is
   .../assumed-role/<role>/<session>, so the role is the second-to-last segment and a
   naive last-segment split would compare session names -- and two probes of the same
   principal have different session names, which would read as a principal mismatch. *)
let index_of_substring ~needle haystack =
  let n = String.length needle
  and h = String.length haystack in
  let rec scan i =
    if i + n > h
    then None
    else if String.sub haystack i n = needle
    then Some i
    else scan (i + 1)
  in
  scan 0
;;

let role_name_of_arn arn =
  let after needle =
    match index_of_substring ~needle arn with
    | None -> None
    | Some i ->
      let from = i + String.length needle in
      Some (String.sub arn from (String.length arn - from))
  in
  (* The real form is ...:assumed-role/<role>/<session> -- colon before, not slash -- and
     missing that made the role name come out as the session, which would have read as a
     principal mismatch between two probes of the same principal. Matched without the
     leading separator so both spellings work. *)
  match after "assumed-role/" with
  | Some rest ->
    (match String.index_opt rest '/' with
     | Some i -> String.sub rest 0 i
     | None -> rest)
  | None ->
    (match after ":role/" with
     | Some name -> name
     | None ->
       (match String.rindex_opt arn '/' with
        | Some i when i + 1 < String.length arn ->
          String.sub arn (i + 1) (String.length arn - i - 1)
        | _ -> arn))
;;

(* The principal's stable role name: canonicalArn first, then arn, then the username. *)
let principal_role_name (i : whoami_identity) =
  match i.canonical_arn, i.arn, i.username with
  | Some a, _, _ -> Some (role_name_of_arn a)
  | None, Some a, _ -> Some (role_name_of_arn a)
  | None, None, Some u -> Some u
  | None, None, None -> None
;;

(* The form canonicalArn reports: role/<name>, with any role path dropped.

   Normalising the *expected* side matters because the gate requires canonicalArn, which is
   path-free: a provisioner role configured with a path (SSO roles are the common case) would
   otherwise produce a false mismatch in the first minute on a perfectly healthy cluster. *)
let normalize_role_arn arn =
  match index_of_substring ~needle:":role/" arn with
  | None -> arn
  | Some i ->
    let prefix = String.sub arn 0 (i + 6) in
    let name = String.sub arn (i + 6) (String.length arn - i - 6) in
    prefix
    ^
      (match String.rindex_opt name '/' with
      | Some j when j + 1 < String.length name ->
        String.sub name (j + 1) (String.length name - j - 1)
      | _ -> name)
;;

(* Whether the response names exactly the expected principal.

   The comparison is the **full** canonical ARN, account and path included. Comparing an
   extracted role name was a fail-*open* -- the same role name in another account, or
   reached through a different role path, would look like the same principal, and a
   different principal being denied afterwards would then read as Deescalated. The strict
   form's worst case is a false mismatch, which lands in Undetermined and does not
   announce Ready. INFRA-061 records the precise comparison (account plus normalised role)
   as the follow-up that makes it exact without the false mismatches. *)
let principal_matches ~expected (identity : whoami_identity) =
  match identity.canonical_arn with
  | Some arn -> Some (String.equal arn expected)
  | None ->
    (* A bare arn carries a session name, so it cannot equal a role ARN: report the
       mismatch rather than guess. *)
    (match identity.arn with
     | Some arn -> Some (String.equal arn expected)
     | None -> None)
;;

(* A refusal by the cluster is evidence of de-escalation only if the credential itself is
   still good.

   "You must be logged in" is also what a valid credential gets when something upstream of
   the cluster is wrong -- a broken trust policy on the role, clock skew, a wrong assumed
   role -- and `Sol_cli_cloud_lifecycle.Principal_refused_by_cluster` maps straight to Deescalated. That would read a
   broken credential as a verified transition, which is a fail-*open* into the one verdict
   that has to mean something. So the caller also confirms the role can still be assumed, and
   only a refusal with a working identity counts. If the identity check fails, the probe
   obtained no usable evidence and says so. *)
type credential_assumption =
  | Credential_assumable
  (** The role was assumed successfully, so the refusal is about the capability. *)
  | Credential_refused
  (** The role itself could not be assumed: a broken credential, not a revoked one. *)
  | Credential_unchecked
  (** The assumption attempt could not be made at all: no usable evidence either way. *)

let refusal_is_deescalation assumption detail =
  match assumption with
  | Credential_assumable -> Sol_cli_cloud_lifecycle.Principal_refused_by_cluster detail
  | Credential_refused ->
    Sol_cli_cloud_lifecycle.Principal_probe_failed
      (Printf.sprintf
         "the cluster refused the probe (%s) and the provisioning role could not be \
          assumed, so a broken credential cannot be told apart from a revoked one"
         detail)
  | Credential_unchecked ->
    Sol_cli_cloud_lifecycle.Principal_probe_failed
      (Printf.sprintf
         "the cluster refused the probe (%s) and the identity check could not be \
          performed, so the refusal is not evidence"
         detail)
;;

(* Compares the **full** canonical ARN, account and path included.

   Comparing an extracted role name was a fail-*open*: the same role name in another
   account, or reached through a different role path, would look like the same principal,
   and a different principal being denied afterwards would then read as Deescalated. The
   strict comparison is the safe direction -- its worst case is a false mismatch, which
   lands in Undetermined and does not announce Ready. INFRA-061 records the precise
   comparison (account plus normalised role) as the follow-up that makes it exact. *)
let deescalation_principal_check ~expected_arn ~provisioner_role_arn env =
  match
    Sol_cli_process.run
      (Sol_cli_process.cmd ~env [ "kubectl"; "auth"; "whoami"; "-o"; "json" ])
  with
  | Ok r when r.Sol_cli_process.exit_code = 0 ->
    (match whoami_identity_of_json r.Sol_cli_process.stdout with
     | Ok identity ->
       let shown =
         match identity.canonical_arn, identity.arn with
         | Some a, _ | None, Some a -> a
         | None, None -> "(unnamed)"
       in
       (match principal_matches ~expected:expected_arn identity with
        | Some true -> Sol_cli_cloud_lifecycle.Principal_confirmed shown
        | Some false -> Sol_cli_cloud_lifecycle.Principal_unexpected shown
        | None ->
          Sol_cli_cloud_lifecycle.Principal_probe_failed "the response named no principal")
     | Error why -> Sol_cli_cloud_lifecycle.Principal_probe_failed why)
  | Ok r ->
    let detail =
      String.trim (r.Sol_cli_process.stderr ^ " " ^ r.Sol_cli_process.stdout)
    in
    (* A refusal from the cluster is the expected post-de-escalation state. Anything
       else -- a credential that could not be assumed, a token that could not be
       generated, no reachable API -- is a measurement failure, and absence of evidence
       must not become evidence of de-escalation. Only the cluster's own answer counts. *)
    if cluster_refused detail
    then (
      (* A refusal is evidence of removal only if the credential is still good. "You must be
         logged in" is also what a working credential gets when the role's trust policy is
         broken, the clock is skewed, or the wrong role was assumed -- and reading that as
         removal would be a fail-open into Deescalated. The raw configured ARN is used here,
         not the path-free form the comparison wants, because this is an IAM call. *)
      let assumption =
        match
          Sol_cli_process.run
            (Sol_cli_process.cmd
               ~env
               [ "aws"
               ; "sts"
               ; "assume-role"
               ; "--role-arn"
               ; provisioner_role_arn
               ; "--role-session-name"
               ; "sol-deescalation-check"
               ])
        with
        | Ok r when r.Sol_cli_process.exit_code = 0 -> Credential_assumable
        | Ok _ -> Credential_refused
        | Error _ -> Credential_unchecked
      in
      refusal_is_deescalation assumption detail)
    else Sol_cli_cloud_lifecycle.Principal_probe_failed detail
  | Error e ->
    Sol_cli_cloud_lifecycle.Principal_probe_failed (Sol_cli_process.error_to_string e)
;;

(* Failing to obtain the probe's cluster access is a measurement failure, which the
   transition verdict already handles as [Undetermined]; it must not abort paths that
   must degrade gracefully -- the offline lifecycle harness injects a cloud failure and
   requires `cloud apply` to resume, and it does not have a real cluster to reach. *)
let deescalation_probe ~region ~outputs ~provisioner_role_arn () =
  match
    provisioner_kubeconfig ~role_arn:provisioner_role_arn ~region outputs (fun env ->
      let principal =
        deescalation_principal_check
          ~expected_arn:(normalize_role_arn provisioner_role_arn)
          ~provisioner_role_arn
          env
      in
      let probes =
        match principal with
        | Sol_cli_cloud_lifecycle.Principal_unexpected _
        | Sol_cli_cloud_lifecycle.Principal_probe_failed _
        | Sol_cli_cloud_lifecycle.Principal_refused_by_cluster _ ->
          (* Never interrogate another principal's capabilities and call it evidence. *)
          []
        | _ ->
          List.map
            (fun capability -> capability, capability_answer_of_can_i ~env capability)
            bootstrap_only_capabilities
      in
      principal, probes)
  with
  | Ok v -> v
  | Error e -> Sol_cli_cloud_lifecycle.Principal_probe_failed e, []
;;

(* Bounded and fail-closed: access-entry changes are eventually consistent so a retry
   is expected, but an unverified claim is not an acceptable outcome. *)
(* DEC-040 gate: the shape of the authorizer's answer is the one thing a fixture cannot
   settle, because the fixtures encode a shape recalled from the API rather than captured
   from a cluster.

   It runs as soon as the cluster is reachable -- after the cloud apply and before the
   platform install, which is the expensive part -- and it **fails the run** unless it
   observes, in order:

   1. an answer at all, retried with backoff because a freshly created EKS endpoint is
      briefly unable to authenticate its own principal. Unreachability is retried and then
      fatal: the gate not having run is a failure, not a pass;
   2. a response the parser can identify a principal from;
   3. that the principal is **the expected provisioner**, not merely that some principal was
      named -- otherwise a leftover credential of another identity passes the shape check;
   4. that the identity came from `canonicalArn`. The de-escalation comparison depends on
      that field, so a pass via the `arn` or `username` fallbacks would be validating a path
      the comparison does not use.

   The raw response is written to a run artifact that survives teardown, so it can be
   promoted to a fixture even if the run later fails. *)
(* The filename carries the run, so a second run cannot overwrite the first one's
   evidence. *)
let whoami_capture_path ~run_id =
  let name = Printf.sprintf "whoami-capture-%s.json" run_id in
  match Sys.getenv_opt "SOL_QUALIFICATION_CAPTURE_DIR" with
  | Some dir -> Some (Filename.concat dir name)
  | None ->
    (match Sys.getenv_opt "HOME" with
     | Some home -> Some (Filename.concat (Filename.concat home ".sol-qual") name)
     | None -> None)
;;

let persist_whoami_capture ~run_id json =
  match whoami_capture_path ~run_id with
  | None ->
    Printf.printf
      "  whoami capture: no writable path (set HOME or SOL_QUALIFICATION_CAPTURE_DIR)\n%!"
  | Some path ->
    (try
       let dir = Filename.dirname path in
       (* The raw capture holds real ARNs and account ids, so the directory is 0700 and the
          file 0600 -- created or tightened, since an existing directory may be looser. *)
       if not (Sys.file_exists dir) then Unix.mkdir dir 0o700;
       (try Unix.chmod dir 0o700 with
        | _ -> ());
       let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
       let oc = Unix.out_channel_of_descr fd in
       output_string oc json;
       close_out oc;
       (try Unix.chmod path 0o600 with
        | _ -> ());
       Printf.printf "  whoami capture: %s\n%!" path
     with
     | _ ->
       Printf.printf
         "  whoami capture: could not write %s -- the raw response is in this log above\n\
          %!"
         path)
;;

let verify_whoami_shape ~region ~outputs ~provisioner_role_arn =
  (* This gate runs after the bootstrap window is open, so a failure here is returned
     to [Sol_cli_cloud_apply.execute], which removes that access before the run
     stops -- otherwise the run would end with [provisioner_bootstrap_admin=true]
     still applied on a cluster it has just decided it cannot verify. *)
  let fail message = Error message in
  let interval_s = whoami_retry_interval_s () in
  (* The expectation is the configured intent -- the target's provisioner role, normalised
     to the path-free form canonicalArn reports, so a role with a path does not produce a
     false mismatch on a healthy cluster. The observation is the authorizer's own answer
     about who authenticated. They are not the same value read back from one place: the
     kubeconfig is built from the config, but the ARN compared against it comes from the
     cluster, so a leftover credential of another identity answers with that other ARN and
     is caught. *)
  let expected = normalize_role_arn provisioner_role_arn in
  let run_id = Printf.sprintf "%d" (int_of_float (Unix.gettimeofday ())) in
  let rec attempt remaining =
    let outcome =
      provisioner_kubeconfig ~role_arn:provisioner_role_arn ~region outputs (fun env ->
        Sol_cli_process.run
          (Sol_cli_process.cmd ~env [ "kubectl"; "auth"; "whoami"; "-o"; "json" ]))
    in
    match outcome with
    | Ok (Ok r) when r.Sol_cli_process.exit_code = 0 ->
      let json = String.trim r.Sol_cli_process.stdout in
      (* Persisted before anything is asserted, on every attempt: the run that fails on a
         shape mismatch is the one whose capture matters most, and writing afterwards would
         leave nothing behind for exactly that case. *)
      persist_whoami_capture ~run_id json;
      let identity_result = whoami_identity_of_json json in
      (match identity_result with
       | Error why ->
         fail
           (Printf.sprintf
              "the authorizer's whoami response did not match the parser (%s). The run \
               stops here rather than spending a bootstrap on a verification that cannot \
               succeed. Raw response: %s"
              why
              json)
       | Ok identity ->
         let source = identity.source in
         Printf.printf "  whoami shape: parsed (identity source: %s)\n%!" source;
         let matched = principal_matches ~expected identity in
         let named =
           match identity.canonical_arn, identity.arn with
           | Some a, _ -> a
           | None, Some a -> a
           | None, None -> "(unnamed)"
         in
         (match matched with
          | Some false ->
            fail
              (Printf.sprintf
                 "the authorizer answered as a different principal than the provisioner \
                  whose elevation this run manages (%s, from %s). The run stops here: \
                  the de-escalation comparison would be about somebody else."
                 named
                 source)
          | None -> fail "the authorizer's answer named no principal at all"
          | Some true ->
            if source <> "extra.canonicalArn" && source <> "userInfo.canonicalArn"
            then
              fail
                (Printf.sprintf
                   "the principal came from %s rather than canonicalArn, which is the \
                    field the de-escalation comparison depends on. The run stops rather \
                    than validating a path the verification does not use. Raw response: \
                    %s"
                   source
                   json)
            else Ok ()))
    | unreachable ->
      let why =
        match unreachable with
        | Ok (Ok r) ->
          Printf.sprintf
            "kubectl exited %d (%s)"
            r.Sol_cli_process.exit_code
            (String.trim (r.Sol_cli_process.stderr ^ " " ^ r.Sol_cli_process.stdout))
        | Ok (Error e) -> Sol_cli_process.error_to_string e
        | Error e -> e
      in
      (* Retried, not treated as terminal. A 401 or an authentication failure immediately
         after cluster creation is usually access-entry or aws-auth propagation lag for the
         *correct* principal, and connection errors are the endpoint not being ready -- both
         fix themselves. A 403 on this call is unusual (SelfSubjectReview is normally allowed
         for any authenticated user) and is retried on the same terms, then fails when the
         window expires.

         The one thing that *is* terminal is a successful answer naming a different identity,
         which is handled above: that is a wrong credential, and no amount of waiting changes
         it. Treating every Unauthorized as terminal here would fail healthy runs in the first
         minute. *)
      if remaining <= 1
      then
        fail
          (Printf.sprintf
             "the authorizer could not be reached to check the whoami shape (%s). The \
              gate not having run is a failure, not a pass: the run stops before the \
              platform install rather than discovering an unreadable shape at \
              de-escalation."
             why)
      else (
        Printf.printf
          "  whoami shape: not reachable yet (%s); retrying in %.0fs\n%!"
          why
          interval_s;
        Unix.sleepf interval_s;
        attempt (remaining - 1))
  in
  attempt cluster_propagation_attempts
;;

(* The verdict after the removal, once it stops changing or the bounded window expires.
   Never exits: the install path treats anything but [Deescalated] as fatal because Ready
   is a least-privilege claim, while the destroy path must not let a probe that can fail
   block teardown (ADR 0003 invariant 6) and reports the verdict instead. *)
let await_deescalation ~region ~outputs ~provisioner_role_arn ~before =
  let interval_s = whoami_retry_interval_s () in
  let rec loop remaining =
    (* The after-probe builds its kubeconfig the same way the window control did, against
       the same cluster and region. That is what makes a refusal attributable to the removal
       rather than to a wrong cluster name, a different endpoint or a region mismatch -- none
       of which the IAM identity check can see. If these two paths ever diverge, the
       guarantee goes with them, so change both or neither. *)
    let principal, probes =
      deescalation_probe ~region ~outputs ~provisioner_role_arn ()
    in
    let verdict =
      Sol_cli_cloud_lifecycle.deescalation_transition
        ~before
        ~after_principal:principal
        ~after:probes
    in
    match verdict with
    | Sol_cli_cloud_lifecycle.Deescalated -> verdict
    | _ when remaining <= 1 -> verdict
    | verdict ->
      Printf.printf
        "  awaiting effective de-escalation: %s\n%!"
        (Sol_cli_cloud_lifecycle.deescalation_verdict_to_string verdict);
      Unix.sleepf interval_s;
      loop (remaining - 1)
  in
  loop deescalation_attempts
;;

(* Operator-facing wording for the control line, kept out of the library: this is how a
   probe result is reported, not part of the verdict. *)
let deescalation_principal_to_string = function
  | Sol_cli_cloud_lifecycle.Principal_confirmed arn -> "confirmed " ^ arn
  | Sol_cli_cloud_lifecycle.Principal_refused_by_cluster why ->
    "refused by the cluster: " ^ why
  | Sol_cli_cloud_lifecycle.Principal_probe_failed why -> "no evidence: " ^ why
  | Sol_cli_cloud_lifecycle.Principal_unexpected who -> "unexpected " ^ who
;;

let capability_answer_to_string = function
  | Sol_cli_cloud_lifecycle.Permitted -> "permitted"
  | Sol_cli_cloud_lifecycle.Denied -> "denied"
  | Sol_cli_cloud_lifecycle.Indeterminate why -> "indeterminate: " ^ why
;;

(* The window control's failure, with every reason it could not be established: an
   operator needs to see which capability was indeterminate and why, not only that the
   window never opened. *)
let window_control_failure ~permitted indeterminate =
  let stop =
    "The run stops rather than proceeding to a verification that can only come back \
     undetermined."
  in
  if not permitted
  then
    Printf.sprintf
      "the bootstrap window never showed a capability permitted, so a later denial could \
       not be told apart from a credential that never worked. %s"
      stop
  else
    Printf.sprintf
      "the bootstrap window showed a capability permitted but also an indeterminate \
       probe (%s), which a later denial could not be told apart from. %s"
      (indeterminate
       |> List.map (fun (capability, why) -> capability ^ ": " ^ why)
       |> String.concat ", ")
      stop
;;

(* [Ok control] once the window shows at least one bootstrap-only capability permitted
   *and* no indeterminate probe -- an indeterminate capability would make the later
   transition [Undetermined] anyway, so failing here catches it before the platform
   install rather than at de-escalation. [Error reason] otherwise; never exits, so the
   destroy path can report rather than be blocked. *)
let observe_bootstrap_window_result ~region ~outputs ~provisioner_role_arn () =
  let interval_s = whoami_retry_interval_s () in
  let rec attempt remaining =
    let control = deescalation_probe ~region ~outputs ~provisioner_role_arn () in
    let principal, probes = control in
    let permitted =
      List.exists
        (fun (_, answer) -> Sol_cli_cloud_lifecycle.answer_is_permitted answer)
        probes
    in
    let indeterminate =
      List.filter_map Sol_cli_cloud_lifecycle.indeterminate_reason probes
    in
    match permitted, indeterminate with
    | true, [] ->
      Printf.printf
        "  bootstrap window control: principal=%s; %s\n%!"
        (deescalation_principal_to_string principal)
        (probes
         |> List.map (fun (capability, answer) ->
           Printf.sprintf
             "%s=%s"
             (Sol_cli_cloud_lifecycle.capability_label capability)
             (capability_answer_to_string answer))
         |> String.concat ", ");
      Ok control
    | _ ->
      if remaining <= 1
      then Error (window_control_failure ~permitted indeterminate)
      else (
        Printf.printf
          "  bootstrap window control: not yet permitted; retrying in %.0fs\n%!"
          interval_s;
        Unix.sleepf interval_s;
        attempt (remaining - 1))
  in
  attempt cluster_propagation_attempts
;;

let aws_cloud_ready ~region outputs =
  let cluster = outputs.cluster_name in
  let status args =
    Sol_cli_cluster.process_output ([ "aws" ] @ args @ [ "--region"; region ])
  in
  match
    ( status
        [ "eks"
        ; "describe-cluster"
        ; "--name"
        ; cluster
        ; "--query"
        ; "cluster.status"
        ; "--output"
        ; "text"
        ]
    , status
        [ "eks"
        ; "describe-addon"
        ; "--cluster-name"
        ; cluster
        ; "--addon-name"
        ; "aws-ebs-csi-driver"
        ; "--query"
        ; "addon.status"
        ; "--output"
        ; "text"
        ] )
  with
  | Some cluster_status, Some addon_status
    when String.trim cluster_status = "ACTIVE" && String.trim addon_status = "ACTIVE" ->
    true
  | _ -> false
;;

(* The provider's share of the platform definition's variables. *)
let platform_vars outputs _context ~cluster_issuer:_ ~region =
  Ok
    { Sol_cli_cluster.fixed =
        [ "cloud_provider=aws"
        ; "aws_region=" ^ region
        ; "cert_manager_irsa_role_arn=" ^ outputs.cert_manager_irsa_role_arn
        ; "managed_resource_dashboards="
          ^ Yojson.Safe.to_string outputs.managed_resource_dashboards
        ]
    ; optional =
        [ "loki_s3_bucket", outputs.loki_s3_bucket
        ; "loki_irsa_role_arn", outputs.loki_irsa_role_arn
        ; "thanos_s3_bucket", outputs.thanos_s3_bucket
        ; "thanos_irsa_role_arn", outputs.thanos_irsa_role_arn
        ; "grafana_irsa_role_arn", outputs.grafana_irsa_role_arn
        ]
    }
;;

let label = "AWS"
let of_outputs_json = aws_outputs_of_json

let cluster ~region ~provisioner_role_arn outputs : Sol_cli_cluster.t =
  { name = outputs.cluster_name
  ; (* The cloud root reports the identity the platform root will act as; the
       target's declaration is what authorized it, so a mismatch means the platform
       would be wired to an identity Sol did not validate. *)
    check_identity =
      (fun ~cluster_access_role_arn ->
        match cluster_access_role_arn with
        | Some arn when arn <> outputs.cluster_access_role_arn ->
          Error "AWS cluster_access_role_arn output does not match the validated target"
        | _ -> Ok ())
  ; platform_vars = platform_vars outputs
  ; with_access =
      (fun f ->
        match provisioner_kubeconfig ~region outputs (fun env -> f ~env) with
        | Ok result -> result
        | Error message -> Error message)
  ; ready = (fun () -> aws_cloud_ready ~region outputs)
  ; bootstrap_window =
      (match provisioner_role_arn with
       | None -> Sol_cli_cluster.No_role_declared
       | Some provisioner_role_arn ->
         (* What the control saw while the window was open; the de-escalation
            verdict is a comparison against it. *)
         let before = ref [] in
         Sol_cli_cluster.Verified
           { principal = provisioner_role_arn
           ; gate = (fun () -> verify_whoami_shape ~region ~outputs ~provisioner_role_arn)
           ; observe =
               (fun () ->
                 match
                   observe_bootstrap_window_result
                     ~region
                     ~outputs
                     ~provisioner_role_arn
                     ()
                 with
                 | Ok (_, probes) ->
                   before := probes;
                   Ok ()
                 | Error message -> Error message)
           ; deescalated =
               (fun () ->
                 match
                   await_deescalation
                     ~region
                     ~outputs
                     ~provisioner_role_arn
                     ~before:!before
                 with
                 | Sol_cli_cloud_lifecycle.Deescalated -> Ok ()
                 | verdict ->
                   Error (Sol_cli_cloud_lifecycle.deescalation_verdict_to_string verdict))
           })
  }
;;

(* INFRA-039: resolve this operation's AWS credentials (moved from `cmd_cloud_tf.ml`,
   HARDEN-005), report the principal they belong to, and fail closed. *)
let credentials ~operation ~leaves_target_standing : (unit, string) result =
  let profile = Sys.getenv_opt "AWS_PROFILE" in
  match Sol_cli_aws_credentials.resolve ~run:Sol_cli_cluster.process_output ~profile with
  | Error detail ->
    Error
      (Sol_cli_aws_credentials.unresolved_message
         ~operation
         ~profile
         ~leaves_target_standing
         ~detail)
  | Ok credentials ->
    Sol_cli_aws_credentials.install credentials;
    Printf.printf "  credentials: %s\n%!" credentials.principal;
    Ok ()
;;
