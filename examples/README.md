# Examples

Runnable applications that teach the Sol product, not test fixtures.

- [`pluto/`](pluto/) — the canonical reference application. One workspace with
  OCaml `-svc`/`-worker` services and the TypeScript `demo_ts` pair, deployable
  to `sol local` and to a real cloud target (`sol/` targets for `dev`, `pilot`,
  `prod`, and a customer-cloud shape). Start here.

Test fixtures that are not meant to teach product usage live under
[`../internal/fixtures/`](../internal/fixtures/) instead — currently the
OCaml-only worker workspace and the e2e demo library. Anything added to
`examples/` should answer a user question; nothing here exists only because a
test needed a different shape.
