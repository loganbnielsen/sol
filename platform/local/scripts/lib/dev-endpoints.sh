#!/usr/bin/env bash

dev_has_ipv6_loopback() {
  if [ -r /proc/net/if_inet6 ]; then
    grep -q '^00000000000000000000000000000001 ' /proc/net/if_inet6
  else
    ifconfig lo0 2>/dev/null | grep -q 'inet6 ::1'
  fi
}

dev_publish_ports() {
  DEV_PUBLISH_ARGS=()
  local mapping host_port container_port
  for mapping in "$@"; do
    host_port="${mapping%%:*}"
    container_port="${mapping##*:}"
    DEV_PUBLISH_ARGS+=(-p "127.0.0.1:${host_port}:${container_port}")
    if dev_has_ipv6_loopback; then
      DEV_PUBLISH_ARGS+=(-p "[::1]:${host_port}:${container_port}")
    fi
  done
}

require_local_publish() {
  local container="${1:?container required}"
  local container_port="${2:?container port required}"
  local bindings published offenders host_ip host_port
  if ! bindings="$(docker inspect --format \
    "{{range (index .HostConfig.PortBindings \"${container_port}/tcp\")}}{{printf \"%s|%s\\n\" .HostIp .HostPort}}{{end}}" \
    "$container" 2>/dev/null)"; then
    echo "ERROR: cannot inspect ${container}'s published ports; refusing to start it." >&2
    return 1
  fi
  published=""
  while IFS='|' read -r host_ip host_port; do
    [ -n "$host_port" ] || continue
    case "$host_ip" in
      127.0.0.1) published="${published}${published:+$'\n'}127.0.0.1:${host_port}" ;;
      ::1) published="${published}${published:+$'\n'}[::1]:${host_port}" ;;
      *) published="${published}${published:+$'\n'}${host_ip:-0.0.0.0}:${host_port}" ;;
    esac
  done <<<"$bindings"
  [ -z "$published" ] && return 0
  offenders="$(printf '%s\n' "$published" | grep -v -e '^127\.0\.0\.1:' -e '^\[::1\]:' || true)"
  if [ -z "$offenders" ] && dev_has_ipv6_loopback \
     && ! printf '%s\n' "$published" | grep -q '^\[::1\]:'; then
    echo "" >&2
    echo "ERROR: ${container} publishes ${container_port} on ${published} only." >&2
    echo "       This host resolves names over the IPv6 loopback as well, so a client that" >&2
    echo "       dials ::1 would find nothing. Recreate the container to publish both" >&2
    echo "       loopback addresses:" >&2
    echo "" >&2
    echo "           docker rm -f ${container}" >&2
    echo "" >&2
    echo "       then run this setup script again." >&2
    echo "" >&2
    return 1
  fi
  [ -z "$offenders" ] && return 0
  echo "" >&2
  echo "ERROR: ${container} publishes ${container_port} on ${published}, not on 127.0.0.1." >&2
  echo "       Developer infrastructure is local-only: these endpoints are unauthenticated," >&2
  echo "       so a binding on a host interface is a privileged exposure." >&2
  echo "       Recreate the container to bind the loopback address:" >&2
  echo "" >&2
  echo "           docker rm -f ${container}" >&2
  echo "" >&2
  echo "       then run this setup script again. For remote access use the authenticated" >&2
  echo "       cloud/hosted path, not these local helpers." >&2
  echo "" >&2
  return 1
}
