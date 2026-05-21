#!/usr/bin/env bash
#
# k8s_full_export.sh — Full-state export of an internal-services DEV host
# for k8s migration. Produces one self-contained artifact set per run.
#
# Companion runbook:
#   RUNBOOK_DEV_FULL_STATE_EXPORT_FOR_K8S_MIGRATION_BANKA_KATILIM_ZT_2026_05_15.md
#
# USAGE:
#   ENV=banka_dev   bash k8s_full_export.sh
#   ENV=katilim_dev bash k8s_full_export.sh
#   ENV=zt_arf_dev  bash k8s_full_export.sh
#   # or positional:
#   bash k8s_full_export.sh banka_dev
#
# SELECT WHAT TO EXPORT (default: everything):
#   ARTIFACTS=litellm_pg,n8n_pg,openwebui_data  bash k8s_full_export.sh banka_dev
#   SKIP=ragflow_es,ragflow_minio               bash k8s_full_export.sh banka_dev
#   ARTIFACTS=list bash k8s_full_export.sh banka_dev   # print menu and exit
#
# AVAILABLE ARTIFACT IDS:
#   litellm_pg            langfuse_pg            n8n_pg
#   ragflow_mysql         langfuse_clickhouse    langfuse_minio
#   ragflow_es            ragflow_minio          openwebui_data
#   n8n_storage           secrets
#
# OUTPUT:
#   /tmp/k8s_export_<env>_<stamp>/
#     <env>_litellm_pg_<stamp>.sql
#     <env>_langfuse_pg_<stamp>.sql
#     <env>_n8n_pg_<stamp>.sql
#     <env>_ragflow_mysql_<stamp>.sql
#     <env>_langfuse_clickhouse_<stamp>.tar.gz
#     <env>_langfuse_minio_<stamp>.tar.gz
#     <env>_ragflow_es_<stamp>.tar.gz
#     <env>_ragflow_minio_<stamp>.tar.gz
#     <env>_openwebui_data_<stamp>.tar.gz
#     <env>_n8n_storage_<stamp>.tar.gz
#     <env>_secrets_<stamp>.tar.gz
#     <env>_manifest_<stamp>.txt
#     <env>_export_<stamp>.log
#
# DESIGN:
#   - Each artifact is wrapped in a guarded function: missing containers are
#     marked SKIP, errors marked FAIL — the whole run never aborts on one bad
#     artifact, because some envs may legitimately not run all services.
#   - Volume tars use `docker stop` + `--volumes-from` + `docker start`.
#     NEVER `compose down/up` (RagFlow ES `_state/` desync gotcha).
#   - SQL dumps run without stopping anything.
#   - Manifest at the end has sha256, size, container→image table, and per
#     artifact status (OK / SKIP / FAIL). Importer reads this first.

set -u
set -o pipefail
shopt -s nullglob

# ---------------------------------------------------------------------------
# Env resolution
# ---------------------------------------------------------------------------
ENV="${1:-${ENV:-}}"
if [[ -z "$ENV" ]]; then
  echo "ERROR: ENV not set. Run as: ENV=banka_dev bash $0   (or pass as arg)" >&2
  exit 2
fi
case "$ENV" in
  banka_dev|katilim_dev|zt_arf_dev) : ;;
  *) echo "ERROR: ENV must be one of: banka_dev katilim_dev zt_arf_dev (got: $ENV)" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# Artifact selection
# ---------------------------------------------------------------------------
ALL_IDS="litellm_pg langfuse_pg n8n_pg ragflow_mysql langfuse_clickhouse langfuse_minio ragflow_es ragflow_minio openwebui_data n8n_storage secrets"

ARTIFACTS="${ARTIFACTS:-all}"
SKIP="${SKIP:-}"

# Image used by vol_tar() to run `tar` against --volumes-from.
#   - If TAR_IMAGE is set explicitly, that image is used (must exist locally,
#     no auto-pull). Useful to force a specific tag.
#   - Otherwise the script scans TAR_IMAGE_CANDIDATES and picks the first one
#     that's already present locally (via `docker image inspect`).
#   - If nothing matches, volume tars SKIP this run; SQL dumps still proceed.
TAR_IMAGE="${TAR_IMAGE:-}"
TAR_IMAGE_CANDIDATES="${TAR_IMAGE_CANDIDATES:-alpine alpine:3.20 alpine:3.19 alpine:3.18 busybox nginx:alpine}"

# Heartbeat interval (seconds) for in-progress vol_tar runs.
HEARTBEAT="${HEARTBEAT:-15}"

if [[ "$ARTIFACTS" == "list" ]]; then
  echo "Available artifact IDs:"
  for id in $ALL_IDS; do echo "  $id"; done
  echo
  echo "Pick a subset:    ARTIFACTS=litellm_pg,n8n_pg bash $0 $ENV"
  echo "Exclude some:     SKIP=ragflow_es,ragflow_minio bash $0 $ENV"
  echo "Everything:       bash $0 $ENV     (default)"
  exit 0
fi

# Build the SELECTED set as a space-padded string for portability (bash 3.2+).
SELECTED=""
if [[ "$ARTIFACTS" == "all" ]]; then
  SELECTED=" $ALL_IDS "
else
  IFS=',' read -ra picks <<<"$ARTIFACTS"
  for id in "${picks[@]}"; do
    id="${id// /}"
    [[ -z "$id" ]] && continue
    if [[ " $ALL_IDS " != *" $id "* ]]; then
      echo "ERROR: unknown artifact id '$id'. Run with ARTIFACTS=list to see valid ids." >&2
      exit 2
    fi
    [[ "$SELECTED" != *" $id "* ]] && SELECTED="$SELECTED $id "
  done
  SELECTED=" ${SELECTED# } "
fi

# Apply SKIP.
if [[ -n "$SKIP" ]]; then
  IFS=',' read -ra skips <<<"$SKIP"
  for id in "${skips[@]}"; do
    id="${id// /}"
    [[ -z "$id" ]] && continue
    if [[ " $ALL_IDS " != *" $id "* ]]; then
      echo "ERROR: unknown artifact id in SKIP: '$id'. Run with ARTIFACTS=list to see valid ids." >&2
      exit 2
    fi
    SELECTED="${SELECTED// $id / }"
  done
fi

# Collapse whitespace and check non-empty.
SELECTED="$(echo "$SELECTED" | tr -s ' ')"
if [[ -z "${SELECTED// /}" ]]; then
  echo "ERROR: nothing selected after applying ARTIFACTS / SKIP." >&2
  exit 2
fi

enabled() { [[ "$SELECTED" == *" $1 "* ]]; }

STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="/tmp/k8s_export_${ENV}_${STAMP}"
LOG="${OUT}/${ENV}_export_${STAMP}.log"
MAN="${OUT}/${ENV}_manifest_${STAMP}.txt"

mkdir -p "$OUT"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
ts()  { date '+%H:%M:%S'; }
log() { printf '[%s] %s\n' "$(ts)" "$*" | tee -a "$LOG" >&2; }

OK_COUNT=0; SKIP_COUNT=0; FAIL_COUNT=0
declare -a STATUS_ROWS=()

record() {
  # record <status> <artifact> <note>
  local status="$1" artifact="$2" note="${3:-}"
  STATUS_ROWS+=("${status}|${artifact}|${note}")
  case "$status" in
    OK)   OK_COUNT=$((OK_COUNT+1))   ;;
    SKIP) SKIP_COUNT=$((SKIP_COUNT+1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT+1)) ;;
  esac
}

# ---------------------------------------------------------------------------
# Resolve tar image for vol_tar(). Explicit TAR_IMAGE wins (must exist locally,
# no auto-pull). Otherwise pick the first candidate present locally. Failure
# is non-fatal — vol_tar() will SKIP volume artifacts while SQL dumps proceed.
# ---------------------------------------------------------------------------
resolve_tar_image() {
  if [[ -n "$TAR_IMAGE" ]]; then
    if docker image inspect "$TAR_IMAGE" >/dev/null 2>&1; then
      log "tar image: $TAR_IMAGE (operator-set, present locally)"
      return 0
    fi
    log "ERROR: TAR_IMAGE=$TAR_IMAGE not present locally and auto-pull is disabled"
    log "       fix: docker pull $TAR_IMAGE   (or unset TAR_IMAGE to use auto-detect)"
    TAR_IMAGE=""
    return 1
  fi
  local cand
  for cand in $TAR_IMAGE_CANDIDATES; do
    if docker image inspect "$cand" >/dev/null 2>&1; then
      TAR_IMAGE="$cand"
      log "tar image: $TAR_IMAGE (auto-selected, first local match from candidates)"
      return 0
    fi
  done
  log "ERROR: none of [$TAR_IMAGE_CANDIDATES] are present locally"
  log "       fix: docker pull alpine   (or pull any image with tar and set TAR_IMAGE)"
  log "       volume tars will SKIP this run; SQL dumps will still proceed"
  return 1
}
resolve_tar_image || true

# ---------------------------------------------------------------------------
# Container discovery
# ---------------------------------------------------------------------------
find_one() {
  # find_one <regex> -> echoes first running container name matching regex
  docker ps --format '{{.Names}}' | grep -E "$1" | head -1
}

# Container-name regexes tolerate both compose v1 (underscores: docker_mysql_1)
# and compose v2 (hyphens: docker-mysql-1). Banka uses the underscore form.
ES_NAME="$(find_one '^(es01|docker[-_]es01[-_]1)$')"
OS_NAME="$(find_one '^(opensearch01|docker[-_]opensearch01[-_]1)$')"
RAGFLOW_MYSQL_NAME="$(find_one '^docker[-_]mysql[-_]1$')"
RAGFLOW_MINIO_NAME="$(docker ps --format '{{.Names}}' | grep -E 'minio' | grep -vE 'langfuse' | head -1)"
LANGFUSE_CLICKHOUSE_NAME="$(find_one '^langfuse-clickhouse$')"
LANGFUSE_MINIO_NAME="$(find_one '^langfuse-minio$')"
OPENWEBUI_NAME="$(find_one '^openwebui$')"
N8N_NAME="$(find_one '^n8n$')"

# If ES isn't found but OpenSearch is, we use OpenSearch for RagFlow indices.
if [[ -z "$ES_NAME" && -n "$OS_NAME" ]]; then
  RAGFLOW_SEARCH_NAME="$OS_NAME"
  RAGFLOW_SEARCH_PATH="/usr/share/opensearch/data"
  RAGFLOW_SEARCH_KIND="opensearch"
else
  RAGFLOW_SEARCH_NAME="$ES_NAME"
  RAGFLOW_SEARCH_PATH="/usr/share/elasticsearch/data"
  RAGFLOW_SEARCH_KIND="elasticsearch"
fi

log "ENV=$ENV STAMP=$STAMP OUT=$OUT"
sel_list=""
for id in $ALL_IDS; do enabled "$id" && sel_list="$sel_list $id"; done
log "Selected artifacts:$sel_list"
log "Discovered containers:"
log "  shared_postgres            = $(find_one '^shared_postgres$')"
log "  ragflow mysql              = $RAGFLOW_MYSQL_NAME"
log "  langfuse-clickhouse        = $LANGFUSE_CLICKHOUSE_NAME"
log "  langfuse-minio             = $LANGFUSE_MINIO_NAME"
log "  ragflow search ($RAGFLOW_SEARCH_KIND) = $RAGFLOW_SEARCH_NAME"
log "  ragflow minio              = $RAGFLOW_MINIO_NAME"
log "  openwebui                  = $OPENWEBUI_NAME"
log "  n8n                        = $N8N_NAME"

# ---------------------------------------------------------------------------
# Artifact functions
# ---------------------------------------------------------------------------

pg_dump_db() {
  local db="$1" out="$2" label="$3"
  if ! docker ps --format '{{.Names}}' | grep -q '^shared_postgres$'; then
    log "[$label] SKIP — shared_postgres not running"
    record SKIP "$out" "shared_postgres not running"
    return
  fi
  log "[$label] pg_dump $db -> $out"
  if docker exec shared_postgres pg_dump -U admin -d "$db" --clean --if-exists > "${OUT}/${out}" 2>>"$LOG"; then
    record OK "$out"
  else
    record FAIL "$out" "pg_dump exit $?"
  fi
}

mysql_dump_ragflow() {
  local out="$1"
  if [[ -z "$RAGFLOW_MYSQL_NAME" ]]; then
    log "[ragflow_mysql] SKIP — no docker-mysql-1 / docker_mysql_1 container running"
    record SKIP "$out" "no docker-mysql-1 / docker_mysql_1 container running"
    return
  fi
  log "[ragflow_mysql] mysqldump rag_flow -> $out (container=$RAGFLOW_MYSQL_NAME)"
  if docker exec "$RAGFLOW_MYSQL_NAME" sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --add-drop-database --add-drop-table --routines --triggers --events --single-transaction --databases rag_flow' > "${OUT}/${out}" 2>>"$LOG"; then
    record OK "$out"
  else
    record FAIL "$out" "mysqldump exit $?"
  fi
}

vol_tar() {
  # vol_tar <container> <mount_path_inside> <out_filename> <label>
  local container="$1" mount="$2" out="$3" label="$4"
  if [[ -z "$TAR_IMAGE" ]]; then
    log "[$label] SKIP — no tar image resolved (see startup log)"
    record SKIP "$out" "no tar image available locally"
    return
  fi
  if [[ -z "$container" ]]; then
    log "[$label] SKIP — container not found"
    record SKIP "$out" "container not found"
    return
  fi
  if ! docker inspect "$container" >/dev/null 2>&1; then
    log "[$label] SKIP — container $container not present"
    record SKIP "$out" "container $container not present"
    return
  fi
  local was_running
  was_running="$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo false)"
  log "[$label] tar $container:$mount -> $out (was_running=$was_running, image=$TAR_IMAGE)"
  if [[ "$was_running" == "true" ]]; then
    docker stop "$container" >>"$LOG" 2>&1 || { record FAIL "$out" "docker stop failed"; return; }
  fi
  ( docker run --rm --volumes-from "$container" -v "${OUT}:/out" "$TAR_IMAGE" tar czf "/out/${out}" -C "$mount" . >>"$LOG" 2>&1 ) &
  local tar_pid=$!
  local target="${OUT}/${out}"
  local elapsed=0
  while kill -0 "$tar_pid" 2>/dev/null; do
    sleep "$HEARTBEAT"
    elapsed=$((elapsed + HEARTBEAT))
    if [[ -f "$target" ]]; then
      local sz; sz=$(du -h "$target" 2>/dev/null | awk '{print $1}')
      log "[$label] still tarring (${elapsed}s elapsed, size=${sz:-?})"
    else
      log "[$label] still tarring (${elapsed}s elapsed, no output file yet)"
    fi
  done
  if wait "$tar_pid"; then
    record OK "$out"
  else
    record FAIL "$out" "tar via volumes-from failed"
  fi
  if [[ "$was_running" == "true" ]]; then
    docker start "$container" >>"$LOG" 2>&1 || log "[$label] WARN: docker start $container failed"
  fi
}

secrets_bundle() {
  local out="$1"
  log "[secrets] scanning for .env / docker-compose / nginx.conf under /opt /srv /root /etc/internal_services /home/*/internal_services"
  local list="${OUT}/.secrets_filelist.txt"
  : > "$list"
  for root in /opt /srv /root /etc/internal_services /home; do
    [[ -d "$root" ]] || continue
    find "$root" -maxdepth 6 \( -name '.env' -o -name '.env.*' -o -name 'docker-compose*.y*ml' -o -name 'nginx.conf' \) \
      -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null >> "$list"
  done
  local n; n=$(wc -l <"$list" | tr -d ' ')
  log "[secrets] found $n files"
  if [[ "$n" -eq 0 ]]; then
    record SKIP "$out" "no .env / compose / nginx.conf files found under standard roots"
    rm -f "$list"
    return
  fi
  if tar czf "${OUT}/${out}" -T "$list" >>"$LOG" 2>&1; then
    record OK "$out" "$n files"
  else
    record FAIL "$out" "tar of secrets failed"
  fi
  rm -f "$list"
}

# ---------------------------------------------------------------------------
# Run all artifacts
# ---------------------------------------------------------------------------

# SQL (no stops)
enabled litellm_pg    && pg_dump_db litellm  "${ENV}_litellm_pg_${STAMP}.sql"   "litellm_pg"
enabled langfuse_pg   && pg_dump_db langfuse "${ENV}_langfuse_pg_${STAMP}.sql"  "langfuse_pg"
enabled n8n_pg        && pg_dump_db n8n      "${ENV}_n8n_pg_${STAMP}.sql"       "n8n_pg"
enabled ragflow_mysql && mysql_dump_ragflow  "${ENV}_ragflow_mysql_${STAMP}.sql"

# Volume tars
enabled langfuse_clickhouse && vol_tar "$LANGFUSE_CLICKHOUSE_NAME" /var/lib/clickhouse    "${ENV}_langfuse_clickhouse_${STAMP}.tar.gz" "langfuse_clickhouse"
enabled langfuse_minio      && vol_tar "$LANGFUSE_MINIO_NAME"      /data                  "${ENV}_langfuse_minio_${STAMP}.tar.gz"      "langfuse_minio"
enabled ragflow_es          && vol_tar "$RAGFLOW_SEARCH_NAME"      "$RAGFLOW_SEARCH_PATH" "${ENV}_ragflow_es_${STAMP}.tar.gz"          "ragflow_${RAGFLOW_SEARCH_KIND}"
enabled ragflow_minio       && vol_tar "$RAGFLOW_MINIO_NAME"       /data                  "${ENV}_ragflow_minio_${STAMP}.tar.gz"       "ragflow_minio"
enabled openwebui_data      && vol_tar "$OPENWEBUI_NAME"           /app/backend/data      "${ENV}_openwebui_data_${STAMP}.tar.gz"      "openwebui_data"
enabled n8n_storage         && vol_tar "$N8N_NAME"                 /home/node/.n8n        "${ENV}_n8n_storage_${STAMP}.tar.gz"         "n8n_storage"

# Secrets
enabled secrets && secrets_bundle "${ENV}_secrets_${STAMP}.tar.gz"

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
log "[manifest] building $MAN"
{
  printf 'env=%s\nstamp=%s\nhost=%s\nexport_ts=%s\n' "$ENV" "$STAMP" "$(hostname)" "$(date -Iseconds)"
  printf 'ragflow_search_kind=%s\n' "$RAGFLOW_SEARCH_KIND"
  printf '\n--- container -> image ---\n'
  docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | sort
  printf '\n--- artifacts ---\n'
  printf '%-6s  %-12s  %s\n' STATUS SIZE FILE
  for row in "${STATUS_ROWS[@]}"; do
    status="${row%%|*}"; rest="${row#*|}"
    artifact="${rest%%|*}"; note="${rest#*|}"
    if [[ "$status" == "OK" && -f "${OUT}/${artifact}" ]]; then
      sz=$(du -h "${OUT}/${artifact}" 2>/dev/null | awk '{print $1}')
      printf '%-6s  %-12s  %s\n' "$status" "$sz" "$artifact"
    else
      printf '%-6s  %-12s  %s   %s\n' "$status" "-" "$artifact" "${note:+($note)}"
    fi
  done
  printf '\n--- sha256 (OK artifacts only) ---\n'
  (cd "$OUT" && sha256sum "${ENV}"_*_"${STAMP}".* 2>/dev/null | grep -vE "manifest|export_${STAMP}\.log") || true
  printf '\n--- totals ---\n'
  printf 'ok=%d skip=%d fail=%d total_size=%s\n' "$OK_COUNT" "$SKIP_COUNT" "$FAIL_COUNT" "$(du -sh "$OUT" | awk '{print $1}')"
} > "$MAN"

# ---------------------------------------------------------------------------
# Summary to stdout
# ---------------------------------------------------------------------------
echo
echo "==================== EXPORT SUMMARY ===================="
cat "$MAN"
echo "========================================================"
echo
echo "Artifacts directory:  $OUT"
echo "Manifest:             $MAN"
echo "Log:                  $LOG"
echo
echo "Pull to Mac:"
echo "  scp -r '<user>@<host>:${OUT}' ~/k8s_migration_exports/${ENV}/"
echo

# Exit non-zero only if everything failed; partial successes return 0.
if [[ "$OK_COUNT" -eq 0 ]]; then
  exit 1
fi
exit 0
