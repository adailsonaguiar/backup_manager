#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

log() {
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"
}

trap 'log "ERRO: backup falhou na linha $LINENO" >&2' ERR

# cron does not inherit the container's environment. This file contains only
# non-secret settings; credentials are supplied through mounted files.
source /run/backup/config
export PGPASSFILE=/run/backup/pgpass
export AWS_SHARED_CREDENTIALS_FILE=/run/backup/aws_credentials
export AWS_CONFIG_FILE=/run/backup/aws_config
export AWS_EC2_METADATA_DISABLED=true
export AWS_RETRY_MODE=standard
export AWS_MAX_ATTEMPTS=5
export AWS_PAGER=

exec 9>/run/backup/backup.lock
if ! flock -n 9; then
  log 'Outra execução está em andamento; backup não iniciado.' >&2
  exit 1
fi

WORK_DIR=$(mktemp -d /var/backups/postgresql/job.XXXXXXXX)
trap 'rm -rf -- "$WORK_DIR"' EXIT

STAMP=$(date -u +%Y-%m-%dT%H-%M-%S-%NZ)
FILE="$WORK_DIR/backup-$STAMP.dump"
DEST="s3://$S3_BUCKET/postgresql/$PGDATABASE/backup-$STAMP.dump"

log "Iniciando backup de $PGDATABASE"
pg_dump --no-password --format=custom --file="$FILE"
test -s "$FILE"
pg_restore --list "$FILE" >/dev/null

log "Enviando para $DEST"
aws --region "$AWS_REGION" s3 cp "$FILE" "$DEST" --sse AES256 --only-show-errors
log 'Backup enviado com sucesso.'

# A missing URL disables monitoring. A failed Push is logged and fails the job:
# the dump is already safely in S3, but monitoring must not report success.
if [[ -s /run/secrets/kuma_push_url ]]; then
  PUSH_URL=$(cat /run/secrets/kuma_push_url)
  if [[ ! "$PUSH_URL" =~ ^https?:// ]]; then
    log 'ERRO: URL do Uptime Kuma deve começar com https:// (ou http:// na rede interna).' >&2
    exit 1
  fi
  curl --fail --silent --show-error --max-time 15 --retry 2 --output /dev/null "$PUSH_URL"
  log 'Monitor Uptime Kuma atualizado.'
fi
