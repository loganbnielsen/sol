module Topic_name : sig
  type t

  val of_string : string -> (t, string) result
  val to_string : t -> string
end = struct
  type t = string

  let valid_char c =
    (c >= 'a' && c <= 'z')
    || (c >= 'A' && c <= 'Z')
    || (c >= '0' && c <= '9')
    || c = '-'
    || c = '_'
    || c = '.'
  ;;

  let of_string s =
    if String.length s = 0
    then Error "topic name must not be empty"
    else if String.length s > 249
    then
      Error
        (Printf.sprintf "topic name too long (%d chars, max 249): %S" (String.length s) s)
    else (
      match String.to_seq s |> Seq.find (fun c -> not (valid_char c)) with
      | Some bad ->
        Error (Printf.sprintf "topic name contains invalid character %C: %S" bad s)
      | None -> Ok s)
  ;;

  let to_string t = t
end

module Migration_file : sig
  type t

  val of_string : string -> (t, string) result
  val to_string : t -> string
end = struct
  type t = string

  let of_string s =
    if String.length s = 0
    then Error "migration filename must not be empty"
    else if not (Filename.check_suffix s ".sql")
    then Error (Printf.sprintf "migration file must end in .sql: %S" s)
    else Ok s
  ;;

  let to_string t = t
end

module Schema_subject : sig
  type t

  val of_string : string -> (t, string) result
  val to_string : t -> string
end = struct
  type t = string

  let of_string s =
    if String.length s = 0 then Error "schema subject must not be empty" else Ok s
  ;;

  let to_string t = t
end

module Consumer_group : sig
  type t

  val of_string : string -> (t, string) result
  val to_string : t -> string
end = struct
  type t = string

  let of_string s =
    if String.length s = 0 then Error "consumer group must not be empty" else Ok s
  ;;

  let to_string t = t
end
