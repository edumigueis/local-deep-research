#!/usr/bin/env bash
# Automated deployment helper for the LDR + SearXNG + Ollama stack.
# Works in Linux, macOS, WSL2 and Git Bash (Docker Desktop).
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE=".env"
COMPOSE=(docker compose)
PROFILE_ARGS=()
GPU=false
PROXY=false

log()  { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: ./deploy.sh <command> [--proxy] [--gpu]

Commands:
  up        Create .env if missing, start the stack, pull the model, wait for health
  status    Show container health + model list
  model     Pull the model currently set in .env (LDR_LLM_MODEL) and restart LDR
  harden    Set LDR_APP_ALLOW_REGISTRATIONS=false and restart LDR (run AFTER admin creation)
  metrics   [seconds, default 300] sample `docker stats` to metrics/, then `docker system df -v`
  down      Stop the stack (keeps volumes)
  destroy   Stop the stack AND delete all volumes (irreversible)

Flags:
  --proxy   Enable the Caddy reverse-proxy profile (HTTPS on 443)
  --gpu     Add docker-compose.gpu.override.yml (NVIDIA)
EOF
}

set_env() { # set_env KEY VALUE  (portable in-place edit, no sed -i)
  local key="$1" val="$2" tmp
  tmp="$(mktemp)"
  if grep -q "^${key}=" "$ENV_FILE"; then
    awk -v k="$key" -v v="$val" -F= 'BEGIN{OFS="="} $1==k{print k"="v; next} {print}' "$ENV_FILE" > "$tmp"
  else
    cat "$ENV_FILE" > "$tmp"; echo "${key}=${val}" >> "$tmp"
  fi
  cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
}

get_env() { grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2-; }

preflight() {
  command -v docker >/dev/null || { err "docker not found"; exit 1; }
  docker compose version >/dev/null 2>&1 || { err "Docker Compose v2 required"; exit 1; }
  docker info >/dev/null 2>&1 || { err "Docker daemon not running"; exit 1; }
  if [[ ! -f "$ENV_FILE" ]]; then
    cp .env.example "$ENV_FILE"; log "Created $ENV_FILE from .env.example"
  fi
  if $PROXY; then
    PROFILE_ARGS+=(--profile proxy)
    set_env TRUST_PROXY_HEADERS true
  fi
  if $GPU; then COMPOSE+=(-f docker-compose.yml -f docker-compose.gpu.override.yml); fi
}

wait_healthy() { # wait_healthy <container> <timeout_s>
  local c="$1" t="${2:-300}" s i=0
  while (( i < t )); do
    s="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null || echo missing)"
    [[ "$s" == "healthy" ]] && { log "$c: healthy"; return 0; }
    sleep 5; i=$((i+5))
  done
  err "$c not healthy after ${t}s (last state: $s). Try: docker logs $c"; return 1
}

searxng_configure() {
  # Patch the settings.yml SearXNG generates on first start (in the searxng_data
  # volume). Idempotent. Paths live inside `sh -c` so Git Bash does not rewrite them.
  #  1. LDR queries SearXNG with format=json, disabled by default (HTTP 403 ->
  #     every research ends with zero sources).
  #  2. The default web engines (DuckDuckGo, Startpage, Brave) answer automated
  #     traffic with CAPTCHAs / rate limits, and Bing's scraper returns unrelated
  #     pages. Yandex and Seznam return relevant results but ship disabled.
  local f=/etc/searxng/settings.yml changed=false e
  if ! docker exec searxng sh -c "grep -q '^    - json\$' $f"; then
    log "SearXNG: enabling JSON output format"
    docker exec searxng sh -c "sed -i '/^  formats:\$/,/^\$/ s/^    - html\$/    - html\n    - json/' $f"
    changed=true
  fi
  for e in ${SEARXNG_EXTRA_ENGINES:-yandex seznam}; do
    if docker exec searxng sh -c "sed -n '/^  - name: $e\$/,/^\$/p' $f | grep -q 'disabled: true'"; then
      log "SearXNG: enabling the $e engine"
      docker exec searxng sh -c "sed -i '/^  - name: $e\$/,/^\$/ {/^    disabled: true\$/d}' $f"
      changed=true
    fi
  done
  if $changed; then docker restart searxng >/dev/null; wait_healthy searxng 120; fi
}

pull_model() {
  local m; m="$(get_env LDR_LLM_MODEL)"
  log "Pulling model '$m' into Ollama (cached in the ollama_data volume)..."
  "${COMPOSE[@]}" exec -T ollama ollama pull "$m"
}

cmd_up() {
  preflight
  log "Starting stack..."
  # Start ollama + searxng first so the model can be pulled before LDR needs it.
  "${COMPOSE[@]}" "${PROFILE_ARGS[@]}" up -d ollama searxng
  wait_healthy ollama_service 120
  wait_healthy searxng 120
  searxng_configure
  pull_model
  "${COMPOSE[@]}" "${PROFILE_ARGS[@]}" up -d
  wait_healthy ldr_app 180
  $PROXY && wait_healthy ldr_caddy 60 || true
  cmd_status
  local url="http://localhost:5000"
  $PROXY && url="https://$(get_env LDR_DOMAIN)"
  log "Ready: $url   -> register the admin account, then run ./deploy.sh harden"
}

cmd_status() {
  preflight
  "${COMPOSE[@]}" "${PROFILE_ARGS[@]}" ps
  echo; log "Models in Ollama:"; "${COMPOSE[@]}" exec -T ollama ollama list || true
}

cmd_model() { preflight; pull_model; "${COMPOSE[@]}" "${PROFILE_ARGS[@]}" up -d local-deep-research; }

cmd_harden() {
  preflight
  set_env LDR_APP_ALLOW_REGISTRATIONS false
  "${COMPOSE[@]}" "${PROFILE_ARGS[@]}" up -d local-deep-research
  wait_healthy ldr_app 180
  log "Public sign-ups disabled (LDR_APP_ALLOW_REGISTRATIONS=false)."
}

cmd_metrics() {
  preflight
  local dur="${1:-300}" ts out; ts="$(date +%Y%m%d-%H%M%S)"
  mkdir -p metrics; out="metrics/docker-stats-$ts.csv"
  echo "timestamp,name,cpu,mem_usage,mem_pct,net_io,block_io" > "$out"
  log "Sampling docker stats every 5s for ${dur}s -> $out (Ctrl-C to stop early). START YOUR RESEARCH QUERY NOW."
  trap 'log "Interrupted."' INT
  local end=$((SECONDS+dur))
  while (( SECONDS < end )); do
    docker stats --no-stream --format "$(date +%T),{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}},{{.NetIO}},{{.BlockIO}}" >> "$out" || true
    sleep 5
  done
  trap - INT
  echo; log "Final snapshot (docker stats --no-stream):"; docker stats --no-stream
  docker system df -v > "metrics/docker-system-df-$ts.txt"
  log "Saved: $out and metrics/docker-system-df-$ts.txt"
}

cmd_down()    { preflight; "${COMPOSE[@]}" --profile proxy down; }
cmd_destroy() {
  preflight
  read -r -p "Delete ALL volumes (research DBs, models, certs)? type 'yes': " a
  [[ "$a" == "yes" ]] && "${COMPOSE[@]}" --profile proxy down -v || log "Aborted."
}

main() {
  local cmd="${1:-}"; shift || true
  local args=()
  for a in "$@"; do
    case "$a" in --proxy) PROXY=true;; --gpu) GPU=true;; *) args+=("$a");; esac
  done
  case "$cmd" in
    up)      cmd_up ;;
    status)  cmd_status ;;
    model)   cmd_model ;;
    harden)  cmd_harden ;;
    metrics) cmd_metrics "${args[0]:-300}" ;;
    down)    cmd_down ;;
    destroy) cmd_destroy ;;
    *)       usage; exit 1 ;;
  esac
}
main "$@"
