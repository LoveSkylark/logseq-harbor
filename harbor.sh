#!/usr/bin/env bash
# Builds and runs the Logseq harbor stack: sync, web, and one MCP container per graph.
#
# Usage: ./harbor.sh {build|up|update [clear]|stop|status}
#   build         build the sync, web and MCP images
#   up            start sync and web, then one MCP container per graph
#   update        start MCP containers only for graphs in config.yaml that have no container yet
#   update clear  also remove MCP containers for graphs no longer in config.yaml (volumes are kept)
#   stop          remove all harbor containers (volumes are kept)
#   status        list harbor containers and active MCP portals
#
# Reads config.yaml next to this script. 'graphs' lists the graphs; each gets its own MCP container,
# host port (12315, 12316, ...), volume and host directory under graphs_dir. 'web: false' skips the
# web container. Secrets may also be set in the process environment, which overrides config.yaml.
# HARBOR_RUNTIME (default: podman, use docker on Linux if preferred) and HARBOR_RUNTIME_ARGS
# (extra CLI arguments) select the container CLI. HARBOR_LOGSEQ_SRC points at the logseq checkout.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
logseq_src="${HARBOR_LOGSEQ_SRC:-$(dirname "$root")/logseq}"
runtime="${HARBOR_RUNTIME:-podman}"
runtime_args=()
if [[ -n "${HARBOR_RUNTIME_ARGS:-}" ]]; then
  read -r -a runtime_args <<<"$HARBOR_RUNTIME_ARGS"
fi

network=harbor-net
sync_image=localhost/logseq-sync:latest
web_image=localhost/logseq-web:latest
mcp_image=localhost/logseq-mcp:latest
sync_port=8787
web_port=8080
mcp_base_port=12315
cognito_client_id=69cs1lgme7p8kbgld8n5kseii6
cognito_issuer=https://cognito-idp.us-east-1.amazonaws.com/us-east-1_dtagLnju8
secret_names=(DB_SYNC_ADMIN_TOKEN LOGSEQ_MCP_TOKEN LOGSEQ_USERNAME LOGSEQ_PASSWORD)

rt() {
  "$runtime" ${runtime_args[@]+"${runtime_args[@]}"} "$@"
}

declare -A settings=()
config_graphs=()

strip_quotes() {
  local v="$1"
  if [[ ${#v} -ge 2 && ( "$v" == \"*\" || "$v" == \'*\' ) ]]; then v="${v:1:${#v}-2}"; fi
  printf '%s' "$v"
}

# Reads the flat YAML subset used by config.yaml: top-level 'key: value' pairs and a 'graphs:' list.
read_settings() {
  local file="$root/config.yaml" line in_graphs=0 key name
  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      if [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]]; then continue; fi
      if [[ "$line" =~ ^graphs:[[:space:]]*$ ]]; then in_graphs=1; continue; fi
      if ((in_graphs)) && [[ "$line" =~ ^[[:space:]]+-[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]]; then
        config_graphs+=("$(strip_quotes "${BASH_REMATCH[1]}")")
        continue
      fi
      in_graphs=0
      if [[ "$line" =~ ^([a-z_]+):[[:space:]]*(.*[^[:space:]])?[[:space:]]*$ ]]; then
        key="${BASH_REMATCH[1]}"
        settings["$key"]="$(strip_quotes "${BASH_REMATCH[2]:-}")"
      fi
    done <"$file"
  fi
  for name in "${secret_names[@]}"; do
    if [[ -n "${!name:-}" ]]; then settings["${name,,}"]="${!name}"; fi
  done
}

expand_home() {
  case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s\n' "$HOME/${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

remove_containers() {
  local name
  for name in "$@"; do
    if rt container inspect "$name" >/dev/null 2>&1; then
      rt rm -f "$name" >/dev/null
    fi
  done
}

ensure_volume() {
  if ! rt volume inspect "$1" >/dev/null 2>&1; then
    rt volume create "$1" >/dev/null
  fi
}

# Container and volume names cannot contain spaces, so they use a slug of the graph name.
graph_slug() {
  printf '%s' "$1" | sed -E 's/[^A-Za-z0-9_-]+/-/g; s/^-+//; s/-+$//'
}

build_images() {
  if [[ ! -d "$logseq_src" ]]; then
    echo "logseq source not found at $logseq_src (set HARBOR_LOGSEQ_SRC)" >&2
    exit 1
  fi
  build_one "$sync_image" "$root/sync"
  build_one "$web_image" "$root/web"
  build_one "$mcp_image" "$root/mcp"
}

build_one() {
  rt build --network host --build-context "logseq=$logseq_src" -t "$1" "$2"
}

wait_for_sync() {
  local i
  for ((i = 0; i < 60; i++)); do
    # curl exits 0 as soon as any HTTP response arrives, whatever the status code.
    if curl -s -m 3 -o /dev/null "http://localhost:$sync_port"; then return 0; fi
    sleep 2
  done
  echo "sync did not answer on port $sync_port" >&2
  exit 1
}

start_stack() {
  local mcp_only=false
  [[ "${1:-}" == --mcp-only ]] && mcp_only=true
  read_settings
  local name
  for name in "${secret_names[@]}"; do
    if [[ -z "${settings[${name,,}]:-}" ]]; then
      echo "${name,,} is not set in config.yaml" >&2
      exit 1
    fi
  done

  local -a graphs=()
  local graph
  graphs=("${config_graphs[@]+"${config_graphs[@]}"}")
  if [[ ${#graphs[@]} -eq 0 ]]; then
    echo "list at least one graph under graphs: in config.yaml" >&2
    exit 1
  fi
  for graph in "${graphs[@]}"; do
    if [[ "$graph" == *[\\/:\*\?\"\<\>\|]* || "$graph" =~ ^[[:space:]] || "$graph" =~ [[:space:]]$ || -z "$(graph_slug "$graph")" ]]; then
      echo "graph '$graph' must be a valid folder name (no \\ / : * ? \" < > |)" >&2
      exit 1
    fi
  done

  local web="${settings[web]:-true}"
  case "$web" in
    true | false) ;;
    *)
      echo "web must be true or false in config.yaml, got '$web'" >&2
      exit 1
      ;;
  esac
  local graphs_dir sync_data_dir
  graphs_dir="$(expand_home "${settings[graphs_dir]:-~/logseq-harbor/graphs}")"
  sync_data_dir="$(expand_home "${settings[sync_data_dir]:-~/logseq-harbor/sync-data}")"

  local base_url="${settings[db_sync_base_url]:-http://localhost:$sync_port}"

  local image
  for image in "$sync_image" "$web_image" "$mcp_image"; do
    if ! rt image inspect "$image" >/dev/null 2>&1; then
      echo "image $image not found; run '$0 build' first" >&2
      exit 1
    fi
  done

  # Secrets reach the containers through the environment, so they never appear on a command line.
  for name in "${secret_names[@]}"; do export "$name=${settings[${name,,}]}"; done

  # 10.89.1.0/24 is the subnet allowed by harbor-forward.service on the Podman VM.
  if ! rt network inspect "$network" >/dev/null 2>&1; then
    rt network create --subnet 10.89.1.0/24 "$network" >/dev/null
  fi
  if [[ "$mcp_only" == true ]]; then
    if [[ "$(rt ps --filter 'name=^logseq-sync$' --filter 'status=running' --format '{{.Names}}')" != logseq-sync ]]; then
      echo "logseq-sync is not running; run '$0 up' first" >&2
      exit 1
    fi
    if [[ "${2:-}" == clear ]]; then
      # Removed before starting new ones so their host ports are free for reuse.
      local -a expected=() existing=() stale=()
      for graph in "${graphs[@]}"; do expected+=("logseq-mcp-$(graph_slug "$graph")"); done
      mapfile -t existing < <(rt ps -a --filter 'name=^logseq-mcp-' --format '{{.Names}}')
      for name in "${existing[@]}"; do
        [[ -z "$name" ]] && continue
        if ! printf '%s\n' "${expected[@]}" | grep -qxF "$name"; then stale+=("$name"); fi
      done
      if [[ ${#stale[@]} -gt 0 ]]; then
        remove_containers "${stale[@]}"
        echo "removed MCP containers for graphs no longer in config.yaml: ${stale[*]}"
      fi
    fi
    start_mcp_containers true "$graphs_dir" "${graphs[@]}"
    show_mcp_portals
    return
  fi

  mkdir -p "$sync_data_dir"
  local -a stale=(logseq-sync logseq-web logseq-mcp)
  for graph in "${graphs[@]}"; do stale+=("logseq-mcp-$(graph_slug "$graph")"); done
  remove_containers "${stale[@]}"

  rt run -d --name logseq-sync --network "$network" --restart unless-stopped \
    -p "$sync_port:8787" \
    -e DB_SYNC_PORT=8787 -e "DB_SYNC_BASE_URL=$base_url" -e DB_SYNC_DATA_DIR=/app/data \
    -e DB_SYNC_STORAGE_DRIVER=sqlite -e DB_SYNC_ASSETS_DRIVER=filesystem -e DB_SYNC_LOG_LEVEL=info \
    -e DB_SYNC_ADMIN_TOKEN \
    -e "COGNITO_ISSUER=$cognito_issuer" -e "COGNITO_CLIENT_ID=$cognito_client_id" \
    -e "COGNITO_JWKS_URL=$cognito_issuer/.well-known/jwks.json" \
    -v "$sync_data_dir:/app/data" --read-only --tmpfs /tmp --cap-drop ALL \
    --security-opt no-new-privileges:true "$sync_image" >/dev/null
  wait_for_sync
  echo "sync on http://localhost:$sync_port"

  if [[ "$web" == true ]]; then
    rt run -d --name logseq-web --network "$network" --restart unless-stopped \
      -p "$web_port:80" "$web_image" >/dev/null
    echo "web on http://localhost:$web_port"
  else
    echo "web disabled in config.yaml"
  fi

  start_mcp_containers false "$graphs_dir" "${graphs[@]}"
  show_mcp_portals
}

# Usage: start_mcp_containers <only_missing true|false> <graphs_dir> <graph>...
# Up assigns ports by the graph's position in config.yaml. Update takes the first free port instead,
# so it never collides with a running portal.
start_mcp_containers() {
  local only_missing="$1" graphs_dir="$2"
  shift 2
  local -a graphs=("$@")
  local i graph port volume host_dir slug next_port=$mcp_base_port used=""
  if [[ "$only_missing" == true ]]; then
    used=" $(rt ps --filter 'name=logseq-mcp-' --format '{{.Ports}}' | sed -n 's/.*:\([0-9]*\)->.*/\1/p' | tr '\n' ' ')"
  fi
  for i in "${!graphs[@]}"; do
    graph="${graphs[$i]}"
    slug="$(graph_slug "$graph")"
    if [[ "$only_missing" == true ]]; then
      if [[ -n "$(rt ps --filter "name=^logseq-mcp-$slug\$" --filter 'status=running' --format '{{.Names}}')" ]]; then
        continue
      fi
      remove_containers "logseq-mcp-$slug"
    fi
    if [[ "$only_missing" == true ]]; then
      while [[ "$used" == *" $next_port "* ]]; do next_port=$((next_port + 1)); done
      port=$next_port
      used+="$port "
    else
      port=$((mcp_base_port + i))
    fi
    volume="mcp-data-$slug"
    host_dir="$graphs_dir/$graph"
    mkdir -p "$host_dir"
    ensure_volume "$volume"
    rt run -d --name "logseq-mcp-$slug" --network "$network" --restart unless-stopped \
      --shm-size 1gb -p "$port:12315" -v "$volume:/data" \
      -v "$host_dir:/data/home/logseq/graphs/$graph" \
      -e LOGSEQ_MCP_ENABLED=true -e LOGSEQ_MCP_HOST=0.0.0.0 -e LOGSEQ_MCP_PORT=12315 \
      -e LOGSEQ_MCP_TOKEN -e LOGSEQ_USERNAME -e LOGSEQ_PASSWORD \
      -e "LOGSEQ_GRAPH_NAME=$graph" -e "LOGSEQ_MCP_PUBLISHED_PORT=$port" \
      -e "COGNITO_CLIENT_ID=$cognito_client_id" \
      -e SYNC_SERVER_URL=http://logseq-sync:8787 "$mcp_image" >/dev/null
    echo "started MCP container for '$graph'"
  done
}

show_mcp_portals() {
  local name graph port
  local -a names
  mapfile -t names < <(rt ps --filter 'name=logseq-mcp-' --filter 'status=running' --format '{{.Names}}')
  if [[ ${#names[@]} -eq 0 ]]; then
    echo "no active MCP portals"
    return
  fi
  echo "Active MCP portals:"
  for name in "${names[@]}"; do
    graph="$(rt inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$name" | sed -n 's/^LOGSEQ_GRAPH_NAME=//p')"
    port="$(rt inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$name" | sed -n 's/^LOGSEQ_MCP_PUBLISHED_PORT=//p')"
    echo "  '$graph' -> http://localhost:$port/mcp"
  done
}

stop_stack() {
  local names
  names="$(rt ps -a --format '{{.Names}}' | grep -E '^logseq-(sync|web|mcp(-|$))' || true)"
  if [[ -z "$names" ]]; then
    echo "no harbor containers"
    return
  fi
  # shellcheck disable=SC2086
  remove_containers $names
}

clear_secrets() {
  local name
  for name in "${secret_names[@]}"; do unset "$name"; done
}
trap clear_secrets EXIT

case "${1:-up}" in
  build) build_images ;;
  up) start_stack ;;
  update) start_stack --mcp-only "${2:-}" ;;
  stop) stop_stack ;;
  status)
    rt ps -a --filter 'name=logseq-' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    show_mcp_portals
    ;;
  *)
    echo "usage: $0 {build|up|update [clear]|stop|status}" >&2
    exit 2
    ;;
esac
