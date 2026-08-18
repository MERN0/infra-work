#!/usr/bin/env bash
#
# 00_backup_existing_stack.sh
#
# Run this ON THE SERVER that currently runs your litellm/langfuse stack,
# BEFORE touching anything else in this repo. It is read-only against your
# running containers (it never stops, removes, or modifies them) and writes
# everything it finds into ./backups/<timestamp>/.
#
# What it does:
#   1. Discovers running containers that look like postgres / clickhouse /
#      redis / minio / litellm / langfuse, and the volumes/mounts they use.
#   2. Dumps every database in every detected postgres container (pg_dumpall).
#   3. Archives the data volumes for clickhouse and minio/s3 containers.
#   4. Copies any config files it finds bind-mounted into litellm/langfuse
#      containers (e.g. litellm's config.yaml).
#   5. Writes backups/<timestamp>/MANIFEST.txt summarizing exactly what it
#      found and backed up (container names, image tags, volume names,
#      mount sources) — read this before editing .env or bringing up the
#      new stack, since it tells you the EXISTING volume names you need to
#      reuse in docker-compose.yml so no data is lost.
#
# This script intentionally does NOT stop or remove anything. It is safe to
# run repeatedly.

set -uo pipefail

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/backups/${TIMESTAMP}"
MANIFEST="${BACKUP_ROOT}/MANIFEST.txt"

mkdir -p "${BACKUP_ROOT}"
echo "Backup output directory: ${BACKUP_ROOT}"

log() { echo "$@" | tee -a "${MANIFEST}"; }

log "==================================================================="
log " Pre-migration backup — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "==================================================================="
log ""

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found on PATH. Run this on the server that hosts the stack." >&2
  exit 1
fi

log "--- All running containers ---"
docker ps --format '  {{.Names}}\t{{.Image}}\t{{.Status}}' | tee -a "${MANIFEST}"
log ""

log "--- All docker volumes ---"
docker volume ls --format '  {{.Driver}}\t{{.Name}}' | tee -a "${MANIFEST}"
log ""

# Helper: does a container name match any of the given grep-style patterns?
matches_any() {
  local name="$1"; shift
  for pat in "$@"; do
    if echo "$name" | grep -qiE "$pat"; then return 0; fi
  done
  return 1
}

POSTGRES_CONTAINERS=$(docker ps --format '{{.Names}}' | grep -iE 'postgres|pgsql|(^|-)db($|-)' || true)
CLICKHOUSE_CONTAINERS=$(docker ps --format '{{.Names}}' | grep -iE 'clickhouse' || true)
MINIO_CONTAINERS=$(docker ps --format '{{.Names}}' | grep -iE 'minio' || true)
REDIS_CONTAINERS=$(docker ps --format '{{.Names}}' | grep -iE 'redis' || true)
LITELLM_CONTAINERS=$(docker ps --format '{{.Names}}' | grep -iE 'litellm' || true)
LANGFUSE_CONTAINERS=$(docker ps --format '{{.Names}}' | grep -iE 'langfuse' || true)

log "--- Detected by role ---"
log "postgres-like:   ${POSTGRES_CONTAINERS:-<none found>}"
log "clickhouse:      ${CLICKHOUSE_CONTAINERS:-<none found>}"
log "minio/s3:        ${MINIO_CONTAINERS:-<none found>}"
log "redis:           ${REDIS_CONTAINERS:-<none found>}"
log "litellm:         ${LITELLM_CONTAINERS:-<none found>}"
log "langfuse:        ${LANGFUSE_CONTAINERS:-<none found>}"
log ""
log "If a service you expect is missing above, it may be named differently —"
log "check 'docker ps' output manually and back it up by hand before proceeding."
log ""

# --- Mounts for every relevant container (so we know real volume names) ---
log "--- Mounts for detected containers ---"
for c in ${POSTGRES_CONTAINERS} ${CLICKHOUSE_CONTAINERS} ${MINIO_CONTAINERS} ${REDIS_CONTAINERS} ${LITELLM_CONTAINERS} ${LANGFUSE_CONTAINERS}; do
  log ""
  log "Container: ${c}"
  docker inspect "${c}" \
    --format '{{range .Mounts}}  {{.Type}}  {{.Name}}{{if not .Name}}{{.Source}}{{end}} -> {{.Destination}}
{{end}}' | tee -a "${MANIFEST}"
  docker inspect "${c}" --format '  image: {{.Config.Image}}' | tee -a "${MANIFEST}"
done
log ""

# --- Postgres: dump every database in every detected postgres container ---
mkdir -p "${BACKUP_ROOT}/postgres"
for c in ${POSTGRES_CONTAINERS}; do
  log "--- Dumping postgres container: ${c} ---"
  PGUSER=$(docker exec "${c}" printenv POSTGRES_USER 2>/dev/null || echo "postgres")
  OUT="${BACKUP_ROOT}/postgres/${c}.sql.gz"
  if docker exec "${c}" pg_dumpall -U "${PGUSER}" 2>>"${MANIFEST}" | gzip > "${OUT}"; then
    log "  OK -> ${OUT} ($(du -h "${OUT}" | cut -f1))"
  else
    log "  FAILED to dump ${c} — inspect manually (wrong PGUSER? check MANIFEST for pg_dumpall error above)."
    rm -f "${OUT}"
  fi
done
log ""

# --- Archive a container's data volume via a throwaway alpine reader ---
archive_container_volume() {
  local container="$1" dest_dir="$2"
  local mount
  mount=$(docker inspect "${container}" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/clickhouse"}}{{.Name}}{{end}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{if eq .Destination "/bitnami/minio/data"}}{{.Name}}{{end}}{{end}}' | head -n1)
  if [ -z "${mount}" ]; then
    log "  Could not auto-detect data volume for ${container} — check mounts above and back up manually."
    return
  fi
  mkdir -p "${dest_dir}"
  local out="${dest_dir}/${container}.tar.gz"
  log "  Archiving volume '${mount}' used by ${container} -> ${out}"
  docker run --rm \
    -v "${mount}:/source:ro" \
    -v "${dest_dir}:/backup" \
    alpine sh -c "tar czf /backup/$(basename "${out}") -C /source ." \
    && log "  OK -> ${out} ($(du -h "${out}" | cut -f1))" \
    || log "  FAILED to archive volume for ${container}"
}

mkdir -p "${BACKUP_ROOT}/clickhouse" "${BACKUP_ROOT}/minio"
for c in ${CLICKHOUSE_CONTAINERS}; do
  log "--- Archiving ClickHouse volume: ${c} ---"
  archive_container_volume "${c}" "${BACKUP_ROOT}/clickhouse"
done
for c in ${MINIO_CONTAINERS}; do
  log "--- Archiving MinIO volume: ${c} ---"
  archive_container_volume "${c}" "${BACKUP_ROOT}/minio"
done
log ""

# --- Copy any bind-mounted config files from litellm/langfuse containers ---
mkdir -p "${BACKUP_ROOT}/configs"
for c in ${LITELLM_CONTAINERS} ${LANGFUSE_CONTAINERS}; do
  log "--- Config bind-mounts for ${c} ---"
  docker inspect "${c}" --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}' \
  | while read -r src; do
      [ -z "${src}" ] && continue
      if [ -f "${src}" ]; then
        dest="${BACKUP_ROOT}/configs/$(basename "${c}")_$(basename "${src}")"
        cp "${src}" "${dest}" 2>/dev/null && log "  copied ${src} -> ${dest}"
      fi
    done
done
log ""

log "==================================================================="
log " Backup finished: ${BACKUP_ROOT}"
log "==================================================================="
log ""
log "NEXT STEPS (do not skip):"
log "  1. Read MANIFEST.txt above and note the EXACT volume names for"
log "     postgres/clickhouse/minio found under 'Mounts for detected containers'."
log "  2. Put those exact names into .env as POSTGRES_VOLUME_NAME,"
log "     LITELLM_DB_VOLUME_NAME, CLICKHOUSE_VOLUME_NAME, MINIO_VOLUME_NAME"
log "     (see .env.example) so the new docker-compose.yml attaches to your"
log "     EXISTING data instead of creating empty new volumes."
log "  3. Only after .env is verified, follow RUNBOOK.md to cut over."
log ""
log "The .sql.gz / .tar.gz files in this folder are your rollback safety net"
log "even if the volume-reuse path above works — keep them until you've"
log "verified the new stack in Langfuse's UI and LiteLLM's /health endpoint."
