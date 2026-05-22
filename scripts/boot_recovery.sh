#!/usr/bin/env bash
#
# boot_recovery.sh — Bring an internal-services Docker host back up after a
# reboot. Uses `docker start` only. Never `compose up` (RagFlow ES `_state/`
# desync gotcha — compose down/up can rewrite _state/ and leave indices
# dangling).
#
# USAGE:
#   bash boot_recovery.sh           # quick: docker start every Exited container at once
#   bash boot_recovery.sh tiered    # data -> apps -> edge -> observability, with waits
#   bash boot_recovery.sh dry       # list state, no action
#
# Tier lists tolerate both compose-v1 (underscore) and compose-v2 (hyphen)
# container names — missing ones are skipped silently.

set -u
shopt -s nullglob

MODE="${1:-quick}"

TIER1=(shared_postgres docker_mysql_1 docker-mysql-1 docker_es01_1 docker-es01-1 docker_minio_1 docker-minio-1 docker_redis_1 docker-redis-1 langfuse-clickhouse langfuse-minio langfuse-redis)
TIER2=(docker_ragflow-cpu_1 docker-ragflow-cpu-1 langfuse-worker langfuse-web litellm n8n)
TIER3=(openwebui ragflow-mcp-server ragflow-mcp-server-citations nginx-proxy)
TIER4=(observability-loki observability-promtail observability-prometheus observability-alertmanager observability-grafana observability-node-exporter observability-cadvisor observability-blackbox)

state()  { docker ps -a --format '{{.Names}}\t{{.Status}}' | sort ; }
exited() { docker ps -a --filter status=exited --format '{{.Names}}' ; }

start_one() {
  local c="$1"
  docker inspect "$c" >/dev/null 2>&1 || { printf '  [missing] %s\n' "$c" ; return 0 ; }
  local s ; s="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)"
  if [[ "$s" == "running" ]]; then
    printf '  [running] %s\n' "$c"
    return 0
  fi
  if docker start "$c" >/dev/null 2>&1; then
    printf '  [started] %s\n' "$c"
  else
    printf '  [FAILED ] %s\n' "$c"
  fi
}

run_tier() {
  local label="$1" ; shift
  printf '\n== %s ==\n' "$label"
  local c
  for c in "$@"; do start_one "$c" ; done
}

printf '== before ==\n' ; state

case "$MODE" in
  dry)
    printf '\n== exited ==\n' ; exited
    exit 0
    ;;
  tiered)
    run_tier "tier1 data"          "${TIER1[@]}"
    sleep 15
    run_tier "tier2 apps"          "${TIER2[@]}"
    sleep 5
    run_tier "tier3 edge"          "${TIER3[@]}"
    run_tier "tier4 observability" "${TIER4[@]}"
    ;;
  quick|*)
    EX="$(exited | tr '\n' ' ')"
    if [[ -z "${EX// /}" ]]; then
      printf '\n== nothing exited ==\n'
    else
      printf '\n== docker start all exited ==\n'
      # shellcheck disable=SC2086
      docker start $EX
    fi
    sleep 10
    ;;
esac

printf '\n== after ==\n' ; state
printf '\n== still exited ==\n' ; exited
