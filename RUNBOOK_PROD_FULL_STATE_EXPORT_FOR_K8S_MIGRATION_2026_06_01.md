# PROD Full-State Export for k8s Migration

Date: 2026-06-01

Companion to the DEV full-state-export runbook in this repo. Same script, same artifact set, two prod-specific defaults:

1. **`langfuse_*` artifacts are excluded by default.** The default `ARTIFACTS=all` covers `litellm_pg n8n_pg ragflow_mysql ragflow_es ragflow_minio openwebui_data n8n_storage secrets`. Opt back in with `ARTIFACTS=all_with_langfuse` (or name the langfuse IDs in a comma list).
2. **Direct streaming to your SSH workstation** through a reverse-port-forwarded `scp`. Artifacts never accumulate on `/tmp` of a prod host, and you don't need a second-hop scp from a bastion afterward — they land directly on the same machine you're SSH'ing from.

Script: [`scripts/k8s_full_export.sh`](scripts/k8s_full_export.sh)

`ENV=` takes the same env identifiers documented in the dev runbook, with `_prod` in place of `_dev`. Substitute `<env>` and `<prod_host>` placeholders below for your environment.

**Assumption:** prod hosts are internet-isolated (no GitHub / public-package access). The script is delivered via `scp` from the operator's repo machine — never `curl`-from-GitHub on the prod host. Same for any patched re-runs.

---

## Section A — One-time workstation-side setup (MobaXterm embedded sshd)

Required so the prod host can `scp` files back through the reverse-forwarded port. MobaXterm ships an embedded OpenSSH server — no `Add-WindowsCapability`, no Administrator PowerShell, no firewall rule needed. The `Add-WindowsCapability` route is in [Appendix 1](#appendix-1--alternative-windows-openssh-server-via-add-windowscapability) for workstations without MobaXterm.

In MobaXterm:

1. Top menubar → **Servers** → **SSH server** → click **Start server** (or **Start**). The status indicator goes green.
2. Note the username MobaXterm advertises in the Servers panel (usually your Windows user) and the port (default `22`).

MobaXterm exposes Windows drives under `/drives/c/...`, not `/c/...` like Microsoft's OpenSSH. Confirm and create the target directory by SSH-ing to your own machine from a local terminal tab:

```bash
ssh -p 22 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null <win_user>@localhost 'mkdir -p /drives/c/exports/prod && ls -ld /drives/c/exports/prod'
```

If that prints the directory, your local sshd is good. (If MobaXterm uses a non-22 port, substitute it everywhere below.)

Linux/macOS workstations: just enable the system sshd (`systemctl enable --now ssh` on Debian/Ubuntu; **System Settings → Sharing → Remote Login** on macOS) and use ordinary `/path/to/exports/prod` paths.

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

Pre-flight scp test — creates a 1-byte file on the workstation (MobaXterm path style):

```bash
echo ping > /tmp/_streamtest && scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null /tmp/_streamtest <win_user>@localhost:/drives/c/exports/prod/ && rm /tmp/_streamtest
```

If the file appears on the workstation under `C:\exports\prod\_streamtest`, streaming is good to go. (If you're on Microsoft OpenSSH instead of MobaXterm, swap `/drives/c/...` → `/c/...`.)

While you're in the SSH session, sanity-check `/tmp` headroom — with `STREAM_DELETE=1`, peak usage is the size of the **largest single artifact**, not the sum (typically ClickHouse or ES):

```bash
df -h /tmp && docker system df
```

If `-R` is blocked, the prod sshd has `AllowTcpForwarding no` — see the fallback in Section D.

---

## Section C — Get the script on the prod host (offline transfer)

Prod is assumed internet-isolated — do **not** try `curl`/`wget` from the prod host. The script ships via `scp` from the operator's repo machine (the same machine that has this runbook checked out).

From the repo machine, in the runbook directory:

```bash
scp scripts/k8s_full_export.sh '<ssh_user>@<prod_host>:/tmp/k8s_full_export.sh'
```

Then on the prod host, make it executable and record its hash:

```bash
chmod +x /tmp/k8s_full_export.sh && sha256sum /tmp/k8s_full_export.sh
```

If the repo machine can't reach the prod host directly (jump-host topology), do a two-hop: `scp` to the jump host, then from the jump host `scp` to the prod host. Verify the sha256 at the final stop matches what `sha256sum scripts/k8s_full_export.sh` prints on the repo machine.

If you re-pull or update the runbook later and need a fresh script on prod, repeat this section — never substitute a download from GitHub on the prod host.

---

## Section D — Run with direct-to-workstation streaming

Inside the SSH session that has `-R 2222:localhost:22` open. `STREAM_DELETE=1` removes each artifact from the prod host immediately after a successful transfer, so `/tmp` never holds more than one large tar at a time.

```bash
STREAM_TO='<win_user>@localhost:/drives/c/exports/prod/<env>' STREAM_PORT=2222 STREAM_DELETE=1 ENV=<env>_prod bash /tmp/k8s_full_export.sh
```

Create the target subdirectory on the workstation first (one per env you'll export):

```powershell
New-Item -ItemType Directory -Force -Path C:\exports\prod\<env>
```

Each `scp` invocation is recorded in the export `.log`; the final manifest is streamed last and includes a `stream_to=...` line for traceability.

### Including Langfuse on a specific host

```bash
STREAM_TO='<win_user>@localhost:/drives/c/exports/prod/<env>' STREAM_PORT=2222 STREAM_DELETE=1 ARTIFACTS=all_with_langfuse ENV=<env>_prod bash /tmp/k8s_full_export.sh
```

### Retrying after a partial failure

`STREAM_DELETE=1` only fires after a successful scp, so a failed transfer leaves the artifact intact on the prod host under `/tmp/k8s_export_<env>_prod_<stamp>/`. Re-run with just the failed ID(s):

```bash
STREAM_TO='<win_user>@localhost:/drives/c/exports/prod/<env>' STREAM_PORT=2222 STREAM_DELETE=1 ARTIFACTS=<failed_id1>,<failed_id2> ENV=<env>_prod bash /tmp/k8s_full_export.sh
```

…or scp the residuals manually from another shell on the prod host:

```bash
scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null /tmp/k8s_export_<env>_prod_<stamp>/<env>_prod_<artifact>_<stamp>.* <win_user>@localhost:/drives/c/exports/prod/<env>/
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

Git Bash / WSL / Linux / macOS (Git Bash & MobaXterm local shell use `/c/...`; MobaXterm's *remote* sshd view of itself uses `/drives/c/...` — for `cd` from a local shell, use `/c/...`):

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
