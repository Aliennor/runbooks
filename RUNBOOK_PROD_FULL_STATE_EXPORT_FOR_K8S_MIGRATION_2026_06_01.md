# PROD Full-State Export for k8s Migration

Date: 2026-06-01

Companion to the DEV full-state-export runbook in this repo. Same script, same artifact set, two prod-specific defaults:

1. **`langfuse_*` artifacts are excluded by default.** The default `ARTIFACTS=all` covers `litellm_pg n8n_pg ragflow_mysql ragflow_es ragflow_minio openwebui_data n8n_storage secrets`. Opt back in with `ARTIFACTS=all_with_langfuse` (or name the langfuse IDs in a comma list).
2. **Direct streaming to your SSH workstation** through a reverse-port-forwarded `scp`. Artifacts never accumulate on `/tmp` of a prod host, and you don't need a second-hop scp from a bastion afterward — they land directly on the same machine you're SSH'ing from.

Script: [`scripts/k8s_full_export.sh`](scripts/k8s_full_export.sh)

`ENV=` takes the same env identifiers documented in the dev runbook, with `_prod` in place of `_dev`. Substitute `<env>` and `<prod_host>` placeholders below for your environment.

---

## Section A — One-time workstation-side setup (Windows OpenSSH Server)

Required so the prod host can `scp` files back through the reverse-forwarded port. Windows 10/11 ships OpenSSH Server as an optional feature; Linux/macOS workstations already have sshd or can enable it via standard package managers (`systemctl enable --now ssh` on Debian/Ubuntu; "Remote Login" in System Settings on macOS).

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

Create the target directory (adjust drive/path as you like):

```powershell
New-Item -ItemType Directory -Force -Path C:\exports\prod
```

Note the Windows username you'll scp as. Under OpenSSH for Windows, paths like `C:\exports\prod` are written `/c/exports/prod` on the scp command line.

---

## Section B — Open SSH with a reverse port forward

From the workstation, when SSH-ing to the prod host, add `-R 2222:localhost:22`. This exposes the workstation's sshd (port 22) on the **prod host's** `localhost:2222`. Any `scp` from the prod host targeting `localhost:2222` lands files on the workstation. Pick any unused source-side port (`2222` is just a common choice).

```bash
ssh -R 2222:localhost:22 <ssh_user>@<prod_host>
```

Inside the SSH session, verify the tunnel:

```bash
ss -tlnp 2>/dev/null | grep 2222 || netstat -tlnp 2>/dev/null | grep 2222
```

Pre-flight scp test — creates a 1-byte file on the workstation:

```bash
echo ping > /tmp/_streamtest && scp -P 2222 -o StrictHostKeyChecking=accept-new /tmp/_streamtest <win_user>@localhost:/c/exports/prod/ && rm /tmp/_streamtest
```

If the file appears on the workstation under `C:\exports\prod\_streamtest`, streaming is good to go.

If `-R` is blocked, the prod sshd has `AllowTcpForwarding no` — see the fallback in Section D.

---

## Section C — Get the script on the prod host

From wherever you keep this runbook's repo, push the script in:

```bash
scp scripts/k8s_full_export.sh '<ssh_user>@<prod_host>:/tmp/k8s_full_export.sh'
```

Verify on the host:

```bash
sha256sum /tmp/k8s_full_export.sh
```

---

## Section D — Run with direct-to-workstation streaming

Inside the SSH session that has `-R 2222:localhost:22` open. `STREAM_DELETE=1` removes each artifact from the prod host immediately after a successful transfer, so `/tmp` never holds more than one large tar at a time.

```bash
STREAM_TO='<win_user>@localhost:/c/exports/prod/<env>' STREAM_PORT=2222 STREAM_DELETE=1 ENV=<env>_prod bash /tmp/k8s_full_export.sh
```

Create the target subdirectory on the workstation first (one per env you'll export):

```powershell
New-Item -ItemType Directory -Force -Path C:\exports\prod\<env>
```

Each `scp` invocation is recorded in the export `.log`; the final manifest is streamed last and includes a `stream_to=...` line for traceability.

### Including Langfuse on a specific host

```bash
STREAM_TO='<win_user>@localhost:/c/exports/prod/<env>' STREAM_PORT=2222 STREAM_DELETE=1 ARTIFACTS=all_with_langfuse ENV=<env>_prod bash /tmp/k8s_full_export.sh
```

### Retrying after a partial failure

`STREAM_DELETE=1` only fires after a successful scp, so a failed transfer leaves the artifact intact on the prod host under `/tmp/k8s_export_<env>_prod_<stamp>/`. Re-run with just the failed ID(s):

```bash
STREAM_TO='<win_user>@localhost:/c/exports/prod/<env>' STREAM_PORT=2222 STREAM_DELETE=1 ARTIFACTS=<failed_id1>,<failed_id2> ENV=<env>_prod bash /tmp/k8s_full_export.sh
```

…or scp the residuals manually from another shell on the prod host:

```bash
scp -P 2222 -o StrictHostKeyChecking=accept-new /tmp/k8s_export_<env>_prod_<stamp>/<env>_prod_<artifact>_<stamp>.* <win_user>@localhost:/c/exports/prod/<env>/
```

### Fallback: no workstation sshd, or `AllowTcpForwarding no`

Drop the `STREAM_*` env vars; the script behaves exactly as in the dev runbook (writes to `/tmp/k8s_export_<env>_prod_<stamp>/`, you scp the directory afterward per Section C of the dev runbook, just with `_prod` in the env identifier).

---

## Section E — Verify on the workstation

The manifest contains sha256 + size for every OK artifact. From the workstation:

PowerShell:

```powershell
Get-FileHash -Algorithm SHA256 .\<env>_prod_<artifact>_<stamp>.tar.gz
```

Git Bash / WSL / Linux / macOS:

```bash
(cd /c/exports/prod/<env> && grep -E '^[0-9a-f]{64}' *_manifest_*.txt | sha256sum -c 2>&1 | tail -20)
```

---

## Section F — Paste-back checklist

Per env, return to chat:

- contents of `<env>_prod_manifest_<stamp>.txt` (full)
- output of Section E sha256 cross-check (last 20 lines)
- any line in the manifest with status `FAIL` or `SKIP`
- size of `<env>_prod_secrets_<stamp>.tar.gz` (so it's clear the secrets actually got captured)
- confirmation that the prod-side staging directory was emptied by `STREAM_DELETE=1`:
  ```bash
  ls -1 /tmp/k8s_export_<env>_prod_<stamp>/ | wc -l
  ```
  should print `0` (or only the manifest+log, if you kept those locally too).
