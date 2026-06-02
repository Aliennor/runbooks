# PROD Full-State Export — Local Staging (No Streaming)

Date: 2026-06-02

Script: [`scripts/k8s_full_export.sh`](scripts/k8s_full_export.sh)

For workstations with limited SSH tools (no reverse-port-forwarding, no embedded sshd) — script and artifacts both live on the prod host's `/tmp`, then a single file-transfer at the end pulls the staging directory to the workstation. Same script as the streaming variant runbook; this path simply omits `STREAM_*`.

---

## Section A — Deliver script to prod

1. On the workstation, save <https://raw.githubusercontent.com/Aliennor/runbooks/main/scripts/k8s_full_export.sh> as `C:\exports\scripts\k8s_full_export.sh` (Notepad++ → EOL = Unix LF, Encoding = UTF-8 without BOM).
2. SSH into the prod host with the SSH tool. Use its SFTP / file-transfer feature to upload `C:\exports\scripts\k8s_full_export.sh` → `/tmp/k8s_full_export.sh`.
3. Strip BOM + CRLF, mark executable, hash, dry-run:

```bash
sed -i '1s/^\xEF\xBB\xBF//' /tmp/k8s_full_export.sh && sed -i 's/\r$//' /tmp/k8s_full_export.sh && chmod +x /tmp/k8s_full_export.sh && sha256sum /tmp/k8s_full_export.sh && wc -l /tmp/k8s_full_export.sh
```

```bash
ARTIFACTS=list ENV=<env>_prod bash /tmp/k8s_full_export.sh
```

Shebang byte check (must show `# ! / u s r / b i n / e n v   b a s h \n` — no `\r`, no BOM):

```bash
head -1 /tmp/k8s_full_export.sh | od -c | head -2
```

---

## Section B — Pre-flight on prod

```bash
df -h /tmp && docker system df && docker ps --format '{{.Names}}' | sort
```

---

## Section C — Run

`/tmp` holds ALL artifacts at once. Default `ARTIFACTS=all` = `litellm_pg n8n_pg ragflow_mysql ragflow_es ragflow_minio openwebui_data n8n_storage secrets` (langfuse_* excluded).

### C.1 — Full run

```bash
ENV=<env>_prod bash /tmp/k8s_full_export.sh 2>&1 | tee /tmp/<env>_prod_export_console.txt
```

### C.2 — Subset batching (tight `/tmp`)

```bash
ARTIFACTS=litellm_pg,n8n_pg,ragflow_mysql,secrets ENV=<env>_prod bash /tmp/k8s_full_export.sh 2>&1 | tee /tmp/<env>_prod_export_console.txt
```

After pull + delete, next batch:

```bash
ARTIFACTS=ragflow_es,ragflow_minio,openwebui_data,n8n_storage ENV=<env>_prod bash /tmp/k8s_full_export.sh 2>&1 | tee -a /tmp/<env>_prod_export_console.txt
```

### C.3 — Including Langfuse

```bash
ARTIFACTS=all_with_langfuse ENV=<env>_prod bash /tmp/k8s_full_export.sh 2>&1 | tee -a /tmp/<env>_prod_export_console.txt
```

### C.4 — Manual container-restart recovery

```bash
docker ps -a --filter status=exited --format '{{.Names}}' | xargs -r -n1 docker start && docker ps --format '{{.Names}}\t{{.Status}}' | column -t
```

---

## Section D — Confirm + pull

Confirm staging on prod:

```bash
ls -1 /tmp/k8s_export_<env>_prod_*/ && du -sh /tmp/k8s_export_<env>_prod_*
```

Pull `/tmp/k8s_export_<env>_prod_<stamp>/` from prod to the workstation via the SSH tool's SFTP / download feature → workstation directory (e.g. `C:\exports\prod\<env>\`).

---

## Section E — Verify on workstation

PowerShell:

```powershell
Get-FileHash -Algorithm SHA256 .\<env>_prod_<artifact>_<stamp>.tar.gz
```

Git Bash / WSL:

```bash
(cd /c/exports/prod/<env>/k8s_export_<env>_prod_* && grep -E '^[0-9a-f]{64}' *_manifest_*.txt | sha256sum -c 2>&1 | tail -20)
```

---

## Section F — Cleanup prod

```bash
rm -rf /tmp/k8s_export_<env>_prod_*
```

---

## Section G — Paste-back per env

- `<env>_prod_manifest_<stamp>.txt`
- Section E sha256 output (last 20 lines)
- any `FAIL` / `SKIP` rows
- size of `<env>_prod_secrets_<stamp>.tar.gz`
- `ls -1 /tmp/k8s_export_<env>_prod_<stamp>/ 2>/dev/null | wc -l` (expect 0 after Section F)
