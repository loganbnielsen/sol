# Stage 1: compile inside ubuntu-24.04 so the binary links against glibc 2.39.
FROM ocaml/opam:ubuntu-24.04-ocaml-5.4 AS build
RUN sudo apt-get update && sudo apt-get install -y librdkafka-dev libpq-dev libssl-dev
# obs-eio/obs-loki-eio/obs-prometheus-eio/obs-tempo-eio/pg-eio/https-eio/
# kafka-eio are extracted opam packages, not yet published to the public
# opam-repository -- matches the pin this repo's own
# .github/actions/pin-opam-packages/action.yml uses (and what the current
# `sol new` scaffold template generates, cli/sol/lib/sol_cli_scaffold_templates.ml).
# `opam repository set-url` first: the base image's default remote is a
# local git+file:// checkout frozen at whatever opam-repository snapshot
# existed when the image was built, which can predate a version https-eio's
# #main branch now requires. Pin before the plain `opam install` below --
# pinning https-eio after a plain install already resolved a lower
# dependency fails, since a pin alone doesn't upgrade an already-installed
# package's already-installed dependencies.
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
RUN opam exec -- dune build examples/venus/app/comms/notify_worker/bin/main.exe

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y librdkafka1 libpq5 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /workspace/_build/default/examples/venus/app/comms/notify_worker/bin/main.exe /usr/local/bin/venus-notify-worker
USER 65534
CMD ["/usr/local/bin/venus-notify-worker"]
