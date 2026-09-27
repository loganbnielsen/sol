let routes = [
  Route.get "/health" ~auth:`Public (fun _req ->
    Response.ok "ok"
  );
]
