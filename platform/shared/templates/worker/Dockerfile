# Stage 1: compile inside ubuntu-24.04 so the binary links against glibc 2.39.
# Dependencies are NOT listed in this file. The image reproduces the environment
# the workspace declares in {{basename}}.opam -- `opam install . --deps-only` -- so the
# workspace owns its dependency choices (including which framework channel it
# tracks) and the build merely reconstructs them. Framework packages carry their
# own pin-depends for anything not yet in the public opam-repository (DEC-025), so
# no Sol repository needs to appear in a generated Dockerfile.
FROM ocaml/opam:ubuntu-24.04-ocaml-5.4 AS build
RUN sudo apt-get update && sudo apt-get install -y \
    librdkafka-dev libpq-dev libssl-dev libgmp-dev pkg-config && \
    sudo rm -rf /var/lib/apt/lists/*
# `opam repository set-url` first: the ocaml/opam base image's default remote is a
# local git+file:// checkout frozen at whatever opam-repository snapshot existed
# when the image was built, which can predate a version a dependency requires
# (observed: https-eio needing tls-eio >= 2.1.0, unsatisfiable against the frozen
# snapshot even after `opam update`). Pointing at the real opam.ocaml.org resolves
# it. CI does not hit this -- ocaml/setup-ocaml initializes a fresh index.
RUN opam repository set-url default https://opam.ocaml.org && opam update
# Only the dependency declaration is copied before installing, so the dependency
# layer is cached independently of workspace source changes.
COPY --chown=opam:opam {{basename}}.opam /workspace/
WORKDIR /workspace
RUN opam install -y --no-self-upgrade --deps-only .
COPY --chown=opam:opam . /workspace
WORKDIR /workspace
RUN opam exec -- dune build {{repo_dir}}/bin/main.exe

# Stage 2: minimal runtime image
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y librdkafka1 libpq5 ca-certificates && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /workspace/_build/default/{{repo_dir}}/bin/main.exe /usr/local/bin/{{binary}}
# Run as nobody (uid 65534) — matches securityContext in generated k8s manifests
USER 65534
CMD ["/usr/local/bin/{{binary}}"]
