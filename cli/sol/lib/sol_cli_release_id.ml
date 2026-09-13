(* FEAT-069: the content-addressed identity of a release.

   A release is *what is running*: the desired released state, canonicalised and
   hashed. It is not an invocation. Two deploys of identical content are one
   release; one deploy is one deployment event (FEAT-070).

   Why content-addressed rather than minted: the identity is rendered into the
   pod template, so a minted id would change the template on every deploy and
   force a rollout even when nothing substantive changed. Observability metadata
   must never be the thing that mutates the workload it observes.

   The projection below is deliberately explicit rather than "hash the plan".
   Only fields whose difference means *this is a different running release* are
   here, so adding a field to the plan (a timestamp, an output directory,
   provenance) cannot silently change every release identity. *)

(* One workload's contribution to the released state. [secrets] holds
   *references* (env key -> secret name), never material: rotating a secret's
   value does not by itself change the release. That is a deliberate rule, not
   an accident -- see the tests. *)
type workload =
  { domain : string
  ; name : string
  ; primitive : string
  ; image : string
  ; config : (string * string) list
  ; secrets : (string * string) list
  ; schedule : string option
  ; replicas : int
  ; cpu : string
  ; memory : string
  ; extra_labels : (string * string) list
  }

type content =
  { workspace : string
  ; environment : string option
  ; workloads : workload list
  }

(** [r-<16 hex>]: a legal Kubernetes label value by construction, so the label
    can be written verbatim without a sanitiser that could disagree with the
    stored id (the BUG-025 failure mode). *)
type t = string

(* Bumping this is a deliberate identity change: it makes every release hash
   differently, which is exactly what you want when the projection's meaning
   changes, and exactly what you must not do accidentally. *)
let encoding_version = "sol-release-v1"

(* Length-prefixed encoding. The length prefix is not decoration: with a bare
   separator, workloads ("ab", "c") and ("a", "bc") would encode identically and
   hash the same. *)
let enc_string b s =
  Buffer.add_string b (Printf.sprintf "%d:" (String.length s));
  Buffer.add_string b s
;;

let enc_int b n = Buffer.add_string b (Printf.sprintf "i%d;" n)

let enc_option enc b = function
  | None -> Buffer.add_char b 'n'
  | Some v ->
    Buffer.add_char b 's';
    enc b v
;;

(* Ordering of a map-like list is not semantic, so it is canonicalised away
   before hashing: [a; b; c] and [c; a; b] are the same release. *)
let enc_pairs b pairs =
  let pairs = List.sort (fun (a, _) (b, _) -> String.compare a b) pairs in
  enc_int b (List.length pairs);
  List.iter
    (fun (k, v) ->
       enc_string b k;
       enc_string b v)
    pairs
;;

let canonical_string (content : content) =
  let b = Buffer.create 256 in
  enc_string b encoding_version;
  enc_string b content.workspace;
  enc_option enc_string b content.environment;
  (* Workload *ordering* is likewise not semantic (discovery order must not
     change the identity), so sort before encoding. *)
  let workloads =
    List.sort
      (fun (a : workload) (c : workload) ->
         let by_domain = String.compare a.domain c.domain in
         if by_domain <> 0
         then by_domain
         else (
           let by_name = String.compare a.name c.name in
           if by_name <> 0 then by_name else String.compare a.primitive c.primitive))
      content.workloads
  in
  enc_int b (List.length workloads);
  List.iter
    (fun (w : workload) ->
       enc_string b w.domain;
       enc_string b w.name;
       enc_string b w.primitive;
       enc_string b w.image;
       enc_pairs b w.config;
       enc_pairs b w.secrets;
       enc_option enc_string b w.schedule;
       enc_int b w.replicas;
       enc_string b w.cpu;
       enc_string b w.memory;
       enc_pairs b w.extra_labels)
    workloads;
  Buffer.contents b
;;

let of_content (content : content) =
  let hex = Digest.to_hex (Digest.string (canonical_string content)) in
  "r-" ^ String.sub hex 0 16
;;

let to_string (t : t) = t
let is_lower_hex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')

let of_string s =
  let expected = "r-<16 lowercase hex>" in
  let bad () = Error (Printf.sprintf "%S is not a release id (expected %s)" s expected) in
  if String.length s <> 18
  then bad ()
  else if String.sub s 0 2 <> "r-"
  then bad ()
  else (
    let ok = ref true in
    for i = 2 to String.length s - 1 do
      if not (is_lower_hex s.[i]) then ok := false
    done;
    if !ok then Ok s else bad ())
;;
