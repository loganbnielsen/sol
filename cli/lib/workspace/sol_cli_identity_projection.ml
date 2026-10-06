(* DEC-063: a caller receives one projected ServiceAccount token per declared
   callee unit. The audience is the callee's Sol unit identity and the kubelet
   refreshes the projected file in place before the token expires.

   The caller does not reconstruct the mount path: the projection names the file
   through the callee's URL environment variable, so the runtime reads the path
   from its own environment and never handles the token itself. *)

type t =
  { volume_name : string
  ; audience : string
  ; url_env_var : string
  ; mount_path : string
  }

let mount_root = "/var/run/sol/identity"
let volume_prefix = "sol-identity-"

(* Volume names are DNS-1123 labels (at most 63 characters). A declared k8s name
   may already be at the limit, so trim the projection prefix rather than emit an
   invalid pod spec; the mount path and the env-var file path keep the full
   name. *)
let truncate_label value =
  if String.length value <= 63
  then value
  else (
    let cut = String.sub value 0 63 in
    let rec last_alnum i =
      if i < 0 then -1 else if cut.[i] = '-' then last_alnum (i - 1) else i
    in
    let stop = last_alnum (String.length cut - 1) in
    if stop < 0 then "sol-identity" else String.sub cut 0 (stop + 1))
;;

let of_call ~callee_k8s_name ~audience ~url_env_var =
  { volume_name = truncate_label (volume_prefix ^ callee_k8s_name)
  ; audience
  ; url_env_var
  ; mount_path = Filename.concat mount_root callee_k8s_name
  }
;;

let token_file t = Filename.concat t.mount_path "token"

let token_file_env_var t =
  let suffix = "_URL" in
  let n = String.length t.url_env_var in
  let m = String.length suffix in
  if n >= m && String.sub t.url_env_var (n - m) m = suffix
  then String.sub t.url_env_var 0 (n - m) ^ "_TOKEN_FILE"
  else t.url_env_var ^ "_TOKEN_FILE"
;;
