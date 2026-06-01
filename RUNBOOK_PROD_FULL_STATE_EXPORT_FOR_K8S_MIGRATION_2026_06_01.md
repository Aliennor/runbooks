# PROD Full-State Export for k8s Migration

Date: 2026-06-01

Script: [`scripts/k8s_full_export.sh`](scripts/k8s_full_export.sh)

Defaults vs DEV runbook: `langfuse_*` excluded from `ARTIFACTS=all` (use `ARTIFACTS=all_with_langfuse` to include); artifacts stream directly to the SSH workstation via reverse-forwarded scp (`STREAM_TO=...`). Prod hosts assumed internet-isolated — script delivered via scp, never curl/wget.

---

## Section A — One-time workstation-side setup (MobaXterm embedded sshd)

In MobaXterm: **Servers → SSH server → Start**. Note username + port.

Loopback test + target dir from a MobaXterm local terminal tab:

```bash
ssh -p 22 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null <win_user>@localhost 'mkdir -p /drives/c/exports/prod && ls -ld /drives/c/exports/prod'
```

Linux/macOS workstations: enable system sshd and use `/c/...` → `/path/to/exports/prod`. Microsoft OpenSSH on Windows: see [Appendix 1](#appendix-1--alternative-windows-openssh-server-via-add-windowscapability) and use `/c/...` instead of `/drives/c/...`.

---

## Section B — Open SSH with a reverse port forward + install key auth

### B.1 — Open the SSH session with reverse forward

```bash
ssh -R 2222:localhost:22 <ssh_user>@<prod_host>
```

Verify tunnel on prod:

```bash
ss -tlnp 2>/dev/null | grep 2222 || netstat -tlnp 2>/dev/null | grep 2222
```

### B.2 — Install SSH key auth (per prod host, before the export run)

On the prod host:

```bash
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub
```

On the workstation (MobaXterm local terminal tab), replacing `<paste>` with the line above:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '<paste>' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
```

Verify from the prod host:

```bash
ssh -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null <win_user>@localhost 'echo KEY_AUTH_OK'
```

### B.3 — Pre-flight scp + headroom check

```bash
echo ping > /tmp/_streamtest && scp -P 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null /tmp/_streamtest <win_user>@localhost:/drives/c/exports/prod/ && rm /tmp/_streamtest
```

```bash
df -h /tmp && docker system df
```

---

## Section C — Get the script on the prod host (offline transfer)

### C.1 — scp from the operator's repo machine

```bash
scp scripts/k8s_full_export.sh '<ssh_user>@<prod_host>:/tmp/k8s_full_export.sh'
```

```bash
chmod +x /tmp/k8s_full_export.sh && sha256sum /tmp/k8s_full_export.sh
```

### C.2 — Workstation GUI authoring + MobaXterm SFTP upload

1. Save script content to `C:\exports\scripts\k8s_full_export.sh` (in Notepad++: EOL = Unix LF, Encoding = UTF-8 without BOM).
2. Drag from Windows Explorer into MobaXterm left-pane SFTP at `/tmp/` on the prod host.
3. Strip BOM + CRLF, make executable, hash, dry-run:

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

### C.3 — Refreshing the script after a runbook update

Repeat C.1 or C.2 to overwrite `/tmp/k8s_full_export.sh`, then re-verify sha256.

---

## Section D — Run with direct-to-workstation streaming

Per-env workstation subfolder (from a MobaXterm local terminal tab):

```bash
mkdir -p /drives/c/exports/prod/<env>
```

Default `ARTIFACTS=all` = `litellm_pg n8n_pg ragflow_mysql ragflow_es ragflow_minio openwebui_data n8n_storage secrets` (langfuse_* excluded).

Manual container-restart recovery:

```bash
docker ps -a --filter status=exited --format '{{.Names}}' | xargs -r -n1 docker start && docker ps --format '{{.Names}}\t{{.Status}}' | column -t
```

### D.1 — Per-env worked sequence

Pre-flight on prod host:

```bash
df -h /tmp && docker system df && docker ps --format '{{.Names}}' | sort
```

Export run:

```bash
STREAM_TO='<win_user>@localhost:/drives/c/exports/prod/<env>' STREAM_PORT=2222 STREAM_DELETE=1 ENV=<env>_prod bash /tmp/k8s_full_export.sh 2>&1 | tee /tmp/<env>_prod_export_console.txt
```

Confirm prod staging dir is empty:

```bash
ls -1 /tmp/k8s_export_<env>_prod_*/ | head -20 ; du -sh /tmp/k8s_export_<env>_prod_*
```

Workstation file listing:

```powershell
Get-ChildItem C:\exports\prod\<env> -Filter '<env>_prod_*' | Sort-Object Name
```

sha256 cross-check (MobaXterm local terminal):

```bash
(cd /c/exports/prod/<env> && grep -E '^[0-9a-f]{64}' *_manifest_*.txt | sha256sum -c 2>&1 | tail -20)
```

### D.2 — Additional envs

Repeat B + D.1 against each remaining prod host (new `<env>`, new `<prod_host>`).

### D.3 — Including Langfuse

```bash
STREAM_TO='<win_user>@localhost:/drives/c/exports/prod/<env>' STREAM_PORT=2222 STREAM_DELETE=1 ARTIFACTS=all_with_langfuse ENV=<env>_prod bash /tmp/k8s_full_export.sh
```

### D.4 — Retrying after a tar/dump failure (re-create artifact)

```bash
STREAM_TO='<win_user>@localhost:/drives/c/exports/prod/<env>' STREAM_PORT=2222 STREAM_DELETE=1 ARTIFACTS=<failed_id1>,<failed_id2> ENV=<env>_prod bash /tmp/k8s_full_export.sh
```

### D.5 — Fallback: no workstation sshd, or `AllowTcpForwarding no`

Drop the `STREAM_*` env vars; the script behaves exactly as in the dev runbook (writes to `/tmp/k8s_export_<env>_prod_<stamp>/`, you scp the directory afterward per Section C of the dev runbook, just with `_prod` in the env identifier). With MobaXterm you can also skip scp entirely: the left-pane SFTP browser follows your remote `cd`, so navigate into the staging directory and drag it onto Windows Explorer.

### D.6 — Salvaging artifacts from a partially-streamed run (artifact exists, scp failed)

```bash
ls -lh /tmp/k8s_export_<env>_prod_*/
```

```bash
EXPDIR=$(ls -1d /tmp/k8s_export_<env>_prod_*/ | head -1) && scp -P 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$EXPDIR"*.sql "$EXPDIR"*.tar.gz "$EXPDIR"*.txt "$EXPDIR"*.log <win_user>@localhost:/drives/c/exports/prod/<env>/
```

```bash
rm -rf "$EXPDIR"
```

---

## Section E — Verify on the workstation

PowerShell:

```powershell
Get-FileHash -Algorithm SHA256 .\<env>_prod_<artifact>_<stamp>.tar.gz
```

Git Bash / MobaXterm local terminal:

```bash
(cd /c/exports/prod/<env> && grep -E '^[0-9a-f]{64}' *_manifest_*.txt | sha256sum -c 2>&1 | tail -20)
```

---

## Section F — Paste-back per env

- `<env>_prod_manifest_<stamp>.txt`
- Section E sha256 output (last 20 lines)
- any `FAIL` / `SKIP` rows
- size of `<env>_prod_secrets_<stamp>.tar.gz`
- `ls -1 /tmp/k8s_export_<env>_prod_<stamp>/ | wc -l` (expect 0)

---

## Appendix 1 — Alternative: Windows OpenSSH Server via `Add-WindowsCapability`

Use this only if MobaXterm isn't available on the workstation. Replaces Section A; the rest of the runbook is unchanged **except** that paths become `/c/exports/prod/<env>` instead of `/drives/c/exports/prod/<env>` (Microsoft OpenSSH exposes drives without the `/drives` prefix).

In an Administrator PowerShell:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
```

```powershell
Set-Service -Name sshd -StartupType Automatic; Start-Service sshd
```

```powershell
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
```

Confirm sshd is listening:

```powershell
Get-Service sshd; netstat -ano | findstr ":22 "
```

Create the target directory:

```powershell
New-Item -ItemType Directory -Force -Path C:\exports\prod
```
