# Observability — Prometheus no targets / Grafana blank after network loss

Happens when the compose project that owns `internal_services_network` (typically `shared-postgres`) is down, so the network doesn't exist and Prometheus can't resolve any container hostname.

Set your paths:

```
POSTGRES_DIR=/opt/orbina/internal_services/shared-postgres
OBS_DIR=/opt/orbina/internal_services/observability
PROM_PORT=19090
```

---

## Step 1 — confirm the network is missing

```
docker network ls | grep internal_services
```

If no output → network is gone. That is the root cause.

---

## Step 2 — bring shared-postgres up (recreates the network)

```
cd $POSTGRES_DIR && docker compose up -d
```

```
sleep 5 && docker network ls | grep internal_services
```

---

## Step 3 — restart observability so containers re-join the new network

```
cd $OBS_DIR && docker compose down && docker compose up -d
```

```
sleep 10 && docker ps --filter name=observability --format 'table {{.Names}}\t{{.Status}}'
```

---

## Step 4 — confirm Prometheus has targets

```
curl -s "http://127.0.0.1:$PROM_PORT/api/v1/query?query=up" | python3 -c "import sys,json; d=json.load(sys.stdin); [print(r['metric'].get('job','?'), r['value'][1]) for r in d.get('data',{}).get('result',[])] or print('NO DATA')"
```

Expected: several lines with job names and value `1`. If still `NO DATA` after 1 minute, run Step 3 again.

---

## Step 5 — bring the rest of the stack up

```
for svc in litellm n8n openweb-ui langfuse qdrant; do
  cd /opt/orbina/internal_services/$svc && docker compose up -d
done
```
