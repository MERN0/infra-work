# infra-work: LiteLLM + Langfuse + vLLM(gpt-oss-130b)

Docker-based stack tying together:
- **LiteLLM** — proxy fronting ~12 provider API keys plus a self-hosted
  `gpt-oss-130b` (vLLM, on a separate host) as a unified OpenAI-compatible
  gateway, with per-team virtual keys and prompt-injection guardrails.
- **Langfuse (self-hosted v3)** — receives traces from every LiteLLM call
  for observability, and is the home for datasets/evaluators/experiments.
- **vLLM (remote)** — not run from this repo; reached over the network as
  `VLLM_API_BASE`/`VLLM_API_KEY`.

## Migrating from an existing deployment

If you already have litellm/langfuse running elsewhere on this server and
want to move to this repo's config **without losing data**, start at
[`RUNBOOK.md`](./RUNBOOK.md) — do not run `docker compose up` here first.

## Fresh install

1. `cp .env.example .env`, fill in real values (see comments in the file),
   `chmod 600 .env`.
2. In `docker-compose.yml`, remove `external: true` (and the `name:` line)
   from any volume you don't already have existing data for.
3. Edit `litellm/config.yaml` — replace the placeholder `model_list` entries
   with your actual 12 providers.
4. `docker compose up -d`
5. Open Langfuse (`http://localhost:3000` via SSH tunnel — everything here
   is internal-only, nothing is exposed publicly), create your first
   project, and copy its API keys into `.env` as `LANGFUSE_PUBLIC_KEY` /
   `LANGFUSE_SECRET_KEY`, then `docker compose up -d litellm` to pick them up.
6. Mint a virtual key per app/team instead of handing out the master key —
   see the comment at the top of `litellm/config.yaml`.

## Layout

```
docker-compose.yml       # full stack definition
litellm/config.yaml      # model_list, langfuse callback wiring, guardrails
.env.example              # all required secrets/config, documented inline
scripts/
  00_backup_existing_stack.sh  # non-destructive pre-migration backup
RUNBOOK.md                # step-by-step in-place migration + rollback
```

## What's wired up and why

- **LiteLLM -> Langfuse tracing**: `litellm_settings.success_callback` /
  `failure_callback` in `litellm/config.yaml`. For traces to be useful (not
  just a flat ungrouped list), pass `trace_user_id`, `session_id`, and
  `tags` in each request's `extra_body.metadata` — see the comment in that
  file.
- **Evaluations**: not automated by this repo — set them up in the Langfuse
  UI once traces are flowing: build a dataset from real traces, add an
  LLM-as-judge evaluator, then run dataset experiments comparing models
  (e.g. `gpt-oss-130b` vs. a hosted model) or prompt versions.
- **Guardrails**: `guardrails` block in `litellm/config.yaml` runs a
  pre-call prompt-injection check. Start with it enabled only on
  public-facing/agentic virtual keys, verify the false-positive rate, then
  broaden. Guardrail triggers should also get logged as scores on the
  corresponding Langfuse trace so injection-attempt rates are visible
  alongside normal observability data.
- **Network**: single internal `llm-net` Docker bridge network; only
  LiteLLM's and Langfuse's ports are published, both bound to `127.0.0.1`.
  Reach them via SSH tunnel or a VPN (Tailscale/WireGuard) — nothing here is
  meant to be exposed to the public internet.

## Operational basics

- All image tags in `docker-compose.yml` are pinned — check for newer
  stable releases before first deploy, then keep them pinned (no `:latest`)
  so an unattended pull can't break the 12-model config.
- Back up `litellm_postgres_data`, `langfuse_postgres_data`, and
  `langfuse_clickhouse_data` on a schedule (cron + the same approach as
  `scripts/00_backup_existing_stack.sh`) — this is your spend history, key
  config, and all trace/eval data.
- Losing `LANGFUSE_SALT` / `LANGFUSE_ENCRYPTION_KEY` / `LANGFUSE_NEXTAUTH_SECRET`
  after data exists means Langfuse can no longer decrypt stored values.
  Generate them once, then treat them as immutable — store a copy somewhere
  outside the server too.
