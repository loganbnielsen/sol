# Homemade Code Audit — Eio/native package replacement candidates

Date: 2026-06-12

Scope: identify code paths where Sun hand-rolls protocol parsing, byte
management, URL parsing, config parsing, or raw socket I/O even though a
maintained Eio-compatible library or existing project dependency can own the
behavior.

## Findings

1. `integrations/kafka/kafka-eio-service/lib/kafka_service.ml` contains a
   custom HTTP/1.1 client for schema registry and Redpanda admin requests. It
   manually parses URLs, writes request lines, parses headers, decodes chunked
   transfer bodies, and now wires TLS setup directly. `cohttp-eio` and `uri`
   are already project dependencies and should own this.

2. `integrations/observability/obs-eio-loki/lib/obs_loki.ml` contains a custom
   Loki HTTP client and hand-built JSON payload strings. HTTP should be handled
   by `cohttp-eio`/`uri`; JSON should be built with `Yojson.Safe`.

3. `integrations/observability/obs-eio-prometheus/lib/obs_prometheus.ml`
   contains a custom Pushgateway HTTP client and URL parser. `cohttp-eio` and
   `uri` should own request construction and URL parsing.

4. `cli/sun/lib/sun_cli_toml.ml` is an ad hoc TOML parser using `String.sub`,
   delimiter scanning, and line-by-line parsing. It silently ignores malformed
   input in many cases and only supports inline tables. Replace it with a
   maintained TOML parser such as `otoml` or `toml`.

5. `integrations/kafka/kafka-eio-service/lib/kafka_service.ml` encodes and
   decodes Confluent wire-format messages with manual `Bytes.get`/`Bytes.set`
   and bit shifts. This code is small but brittle; move it behind a dedicated
   codec using `cstruct` big-endian helpers or another maintained binary buffer
   abstraction already suitable for OCaml.

6. Several tests include raw HTTP clients/servers and copied protocol parsing
   helpers. Tests should exercise the same production HTTP stack where possible
   and use `cohttp-eio` test servers/clients instead of duplicating parsers.

## Non-finding

The librdkafka C stubs are low-level and deserve continued scrutiny, but they
wrap a C library without an obvious Eio-native replacement currently used by
the project. Do not replace them as part of this audit unless a maintained
OCaml Kafka client with the required producer, consumer, transactions, and
security support is selected explicitly.
