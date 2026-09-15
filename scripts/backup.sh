#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$ROOT_DIR/config/databases.yml"
BACKUP_DIR="$ROOT_DIR/backups"
LOG_DIR="$ROOT_DIR/logs"
ENV_FILE="$ROOT_DIR/.env"

RETENTION_DAYS=30
COMPRESS_LEVEL=6

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
  log "ERRO: $*" >&2
  exit 1
}

command -v yq >/dev/null 2>&1 || fail "yq não encontrado. Instale: https://github.com/mikefarah/yq"
command -v pg_dump >/dev/null 2>&1 || fail "pg_dump não encontrado. Instale: sudo apt install -y postgresql-client"

[ -f "$CONFIG_FILE" ] || fail "Arquivo de configuração não encontrado: $CONFIG_FILE"

mkdir -p "$BACKUP_DIR" "$LOG_DIR"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

LOG_FILE="$LOG_DIR/backup_$(date '+%Y%m%d_%H%M%S').log"
exec > >(tee -a "$LOG_FILE") 2>&1

log "Início do backup"

COUNT="$(yq '.databases | length' "$CONFIG_FILE")"
SUCCESS=0
FAILED=0

for ((i = 0; i < COUNT; i++)); do
  NAME="$(yq -r ".databases[$i].name" "$CONFIG_FILE")"
  HOST="$(yq -r ".databases[$i].host" "$CONFIG_FILE")"
  PORT="$(yq -r ".databases[$i].port" "$CONFIG_FILE")"
  DATABASE="$(yq -r ".databases[$i].database" "$CONFIG_FILE")"
  USER="$(yq -r ".databases[$i].user" "$CONFIG_FILE")"

  ENV_KEY="PGPASSWORD_$(echo "$NAME" | tr '[:lower:]-' '[:upper:]_')"
  PASSWORD="${!ENV_KEY:-${PGPASSWORD:-}}"

  if [ -z "$PASSWORD" ]; then
    log "✗ $NAME — senha não definida (use $ENV_KEY ou PGPASSWORD)"
    FAILED=$((FAILED + 1))
    continue
  fi

  DEST_DIR="$BACKUP_DIR/$NAME"
  mkdir -p "$DEST_DIR"
  DUMP_FILE="$DEST_DIR/${NAME}_$(date '+%Y%m%d_%H%M%S').dump"

  if PGPASSWORD="$PASSWORD" pg_dump \
      --host="$HOST" \
      --port="$PORT" \
      --username="$USER" \
      --dbname="$DATABASE" \
      --format=custom \
      --compress="$COMPRESS_LEVEL" \
      --no-password \
      --file="$DUMP_FILE"; then

    SIZE_BYTES="$(stat -c %s "$DUMP_FILE" 2>/dev/null || stat -f %z "$DUMP_FILE")"
    SIZE_MB="$(awk -v b="$SIZE_BYTES" 'BEGIN { printf "%.0f", b / 1024 / 1024 }')"
    log "✓ $NAME  $SIZE_MB MB"
    SUCCESS=$((SUCCESS + 1))
  else
    log "✗ $NAME — falha no pg_dump"
    FAILED=$((FAILED + 1))
  fi
done

log "Removendo backups com mais de $RETENTION_DAYS dias"
  bash "$SCRIPT_DIR/cleanup.sh" || log "Aviso: cleanup retornou erro"

TOTAL=$((SUCCESS + FAILED))
log "Backup concluído: $SUCCESS/$TOTAL"
echo ""
echo "Backup concluído: $SUCCESS/$TOTAL"

[ "$FAILED" -eq 0 ]
