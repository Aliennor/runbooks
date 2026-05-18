# LiteLLM Loki Forensic Audit

Audit a LiteLLM proxy's stdout in Loki for admin-API mutations and `Authorization`/`Bearer`/`sk-` leakage over a time window.

Driver: [`scripts/loki_litellm_forensic.sh`](scripts/loki_litellm_forensic.sh).

## Env

| var | required | example |
|---|---|---|
| `LOKI_START` | yes | `2026-04-15T00:00:00Z` |
| `LOKI_END` | yes | `2026-05-15T00:00:00Z` |
| `LITELLM_CONTAINER` | no (default `litellm`) | `litellm-proxy` |

## Run

```bash
LOKI_START='2026-04-15T00:00:00Z' LOKI_END='2026-05-15T00:00:00Z' bash scripts/loki_litellm_forensic.sh 2>&1 | tee /tmp/loki_litellm_audit_$(hostname)_$(date +%Y%m%d_%H%M%S).log
```
