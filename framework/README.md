# Framework

First-party implementations of Sol's [application contract](../contract/).

- [`ocaml/`](ocaml/) — the OCaml framework packages (`sol-svc`, `sol-worker`,
  `sol-fn`, `sol-jobs`, `sol-obs`, plus the internal `sol-runtime`/`sol-env`
  plumbing and `kafka-eio-service`). These are the supported application-facing
  API; each package's `.md` next to its `lib/` is its spec.
- **TypeScript** — not in this repository. The TypeScript framework is published
  as the `@sol-fab/kafka` and `@sol-fab/obs` npm packages from their own public
  repositories, using the same extraction pattern as the OCaml `*-eio` packages.
  Sol hosts the TypeScript *scaffold templates* and the
  [`demo_ts`](../examples/pluto/app/demo_ts/README.md) showcase, but not the
  framework implementation. A `framework/typescript/` directory would be empty
  today, so it does not exist.

The framework packages are consumed exactly like any other OPAM packages. Their
contracts are the `.opam` files at the repository root (see
[`../dune-project`](../dune-project), DEC-025); a workspace installed through
`opam` needs no enclosing Sol checkout.
