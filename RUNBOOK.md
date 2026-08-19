# Migration runbook: existing stack -> this repo's docker-compose.yml

Follow this in order, on the server that currently runs litellm/langfuse.
Do not skip the backup step. Each step says how to tell it worked before
you move to the next one.

## 0. Prerequisites

- `docker` and `docker compose` (v2) available on the server.
- This repo cloned/copied onto the server.
- Enough free disk for a full backup (Postgres dumps + ClickHouse/MinIO
  archives) alongside the live data — check with `df -h`.

## 1. Back up and discover the existing stack (non-destructive)

```bash
cd infra-work
./scripts/00_backup_existing_stack.sh
```

This does **not** stop or modify anything currently running. It writes to
`backups/<timestamp>/` and prints a `MANIFEST.txt` listing:
- every container it found and matched to a role (postgres/clickhouse/minio/redis/litellm/langfuse)
- the exact **volume names** each one uses
- `.sql.gz` dumps of every Postgres database it could reach
- `.tar.gz` archives of the ClickHouse and MinIO data volumes
- copies of any bind-mounted litellm/langfuse config files it found

**Read `backups/<timestamp>/MANIFEST.txt` in full before continuing.** If it
says a service wasn't auto-detected (different container naming), back that
one up manually the same way (`pg_dumpall`, or tar the volume) before
proceeding — do not skip a service just because the script missed it.

## 2. Populate .env

```bash
cp .env.example .env
chmod 600 .env
```

Fill in:
- The 12 provider keys and the vLLM `api_base`/`api_key` (from wherever they
  currently live — old compose file, secrets manager, etc.).
- Langfuse's `NEXTAUTH_SECRET` / `SALT` / `ENCRYPTION_KEY` — **use the
  EXISTING values from your current deployment, not new ones.** These
  encrypt data already stored in Langfuse's Postgres; generating new ones
  makes old encrypted values (e.g. stored API keys inside Langfuse) unreadable.
  Find them in the old compose file's environment block or the copied
  configs under `backups/<timestamp>/configs/`.
- `LANGFUSE_POSTGRES_VOLUME_NAME`, `LANGFUSE_CLICKHOUSE_VOLUME_NAME`,
  `LANGFUSE_MINIO_VOLUME_NAME`, `LITELLM_POSTGRES_VOLUME_NAME` — copy these
  **verbatim** from the "Mounts for detected containers" section of
  `MANIFEST.txt`. This is what makes the migration in-place: the new
  containers mount the same named volumes your data already lives in.

If any of the four volume names truly don't exist yet (first-ever install,
nothing to migrate for that piece), remove `external: true` and the matching
`name:` line for that volume in `docker-compose.yml` instead of leaving the
env var blank — an unset external volume name will make `docker compose up`
fail fast rather than silently doing the wrong thing, which is intentional.

### 2a. Match image versions to what's already on disk (critical for Postgres/ClickHouse/Langfuse)

`docker-compose.yml` defaults every image to the current actual-latest release.
Postgres and ClickHouse data directories are version-format-specific, and
Langfuse v4 has real breaking changes vs v2/v3 — attaching a newer major
version straight to old data can fail to start or silently skip a required
migration. Before step 4, check what's actually running on the old stack:

```bash
docker inspect <old-litellm-db-container>       --format '{{.Config.Image}}'
docker inspect <old-langfuse-postgres-container> --format '{{.Config.Image}}'
docker inspect <old-langfuse-clickhouse-container> --format '{{.Config.Image}}'
docker inspect <old-langfuse-web-container>      --format '{{.Config.Image}}'
```

Set `LITELLM_POSTGRES_IMAGE_TAG`, `LANGFUSE_POSTGRES_IMAGE_TAG`,
`CLICKHOUSE_IMAGE_TAG`, and `LANGFUSE_IMAGE_TAG` in `.env` to those **same
versions** for this cutover — do not let the migration also be a version
upgrade. Once the new stack is verified working on matched versions, upgrade
each piece deliberately and separately (Postgres: `pg_upgrade`; Langfuse:
follow `langfuse.com/self-hosting/upgrade` for the specific version jump).
`LITELLM_IMAGE_TAG`, `REDIS_IMAGE_TAG`, and `MINIO_IMAGE_TAG` are safe to take
at latest-default even during migration — LiteLLM itself is stateless, Redis
here is a fresh non-migrated cache volume, and MinIO's Docker Hub image is
frozen at a single tag regardless (see `.env.example`).

## 3. Stop the old stack — without deleting volumes

```bash
cd /path/to/old/deployment
docker compose down          # NOT `docker compose down -v` — that deletes volumes
```

Confirm the volumes still exist after this:
```bash
docker volume ls | grep -E 'postgres|clickhouse|minio'
```
They should still be listed. If your old deployment used a different
`docker compose` project name and this repo's `name: llm-platform` in
`docker-compose.yml` would create a naming collision, that's fine — the
external volumes are referenced by their literal names, not by project name.

## 4. Bring up the new stack

```bash
cd infra-work
docker compose up -d
docker compose ps
```

Watch for any service failing to start because an external volume doesn't
exist — that means a name in `.env` doesn't exactly match `docker volume ls`
output. Fix the `.env` value and re-run rather than letting compose create a
new empty volume under a different name.

## 5. Verify data survived

- **Langfuse**: open an SSH tunnel (`ssh -L 3000:127.0.0.1:3000 your-server`)
  and browse to `http://localhost:3000`. Log in with your existing account,
  confirm old projects, traces, and API keys are all present.
- **LiteLLM**: `curl http://localhost:4000/health/liveliness` (via tunnel or
  on-box) should return healthy. Then `curl -H "Authorization: Bearer $LITELLM_MASTER_KEY" http://localhost:4000/key/list` should show your existing virtual keys if LiteLLM already had its own DB before.
- Send one real request through LiteLLM to `gpt-oss-130b` and confirm a new
  trace appears in Langfuse's UI within a few seconds — this proves the
  LiteLLM -> Langfuse callback wiring (config.yaml `success_callback`) is
  live end-to-end.

## 6. Only after verification: clean up

Keep `backups/<timestamp>/` for at least a few weeks. Once you're confident
in the new stack, decommission the old compose project's *config* (not the
shared volumes, which the new stack now owns) and rotate `.env` permissions/
storage per your normal secrets handling.

## Rollback

If step 5 fails:
```bash
cd infra-work && docker compose down   # again, no -v
cd /path/to/old/deployment && docker compose up -d
```
The old stack's containers are gone but the named volumes were never
touched, so bringing the old compose file back up reattaches to the same
data. The `backups/<timestamp>/` dumps are the last-resort fallback if a
volume itself was somehow corrupted — restore a Postgres dump with
`gunzip -c backups/<ts>/postgres/<container>.sql.gz | docker exec -i <new-postgres-container> psql -U <user>`.
