sol_providers() {
  local root="$1"
  if [ -n "${SOL_PROVIDERS:-}" ]; then
    printf '%s\n' $SOL_PROVIDERS
    return 0
  fi
  local printer="$root/_build/default/cli/test/print_providers.exe"
  if [ ! -x "$printer" ]; then
    echo "sol_providers: $printer is not built; run \`dune build\` first" >&2
    return 1
  fi
  local out
  out="$("$printer")" || return 1
  if [ -z "$out" ]; then
    echo "sol_providers: the provider printer printed nothing" >&2
    return 1
  fi
  printf '%s\n' "$out"
}
