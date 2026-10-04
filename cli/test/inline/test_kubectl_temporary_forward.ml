let free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
       Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
       match Unix.getsockname socket with
       | Unix.ADDR_INET (_, port) -> port
       | Unix.ADDR_UNIX _ -> 0)
;;

let listening_socket port =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt socket Unix.SO_REUSEADDR true;
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
  Unix.listen socket 1;
  socket
;;

let with_fake_kubectl ~script f =
  let dir = Filename.temp_file "sol-fake-kubectl" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let path = Filename.concat dir "kubectl" in
  let channel = open_out path in
  output_string channel script;
  close_out channel;
  Unix.chmod path 0o755;
  let saved = Sys.getenv_opt "PATH" in
  Unix.putenv "PATH" (dir ^ ":" ^ Option.value saved ~default:"");
  Fun.protect f ~finally:(fun () ->
    Unix.putenv "PATH" (Option.value saved ~default:"");
    Sys.remove path;
    Unix.rmdir dir)
;;

let forward ~port =
  Sol_cli_kubectl.temporary_port_forward
    ~ctx:Sol_cli_kube_destination.local_context
    ~service:"redpanda"
    ~namespace:"redpanda"
    ~local_port:port
    ~remote_port:8081
;;

let explains ~needle = function
  | Ok () -> false
  | Error (Sol_cli_kubectl.Readiness_check_failed message) ->
    Sol_cli_string.contains ~needle message
  | Error (Sol_cli_kubectl.Not_started _) | Error Sol_cli_kubectl.Not_ready -> false
;;

let check ~what ~needle result =
  if not (explains ~needle result)
  then Windtrap.fail (what ^ ": expected an error naming " ^ needle)
;;

let%test "an unrelated listener on the requested port is refused, never adopted" =
  let port = free_port () in
  let socket = listening_socket port in
  let result =
    with_fake_kubectl ~script:"#!/bin/sh\nexit 1\n" (fun () -> forward ~port)
  in
  Unix.close socket;
  check ~what:"an unrelated listener" ~needle:"already listening" result
;;

let%test "a forward whose process exits is not reported ready" =
  let port = free_port () in
  let result =
    with_fake_kubectl ~script:"#!/bin/sh\nexit 1\n" (fun () -> forward ~port)
  in
  check ~what:"a dead forward" ~needle:"exited before" result
;;

let%test "a live forward that owns the port is ready" =
  let port = free_port () in
  let script =
    Printf.sprintf
      "#!/bin/sh\n\
       python3 -c \"import socket,time; s=socket.socket(); \
       s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', \
       %d)); s.listen(1); time.sleep(30)\"\n"
      port
  in
  match with_fake_kubectl ~script (fun () -> forward ~port) with
  | Ok () -> ()
  | Error _ -> Windtrap.fail "a live forward that owns the port must be ready"
;;
