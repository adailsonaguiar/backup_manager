#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$ROOT_DIR/backups"
LOG_DIR="$ROOT_DIR/logs"

RETENTION_DAYS=30

mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/cleanup_$(date '+%Y%m%d_%H%M%S').log"

{
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Início da limpeza (reteção de $RETENTION_DAYS dias)"

  if [ ! -d "$BACKUP_DIR" ]; then
    echo "Nada a limpar: $BACKUP_DIR não existe"
    exit 0
  fi

  REMOVED=0
  while IFS= read -r file; do
    echo "Removendo: $file"
    rm -f "$file"
    REMOVED=$((REMOVED + 1))
  done < <(find "$BACKUP_DIR" -type f -name '*.dump' -mtime +"$RETENTION_DAYS" -print)

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Removidos: $REMOVED arquivo(s)"
} >> "$LOG_FILE" 2>&1
