# Contract

Sol's language-neutral application contract: what any application must do to be
a valid Sol workload, independent of whether it is written in OCaml or
TypeScript. The framework implementations live in [`../framework/`](../framework/);
this directory is the product-level definition both of them target.

| Concept | Where the contract is defined |
| --- | --- |
| Project/workspace declarations (`sol.yml`, `sol.toml`) | `cli/lib/sol_cli_config.ml`, `cli/lib/sol_cli_manifest*.ml` |
| Container build + discovery (`app/<domain>/<name>_{svc,worker,fn}/` + `Dockerfile`) | [`runtime.md`](runtime.md) |
| `PORT`, `GET /healthz`, `GET /metrics`, `SIGTERM`/drain | [`runtime.md`](runtime.md) |
| `-svc` / `-worker` / `-fn` runtime expectations | [`runtime.md`](runtime.md) |
| Substrate Sol assumes around the container (cluster, registry, Kafka, secrets, DNS) | [`substrate.md`](substrate.md) |
| Generated vs user-authored artifacts | [`substrate.md`](substrate.md) |

- [`runtime.md`](runtime.md) — the runtime contract *inside* a container.
- [`substrate.md`](substrate.md) — the substrate contract *around* a container.

The authoritative text for each row above is the linked document or source
file; this directory organizes them as one concept and does not keep a second
copy. Framework-level details (service lifecycles, observability facades,
Kafka policy) live with the package that owns them under
[`../framework/ocaml/`](../framework/ocaml/).
