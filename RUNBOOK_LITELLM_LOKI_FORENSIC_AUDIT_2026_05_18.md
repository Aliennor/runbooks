# LiteLLM Loki Forensic Audit

Date: 2026-05-18

Audit a deployed [LiteLLM proxy](https://github.com/BerriAI/litellm) for
two patterns in its historical stdout, without needing access to the
running container itself:

1. **Admin-API mutations** — `POST/PUT/DELETE` on `/key`, `/user`, `/team`, `/model`, `/config`, `/customer`, `/organization`. Useful when you need to know whether anyone hit the management endpoints during a given window and from where.
2. **Authorization-header / Bearer-token / sk- pattern leakage** — relevant after security advisories that ask "did your LiteLLM version log incoming auth headers to stdout?" Useful as the definitive answer when the LiteLLM container has since been recreated and `docker logs` is empty.

Driver script: [`scripts/loki_litellm_forensic.sh`](scripts/loki_litellm_forensic.sh).

## Why this is non-trivial

Two gotchas trip up a naive `curl` against Loki on a typical observability-stack deployment:

1. **Loki often isn't bound to a host port.** It listens on `:3100` inside its docker network but doesn't publish to the host. A `curl http://127.0.0.1:3100/ready` from the host shell returns `connection refused`. Promtail talks to Loki via the docker DNS name `loki`, which doesn't resolve from the host either.
2. **Loki rejects long queries.** Default `max_query_length` is around 30 days. Querying a 75-day window in one call returns `HTTP 400`.

This script handles both:

- **Container-exec dispatch.** It probes candidate containers (`promtail`, `loki`, `grafana`, the litellm container) and uses the first one that has a working `sh` + `wget`/`curl` and can reach `http://loki:3100/ready`. All Loki API calls go through `docker exec` from that container.
- **Window chunking.** The script splits the requested window into 28-day pieces, runs each query separately, and aggregates the counts.

## Requirements

- Bash, `python3` (for URL-encoding and JSON parsing), `docker`, `sudo` (if your user can't run docker rootless).
- A LiteLLM container that ships stdout to Loki via Promtail (default `json-file` driver + a Promtail sidecar tailing `/var/lib/docker/containers/*/*-json.log` is the canonical setup).
- A container on Loki's docker network with `sh` + `wget` or `curl`. Promtail is the canonical choice; the script falls back to other candidates if promtail is distroless.

## Required env

| Variable | Format | Example |
|---|---|---|
| `LOKI_START` | RFC3339 timestamp, the start of the audit window | `2026-04-15T00:00:00Z` |
| `LOKI_END` | RFC3339 timestamp, the end of the audit window | `2026-05-15T00:00:00Z` |

Set both before running. There are no defaults — if either is missing the script exits with an error explaining how to set them.

## Optional env

| Variable | Default | What it does |
|---|---|---|
| `LITELLM_CONTAINER` | `litellm` | The container-name value the script substitutes into LogQL selectors like `{container_name="..."}`. Change this if your container is named `litellm-proxy` or similar. |

## Run

On a host that has both `docker ps` access and at least one container on Loki's network:

```bash
LOKI_START='2026-04-15T00:00:00Z' \
LOKI_END='2026-05-15T00:00:00Z' \
bash scripts/loki_litellm_forensic.sh 2>&1 | tee /tmp/loki_litellm_audit_$(hostname)_$(date +%Y%m%d_%H%M%S).log
```

The script prints to stdout; `tee` captures the full output for paste-back / archival.

## Output layout

The script emits 8 sections separated by banners like `========== <N> ... ==========`. The interesting ones:

- **Section 1** — which container the script picked for `docker exec`. If it errors here, no container on the host has both a usable shell and connectivity to `loki:3100`.
- **Section 4** — which LogQL label (`container_name`, `compose_service`, etc.) actually selects the litellm container in your Promtail setup. Probed against the last hour of data.
- **Section 6** — per-chunk count of admin-API mutations across the window, with up to 20 sample lines per non-zero chunk.
- **Section 7** — per-chunk count of `Authorization` / `Bearer` / `sk-` matches, with up to 10 sample lines per non-zero chunk.
- **Section 8** — earliest line in the window per the chosen selector. Tells you whether Loki retention actually covers the start of your window. If the earliest line is later than `LOKI_START`, either widen the window or accept that retention aged out the earlier data.
- **VERDICT** — final summary.

## Interpreting the verdict

| Section 6 admin total | Section 7 auth-leak total | Section 8 earliest line | What it means |
|---|---|---|---|
| anything | `0` | inside `[LOKI_START..LOKI_END]` | LiteLLM did not log auth headers in this window. Audit closed. |
| anything | `0` | later than `LOKI_START` | Loki retention has aged out the early window. Either widen / re-run, or accept that you can only confirm "no leaks after X". |
| anything | `> 0` | anything | Auth headers WERE logged. Read the sample lines, identify exposed keys / users, prioritize their rotation. |

Section 6 ("admin mutations") is informational — useful for correlating with API key creation timestamps if you're tracking who minted what. It does not change the auth-leak verdict.

## Caveats

- This audit only checks the LiteLLM container's stdout. If your proxy was behind an nginx vhost that *also* logged headers (uncommon but possible), check that nginx vhost's access log too.
- The auth-leak regex catches `Authorization:`, `Bearer <8+ chars>`, and `sk-<16+ chars>`. It will not catch base64-encoded or otherwise-encoded credentials. The advisory class this audit was written for involved plaintext echo of incoming headers, which this pattern matches reliably.
- Loki's response is JSON. The script parses with `python3` — if your host lacks `python3`, install it (most modern distros ship it; the script does not attempt `python2`).
- Promtail being on Loki's network is an assumption. If your observability stack runs promtail on a different network than Loki, you'll need to either pick a different container in `probe_container` or run the script from one that satisfies both constraints.
