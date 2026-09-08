---
id: AUDIT-026
type: audit-finding
severity: medium
source: project/audits/2026-06-11_audit.md
branch: AUDIT-026/multi-stage-dockerfile
worktree: ../sun-AUDIT-026-multi-stage-dockerfile
---

Generated Dockerfiles copy host-compiled binaries (non-hermetic build)

**Depends on:** None.

**Description:** All generated and reference Dockerfiles copy a pre-compiled binary from `_build/default/` into an Ubuntu 24.04 base image (`cli/sun/lib/sun_cli_cmd_new.ml` scaffold template; `examples/venus/` and `examples/pluto/` Dockerfiles). If the host OCaml toolchain links against a different glibc version than ubuntu:24.04 (currently glibc 2.39), the binary will crash at startup with "GLIBC_X.XX not found".

**Impact:** Images that build successfully on the developer's machine may fail to start in production or on a different CI host. This is a silent runtime failure.

**Remediation:** Replace the generated Dockerfile template with a multi-stage build:
```dockerfile
FROM ocaml/opam:ubuntu-24.04-ocaml-5.4.1 AS build
RUN sudo apt-get install -y librdkafka-dev libpq-dev
COPY . /workspace
WORKDIR /workspace
RUN opam exec -- dune build <service>/bin/main.exe

FROM ubuntu:24.04
RUN apt-get install -y librdkafka1 libpq5 ca-certificates
COPY --from=build /workspace/_build/default/<service>/bin/main.exe /usr/local/bin/<svc>
CMD ["/usr/local/bin/<svc>"]
```
Update scaffold template, examples, and the Dockerfile generation in `sun up`.

**Review notes (2026-06-12, fail):** Scaffold template and `cmd_up.ml` were correctly updated. Four example Dockerfiles were NOT updated and must be converted to multi-stage builds before this ticket can pass:
- `examples/pluto/app/payments/charge_svc/Dockerfile`
- `examples/pluto/app/comms/notify_worker/Dockerfile`
- `examples/venus/app/logistics/fulfillment_worker/Dockerfile`
- `examples/venus/app/comms/notify_worker/Dockerfile`

All four still use the old single-stage pattern (`FROM ubuntu:24.04` + `COPY _build/...`) and are missing `USER 65534`.
