# FEAT-101 / DEC-049: the migration runner published with a Sol release. It is
# that release's own binary -- the one in the release archive -- so the runner
# and the CLI that selects it are the same build. The build context holds only
# `sol`.
FROM ubuntu:24.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 libgmp10 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY sol /usr/local/bin/sol
ENTRYPOINT ["/usr/local/bin/sol"]
