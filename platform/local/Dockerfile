# Multi-stage build for sol-demo.
# Stage 1: build the OCaml binary
FROM ocaml/opam:ubuntu-24.04-ocaml-5.2 AS builder

WORKDIR /app
RUN sudo apt-get update && sudo apt-get install -y librdkafka-dev
RUN opam install -y eio eio_main caqti caqti-eio caqti-driver-postgresql cohttp-eio yojson base64

COPY dune-project dune-workspace ./
COPY integrations/kafka/ ./kafka/
COPY primitives/ ./primitives/
COPY examples/demo/ ./examples/demo/

# Build demo
RUN eval $(opam env) && dune build examples/demo/bin/demo.exe

# Stage 2: minimal runtime image
FROM ubuntu:24.04 AS runtime

RUN apt-get update && apt-get install -y librdkafka1 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/_build/default/examples/demo/bin/demo.exe /usr/local/bin/sol-demo

ENTRYPOINT ["/usr/local/bin/sol-demo"]
