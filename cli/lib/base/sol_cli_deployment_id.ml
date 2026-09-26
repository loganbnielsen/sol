(* FEAT-070: the minted identity of one deployment event.

   [d-<YYYYMMDDtHHMMSSz>-<16 lowercase hex>]. Time-prefixed so lexical order is
   roughly deployment order; entropy-suffixed so two actors minting in the same
   second do not collide. Minted, never content-derived: a release is *what is
   running*, a deployment is *one invocation*, and even a no-op redeploy of the
   same release is a real event with its own id.

   Lowercase [t]/[z]: the id becomes part of [sol-deployment-<id>] verbatim, and
   Kubernetes object names are lowercase RFC 1123. *)

type t = string

(* The UTC prefix. Lowercase separators, see the header. *)
let time_part (now : float) : string = Sol_cli_time.compact_lower now

let entropy_hex (entropy : string) : string =
  String.sub (Digest.to_hex (Digest.string entropy)) 0 16
;;

let create ~(now : float) ~(entropy : string) : t =
  Printf.sprintf "d-%s-%s" (time_part now) (entropy_hex entropy)
;;

(* 16 bytes from the OS entropy source where one exists. The fallback is weaker
   but keeps the id mintable anywhere; the guarantee needed is collision
   resistance across actors, not unpredictability. *)
let random_entropy () : string =
  let n = 16 in
  let from_urandom () =
    let ic = open_in_bin "/dev/urandom" in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> really_input_string ic n)
  in
  try from_urandom () with
  | _ ->
    Random.self_init ();
    String.init n (fun _ -> Char.chr (Random.int 256))
;;

let to_string (t : t) = t
let is_digit c = c >= '0' && c <= '9'
let is_lower_hex c = is_digit c || (c >= 'a' && c <= 'f')

let all_between s lo hi p =
  let ok = ref true in
  for i = lo to hi do
    if not (p s.[i]) then ok := false
  done;
  !ok
;;

(* [d-YYYYMMDDtHHMMSSz-<16 hex>]: 2 + 16 + 1 + 16 = 35. *)
let of_string s =
  let expected = "d-<YYYYMMDDtHHMMSSz>-<16 lowercase hex>" in
  let bad () =
    Error (Printf.sprintf "%S is not a deployment id (expected %s)" s expected)
  in
  if String.length s <> 35
  then bad ()
  else if String.sub s 0 2 <> "d-"
  then bad ()
  else if s.[10] <> 't' || s.[17] <> 'z' || s.[18] <> '-'
  then bad ()
  else if not (all_between s 2 9 is_digit)
  then bad ()
  else if not (all_between s 11 16 is_digit)
  then bad ()
  else if not (all_between s 19 34 is_lower_hex)
  then bad ()
  else Ok s
;;
