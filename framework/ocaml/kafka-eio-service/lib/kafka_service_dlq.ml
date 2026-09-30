let hdr_decode_error = "X-Sol-Decode-Error"
let hdr_origin_group = "X-Sol-Origin-Group"

type relay =
  { source : Kafka.Consumer.message
  ; headers : (string * string option) list
  }

let decode_failure_message ~raw_msg ~decode_error ~group_id =
  { source = raw_msg
  ; headers =
      (hdr_decode_error, Some decode_error)
      :: (hdr_origin_group, Some group_id)
      :: raw_msg.Kafka.Consumer.headers
  }
;;

let route_decode_error ~dlq_topic ~raw_msg ~decode_error ~group_id ~publish ~ack =
  Printf.eprintf "sol-worker: DECODE_ERROR to_dlq=true error=%S\n%!" decode_error;
  let open Result.Syntax in
  let* () =
    publish
      ~target_topic:dlq_topic
      (decode_failure_message ~raw_msg ~decode_error ~group_id)
  in
  ack ()
;;

let max_group_segment_len = 64
let group_hash_len = 12

let sanitize_group_id group_id =
  let sanitized =
    String.map
      (function
        | ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-') as c -> c
        | _ -> '-')
      group_id
  in
  if sanitized = "" then "unscoped" else sanitized
;;

let canonical_group_segment group_id =
  let readable = sanitize_group_id group_id in
  let hash = String.sub (Digest.to_hex (Digest.string group_id)) 0 group_hash_len in
  let prefix_len = max_group_segment_len - group_hash_len - 1 in
  let prefix =
    if String.length readable <= prefix_len
    then readable
    else String.sub readable 0 prefix_len
  in
  prefix ^ "-" ^ hash
;;

let dlq_topic_name ~source ~group_id =
  Printf.sprintf "%s.%s.dlq" source (canonical_group_segment group_id)
;;
