FROM ubuntu:24.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 libgmp10 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY sol /usr/local/bin/sol
ENTRYPOINT ["/usr/local/bin/sol"]
