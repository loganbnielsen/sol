# Stage 1: compile inside ubuntu-24.04 so the binary links against glibc 2.39.
#
# Dependencies are NOT listed in this file. The image reproduces the environment
# this workspace declares in pluto.opam -- "opam install . --deps-only" -- so the
# workspace owns its dependency choices, including which framework channel it
# tracks, and the build merely reconstructs them (DEC-025). The build context is
# the workspace root, which is exactly what 'sol up' uses.
FROM ocaml/opam:ubuntu-24.04-ocaml-5.4 AS build
RUN sudo apt-get update && sudo apt-get install -y \
    librdkafka-dev libpq-dev libssl-dev libgmp-dev pkg-config && \
    sudo rm -rf /var/lib/apt/lists/*
# The base image's default remote is a local git+file:// checkout frozen at
# whatever opam-repository snapshot existed when the image was built, which can
# predate a version a dependency needs. Point at the real index.
RUN opam repository set-url default https://opam.ocaml.org && opam update
COPY --chown=opam:opam pluto.opam /workspace/
WORKDIR /workspace
RUN opam install -y --no-self-upgrade --deps-only .
COPY --chown=opam:opam . /workspace
RUN opam exec -- dune build app/checkout/checkout_svc/bin/main.exe

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y librdkafka1 libpq5 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /workspace/_build/default/app/checkout/checkout_svc/bin/main.exe /usr/local/bin/pluto-checkout-svc
# Run as nobody (uid 65534) -- matches securityContext in generated k8s manifests
USER 65534
CMD ["/usr/local/bin/pluto-checkout-svc"]
