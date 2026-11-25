#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

required=(PGHOST PGPORT PGDATABASE PGUSER S3_BUCKET AWS_REGION BACKUP_NAME)
for key in "${required[@]}"; do
  if [[ -z "${!key:-}" ]]; then
    printf 'Configuração obrigatória ausente: %s\n' "$key" >&2
    exit 1
  fi
done

[[ "$PGPORT" =~ ^[0-9]+$ ]] && (( 10#$PGPORT >= 1 && 10#$PGPORT <= 65535 )) || {
  echo 'PGPORT inválida' >&2
  exit 1
}
[[ "$BACKUP_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || {
  echo 'BACKUP_NAME deve conter somente letras, números, _ ou -' >&2
  exit 1
}
[[ "$S3_BUCKET" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || {
  echo 'S3_BUCKET inválido' >&2
  exit 1
}

install -d -m 700 /run/backup /var/backups/postgresql
for name in pgpass aws_credentials; do
  [[ -s "/run/secrets/$name" ]] || {
    printf 'Secret ausente ou vazio: %s\n' "$name" >&2
    exit 1
  }
  install -m 600 "/run/secrets/$name" "/run/backup/$name"
done

# AWS CLI must not fall back to credentials in the image or metadata service.
# The mounted credentials file uses the [default] profile.
: > /run/backup/aws_config
chmod 600 /run/backup/aws_config

if [[ -n "${PGSSLROOTCERT:-}" && ! -r "$PGSSLROOTCERT" ]]; then
  echo 'PGSSLROOTCERT não está acessível' >&2
  exit 1
fi

# Serialize only non-secret settings, safely quoted for the scheduled shell.
{
  for key in PGHOST PGPORT PGDATABASE PGUSER S3_BUCKET AWS_REGION BACKUP_NAME; do
    printf 'export %s=%q\n' "$key" "${!key}"
  done
  for key in PGSSLMODE PGSSLROOTCERT PGCONNECT_TIMEOUT; do
    printf 'export %s=%q\n' "$key" "${!key:-}"
  done
} > /run/backup/config
chmod 600 /run/backup/config

echo 'Backup agendado para 00:00, 06:00, 12:00 e 18:00 UTC.'
exec cron -f
