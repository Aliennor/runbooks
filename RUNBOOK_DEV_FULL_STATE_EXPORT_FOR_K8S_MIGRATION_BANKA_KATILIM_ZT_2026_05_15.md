# DEV Full-State Export for k8s Migration — Banka DEV, Katilim DEV, ZT ARF DEV

Date: 2026-05-15

Single-script export. Successor to `RUNBOOK_DEV_INTERNAL_SERVICES_DB_DUMPS_BANKA_ZT_KATILIM_2026_05_15.md`
(SQL only). One bash invocation per host produces every artifact required to
rehydrate the stack on k8s with no extra effort: SQL dumps + ClickHouse +
MinIO buckets + ES/OpenSearch indices + OpenWebUI / n8n volumes + secrets
bundle + manifest. No paste-back per artifact.

Script: [`scripts/k8s_full_export.sh`](scripts/k8s_full_export.sh)

Every artifact is its own separate file (no final bundle), and you can pick exactly which ones to export per run via `ARTIFACTS=` / `SKIP=` env vars.

## Hard Rules Baked Into The Script

- `docker stop` / `docker start` only — **never `compose down/up`** (RagFlow ES `_state/` desync).
- Each artifact runs in its own guarded function: missing containers → SKIP, errors → FAIL, run never aborts.
- Volume tars use `--volumes-from` + a tar-capable image. The script auto-detects from `TAR_IMAGE_CANDIDATES` (default: `alpine alpine:3.20 alpine:3.19 alpine:3.18 busybox nginx:alpine`) — first local match wins, no network pull. Override with `TAR_IMAGE=<image>` to force a specific tag.
- Volume tars emit heartbeat lines every `HEARTBEAT` seconds (default 15) while running, so long ClickHouse / ES tars are visibly progressing.
- If no candidate image is present locally, volume tars SKIP cleanly and the manifest records the reason; SQL dumps still proceed.
- Manifest is generated last with sha256 + size + container→image table + per-artifact status (OK / SKIP / FAIL).

## Artifact Set Per Host

| File | Source | Purpose |
|---|---|---|
| `<env>_litellm_pg_<stamp>.sql` | `shared_postgres` db `litellm` | virtual keys, model rows, spend |
| `<env>_langfuse_pg_<stamp>.sql` | `shared_postgres` db `langfuse` | orgs, projects, API keys, members |
| `<env>_n8n_pg_<stamp>.sql` | `shared_postgres` db `n8n` | workflows, credentials (encrypted), executions |
| `<env>_ragflow_mysql_<stamp>.sql` | `docker-mysql-1` db `rag_flow` | KBs, tenants, llm bindings, doc metadata |
| `<env>_langfuse_clickhouse_<stamp>.tar.gz` | `langfuse_clickhouse_data` vol | trace / observation rows |
| `<env>_langfuse_minio_<stamp>.tar.gz` | `langfuse_minio_data` vol | event blobs + media uploads |
| `<env>_ragflow_es_<stamp>.tar.gz` | `esdata01` (or `osdata01`) vol | RagFlow vector indices |
| `<env>_ragflow_minio_<stamp>.tar.gz` | RagFlow `minio_data` vol | source-doc blobs |
| `<env>_openwebui_data_<stamp>.tar.gz` | `openwebui_data` vol | sqlite db, uploads, chromadb |
| `<env>_n8n_storage_<stamp>.tar.gz` | `n8n_storage` vol | `.n8n/config` (encryption key), binaryData |
| `<env>_secrets_<stamp>.tar.gz` | `.env`, `docker-compose*.yml`, `nginx.conf` under `/opt /srv /root /etc/internal_services /home` | every key needed to read the dumps |
| `<env>_manifest_<stamp>.txt` | generated | sha256, sizes, image tags, container names, statuses |
| `<env>_export_<stamp>.log` | generated | full log of the run |

Importer reads `manifest.txt` first. **The secrets bundle is the most sensitive
file** — without it, n8n credentials and Langfuse trace bodies are unreadable.

---

## Artifact IDs (for `ARTIFACTS=` / `SKIP=`)

```
litellm_pg            langfuse_pg            n8n_pg
ragflow_mysql         langfuse_clickhouse    langfuse_minio
ragflow_es            ragflow_minio          openwebui_data
n8n_storage           secrets
```

`ARTIFACTS=all` (the default) **excludes the langfuse_* trio** (`langfuse_pg`, `langfuse_clickhouse`, `langfuse_minio`). To include them either name them explicitly (`ARTIFACTS=langfuse_pg,langfuse_clickhouse,langfuse_minio,...`) or use `ARTIFACTS=all_with_langfuse`.

### Streaming artifacts straight to your workstation

Set `STREAM_TO=<user>@<host>:/<path>` and each OK artifact is `scp`-pushed as soon as it's produced. Combine with `STREAM_DELETE=1` to free `/tmp` on the source. Use `STREAM_PORT=<n>` when scp'ing through a reverse-forwarded port. Manifest + log are streamed at the end of the run. See the prod runbook (internal repo) for the Windows-side OpenSSH-Server / reverse-port-forward recipe.

Print the menu on a host without running anything:

```bash
ARTIFACTS=list bash /tmp/k8s_full_export.sh banka_dev
```

---

## Section A — Get The Script On Each Host

From your Mac, in this repo:

```bash
scp scripts/k8s_full_export.sh '<user>@10.11.115.108:/tmp/k8s_full_export.sh'
```

```bash
scp scripts/k8s_full_export.sh '<user>@10.210.22.88:/tmp/k8s_full_export.sh'
```

```bash
scp scripts/k8s_full_export.sh '<user>@<zt_arf_dev_host>:/tmp/k8s_full_export.sh'
```

Verify on each host (sha256 of the script is printed at the top of the manifest after any run; compare against the value in `git log` for the `scripts/k8s_full_export.sh` you scp'd):

```bash
sha256sum /tmp/k8s_full_export.sh
```

---

## Section B — Run On Each Host

Default = export everything. Banka DEV (10.11.115.108):

```bash
ENV=banka_dev bash /tmp/k8s_full_export.sh
```

Katilim DEV (10.210.22.88):

```bash
ENV=katilim_dev bash /tmp/k8s_full_export.sh
```

ZT ARF DEV:

```bash
ENV=zt_arf_dev bash /tmp/k8s_full_export.sh
```

### Choosing what to export

Only a subset:

```bash
ARTIFACTS=litellm_pg,n8n_pg,openwebui_data bash /tmp/k8s_full_export.sh banka_dev
```

Exclude a few from "all":

```bash
SKIP=ragflow_es,ragflow_minio bash /tmp/k8s_full_export.sh banka_dev
```

Just databases (skip every volume tar):

```bash
ARTIFACTS=litellm_pg,langfuse_pg,n8n_pg,ragflow_mysql,secrets bash /tmp/k8s_full_export.sh banka_dev
```

Just OpenWebUI:

```bash
ARTIFACTS=openwebui_data,secrets bash /tmp/k8s_full_export.sh banka_dev
```

Output lands in `/tmp/k8s_export_<env>_<stamp>/`. The final summary
(printed at end of run) contains the full manifest, marking each
unselected/unfound artifact accordingly.

### Tar image selection (hosts that can't pull `alpine:latest`)

By default the script scans for one of [`alpine`, `alpine:3.20`, `alpine:3.19`, `alpine:3.18`, `busybox`, `nginx:alpine`] and uses the first one already present locally — **no network pull**. The chosen image is logged at startup (`tar image: <name> (auto-selected, ...)`) and again on every heartbeat line.

To force a specific image (must exist locally; no auto-pull):

```bash
TAR_IMAGE=alpine:3.20 ENV=banka_dev bash /tmp/k8s_full_export.sh
```

To extend the candidate list (any image with `tar` works — `busybox`, `debian:bookworm-slim`, `nginx:alpine`, etc.):

```bash
TAR_IMAGE_CANDIDATES="alpine alpine:3.20 nginx:alpine debian:bookworm-slim" ENV=banka_dev bash /tmp/k8s_full_export.sh
```

If none of the candidates are present, volume tars SKIP for that run and the manifest records the reason — SQL dumps still proceed. Pull any tar-capable image locally (`docker pull alpine` etc.) and re-run only the volume artifacts:

```bash
ARTIFACTS=langfuse_clickhouse,langfuse_minio,ragflow_es,ragflow_minio,openwebui_data,n8n_storage \
  ENV=banka_dev bash /tmp/k8s_full_export.sh
```

---

## Section C — Pull To Mac

Replace `<EXPORT_DIR>` with the path printed by the script (or glob it).

```bash
mkdir -p ~/k8s_migration_exports/banka_dev && scp -r '<user>@10.11.115.108:/tmp/k8s_export_banka_dev_*' ~/k8s_migration_exports/banka_dev/
```

```bash
mkdir -p ~/k8s_migration_exports/katilim_dev && scp -r '<user>@10.210.22.88:/tmp/k8s_export_katilim_dev_*' ~/k8s_migration_exports/katilim_dev/
```

```bash
mkdir -p ~/k8s_migration_exports/zt_arf_dev && scp -r '<user>@<zt_arf_dev_host>:/tmp/k8s_export_zt_arf_dev_*' ~/k8s_migration_exports/zt_arf_dev/
```

Verify checksums on Mac match the manifest:

```bash
for d in ~/k8s_migration_exports/*/k8s_export_*; do echo "--- $d ---"; (cd "$d" && grep -E '^[0-9a-f]{64}' *_manifest_*.txt | sha256sum -c 2>&1 | tail -20); done
```

---

## Section D — Handoff Layout (what the importer receives)

```
~/k8s_migration_exports/
├── banka_dev/k8s_export_banka_dev_<stamp>/
│   ├── banka_dev_manifest_<stamp>.txt          <- read first
│   ├── banka_dev_export_<stamp>.log
│   ├── banka_dev_litellm_pg_<stamp>.sql
│   ├── banka_dev_langfuse_pg_<stamp>.sql
│   ├── banka_dev_n8n_pg_<stamp>.sql
│   ├── banka_dev_ragflow_mysql_<stamp>.sql
│   ├── banka_dev_langfuse_clickhouse_<stamp>.tar.gz
│   ├── banka_dev_langfuse_minio_<stamp>.tar.gz
│   ├── banka_dev_ragflow_es_<stamp>.tar.gz
│   ├── banka_dev_ragflow_minio_<stamp>.tar.gz
│   ├── banka_dev_openwebui_data_<stamp>.tar.gz
│   ├── banka_dev_n8n_storage_<stamp>.tar.gz
│   └── banka_dev_secrets_<stamp>.tar.gz        <- highest sensitivity
├── katilim_dev/k8s_export_katilim_dev_<stamp>/...
└── zt_arf_dev/k8s_export_zt_arf_dev_<stamp>/...
```

---

## Section E — Restore Reference (k8s side)

Generic one-liners. `<ns>` = target namespace per env.

### E.1 Postgres dbs

```bash
kubectl -n <ns> exec -i <postgres-pod> -- psql -U admin -d litellm < <env>_litellm_pg_<stamp>.sql
```

```bash
kubectl -n <ns> exec -i <postgres-pod> -- psql -U admin -d langfuse < <env>_langfuse_pg_<stamp>.sql
```

```bash
kubectl -n <ns> exec -i <postgres-pod> -- psql -U admin -d n8n < <env>_n8n_pg_<stamp>.sql
```

### E.2 RagFlow MySQL

```bash
kubectl -n <ns> exec -i <mysql-pod> -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' < <env>_ragflow_mysql_<stamp>.sql
```

### E.3 Volume tars → PVC (pattern; repeat per artifact)

Target pod scaled to 0, PVC empty, then:

```bash
kubectl -n <ns> cp <env>_langfuse_clickhouse_<stamp>.tar.gz <loader-pod>:/tmp/ && kubectl -n <ns> exec <loader-pod> -- sh -c 'cd /var/lib/clickhouse && tar xzf /tmp/<env>_langfuse_clickhouse_*.tar.gz && rm /tmp/<env>_langfuse_clickhouse_*.tar.gz'
```

Mount targets per artifact:

| Artifact | Mount path in target pod |
|---|---|
| `langfuse_clickhouse` | `/var/lib/clickhouse` |
| `langfuse_minio` | `/data` |
| `ragflow_es` | `/usr/share/elasticsearch/data` (or `/usr/share/opensearch/data` — manifest names which) |
| `ragflow_minio` | `/data` |
| `openwebui_data` | `/app/backend/data` |
| `n8n_storage` | `/home/node/.n8n` |

### E.4 Secrets → k8s Secret per service

The `.env` files inside `<env>_secrets_<stamp>.tar.gz` are the source of truth. Keys that **must match** the dumps or data becomes unreadable:

- `langfuse/.env` → `ENCRYPTION_KEY`, `SALT`, `NEXTAUTH_SECRET`, `CLICKHOUSE_PASSWORD`, `REDIS_AUTH`, `MINIO_ROOT_PASSWORD`, `LANGFUSE_S3_*_SECRET_ACCESS_KEY`
- `litellm/.env` → `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, `DATABASE_URL`
- `n8n/.env` + `n8n_storage/config` → `N8N_ENCRYPTION_KEY` (in `.n8n/config`, **also** inside the volume tar — both must match)
- `openweb-ui/.env` → `WEBUI_SECRET_KEY`
- `ragflow/.env` → `MINIO_*`, `MYSQL_*`, `ELASTIC_PASSWORD`

---

## Section F — Paste-Back Checklist

Per env, return to chat:

- contents of `<env>_manifest_<stamp>.txt` (full)
- output of Section C checksum verify (last 20 lines)
- any line in the manifest with status `FAIL` or `SKIP`
- size of `<env>_secrets_<stamp>.tar.gz` (so it's clear the secrets actually got captured)
