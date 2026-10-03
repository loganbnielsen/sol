sol_provider_rows() {
  local root="$1"
  if [ -n "${SOL_PROVIDERS:-}" ]; then
    printf '%s\n' "$SOL_PROVIDERS"
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

provider_rows_parse() {
  local rows="$1" line name status count=0
  PROVIDER_NAMES=()
  PROVIDER_STATUSES=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *$'\t'*) ;;
      *) return 1 ;;
    esac
    name="${line%%$'\t'*}"
    status="${line#*$'\t'}"
    case "$name" in
      '' | *' '*) return 1 ;;
    esac
    case "$status" in
      present | not_applicable | not_implemented) ;;
      *) return 1 ;;
    esac
    case " ${PROVIDER_NAMES[*]} " in
      *" $name "*) return 1 ;;
    esac
    PROVIDER_NAMES+=("$name")
    PROVIDER_STATUSES+=("$status")
    count=$((count + 1))
  done <<<"$rows"
  [ "$count" -gt 0 ]
}

provider_registered() {
  case " ${PROVIDER_NAMES[*]} " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

provider_root_status() {
  local i
  for i in "${!PROVIDER_NAMES[@]}"; do
    if [ "${PROVIDER_NAMES[$i]}" = "$1" ]; then
      PROVIDER_ROOT_STATUS="${PROVIDER_STATUSES[$i]}"
      return 0
    fi
  done
  return 1
}
