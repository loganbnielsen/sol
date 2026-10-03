stray_terraform_state() {
  local root="$1" marker="$2" strays
  if ! strays="$(
    find "$root" -newer "$marker" \
      \( -name .terraform -o -name '*.tfstate' -o -name errored.tfstate \) -print
  )"; then
    printf 'stray_terraform_state: could not scan %s\n' "$root" >&2
    return 1
  fi
  [ -n "$strays" ] || return 0
  printf '%s\n' "$strays"
}
