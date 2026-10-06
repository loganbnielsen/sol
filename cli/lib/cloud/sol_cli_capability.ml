(* Provider-neutral arbitration of "can this identity do X?" answers.

   The bootstrap window's capability questions and the de-escalation comparison
   are pure functions of `kubectl auth can-i` answers: they carry no provider or
   lifecycle state, so both the lifecycle module and each provider's window
   observer can share them. Keeping them here (rather than in the lifecycle
   module, which depends on the provider-capability registry) lets provider
   cluster modules use them without a module cycle. *)

type deescalation_principal =
  | Principal_confirmed of string
  | Principal_refused_by_cluster of string
  | Principal_probe_failed of string
  | Principal_unexpected of string

type deescalation_verdict =
  | Deescalated
  | Still_elevated of string list
  | Undetermined of string

type capability_answer =
  | Permitted
  | Denied
  | Indeterminate of string

let first_token text =
  let text = String.trim text in
  let line_end =
    match String.index_opt text '\n' with
    | Some i -> i
    | None -> String.length text
  in
  let rec scan i =
    if i >= line_end
    then i
    else (
      match text.[i] with
      | ' ' | '\t' | '\r' -> i
      | _ -> scan (i + 1))
  in
  String.sub text 0 (scan 0)
;;

let capability_answer_of_can_i_output ~exit_code ~stdout ~stderr =
  let describe () =
    let text = String.trim (stderr ^ " " ^ stdout) in
    if String.equal text ""
    then Printf.sprintf "kubectl exited %d with no output" exit_code
    else Printf.sprintf "kubectl exited %d (%s)" exit_code text
  in
  match first_token stdout with
  | "yes" when exit_code = 0 -> Permitted
  | "no" when exit_code = 1 -> Denied
  | "yes" | "no" ->
    Indeterminate
      (Printf.sprintf
         "kubectl answered %S but exited %d; a mismatch is not an answer"
         (first_token stdout)
         exit_code)
  | _ -> Indeterminate (describe ())
;;

type capability =
  { verb : string
  ; resource : string
  }

let capability_label { verb; resource } = Printf.sprintf "%s %s" verb resource

let answer_is_permitted = function
  | Permitted -> true
  | Denied | Indeterminate _ -> false
;;

let indeterminate_reason (capability, answer) =
  match answer with
  | Indeterminate why -> Some (capability_label capability, why)
  | Permitted | Denied -> None
;;

let permitted_capabilities probes =
  probes
  |> List.filter_map (fun (capability, answer) ->
    if answer_is_permitted answer then Some capability else None)
;;

let still_permitted probes = List.map capability_label (permitted_capabilities probes)

let deescalation_verdict
      ~(principal : deescalation_principal)
      (probes : (capability * capability_answer) list)
  : deescalation_verdict
  =
  match principal with
  | Principal_unexpected who ->
    Undetermined
      (Printf.sprintf
         "the probe answered as %s, not the principal whose elevation was removed"
         who)
  | Principal_probe_failed why -> Undetermined why
  | Principal_refused_by_cluster _why -> Deescalated
  | Principal_confirmed _ ->
    let still = still_permitted probes in
    if still <> []
    then Still_elevated still
    else (
      match List.find_map indeterminate_reason probes with
      | Some (capability, why) ->
        Undetermined
          (Printf.sprintf
             "the capability probe for %s obtained no usable answer (%s), so the \
              effective surface is not established"
             capability
             why)
      | None ->
        if probes = []
        then Undetermined "no capability probe produced an answer"
        else Deescalated)
;;

let successor_authority (successor : (capability * capability_answer) list) =
  let unmet =
    successor
    |> List.filter_map (fun (capability, answer) ->
      match answer with
      | Permitted -> None
      | Denied -> Some (Printf.sprintf "%s is denied" (capability_label capability))
      | Indeterminate why ->
        Some
          (Printf.sprintf
             "%s obtained no usable answer (%s)"
             (capability_label capability)
             why))
  in
  if successor = []
  then
    Error
      "no successor capability was probed, so the successor's authority is not \
       established"
  else if unmet <> []
  then Error (String.concat "; " unmet)
  else Ok ()
;;

let deescalation_transition
      ~(before : (capability * capability_answer) list)
      ~after_principal
      ~(after : (capability * capability_answer) list)
  =
  match after_principal with
  | Principal_unexpected who ->
    Undetermined
      (Printf.sprintf
         "the principal answering after de-escalation was %s, not the one observed \
          during the window; the transition is not established"
         who)
  | Principal_probe_failed why ->
    Undetermined ("the post-de-escalation probe obtained no evidence: " ^ why)
  | Principal_refused_by_cluster _ -> Deescalated
  | Principal_confirmed _ ->
    let still = still_permitted after in
    if still <> []
    then Still_elevated still
    else (
      match List.find_map indeterminate_reason after with
      | Some (capability, why) ->
        Undetermined
          (Printf.sprintf
             "the capability probe for %s obtained no usable answer after de-escalation \
              (%s), so removal is not established"
             capability
             why)
      | None ->
        let before_permitted = permitted_capabilities before in
        let uncovered =
          before_permitted
          |> List.filter (fun capability -> not (List.mem_assoc capability after))
        in
        if uncovered <> []
        then
          Undetermined
            (Printf.sprintf
               "the post-de-escalation probe did not cover %s, so its removal is not \
                established"
               (String.concat ", " (List.map capability_label uncovered)))
        else (
          match List.find_map indeterminate_reason before with
          | Some (capability, why) ->
            Undetermined
              (Printf.sprintf
                 "the bootstrap window probe for %s obtained no usable answer (%s), so \
                  its later removal cannot be demonstrated"
                 capability
                 why)
          | None ->
            if before_permitted = []
            then
              Undetermined
                "the bootstrap-only capabilities were never observed permitted, so no \
                 removal can be demonstrated"
            else Deescalated))
;;

let deescalation_verdict_to_string = function
  | Deescalated ->
    "de-escalated: the effective surface no longer permits bootstrap capabilities"
  | Still_elevated capabilities ->
    Printf.sprintf
      "still elevated: the de-escalated identity is still permitted %s"
      (String.concat ", " capabilities)
  | Undetermined why -> Printf.sprintf "undetermined: %s" why
;;
