# Observability — Promtail exited / Grafana no data

Covers two related failure modes that typically happen together after a compose down/up on a co-located stack on a Podman host.

Set your paths:

```
OBS_DIR=/opt/orbina/internal_services/observability
GRAFANA_PORT=13001
GRAFANA_PASS=<your-grafana-admin-password>
PROM_PORT=19090
LOKI_PORT=3100
```

---

## 1. Check container state

```
docker ps -a --filter name=observability --format 'table {{.Names}}\t{{.Status}}'
```

---

## 2. Promtail exit reason

```
docker logs --tail 60 observability-promtail 2>&1 | tail -60
```

```
docker inspect --format 'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' observability-promtail
```

---

## 3. Fix: Podman socket missing (exit reason: "cannot connect to Docker daemon")

On Podman hosts Promtail mounts `/var/run/docker.sock` for container discovery. After a stack down/up the socket can go stale.

```
systemctl restart podman.socket
```

If that fails:

```
rm -f /var/run/docker.sock && nohup podman system service --time=0 unix:///var/run/docker.sock > /tmp/podman-socket.log 2>&1 &
```

```
sleep 3 && ls -la /var/run/docker.sock
```

Recreate Promtail:

```
cd $OBS_DIR && docker compose up -d --no-deps --force-recreate promtail
```

```
sleep 5 && docker logs --tail 20 observability-promtail 2>&1 | tail -20
```

---

## 4. Fix: All Grafana panels empty (Prometheus + Loki both dead)

Happens when `internal_services_network` was recreated by another stack's compose down/up, leaving observability containers with stale network state.

Check Prometheus targets:

```
curl -s http://127.0.0.1:$PROM_PORT/api/v1/targets | python3 -c "import sys,json; t=json.load(sys.stdin)['data']['activeTargets']; [print(x['labels'].get('job','?'), x['health'], x.get('lastError','')) for x in t]"
```

Check Loki ready:

```
curl -s http://127.0.0.1:$LOKI_PORT/ready
```

If Prometheus has no targets or all targets are down, restart the full observability stack:

```
cd $OBS_DIR && docker compose down && docker compose up -d
```

```
sleep 10 && docker ps --filter name=observability --format 'table {{.Names}}\t{{.Status}}'
```

---

## 5. Reload Grafana datasource provisioning (if panels still empty after restart)

```
curl -s -X POST -u admin:$GRAFANA_PASS http://127.0.0.1:$GRAFANA_PORT/api/admin/provisioning/datasources/reload
```

Wait 1-2 minutes then refresh the Grafana dashboards.
