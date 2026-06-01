# Prometheus blackbox targets fix — wrong container names

Symptom: HTTP probe and some service panels in Grafana show "no data." TCP probes for shared_postgres work but HTTP probes for langfuse, openwebui return no data.

Root cause: `prometheus.yml` blackbox targets used multi-subsidiary container names (`openwebui-zfilo`, `langfuse-zfilo-web`, etc.) that do not exist on this single-tenant machine. The series were never created in Prometheus so the panels show no data instead of 0.

Fix: replace blackbox targets with the actual running container names.

Image: `docker.io/aliennor/banka-dev108-prometheus-targets:2026-06-01-r1` (encrypted)

---

## Set key

```
PATCH_KEY=<your-patch-key>
```

---

## Pull and decrypt

```
docker pull docker.io/aliennor/banka-dev108-prometheus-targets:2026-06-01-r1
```

```
docker run --rm docker.io/aliennor/banka-dev108-prometheus-targets:2026-06-01-r1 cat /patch/prometheus.yml.enc | openssl enc -aes-256-cbc -pbkdf2 -d -k "$PATCH_KEY" > /tmp/prometheus-patch.yml
```

```
head -3 /tmp/prometheus-patch.yml
```

Expected first line: `global:`. Binary output means wrong key.

---

## Backup and apply

```
cp /opt/orbina/internal_services/observability/prometheus/prometheus.yml /opt/orbina/internal_services/observability/prometheus/prometheus.yml.bak.$(date +%Y%m%d%H%M%S)
```

```
cp /tmp/prometheus-patch.yml /opt/orbina/internal_services/observability/prometheus/prometheus.yml
```

Prometheus hot-reloads config — no container restart needed:

```
curl -s -X POST http://127.0.0.1:19090/-/reload
```

---

## Verify

```
sleep 15 && curl -s 'http://127.0.0.1:19090/api/v1/targets' | python3 -c "import sys,json; t=json.load(sys.stdin)['data']['activeTargets']; [print(x['labels'].get('service','?'), x['health']) for x in t if x['labels'].get('job') in ('blackbox-http','blackbox-tcp')]"
```

Expected: `langfuse-web`, `openwebui`, `nginx-proxy`, `n8n`, `litellm`, `shared_postgres` all showing `up` or `unknown` (first scrape pending).

---

## Rollback

```
cp /opt/orbina/internal_services/observability/prometheus/prometheus.yml.bak.* /opt/orbina/internal_services/observability/prometheus/prometheus.yml && curl -s -X POST http://127.0.0.1:19090/-/reload
```
