type level = Obs_eio.level = Debug | Info | Warn | Error
type span = Obs_eio.span

type t = {
  ot       : Obs_eio.t;
  backend  : Obs_eio.backend;
  renderer : unit -> string;
}

let env_nonempty name =
  match Sys.getenv_opt name with
  | Some value when value <> "" -> Some value
  | _ -> None

let of_env ~net ~clock ~mono_clock ~service ?(context = []) () =
  let log_backend =
    match env_nonempty "LOKI_URL" with
    | None -> Obs_eio.stdout
    | Some url ->
      let label_names = List.map (fun (k, _) -> Obs_loki.stream_label_exn k) context in
      Obs_loki.create ~net ~clock ~url ~label_names ()
  in
  let prom_backend, renderer = Obs_prometheus.create () in
  let backend = Obs_eio.compose log_backend prom_backend in
  let backend =
    match env_nonempty "TEMPO_URL" with
    | None -> backend
    | Some url -> Obs_eio.compose backend (Obs_tempo.create ~net ~clock ~url ())
  in
  let ot = Obs_eio.create ~service ~mono_clock ~backend () in
  let ot = match context with [] -> ot | fields -> Obs_eio.with_context ot fields in
  { ot; backend; renderer }

let log_debug t ?fields msg = Obs_eio.log_standalone t.ot Debug ?fields msg
let log_info  t ?fields msg = Obs_eio.log_standalone t.ot Info ?fields msg
let log_warn  t ?fields msg = Obs_eio.log_standalone t.ot Warn ?fields msg
let log_error t ?fields msg = Obs_eio.log_standalone t.ot Error ?fields msg

let with_span t ?parent name f = Obs_eio.with_span t.ot ?parent name f
let log = Obs_eio.log
let current_trace_context = Obs_eio.current_trace_context

let trace_id_string (ctx : Obs_trace.t) =
  let hi, lo = ctx.trace_id in
  Printf.sprintf "%016Lx%016Lx" hi lo

let counter t ~name ~help ~label_names = Obs_eio.register_counter t.ot ~name ~help ~label_names
let gauge t ~name ~help ~label_names = Obs_eio.register_gauge t.ot ~name ~help ~label_names
let histogram t ~name ~help ~label_names = Obs_eio.register_histogram t.ot ~name ~help ~label_names

let with_context t fields = { t with ot = Obs_eio.with_context t.ot fields }

let obs_eio t = t.ot
let metrics_renderer t = t.renderer
let backend_and_renderer t = (t.backend, t.renderer)
