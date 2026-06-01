# Grafana datasource 502 — corporate proxy bypass fix

Symptom: Grafana dashboards show no data. Prometheus returns data at its host port. `docker exec observability-grafana wget http://prometheus:9090` returns 502.

Root cause: the Grafana container inherits the host's corporate HTTP proxy via environment. All datasource requests (`prometheus:9090`, `loki:3100`) are routed through the proxy, which can't resolve internal container names and returns 502.

Fix: add `NO_PROXY` to the Grafana service environment so container-to-container traffic bypasses the proxy.

Image: `docker.io/aliennor/banka-dev108-grafana-no-proxy:2026-06-01-r2` (encrypted)

---

## Set key

```
PATCH_KEY=<your-patch-key>
```

---

## Pull and decrypt compose file

```
docker pull docker.io/aliennor/banka-dev108-grafana-no-proxy:2026-06-01-r2
```

```
docker run --rm docker.io/aliennor/banka-dev108-grafana-no-proxy:2026-06-01-r2 cat /patch/observability/docker-compose.yml.enc | openssl enc -aes-256-cbc -pbkdf2 -d -k "$PATCH_KEY" > /tmp/grafana-compose-patch.yml
```

```
head -3 /tmp/grafana-compose-patch.yml
```

Expected first line: `version: '3.8'`. If you see binary garbage the key is wrong.

---

## Backup and apply

```
cp /opt/orbina/internal_services/observability/docker-compose.yml /opt/orbina/internal_services/observability/docker-compose.yml.bak.$(date +%Y%m%d%H%M%S)
```

```
cp /tmp/grafana-compose-patch.yml /opt/orbina/internal_services/observability/docker-compose.yml
```

```
cd /opt/orbina/internal_services/observability && docker compose up -d --no-deps --force-recreate grafana
```

---

## Verify

```
sleep 10 && docker exec observability-grafana wget -qO- 'http://prometheus:9090/api/v1/query?query=up' 2>&1 | head -3
```

Expected: JSON with `"status":"success"`. Then check Grafana dashboards — panels should populate within a minute.

---

## Rollback

```
cp /opt/orbina/internal_services/observability/docker-compose.yml.bak.* /opt/orbina/internal_services/observability/docker-compose.yml
```

```
cd /opt/orbina/internal_services/observability && docker compose up -d --no-deps --force-recreate grafana
```
