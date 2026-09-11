FROM ocaml/opam:ubuntu-24.04-ocaml-5.4 AS build
RUN sudo apt-get update && sudo apt-get install -y librdkafka-dev libpq-dev libssl-dev
RUN opam repository set-url default https://opam.ocaml.org && \
    opam update && \
    opam pin add https-eio https://github.com/loganbnielsen/https-eio.git#main -y && \
    opam pin add kafka-eio https://github.com/loganbnielsen/kafka-eio.git#main -y && \
    opam pin add obs-eio https://github.com/loganbnielsen/obs-eio.git#main -y && \
    opam pin add obs-loki-eio https://github.com/loganbnielsen/obs-loki-eio.git#main -y && \
    opam pin add obs-prometheus-eio https://github.com/loganbnielsen/obs-prometheus-eio.git#main -y && \
    opam pin add obs-tempo-eio https://github.com/loganbnielsen/obs-tempo-eio.git#main -y && \
    opam pin add pg-eio https://github.com/loganbnielsen/pg-eio.git#main -y
RUN opam install -y --no-self-upgrade \
    eio eio_main cohttp-eio http yojson cmdliner base64 uri cstruct mtime \
    tls-eio x509 domain-name ptime otoml jose \
    caqti-eio caqti-driver-postgresql
COPY --chown=opam:opam . /workspace
WORKDIR /workspace
RUN opam exec -- dune build examples/pluto/app/checkout/checkout_svc/bin/main.exe

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y librdkafka1 libpq5 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /workspace/_build/default/examples/pluto/app/checkout/checkout_svc/bin/main.exe /usr/local/bin/pluto-checkout-svc
USER 65534
CMD ["/usr/local/bin/pluto-checkout-svc"]
