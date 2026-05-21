# RagFlow MinIO — exited, restart without compose

Container assumed name: `docker_minio_1` (compose-v1 project `docker`, service `minio`). For compose-v2 hosts swap to `docker-minio-1`.

## State

```
docker inspect -f 'state={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restartpolicy={{.HostConfig.RestartPolicy.Name}} startedat={{.State.StartedAt}} finishedat={{.State.FinishedAt}} error={{.State.Error}}' docker_minio_1
```

## Last logs

```
docker logs --tail 200 docker_minio_1 2>&1 | tail -200
```

## Port holders (9000 / 9001 / 9002)

```
ss -tlnp 2>/dev/null | grep -E ':9000|:9001|:9002' || sudo netstat -tlnp 2>/dev/null | grep -E ':9000|:9001|:9002'
```

## Sibling minio containers

```
docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Image}}' | grep -i minio
```

## Mounts

```
docker inspect -f '{{range .Mounts}}{{.Type}} {{.Name}}{{.Source}} -> {{.Destination}}{{println}}{{end}}' docker_minio_1
```

## Disk free on the mount source

```
df -h $(docker inspect -f '{{range .Mounts}}{{.Source}}{{println}}{{end}}' docker_minio_1 | head -1)
```

## Start

```
docker start docker_minio_1
```

## Verify running

```
sleep 5 && docker ps --format '{{.Names}}\t{{.Status}}' | grep docker_minio_1
```

## Boot logs

```
docker logs --tail 80 docker_minio_1 2>&1 | tail -80
```

## In-network readiness probe

```
docker run --rm --network docker_default curlimages/curl:8.10.1 -sf -o /dev/null -w 'minio_ready=%{http_code}\n' http://docker_minio_1:9000/minio/health/ready
```

## If restart-loops, capture next-death

```
docker events --since 1m --filter container=docker_minio_1 --format '{{.Time}} {{.Action}} {{.Actor.Attributes.exitCode}}' & sleep 30 ; kill %1 ; docker logs --tail 100 docker_minio_1
```

## Recent OOM kills on host

```
dmesg -T 2>/dev/null | grep -i -E 'killed process|out of memory' | tail -20
```
