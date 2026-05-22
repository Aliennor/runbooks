# Host reboot recovery — Docker internal-services stack

`docker start`-only path. Never `compose up` (RagFlow ES `_state/` desync gotcha). Driver: [`scripts/boot_recovery.sh`](scripts/boot_recovery.sh).

## Fetch script onto host

```
curl -fsSL -o /tmp/boot_recovery.sh https://raw.githubusercontent.com/Aliennor/runbooks/main/scripts/boot_recovery.sh && sha256sum /tmp/boot_recovery.sh
```

## Dry run

```
bash /tmp/boot_recovery.sh dry
```

## Quick recovery (one shot, all Exited at once)

```
bash /tmp/boot_recovery.sh
```

## Tiered recovery (data -> apps -> edge -> observability, with waits)

```
bash /tmp/boot_recovery.sh tiered
```

## State after

```
docker ps -a --format '{{.Names}}\t{{.Status}}' | sort
```

## Anything still Exited

```
docker ps -a --filter status=exited --format '{{.Names}}\t{{.Status}}'
```

## Postgres ready

```
docker exec shared_postgres pg_isready -U admin
```

## MySQL ready

```
docker exec $(docker ps --format '{{.Names}}' | grep -E '^docker[-_]mysql[-_]1$' | head -1) sh -c 'mysqladmin -uroot -p"$MYSQL_ROOT_PASSWORD" ping'
```

## Elasticsearch ready

```
docker exec $(docker ps --format '{{.Names}}' | grep -E '^docker[-_]es01[-_]1$' | head -1) sh -c 'curl -sk -u "elastic:$ELASTIC_PASSWORD" https://localhost:9200/_cluster/health'
```

## MinIO ready (RagFlow)

```
docker exec $(docker ps --format '{{.Names}}' | grep -E '^docker[-_]minio[-_]1$' | head -1) sh -c 'curl -sf -o /dev/null -w "minio=%{http_code}\n" http://localhost:9000/minio/health/ready'
```

## LiteLLM ready

```
docker exec litellm sh -c 'curl -sf -o /dev/null -w "litellm=%{http_code}\n" http://localhost:4000/health/liveliness'
```

## Langfuse web ready

```
docker exec langfuse-web sh -c 'wget -qO- -T 5 http://localhost:3000/api/public/health' | head -3
```

## n8n ready

```
docker exec n8n sh -c 'wget -qO- -T 5 http://localhost:5678/healthz' | head -3
```

## OpenWebUI ready

```
docker exec openwebui sh -c 'curl -sf -o /dev/null -w "openwebui=%{http_code}\n" http://localhost:8080/health'
```

## RagFlow ready

```
docker exec $(docker ps --format '{{.Names}}' | grep -E '^docker[-_]ragflow-cpu[-_]1$' | head -1) sh -c 'curl -sf -o /dev/null -w "ragflow=%{http_code}\n" http://localhost:9380/'
```

## nginx-proxy upstream pass-through

```
docker exec nginx-proxy nginx -t
```

## Per-container next-death logs (substitute <c>)

```
docker logs --tail 100 <c>
```

```
docker events --since 2m --filter container=<c> --format '{{.Time}} {{.Action}} {{.Actor.Attributes.exitCode}}'
```
