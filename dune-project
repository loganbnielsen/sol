(lang dune 3.0)

;; The framework's .opam files are HAND-WRITTEN, not generated (DEC-025).
;;
;; Dune's generator cannot express `pin-depends` (verified: "Unknown field
;; pin-depends"), and four of the framework's dependencies -- obs-loki-eio,
;; obs-tempo-eio, pg-eio, lambda-eio -- are not yet in the public
;; opam-repository. Their pins are part of the packages' actual dependency
;; contract, so the source of truth has to be able to state them. A generated
;; file that silently under-describes the real graph is worse than a maintained
;; one; RELEASE-005 removes the pin-depends entries when those packages are
;; published.
(generate_opam_files false)

;; ── Framework packages (DEC-025) ─────────────────────────────────────────────
;;
;; Supported application-facing API: sol-svc, sol-worker, sol-fn, sol-jobs,
;; sol-obs, kafka-eio-service.
;;
;; Installable internal framework packages: sol-runtime, sol-env. These are
;; shared plumbing that public framework libraries link against, so they must be
;; installed and resolvable -- but they are NOT supported for direct application
;; use. "Internal" here means "not part of the supported API", not "not
;; installed": Dune's no-public_name libraries implement the latter literally,
;; which cannot work for a shared library consumed by sibling packages.
;;
;; All framework packages ride ONE coordinated release train (DEC-025): their
;; versions move together, and consumers should never select sol-runtime/sol-env
;; independently -- opam pulls the matching version transitively.
;;
;; The public library names are hyphenated (sol-svc, kafka-eio-service, ...).
;; The underscore spellings (sol_svc, kafka_eio_service, ...) are monorepo-internal
;; Dune library names and are not the external identity.

(package
 (name kafka-eio-service)
 (synopsis
  "Sol's Kafka policy layer: schema-registry ordering/fatality, explicit topic provisioning, Confluent wire format, decode/retry/crash routing")
 (depends
  (ocaml (>= 5.4.0))
  (dune (>= 3.0))
  cstruct
  eio
  http
  https-eio
  kafka-eio
  obs-eio
  uri
  yojson))

(package
 (name sol-env)
 (synopsis
  "Internal: Sol's environment/config plumbing. Not part of the supported application API")
 (depends
  (ocaml (>= 5.4.0))
  (dune (>= 3.0))
  eio))

(package
 (name sol-runtime)
 (synopsis
  "Internal: Sol's shared runtime plumbing. Not part of the supported application API")
 (depends
  (ocaml (>= 5.4.0))
  (dune (>= 3.0))
  eio))

(package
 (name sol-obs)
 (synopsis
  "Sol's observability conventions: metric names, label vocabularies, Loki push shape, W3C traceparent propagation")
 (depends
  (ocaml (>= 5.4.0))
  (dune (>= 3.0))
  eio
  obs-eio
  obs-loki-eio
  obs-prometheus-eio
  obs-tempo-eio))

(package
 (name sol-fn)
 (synopsis "Sol's scheduled-function application shape")
 (depends
  (ocaml (>= 5.4.0))
  (dune (>= 3.0))
  eio
  lambda-eio
  obs-eio
  obs-prometheus-eio
  sol-env
  sol-obs
  sol-runtime))

(package
 (name sol-jobs)
 (synopsis "Sol's background-job application shape")
 (depends
  (ocaml (>= 5.4.0))
  (dune (>= 3.0))
  caqti
  eio
  obs-eio
  obs-prometheus-eio
  pg-eio
  sol-env
  sol-obs
  sol-runtime))

(package
 (name sol-svc)
 (synopsis "Sol's HTTP service application shape")
 (depends
  (ocaml (>= 5.4.0))
  (dune (>= 3.0))
  base64
  cohttp-eio
  eio
  http
  https-eio
  jose
  obs-eio
  ptime
  sol-obs
  sol-runtime
  uri
  yojson))

(package
 (name sol-worker)
 (synopsis "Sol's Kafka worker application shape")
 (depends
  (ocaml (>= 5.4.0))
  (dune (>= 3.0))
  eio
  kafka-eio
  kafka-eio-service
  obs-eio
  obs-prometheus-eio
  sol-env
  sol-obs
  sol-runtime))

;; ── The CLI and everything else in this repository ───────────────────────────
;; Not a framework package. FEAT-085 removes the example workspaces from this
;; Dune project, at which point much of the depends list below becomes unnecessary
;; for this package.

(package
 (name sol)
 (allow_empty)
 (synopsis "Sol — open-source OCaml software factory for backend systems")
 (depends
  (ocaml (>= 5.4.0))
  (dune  (>= 3.0))
  eio
  eio_main
  cohttp-eio
  http
  yojson
  cmdliner
  base64
  uri
  cstruct
  kafka-eio
  obs-eio
  obs-loki-eio
  obs-prometheus-eio
  obs-tempo-eio
  https-eio
  mtime
  caqti-eio
  caqti-driver-postgresql
  pg-eio
  digestif
  aws-eio
  s3-eio
  dynamodb-eio
  lambda-eio
  otoml
  jose
  ptime
  (alcotest :with-test)
  (mirage-crypto-pk :with-test)
  (mirage-crypto-rng :with-test)))
