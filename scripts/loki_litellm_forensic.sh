#!/bin/bash
# LiteLLM Loki forensic audit. Required env: LOKI_START, LOKI_END (RFC3339). Optional: LITELLM_CONTAINER (default litellm).
# Example: LOKI_START='2026-04-15T00:00:00Z' LOKI_END='2026-05-15T00:00:00Z' bash loki_litellm_forensic.sh

set +e
umask 077

if [ -z "${LOKI_START:-}" ] || [ -z "${LOKI_END:-}" ]; then
  echo "ERROR: LOKI_START and LOKI_END must be set (RFC3339)."
  echo "Example:"
  echo "  LOKI_START='2026-04-15T00:00:00Z' LOKI_END='2026-05-15T00:00:00Z' bash $0"
  exit 1
fi

SUDO=""
docker ps >/dev/null 2>&1 || SUDO="sudo"

START="$LOKI_START"
END="$LOKI_END"
LITELLM_CONTAINER="${LITELLM_CONTAINER:-litellm}"

HOST="$(hostname)"
STAMP="$(date -Iseconds)"

echo "== LiteLLM Loki forensic audit =="
echo "host=$HOST"
echo "stamp=$STAMP"
echo "LOKI_START=$START"
echo "LOKI_END=$END"
echo "LITELLM_CONTAINER=$LITELLM_CONTAINER"

echo
echo "========== 1 pick a container that can reach Loki =========="

EXEC_CID=""
EXEC_NAME=""
FETCH_CMD=""

probe_container() {
  local cid="$1"
  local name="$2"
  local has_sh=$($SUDO docker exec "$cid" sh -c 'echo ok' 2>/dev/null)
  [ "$has_sh" != "ok" ] && return 1
  local has_wget=$($SUDO docker exec "$cid" sh -c 'which wget >/dev/null 2>&1 && echo y' 2>/dev/null)
  local has_curl=$($SUDO docker exec "$cid" sh -c 'which curl >/dev/null 2>&1 && echo y' 2>/dev/null)
  if [ "$has_wget" = "y" ]; then
    local ready=$($SUDO docker exec "$cid" sh -c 'wget -qO- --timeout=5 http://loki:3100/ready 2>/dev/null' 2>/dev/null)
    if [ "$ready" = "ready" ]; then
      EXEC_CID="$cid"; EXEC_NAME="$name"; FETCH_CMD='wget -qO- --timeout=20'; return 0
    fi
  fi
  if [ "$has_curl" = "y" ]; then
    local ready=$($SUDO docker exec "$cid" sh -c 'curl -fsS --max-time 5 http://loki:3100/ready 2>/dev/null' 2>/dev/null)
    if [ "$ready" = "ready" ]; then
      EXEC_CID="$cid"; EXEC_NAME="$name"; FETCH_CMD='curl -fsS --max-time 20'; return 0
    fi
  fi
  return 1
}

for filter in 'name=promtail' 'name=loki' 'name=grafana' "name=$LITELLM_CONTAINER"; do
  for cid in $($SUDO docker ps --filter "$filter" -q); do
    name=$($SUDO docker inspect "$cid" --format '{{.Name}}' | sed 's#^/##')
    echo "+ trying $name ($cid)"
    if probe_container "$cid" "$name"; then
      echo "  reaches loki:3100, using $FETCH_CMD"
      break 2
    fi
    echo "  cannot reach loki:3100 from this container"
  done
done

if [ -z "$EXEC_CID" ]; then
  echo "ERROR: no container could reach http://loki:3100/ready. Check:"
  echo "  - is loki actually running? ($SUDO docker ps | grep loki)"
  echo "  - is promtail on the same docker network as loki?"
  echo "  - $SUDO docker network ls and check membership"
  exit 1
fi

echo "selected: $EXEC_NAME ($EXEC_CID)"

loki_get() {
  local url="$1"
  $SUDO docker exec "$EXEC_CID" sh -lc "$FETCH_CMD '$url'" 2>&1
}

echo
echo "========== 2 available labels =========="
loki_get "http://loki:3100/loki/api/v1/labels"

echo
echo "========== 3 values for likely container selectors =========="
for L in container container_name compose_service compose_project job filename app service_name name; do
  echo "+ label '$L':"
  loki_get "http://loki:3100/loki/api/v1/label/$L/values" | head -c 1500
  echo
  echo
done

url_encode() {
  python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

echo
echo "========== 4 identify the LiteLLM selector (probe last 1h) =========="
RECENT_START=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)
RECENT_END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
FOUND_SEL=""
for SEL_LABEL in container_name container compose_service compose_project job name service_name; do
  SEL="{${SEL_LABEL}=\"${LITELLM_CONTAINER}\"}"
  Q=$(url_encode "$SEL")
  S=$(url_encode "$RECENT_START")
  E=$(url_encode "$RECENT_END")
  RESULT=$(loki_get "http://loki:3100/loki/api/v1/query_range?query=$Q&start=$S&end=$E&limit=1&direction=backward")
  N=$(echo "$RESULT" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); n=sum(len(s.get("values",[])) for s in d.get("data",{}).get("result",[])); print(n)
except: print(-1)' 2>/dev/null)
  echo "  $SEL -> $N line(s) in last 1h"
  if [ "$N" != "0" ] && [ "$N" != "-1" ] && [ -n "$N" ] && [ -z "$FOUND_SEL" ]; then
    FOUND_SEL="$SEL"
  fi
done

if [ -z "$FOUND_SEL" ]; then
  echo "WARN: no candidate selector matched the litellm container in the last hour."
  echo "      Either promtail labels it differently, or no fresh logs are coming in."
  echo "      Falling back to {container_name=\"$LITELLM_CONTAINER\"} for the historical scan."
  FOUND_SEL="{container_name=\"$LITELLM_CONTAINER\"}"
fi
echo "selected selector: $FOUND_SEL"

echo
echo "========== 5 compute 28-day chunks =========="
CHUNKS=$(python3 -c "
from datetime import datetime, timedelta
s = datetime.fromisoformat('$START'.replace('Z','+00:00'))
e = datetime.fromisoformat('$END'.replace('Z','+00:00'))
out = []
cur = s
while cur < e:
    nxt = min(cur + timedelta(days=28), e)
    out.append(f\"{cur.strftime('%Y-%m-%dT%H:%M:%SZ')}|{nxt.strftime('%Y-%m-%dT%H:%M:%SZ')}\")
    cur = nxt
print(' '.join(out))
")
for c in $CHUNKS; do echo "  $c"; done

run_loki_query() {
  local sel="$1" filter="$2" s="$3" e="$4" limit="${5:-50}"
  local q="${sel} |~ ${filter}"
  local Q=$(url_encode "$q") S=$(url_encode "$s") E=$(url_encode "$e")
  loki_get "http://loki:3100/loki/api/v1/query_range?query=$Q&start=$S&end=$E&limit=$limit&direction=backward"
}

count_lines() {
  python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); print(sum(len(s.get("values",[])) for s in d.get("data",{}).get("result",[])))
except: print(0)' 2>/dev/null
}

print_samples() {
  local n="${1:-15}"
  python3 -c "
import sys,json,datetime
try:
  d=json.load(sys.stdin)
  for stream in d.get('data',{}).get('result',[]):
    for ts,line in stream.get('values',[])[:$n]:
      try:
        ts_s = int(ts) // 1_000_000_000
        h = datetime.datetime.utcfromtimestamp(ts_s).isoformat() + 'Z'
      except:
        h = ts
      print(f'  {h}  {line[:240]}')
except Exception as ex:
  print(f'  (parse error: {ex})')
" 2>/dev/null
}

echo
echo "========== 6 admin-mutation count per chunk =========="
TOTAL_ADMIN=0
for c in $CHUNKS; do
  s="${c%|*}"; e="${c#*|}"
  echo "+ chunk $s..$e"
  R=$(run_loki_query "$FOUND_SEL" '" (POST|PUT|DELETE) /(key|user|team|model|config|customer|organization)/"' "$s" "$e" 100)
  N=$(echo "$R" | count_lines)
  echo "  matches: $N"
  TOTAL_ADMIN=$((TOTAL_ADMIN + ${N:-0}))
  if [ "${N:-0}" -gt 0 ]; then
    echo "$R" | print_samples 20
  fi
done
echo "TOTAL admin-mutations across [$START..$END]: $TOTAL_ADMIN"

echo
echo "========== 7 auth-leak count (Authorization|Bearer|sk-) per chunk =========="
TOTAL_LEAK=0
for c in $CHUNKS; do
  s="${c%|*}"; e="${c#*|}"
  echo "+ chunk $s..$e"
  R=$(run_loki_query "$FOUND_SEL" '"Authorization:|Bearer [A-Za-z0-9_-]{8,}|sk-[A-Za-z0-9_-]{16,}"' "$s" "$e" 30)
  N=$(echo "$R" | count_lines)
  echo "  matches: $N"
  TOTAL_LEAK=$((TOTAL_LEAK + ${N:-0}))
  if [ "${N:-0}" -gt 0 ]; then
    echo "$R" | print_samples 10
  fi
done
echo "TOTAL auth-leak lines across [$START..$END]: $TOTAL_LEAK"

echo
echo "========== 8 retention probe — earliest line in window =========="
Q=$(url_encode "$FOUND_SEL")
S=$(url_encode "$START")
E1=$(url_encode "$(python3 -c "
from datetime import datetime, timedelta
s=datetime.fromisoformat('$START'.replace('Z','+00:00'))
print((s+timedelta(days=28)).strftime('%Y-%m-%dT%H:%M:%SZ'))
")")
R=$(loki_get "http://loki:3100/loki/api/v1/query_range?query=$Q&start=$S&end=$E1&limit=1&direction=forward")
echo "$R" | print_samples 1

echo
echo "========== VERDICT =========="
echo "selector used:        $FOUND_SEL"
echo "window:               [$START..$END]"
echo "admin-mutation hits:  $TOTAL_ADMIN"
echo "auth-leak hits:       $TOTAL_LEAK"
echo
if [ "$TOTAL_LEAK" = "0" ]; then
  echo "verdict: LiteLLM did NOT log Authorization/Bearer/sk- patterns to"
  echo "         stdout in this window (subject to Loki retention — confirm"
  echo "         section 8 shows a timestamp inside the audited window)."
else
  echo "verdict: auth-leak matches found — investigate the sample lines above."
fi

echo
echo "========== AUDIT COMPLETE =========="
echo "host=$HOST finished=$(date -Iseconds)"
