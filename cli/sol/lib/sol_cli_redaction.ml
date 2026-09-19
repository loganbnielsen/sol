let replace_all ~needle ~replacement text =
  if needle = ""
  then text
  else (
    let needle_len = String.length needle in
    let text_len = String.length text in
    let out = Buffer.create text_len in
    let rec loop offset =
      if offset >= text_len
      then Buffer.contents out
      else
        match String.index_from_opt text offset needle.[0] with
        | None ->
          Buffer.add_substring out text offset (text_len - offset);
          Buffer.contents out
        | Some index ->
          if index + needle_len <= text_len
             && String.sub text index needle_len = needle
          then (
            Buffer.add_substring out text offset (index - offset);
            Buffer.add_string out replacement;
            loop (index + needle_len))
          else (
            Buffer.add_substring out text offset (index - offset + 1);
            loop (index + 1))
    in
    loop 0)
;;

let password_span url =
  match String.index_opt url ':' with
  | None -> None
  | Some scheme_colon ->
    let authority_start = scheme_colon + 3 in
    if authority_start > String.length url
       || String.sub url (scheme_colon + 1) (min 2 (String.length url - scheme_colon - 1))
          <> "//"
    then None
    else (
      match String.index_from_opt url authority_start '@' with
      | None -> None
      | Some at ->
        (match String.index_from_opt url authority_start ':' with
         | Some password_colon when password_colon < at && password_colon + 1 < at ->
           Some (password_colon + 1, at)
         | _ -> None))
;;

let connection_error ~url text =
  match password_span url with
  | None -> text
  | Some (password_start, password_end) ->
    let password = String.sub url password_start (password_end - password_start) in
    (* Replace the credential value, not just the complete URI.  libpq/caqti may
       wrap or normalize the URL before reporting it; the secret itself is the
       invariant that must never cross stderr or a Job-log boundary. *)
    replace_all ~needle:password ~replacement:"<redacted>" text
;;
