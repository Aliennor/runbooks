# Runbooks

Public runbook drop. One curated runbook at a time.

## Current

- [RUNBOOK_DEV_FULL_STATE_EXPORT_FOR_K8S_MIGRATION_BANKA_KATILIM_ZT_2026_05_15.md](RUNBOOK_DEV_FULL_STATE_EXPORT_FOR_K8S_MIGRATION_BANKA_KATILIM_ZT_2026_05_15.md) — operator-runnable export of every DEV-server state surface (Postgres, MySQL, ClickHouse, MinIO, ES/OpenSearch, OpenWebUI, n8n, secrets) into separate artifacts for a k8s migration importer. Driver script: [`scripts/k8s_full_export.sh`](scripts/k8s_full_export.sh).
- [RUNBOOK_LITELLM_LOKI_FORENSIC_AUDIT_2026_05_18.md](RUNBOOK_LITELLM_LOKI_FORENSIC_AUDIT_2026_05_18.md) — audit a deployed LiteLLM proxy's stdout in Loki for admin-API mutations and `Authorization`/`Bearer`/`sk-` header leakage over an arbitrary window. Solves the two common deployment gotchas (Loki not bound to host port, Loki's ~30-day `max_query_length` cap). Driver script: [`scripts/loki_litellm_forensic.sh`](scripts/loki_litellm_forensic.sh).
- [RUNBOOK_RAGFLOW_MINIO_EXITED_RESTART_2026_05_21.md](RUNBOOK_RAGFLOW_MINIO_EXITED_RESTART_2026_05_21.md) — bring a RagFlow MinIO container (`docker_minio_1` / `docker-minio-1`) back up after it exits and the other containers in the stack came back without it. Single-container `docker start` path so compose isn't rerun (avoids RagFlow ES `_state/` desync). Includes pre-start inspect (exit code, OOM, mounts, disk-free, port holders) and post-start readiness probe.
